import AppKit
import ApplicationServices

/// macOS 27 renders status buttons in a system-owned window, so a tracking
/// area on NSStatusBarButton cannot observe hover. Read our own AX item only
/// while the pointer is in the menu bar. Never synthesize mouse events.
@MainActor final class HoverMonitor {
    private var timer: Timer?
    private var enteredAt: Date?
    private var fired = false
    private var frames: [CGRect] = []
    private var lastRead = Date.distantPast
    var onHover: (() -> Void)?

    func setEnabled(_ enabled: Bool) {
        if !enabled { stop(); return }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        enteredAt = nil; fired = false; lastRead = .distantPast
    }
    /// A click or a Command-drag is the user's own answer. Re-arming here would let
    /// the hover reopen what that click just closed while the pointer still rests on
    /// the icon, so wait until the pointer has left it.
    func pointerUsed() {
        enteredAt = nil; fired = true
    }
    private func tick() {
        // Native Command-drag rearranges status items; hover must not interrupt it.
        guard !NSEvent.modifierFlags.contains(.command), NSEvent.pressedMouseButtons == 0 else {
            pointerUsed(); return
        }
        guard AXIsProcessTrusted(), let primary = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        let screens = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: primary.frame.maxY - $0.frame.maxY,
                   width: $0.frame.width, height: $0.frame.height)
        }
        guard let target = screens.first(where: { $0.contains(point) && point.y < $0.minY + 40 }) else {
            enteredAt = nil; fired = false; return
        }
        if Date().timeIntervalSince(lastRead) > 0.75 { frames = readFrames(); lastRead = Date() }
        let inside = frames.contains { frame in
            guard let source = screens.first(where: { $0.contains(frame.origin) }) else { return false }
            let projected = CGRect(x: target.maxX - (source.maxX - frame.minX),
                                   y: target.minY + frame.minY - source.minY,
                                   width: frame.width, height: frame.height)
            return projected.contains(point)
        }
        guard inside else { enteredAt = nil; fired = false; return }
        if enteredAt == nil { enteredAt = Date() }
        if !fired, let enteredAt, Date().timeIntervalSince(enteredAt) >= 0.35 {
            fired = true; onHover?()
        }
    }
    private func readFrames() -> [CGRect] {
        let root = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, "AXExtrasMenuBar" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return [] }
        let bar = value as! AXUIElement
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return [] }
        return elements.compactMap { element in
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
                  CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero; var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: origin, size: extent)
        }
    }
}
