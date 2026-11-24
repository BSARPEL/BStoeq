import AppKit
import ConvertCore

/// Notices a file drag in any app without a permission: mouse monitors wake it, then it reads the primary
/// button, the modifier keys and the drag pasteboard's change count every 16 ms until the button comes up.
/// What that means is `DragTracker`'s to decide. Reads only the drag pasteboard, and its contents only when
/// the ring opens. Never posts or synthesizes events.
@MainActor final class DragMonitor {
    /// The ring should open: the pointer in Cocoa coordinates, the dragged files (at most
    /// `DragTracker.fileLimit`) and how many distinct files were dragged in all.
    var onOpen: ((NSPoint, [URL], Int) -> Void)?
    /// The button came up, or a new press arrived, while the ring was open.
    var onClose: (() -> Void)?

    private let pasteboard = NSPasteboard(name: .drag)
    private var tracker = DragTracker()
    private var monitors: [Any] = []
    private var sampler: Timer?
    private var refresher: Timer?
    private var activity: NSObjectProtocol?

    func setEnabled(_ enabled: Bool, trigger: DonutTrigger, finderOnly: Bool) {
        guard enabled else { stop(); return }
        tracker.trigger = trigger; tracker.finderOnly = finderOnly
        guard monitors.isEmpty else { return }
        tracker = DragTracker(trigger: trigger, finderOnly: finderOnly, changeCount: pasteboard.changeCount)
        let press: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pressed() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: press) { monitors.append(global) }
        // Global monitors never see presses in our own windows (the converter page's drop zone).
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in press(event); return event }) {
            monitors.append(local)
        }
        // Some trackpad drags arrive without a mouse-down: follow them from their first movement.
        if let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.startSampling() }
        }) { monitors.append(dragged) }
        let refresher = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresher.tolerance = 0.5
        RunLoop.main.add(refresher, forMode: .common)
        self.refresher = refresher
    }

    /// The ring was closed while the button is still down: it stays closed until the key is pressed anew.
    func dismiss() { tracker.dismiss() }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        refresher?.invalidate(); refresher = nil
        stopSampling()
        tracker = DragTracker(trigger: tracker.trigger, finderOnly: tracker.finderOnly)
    }

    private func pressed() {
        if tracker.press(changeCount: pasteboard.changeCount) == .close { onClose?() }
        startSampling()
    }

    private func startSampling() {
        guard sampler == nil, !monitors.isEmpty else { return }
        // App Nap stretches the timers of an app without visible windows: drags went unnoticed after idling.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Following a drag")
        // Common modes: the default mode pauses while a menu or another tracking loop runs.
        let sampler = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        RunLoop.main.add(sampler, forMode: .common)
        self.sampler = sampler
        sample()
    }

    private func stopSampling() {
        sampler?.invalidate(); sampler = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Between presses: a press that was missed starts sampling; otherwise the baseline count is refreshed,
    /// since an app may write the drag pasteboard after its drop.
    private func refresh() {
        guard sampler == nil else { return }
        if NSEvent.pressedMouseButtons & 1 == 1 { startSampling(); return }
        _ = tracker.update(DragTracker.Sample(buttonDown: false, changeCount: pasteboard.changeCount))
    }

    private func sample() {
        let down = NSEvent.pressedMouseButtons & 1 == 1, count = pasteboard.changeCount
        let types = down && tracker.wantsTypes(changeCount: count) ? (pasteboard.types ?? []).map(\.rawValue) : nil
        let action = tracker.update(DragTracker.Sample(buttonDown: down, changeCount: count, types: types,
                                                       modifiers: NSEvent.modifierFlags.rawValue, time: ProcessInfo.processInfo.systemUptime))
        if !down { stopSampling() }
        switch action {
        case .open: open()
        case .close: onClose?()
        case .none: break
        }
    }

    private func open() {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        let found = DragTracker.files(urls)
        guard !found.files.isEmpty, let onOpen else { tracker.dismiss(); return }
        onOpen(NSEvent.mouseLocation, found.files, found.total)
    }
}
