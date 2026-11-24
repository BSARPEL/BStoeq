import AppKit
import Combine
import SwiftUI
import BStoeqCore

/// A small progress ring where the ring was, for every job dropped on it (`Origin.donut`). It shows the
/// percentage once one is known, a check on success, and fades when the job is over or when the card
/// stack takes it over (a job still running after 5 s, or one that ended with a failure, a skip or a
/// notice). Hovering a running job shows ×, which cancels; clicking a finished success reveals the output.
@MainActor final class ConversionHUD {
    private let manager: ConverterManager
    private let localizer: () -> Localizer
    private let scheme: () -> ColorScheme?
    private var subscription: AnyCancellable?
    private var items: [UUID: Item] = [:]
    /// Activities already looked at, so a ring appears once per job and never for jobs that were there before.
    private var seen = Set<UUID>()
    private var latest: [ConversionActivity] = []
    private var timer: Timer?

    private static let side: CGFloat = 44
    /// The card stack shows a job still running this long after it started.
    private static let handOff: TimeInterval = 5
    private static let minimum: TimeInterval = 0.6
    private static let checkHold: TimeInterval = 0.9
    private static let spinnerDelay: TimeInterval = 0.35

    init(manager: ConverterManager, localizer: @escaping () -> Localizer, scheme: @escaping () -> ColorScheme?) {
        self.manager = manager; self.localizer = localizer; self.scheme = scheme
        seen = Set(manager.activities.map(\.id))
        latest = manager.activities
        // `$activities` delivers the new value before the property changes: use what it hands over.
        subscription = manager.$activities.dropFirst().sink { [weak self] activities in
            MainActor.assumeIsolated { self?.update(activities) }
        }
    }

    func stop() {
        subscription?.cancel(); subscription = nil
        timer?.invalidate(); timer = nil
        for item in items.values { item.panel.orderOut(nil) }
        items = [:]
    }

    private func update(_ activities: [ConversionActivity]) {
        latest = activities
        for activity in activities where seen.insert(activity.id).inserted {
            guard case .donut(let centre) = activity.origin else { continue }
            items[activity.id] = makeItem(activity.id, centre: centre)
        }
        seen.formIntersection(activities.map(\.id))
        tick()
        if !items.isEmpty, timer == nil {
            // Time decides as much as the events do (the spinner's delay, the hand-off, the check's hold).
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        for item in items.values where !item.fading {
            advance(item, activity: latest.first { $0.id == item.id }, now: now)
        }
        if items.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func advance(_ item: Item, activity: ConversionActivity?, now: TimeInterval) {
        let age = now - item.created
        // Dismissed or pushed out of the list: nothing left to show.
        guard let activity else { fade(item); return }
        guard activity.phase == .finished else {
            if age >= Self.handOff { fade(item); return }
            let fraction = activity.fraction ?? 0
            item.face.set(fraction > 0 ? .percent(min(1, fraction)) : age >= Self.spinnerDelay ? .spinner : .waiting, running: true)
            item.content.setAccessibilityLabel(localizer().text("İptal et"))
            return
        }
        let success = !activity.cancelled && activity.failed == 0 && activity.skipped == 0
            && activity.problems.isEmpty
            && activity.notices.allSatisfy { ConversionCardPolicy.confirmations.contains($0.key) }
        guard success else {
            // The card says what happened; the small ring only keeps its minimum time.
            item.face.set(item.face.mode, running: false)
            if age >= Self.minimum { fade(item) }
            return
        }
        if item.finished == nil {
            item.finished = now; item.outputs = activity.outputs
            item.face.set(.check, running: false)
            item.content.setAccessibilityLabel(localizer().text("Finder’da göster"))
        }
        if !item.face.hovered, let finished = item.finished, now >= max(finished + Self.checkHold, item.created + Self.minimum) {
            fade(item)
        }
    }

    private func fade(_ item: Item) {
        guard !item.fading else { return }
        item.fading = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            item.panel.animator().alphaValue = 0
        }
        let id = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let item = self.items[id], item.fading else { return }
                item.panel.orderOut(nil)
                self.items[id] = nil
                if self.items.isEmpty { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    private func clicked(_ id: UUID) {
        guard let item = items[id], !item.fading else { return }
        if item.face.running { manager.cancel(id) } else if item.finished != nil, !item.outputs.isEmpty { manager.reveal(item.outputs) }
    }

    /// Centred on the ring's centre (where the drop happened is a slice, so never under the pointer).
    private func makeItem(_ id: UUID, centre: CGPoint) -> Item {
        let side = Self.side
        let rect = NSRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        let panel = HUDPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let localizer = localizer()
        panel.title = localizer.text("Dönüştürülüyor…")
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let face = Face()
        let content = ClickView(frame: NSRect(origin: .zero, size: rect.size))
        content.setAccessibilityRole(.button)
        content.setAccessibilityLabel(localizer.text("İptal et"))
        content.onHover = { [weak face] inside in face?.setHovered(inside) }
        content.onClick = { [weak self] in self?.clicked(id) }
        let host = NSHostingView(rootView: RingFace(face: face)
            .environment(\.locale, Locale(identifier: localizer.language.rawValue))
            .preferredColorScheme(scheme()))
        host.sizingOptions = []
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        panel.contentView = content
        panel.orderFrontRegardless()
        return Item(id: id, panel: panel, content: content, face: face, created: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Pieces

    @MainActor private final class Item {
        let id: UUID
        let panel: NSPanel
        let content: NSView
        let face: Face
        let created: TimeInterval
        var finished: TimeInterval?
        var outputs: [URL] = []
        var fading = false
        init(id: UUID, panel: NSPanel, content: NSView, face: Face, created: TimeInterval) {
            self.id = id; self.panel = panel; self.content = content; self.face = face; self.created = created
        }
    }

    @MainActor private final class Face: ObservableObject {
        enum Mode: Equatable { case waiting, spinner, percent(Double), check }
        @Published private(set) var mode = Mode.waiting
        @Published private(set) var running = true
        @Published private(set) var hovered = false
        func set(_ mode: Mode, running: Bool) {
            if self.mode != mode { self.mode = mode }
            if self.running != running { self.running = running }
        }
        func setHovered(_ hovered: Bool) { if self.hovered != hovered { self.hovered = hovered } }
    }

    private struct RingFace: View {
        @ObservedObject var face: Face
        @Environment(\.locale) private var locale

        var body: some View {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3.5).padding(6)
                switch face.mode {
                case .waiting: EmptyView()
                case .spinner: ProgressView().controlSize(.small)
                case .percent(let fraction):
                    Circle().trim(from: 0, to: fraction)
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(6)
                        .animation(.linear(duration: 0.1), value: fraction)
                    Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                case .check:
                    Circle().fill(Color.green).padding(6)
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
                if face.running, face.hovered {
                    Circle().fill(.regularMaterial).padding(3)
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: ConversionHUD.side, height: ConversionHUD.side)
            .accessibilityHidden(true)
        }
    }

    private final class HUDPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the clicks itself (the SwiftUI drawing inside only paints) and reports the pointer entering
    /// and leaving, also while another app is active.
    private final class ClickView: NSView {
        var onHover: ((Bool) -> Void)?
        var onClick: (() -> Void)?
        private var area: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            self.area = area
        }
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }
    }
}
