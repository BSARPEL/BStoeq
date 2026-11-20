import AppKit
import ApplicationServices
import BStoeqCore

/// Preserve the user's mouse-button intent. Prefer the matching accessibility
/// action; otherwise forward a click only to a freshly verified menu-bar target.
@MainActor final class MenuItemAccess {
    private var task: Task<Void, Never>?
    private(set) var isInteracting = false
    var onUnavailable: (() -> Void)?

    func cancel() {
        task?.cancel(); task = nil; isInteracting = false
    }

    func open(_ app: BarApp, action: MenuActivation) {
        cancel()
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first?.processIdentifier else {
            onUnavailable?(); return
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
        isInteracting = true
        task = Task { [weak self] in
            let operation = Task.detached(priority: .userInitiated) {
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, AXIsProcessTrusted() else { return false }
                    let items = Self.items(pid: pid)
                    // Prefer an item that explicitly supports the intended gesture.
                    if let item = items.first(where: { action.supports(Self.actions($0)) }) {
                        guard !Task.isCancelled else { return false }
                        let result = AXUIElementPerformAction(item, action.accessibilityAction as CFString)
                        if result == .success || result == .cannotComplete { return true }
                        // A timeout may mean a tracking menu is already open. Never
                        // follow it with a second click that would dismiss that menu.
                        if result != .actionUnsupported && result != .notImplemented { return false }
                    }
                    for item in items {
                        guard !Task.isCancelled else { return false }
                        if await Self.forwardClick(item: item, pid: pid, action: action, screens: screens) { return true }
                    }
                }
                return false
            }
            let opened = await withTaskCancellationHandler { await operation.value }
                onCancel: { operation.cancel() }
            guard !Task.isCancelled, let self else { return }
            if !opened { self.isInteracting = false; self.onUnavailable?(); return }
            try? await Task.sleep(for: .milliseconds(700))
            while !Task.isCancelled {
                let tracking = await Task.detached(priority: .utility) { Self.targetHasFocus(pid: pid) }.value
                guard !Task.isCancelled else { return }
                self.isInteracting = tracking
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    nonisolated private static func items(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let value = attribute(app, "AXExtrasMenuBar"), CFGetTypeID(value) == AXUIElementGetTypeID(),
              let children = attribute(value as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        for item in children { AXUIElementSetMessagingTimeout(item, 0.3) }
        return children
    }
    nonisolated private static func actions(_ item: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(item, &value) == .success else { return [] }
        return value as? [String] ?? []
    }
    nonisolated private static func frame(_ item: AXUIElement) -> CGRect? {
        guard let p = attribute(item, kAXPositionAttribute), let s = attribute(item, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    nonisolated private static func targetAtPoint(_ point: CGPoint, pid: pid_t) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var value: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &value) == .success,
              let value else { return false }
        var owner: pid_t = 0
        return AXUIElementGetPid(value, &owner) == .success && owner == pid
    }
    nonisolated private static func forwardClick(item: AXUIElement, pid: pid_t, action: MenuActivation, screens: [CGRect]) async -> Bool {
        guard let rect = frame(item), MenuTargetGeometry.isOnMenuBar(rect, screens: screens) else { return false }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard targetAtPoint(point, pid: pid), let original = CGEvent(source: nil)?.location else { return false }
        let button: CGMouseButton = action == .contextMenu ? .right : .left
        let downType: CGEventType = action == .contextMenu ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = action == .contextMenu ? .rightMouseUp : .leftMouseUp
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button),
              !Task.isCancelled else { return false }
        // WindowServer can route a menu-bar click using the current pointer location.
        // Restore only if the user has not moved their pointer in the meantime.
        CGWarpMouseCursorPosition(point)
        defer {
            if let current = CGEvent(source: nil)?.location, hypot(current.x - point.x, current.y - point.y) < 4 {
                CGWarpMouseCursorPosition(original)
            }
        }
        try? await Task.sleep(for: .milliseconds(25))
        guard !Task.isCancelled, AXIsProcessTrusted(), targetAtPoint(point, pid: pid) else { return false }
        down.flags = []; up.flags = []
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(35))
        // Always release a mouse button that we pressed, even after cancellation.
        up.post(tap: .cghidEventTap)
        return true
    }
    nonisolated private static func targetHasFocus(pid: pid_t) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let value = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        var owner: pid_t = 0
        // Include custom popovers and controls, not only AXMenu / AXMenuItem.
        return AXUIElementGetPid(value as! AXUIElement, &owner) == .success && owner == pid
    }
}
