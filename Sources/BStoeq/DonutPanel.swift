import AppKit
import SwiftUI
import BStoeqCore
import ConvertCore

/// The ring at the pointer while files are dragged: the one entry point the app delegate drives.
/// `DragMonitor` says when it opens and closes, a reused non-activating panel takes the drop, and
/// `ConverterManager.drop` does the work; `ConversionHUD` then shows the job where the ring was.
/// The panel never becomes key and never activates the app: the drag belongs to Finder.
@MainActor final class DonutController {
    private let manager: ConverterManager
    private weak var model: AppModel?
    private let monitor = DragMonitor()
    private let hud: ConversionHUD
    private let ring = DonutView.Model()
    private var panel: NSPanel?
    /// What the ring acts on, read when it opened (at most `DragTracker.fileLimit`), and how many were dragged.
    private var files: [URL] = []
    private var total = 0
    /// Slices whose conversion would move an original to the Trash (the engine's rule, with the stored settings).
    private var trashing = Set<String>()
    /// The drag's operation mask allows none of copy, generic and link over the hovered slice.
    private var refused = false
    /// Invalidates the delayed close and the failsafe of an earlier ring.
    private var generation = 0
    private var keyTimer: Timer?
    private var escapeDown = false, tabDown = false
    private var dwell: Timer?
    private var dwellArmed = true
    private var lastScroll: TimeInterval = -1
    private var scrollMonitors: [Any] = []

    init(manager: ConverterManager, model: AppModel) {
        self.manager = manager; self.model = model
        hud = ConversionHUD(manager: manager,
                            localizer: { [weak model] in model?.localizer ?? Localizer(language: .system) },
                            scheme: { [weak model] in Self.scheme(model?.preferences.appearance) })
        monitor.onOpen = { [weak self] pointer, files, total in self?.open(at: pointer, files: files, total: total) }
        monitor.onClose = { [weak self] in self?.released() }
    }

    /// Called from `AppDelegate.updateStatus()`: off while the feature is off and while the menu bar is
    /// being arranged. The small rings of running jobs stay either way.
    func setEnabled(_ enabled: Bool, trigger: DonutTrigger, finderOnly: Bool) {
        monitor.setEnabled(enabled, trigger: trigger, finderOnly: finderOnly)
        if !enabled { close() }
    }

    /// Quit.
    func stop() {
        monitor.stop(); close(); hud.stop()
        panel = nil
    }

    private var localizer: Localizer { model?.localizer ?? Localizer(language: .system) }
    private func L(_ key: String, _ arguments: CVarArg...) -> String { localizer.text(key, arguments: arguments) }

