import AppKit
import ApplicationServices
import BStoeqCore

struct MenuBarLayoutItem: Identifiable, Equatable, Sendable {
    let id: String
    let bundleID: String
    let name: String
    let pid: Int32
    let frame: CGRect
    let screenIndex: Int
    let systemIdentifier: String?
    let movable: Bool
}

/// An editor of the actual status items, never a separately saved preview order.
@MainActor final class MenuBarLayoutController: ObservableObject {
    @Published private(set) var items: [MenuBarLayoutItem] = []
    @Published private(set) var refreshing = false
    @Published private(set) var moving = false
    @Published private(set) var error: UserMessage?
    private var active = false
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    private var gesture: MenuBarDragGesture?
    private var refreshTimer: Timer?
    private var permissionError: UserMessage { UserMessage("Simgeleri düzenlemek için BStoeq’in Erişilebilirlik iznini aç.") }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard !active else { refresh(); return }
        active = true
        let nc = NotificationCenter.default
        observe(nc, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.cancelMove(); controller.refresh()
        }
        observe(nc, NSApplication.didHideNotification) { $0.cancelMove() }
        observe(nc, NSApplication.willTerminateNotification) { $0.stop() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.stop() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active, !self.refreshing, !self.moving,
                      NSEvent.pressedMouseButtons == 0, AppModel.settingsWindowVisible() else { return }
                self.refresh()
            }
        }
        refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (MenuBarLayoutController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    /// Synchronously release the posted mouse button before hiding or shutdown.
    func cancelMove() {
        gesture?.cancel()
        moveTask?.cancel()
    }

    func stop() {
        active = false; generation += 1
        cancelMove(); refreshTask?.cancel(); refreshTask = nil; refreshing = false
        refreshTimer?.invalidate(); refreshTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    func refresh() {
        guard active, !moving else { return }
        refreshTask?.cancel(); generation += 1
        let current = generation
        guard AXIsProcessTrusted() else {
            items = []; refreshing = false
            error = UserMessage("Simgeleri düzenlemek için BStoeq’in Erişilebilirlik iznini aç.")
            return
        }
        refreshing = true
        let input = Self.input()
        refreshTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { Self.scan(input) }
            let snapshot = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.active, self.generation == current else { return }
            self.items = snapshot.map(\.item); self.refreshing = false
            if AXIsProcessTrusted(), self.error == self.permissionError { self.error = nil }
        }
    }

    func move(_ sourceID: String, before targetID: String) { move(sourceID, targetID: targetID, before: true) }
    func moveAfter(_ sourceID: String, targetID: String) { move(sourceID, targetID: targetID, before: false) }

    private func move(_ sourceID: String, targetID: String, before: Bool) {
        guard active, !moving, sourceID != targetID else { return }
        guard AXIsProcessTrusted() else {
            error = UserMessage("Simgeleri düzenlemek için BStoeq’in Erişilebilirlik iznini aç."); return
        }
        guard let oldSource = items.first(where: { $0.id == sourceID }), oldSource.movable,
              let oldTarget = items.first(where: { $0.id == targetID }) else {
            error = UserMessage("Bu simgenin konumu macOS tarafından sabitlenmiş olabilir."); return
        }
        guard oldSource.screenIndex == oldTarget.screenIndex else {
            error = UserMessage("Simgeleri aynı ekranın menü çubuğu içinde taşı."); return
        }
        generation += 1; refreshTask?.cancel(); refreshing = false
        moving = true; error = nil
        let input = Self.input()
        let session = MenuBarDragGesture()
        gesture = session
        moveTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                await Self.performMove(sourceID: sourceID, targetID: targetID, before: before,
                                       input: input, gesture: session)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: {
                session.cancel(); worker.cancel()
            }
            guard let self else { return }
            self.gesture = nil; self.moveTask = nil; self.moving = false
            if self.active, !Task.isCancelled {
                if let message = result { self.error = UserMessage(message) }
                self.refresh()
            }
        }
    }

    private struct Candidate: Sendable { let pid: pid_t; let bundleID: String; let name: String }
    private struct Input: Sendable { let candidates: [Candidate]; let screens: [CGRect] }
    private struct Entry: @unchecked Sendable { let item: MenuBarLayoutItem; let element: AXUIElement }

    private static func input() -> Input {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return Input(candidates: NSWorkspace.shared.runningApplications.compactMap {
            guard let id = $0.bundleIdentifier else { return nil }
            return Candidate(pid: $0.processIdentifier, bundleID: id, name: $0.localizedName ?? id)
        }, screens: NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        })
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    nonisolated private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    nonisolated private static func matchesHit(_ element: AXUIElement, pid: pid_t, point: CGPoint) -> Bool {
        let root = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return false }
        var owner: pid_t = 0
        guard AXUIElementGetPid(current, &owner) == .success, owner == pid else { return false }
        // AX can return a child button of a menu-bar item. Its ancestor must be
        // this exact item, not merely another icon owned by the same process.
        for _ in 0..<5 {
            if CFEqual(current, element) { return true }
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        return false
    }

    nonisolated private static func scan(_ input: Input) -> [Entry] {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return [] }
        var entries: [Entry] = []; var seen = Set<String>()
        for app in input.candidates {
            guard !Task.isCancelled else { return [] }
            let root = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(root, 0.08)
            guard let menu = attribute(root, "AXExtrasMenuBar"), CFGetTypeID(menu) == AXUIElementGetTypeID() else { continue }
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 5, !Task.isCancelled else { return }
                AXUIElementSetMessagingTimeout(element, 0.08)
                if attribute(element, kAXRoleAttribute) as? String == kAXMenuBarItemRole {
                    guard let rect = frame(element), rect.width >= 4,
                          let screen = input.screens.firstIndex(where: { MenuTargetGeometry.isOnMenuBar(rect, screens: [$0]) }),
                          matchesHit(element, pid: app.pid, point: CGPoint(x: rect.midX, y: rect.midY)) else { return }
                    let id = "\(app.pid):\(CFHash(element))"
                    guard seen.insert(id).inserted else { return }
                    let identifier = attribute(element, kAXIdentifierAttribute) as? String
                    let description = attribute(element, kAXDescriptionAttribute) as? String
                    let title = attribute(element, kAXTitleAttribute) as? String
                    let named: String
                    switch identifier {
                    case "com.apple.menuextra.wifi": named = "Wi‑Fi"
                    case "com.apple.menuextra.battery": named = "Pil"
                    case "com.apple.menuextra.controlcenter": named = "Denetim Merkezi"
                    case "com.apple.menuextra.clock": named = "Saat"
                    default:
                        let detail = [description, title].compactMap { $0 }.first { !$0.isEmpty }
                        named = app.bundleID.hasPrefix("com.apple.") ? (detail ?? app.name) : app.name
                    }
                    let fixed = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"].contains(identifier ?? "")
                    entries.append(Entry(item: MenuBarLayoutItem(id: id, bundleID: app.bundleID, name: named,
                        pid: app.pid, frame: rect, screenIndex: screen, systemIdentifier: identifier, movable: !fixed), element: element))
                    return
                }
                for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
            }
            visit(menu as! AXUIElement, depth: 0)
        }
        return entries.sorted {
            if $0.item.screenIndex != $1.item.screenIndex { return $0.item.screenIndex < $1.item.screenIndex }
            return $0.item.frame.minX < $1.item.frame.minX
        }
    }

    nonisolated private static func performMove(sourceID: String, targetID: String, before: Bool,
                                               input: Input, gesture: MenuBarDragGesture) async -> String? {
        defer { gesture.finish() }
        guard !Task.isCancelled else { return nil }
        let snapshot = scan(input)
        guard let source = snapshot.first(where: { $0.item.id == sourceID }), source.item.movable,
              let target = snapshot.first(where: { $0.item.id == targetID }),
              source.item.screenIndex == target.item.screenIndex,
              let destination = MenuBarReorderGeometry.destination(source: source.item.frame, target: target.item.frame,
                        screen: input.screens[source.item.screenIndex], before: before) else {
            return "Simgenin konumu değişti veya simgeye ulaşılamıyor. Yenile ve tekrar dene."
        }
        let screenOrder = snapshot.filter { $0.item.screenIndex == source.item.screenIndex }.map(\.item.id)
        if MenuBarReorderGeometry.areAdjacent(sourceID: sourceID, targetID: targetID, order: screenOrder, before: before) { return nil }
        let point = CGPoint(x: source.item.frame.midX, y: source.item.frame.midY)
        let targetPoint = CGPoint(x: target.item.frame.midX, y: target.item.frame.midY)
        guard matchesHit(source.element, pid: source.item.pid, point: point),
              matchesHit(target.element, pid: target.item.pid, point: targetPoint),
              !Task.isCancelled, gesture.prepare(at: point) else {
            return "İmleç kullanımda veya simgeye ulaşılamıyor. Sürüklemeyi bitirip tekrar dene."
        }
        try? await Task.sleep(for: .milliseconds(35))
        guard !Task.isCancelled, AXIsProcessTrusted(),
              matchesHit(source.element, pid: source.item.pid, point: point),
              matchesHit(target.element, pid: target.item.pid, point: targetPoint), gesture.begin() else {
            return "Simge taşınamadı. Menü çubuğunu yenileyip tekrar dene."
        }
        try? await Task.sleep(for: .milliseconds(60))
        for step in 1...16 {
            guard !Task.isCancelled, AXIsProcessTrusted() else { return nil }
            let progress = CGFloat(step) / 16
            let next = CGPoint(x: point.x + (destination.x - point.x) * progress, y: point.y)
            guard gesture.advance(to: next) else { return "İmleç hareket ettiği için taşıma durduruldu. Tekrar deneyebilirsin." }
            try? await Task.sleep(for: .milliseconds(18))
        }
        gesture.finish()
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return nil }
            if let actualSource = frame(source.element), let actualTarget = frame(target.element),
               MenuTargetGeometry.isOnMenuBar(actualSource, screens: [input.screens[source.item.screenIndex]]),
               MenuTargetGeometry.isOnMenuBar(actualTarget, screens: [input.screens[source.item.screenIndex]]),
               matchesHit(source.element, pid: source.item.pid, point: CGPoint(x: actualSource.midX, y: actualSource.midY)),
               matchesHit(target.element, pid: target.item.pid, point: CGPoint(x: actualTarget.midX, y: actualTarget.midY)),
               MenuBarReorderGeometry.hasRequestedOrder(source: actualSource, target: actualTarget, before: before) {
                let actualOrder = scan(input).filter { $0.item.screenIndex == source.item.screenIndex }.map(\.item.id)
                if MenuBarReorderGeometry.areAdjacent(sourceID: sourceID, targetID: targetID, order: actualOrder, before: before) { return nil }
            }
        }
        return "macOS bu taşımayı uygulamadı. Simge sabit olabilir; üst çubukta ⌘ tuşuyla sürüklemeyi deneyebilirsin."
    }
}