    private static func scheme(_ appearance: String?) -> ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }

    // MARK: Opening and closing

    private func open(at pointer: NSPoint, files: [URL], total: Int) {
        close()
        let faces = manager.faces(for: files)
        guard !faces.front.isEmpty,
              let screen = NSScreen.containing(pointer) ?? NSScreen.main ?? NSScreen.screens.first else { monitor.dismiss(); return }
        generation += 1
        self.files = files; self.total = total
        trashing = trashingSlices(faces, files: files)
        refused = false; dwellArmed = true; lastScroll = -1
        ring.reset(faces: faces, count: files.count, localizer: localizer, scheme: Self.scheme(model?.preferences.appearance))
        let side = DonutView.side
        let centre = DonutGeometry.centre(near: pointer, extent: side, in: screen.visibleFrame)
        let frame = NSRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        let panel = self.panel ?? makePanel(side: side)
        self.panel = panel
        panel.title = L("Dönüştürme halkası")
        panel.setFrame(frame, display: true)
        // Where the pointer is now decides the first line: usually the hub, unless the screen edge moved the ring.
        ring.setHover(hover(for: ring.geometry.hit(CGPoint(x: pointer.x - centre.x, y: pointer.y - centre.y))))
        updateStatus()
        panel.orderFrontRegardless()
        let generation = generation
        // One turn later, so the first frame is drawn closed and the opening animates.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self, self.generation == generation { self.ring.setShown(true) } }
        }
        manager.donutOpened()
        startKeys(); startScrollMonitors(); armFailsafe(generation)
    }

    private func makePanel(side: CGFloat) -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let panel = RingPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        let content = DropView(frame: rect)
        content.hovered = { [weak self] point, mask in self?.dragged(to: point, mask: mask) ?? [] }
        content.exited = { [weak self] in self?.exited() }
        content.dropped = { [weak self] point, mask, urls in self?.drop(at: point, mask: mask, urls: urls) ?? false }
        content.scrolled = { [weak self] event in self?.scrolled(event) }
        let host = NSHostingView(rootView: DonutView(model: ring))
        // The drawing must never resize the panel: the hit-testing assumes the ring sits in its middle.
        host.sizingOptions = []
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        panel.contentView = content
        return panel
    }

    /// The button came up (or a press arrived) while the ring was open. The drop and the release race, so the
    /// ring waits a moment before it closes.
    private func released() {
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { if let self, self.generation == generation { self.close() } }
        }
    }

    /// A ring whose release was never seen closes itself; one still being dragged is checked again later.
    private func armFailsafe(_ generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.panel?.isVisible == true else { return }
                if NSEvent.pressedMouseButtons & 1 == 1 { self.armFailsafe(generation) } else { self.close() }
            }
        }
    }

    private func close() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        panel.orderOut(nil)
        stopKeys(); stopScrollMonitors()
        dwell?.invalidate(); dwell = nil
        ring.setShown(false)
        files = []; total = 0; trashing = []
        manager.donutClosed()
    }

    // MARK: The drag over the ring

    private func hover(for hit: DonutGeometry.Hit) -> DonutView.Model.Hover? {
        switch hit {
        case .slice(let index): .slice(index)
        case .hub: .hub
        case .rim: .rim
        case .outside: nil
        }
    }

    private func isFlip(_ index: Int) -> Bool { ring.slices.indices.contains(index) && ring.slices[index].content == .flip }

    /// The slice under `point` that a drop would act on, if any.
    private func target(at point: CGPoint) -> DonutSlice? {
        guard case .slice(let index) = ring.geometry.hit(point), ring.slices.indices.contains(index) else { return nil }
        let slice = ring.slices[index]
        return slice.enabled && slice.content != .flip ? slice : nil
    }

    /// AppKit narrows the source's mask by the modifier held (Option copy, Command generic, Control link).
    /// Never move or delete: the source would remove the originals.
    private static func operation(for mask: NSDragOperation) -> NSDragOperation {
        [NSDragOperation.copy, .generic, .link].first { mask.contains($0) } ?? []
    }

    private func dragged(to point: CGPoint, mask: NSDragOperation) -> NSDragOperation {
        let previous = ring.hover
        let hover = hover(for: ring.geometry.hit(point))
        ring.setHover(hover)
        if hover != previous {
            if case .slice(let index)? = previous, isFlip(index) { dwell?.invalidate(); dwell = nil; dwellArmed = true }
            if case .slice(let index)? = hover, ring.slices.indices.contains(index), ring.slices[index].enabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                if isFlip(index) { startDwell(index) }
            }
        }
        let operation = target(at: point) != nil ? Self.operation(for: mask) : []
        refused = target(at: point) != nil && operation.isEmpty
        updateStatus()
        return operation
    }

    private func exited() {
        ring.setHover(nil); refused = false
        dwell?.invalidate(); dwell = nil; dwellArmed = true
        updateStatus()
    }

    private func drop(at point: CGPoint, mask: NSDragOperation, urls: [URL]) -> Bool {
        guard let slice = target(at: point), !Self.operation(for: mask).isEmpty, let panel else { return false }
        let dropped = DragTracker.files(urls).files
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        manager.drop(dropped.isEmpty ? files : dropped, on: slice, at: centre)
        close()
        return true
    }

    // MARK: Flipping

    private func flip() {
        guard ring.hasBack, panel?.isVisible == true else { return }
        ring.flip(); refused = false
        dwell?.invalidate(); dwell = nil
        updateStatus()
    }

    /// Resting on the flip slice turns the ring once; the pointer must leave it before it turns again.
    private func startDwell(_ index: Int) {
        guard dwellArmed else { return }
        dwell?.invalidate()
        let generation = generation, back = ring.back
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.ring.back == back, self.ring.hover == .slice(index) else { return }
                self.dwellArmed = false
                self.flip()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwell = timer
    }

    /// One flip per burst of wheel events (a burst ends after 300 ms without one), however many routes
    /// delivered the same event.
    private func scrolled(_ event: NSEvent) {
        guard panel?.isVisible == true, event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0 else { return }
        let burst = lastScroll >= 0 && event.timestamp - lastScroll <= 0.3
        lastScroll = event.timestamp
        if !burst { flip() }
    }

    /// The wheel over the ring reaches our own panel (the content view and the local monitor); over the
    /// transparent part it goes to the app below, which only a global monitor sees.
    private func startScrollMonitors() {
        guard scrollMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }) { scrollMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
        }) { scrollMonitors.append(global) }
    }

    private func stopScrollMonitors() {
        for monitor in scrollMonitors { NSEvent.removeMonitor(monitor) }
        scrollMonitors = []
    }

    /// Esc closes and Tab flips, best effort: the key state is polled (no permission needed), and it reads
    /// "up" while another app holds Secure Input, so nothing may depend on it.
    private func startKeys() {
        stopKeys()
        escapeDown = CGEventSource.keyState(.combinedSessionState, key: 53)
        tabDown = CGEventSource.keyState(.combinedSessionState, key: 48)
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollKeys() } }
        RunLoop.main.add(timer, forMode: .common)
        keyTimer = timer
    }

    private func stopKeys() { keyTimer?.invalidate(); keyTimer = nil }

    private func pollKeys() {
        let escape = CGEventSource.keyState(.combinedSessionState, key: 53)
        let tab = CGEventSource.keyState(.combinedSessionState, key: 48)
        defer { escapeDown = escape; tabDown = tab }
        if escape, !escapeDown { monitor.dismiss(); close(); return }
        if tab, !tabDown { flip() }
    }

    // MARK: The status line

    private func trashingSlices(_ faces: DonutFaces, files: [URL]) -> Set<String> {
        guard let options = model?.preferences.converter.options, options.trashOriginals else { return [] }
        let engine = manager.engine
        var ids = Set<String>()
        for slice in faces.front + faces.back where slice.enabled {
            guard case .target(let target) = slice.content else { continue }
            let trashes = files.contains { url in
                guard let format = FormatRegistry.format(of: url) else { return false }
                return ConversionEngine.trashesOriginal(target, source: format, options: options)
                    && engine.availability(of: target, for: url) == .available
            }
            if trashes { ids.insert(slice.id) }
        }
        return ids
    }

    private func updateStatus() {
        let cancel = L("Vazgeçmek için buraya bırak"), start = L("Dönüştürmek için bir dilime bırak")
        var status: String, note: String?
        switch ring.hover {
        case .slice(let index) where ring.slices.indices.contains(index):
            let slice = ring.slices[index]
            if slice.content == .flip {
                status = L("Diğerleri için kaydır")
            } else if !slice.enabled {
                status = slice.reasonKey.map { key in slice.reasonDetail.map { L(key, $0) } ?? L(key) } ?? ""
            } else if refused {
                status = L("Bu dosyalar buraya bırakılamıyor.")
            } else {
                let title = slice.titleIsKey ? L(slice.title) : slice.title
                let fitting = min(slice.fitting, files.count)
                status = fitting == total ? (fitting == 1 ? L("1 dosya → %@", title) : L("%d dosya → %@", fitting, title))
                    : L("%@ dosya → %@", "\(fitting) / \(total)", title)
                note = slice.noteKey.map { L($0) } ?? (trashing.contains(slice.id) ? L("Özgün dosya Çöp Sepeti’ne taşınır") : nil)
            }
        case .hub: status = ring.leftHub ? cancel : start
        case .rim: status = cancel
        case .slice, nil: status = ring.hasBack ? L("Diğerleri için kaydır") : start
        }
        ring.setStatus(status, note: note)
    }

    // MARK: Pieces

    /// Shown during someone else's drag: it must never take the keyboard from the app being dragged from.
    private final class RingPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The panel's content: the drop target, with the SwiftUI drawing inside it. Points are handed on relative
    /// to the ring's centre, y up (the view is not flipped).
    private final class DropView: NSView {
        var hovered: ((CGPoint, NSDragOperation) -> NSDragOperation)?
        var exited: (() -> Void)?
        var dropped: ((CGPoint, NSDragOperation, [URL]) -> Bool)?
        var scrolled: ((NSEvent) -> Void)?
        private var cached: [URL] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private func point(_ sender: any NSDraggingInfo) -> CGPoint {
            let local = convert(sender.draggingLocation, from: nil)
            return CGPoint(x: local.x - bounds.midX, y: local.y - bounds.midY)
        }
        private static func urls(_ pasteboard: NSPasteboard) -> [URL] {
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] else { return urls }
            return paths.map { URL(fileURLWithPath: $0) }
        }

        // Read once on entry: reading the pasteboard on every move made the drag stutter.
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            cached = Self.urls(sender.draggingPasteboard)
            return draggingUpdated(sender)
        }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            hovered?(point(sender), sender.draggingSourceOperationMask) ?? []
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { exited?() }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            let urls = Self.urls(sender.draggingPasteboard)
            return dropped?(point(sender), sender.draggingSourceOperationMask, urls.isEmpty ? cached : urls) ?? false
        }
        override func draggingEnded(_ sender: any NSDraggingInfo) { cached = [] }
        override func scrollWheel(with event: NSEvent) { scrolled?(event) }
    }
}