/// Main-thread cancellation and background posting share one lock. Returning
/// from cancel guarantees no held button and no future drag posts from this job.
private final class MenuBarDragGesture: @unchecked Sendable {
    private let lock = NSLock()
    private let source = CGEventSource(stateID: .combinedSessionState)
    private var cancelled = false
    private var held = false
    private var prepared = false
    private var original = CGPoint.zero
    private var last = CGPoint.zero

    func prepare(at point: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right),
              let current = CGEvent(source: nil)?.location else { return false }
        source?.localEventsSuppressionInterval = 0
        original = current; last = point; prepared = true
        return CGWarpMouseCursorPosition(point) == .success
    }
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, prepared, pointerAtLast(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right),
              post(.leftMouseDown, at: last) else { return false }
        held = true; return true
    }
    func advance(to point: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, held else { return false }
        guard pointerAtLast() else { cancelled = true; release(restore: false); return false }
        // Warp and event must remain under the same lock as synchronous cancel.
        guard CGWarpMouseCursorPosition(point) == .success, post(.leftMouseDragged, at: point) else {
            cancelled = true; release(restore: false); return false
        }
        last = point; return true
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        release(restore: !cancelled)
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; release(restore: false)
    }
    private func pointerAtLast() -> Bool {
        guard let current = CGEvent(source: nil)?.location else { return false }
        return hypot(current.x - last.x, current.y - last.y) < 8
    }
    private func release(restore: Bool) {
        let mayRestore = prepared && restore && pointerAtLast()
        if held { _ = post(.leftMouseUp, at: last); held = false }
        if mayRestore { CGWarpMouseCursorPosition(original) }
        prepared = false
    }
    private func post(_ type: CGEventType, at point: CGPoint) -> Bool {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return false }
        event.flags = .maskCommand
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: 0x4261726c6574)
        event.post(tap: .cghidEventTap)
        return true
    }
}
