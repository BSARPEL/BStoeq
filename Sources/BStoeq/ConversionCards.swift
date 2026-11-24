import AppKit
import Combine
import SwiftUI
import BStoeqCore
import ConvertCore

/// Decides what the stack of cards under the menu bar shows. It is handed the activities, the time and
/// whether the settings window is visible, and remembers only what it has seen: when a job appeared, which
/// cards were closed and when a finished card's time is up. Nothing here reads the disk or the screen.
struct ConversionCardPolicy {
    /// A job still waiting or running this long after it appeared is "long" and gets a card.
    static let showAfter: TimeInterval = 5
    /// How long a finished card stays on screen without problems, and with failures, skips or notices.
    static let calmLife: TimeInterval = 6
    static let troubledLife: TimeInterval = 15
    /// Cards shown at once; the rest are counted in one line.
    static let limit = 3
    /// Notices a ring action ends with that the small ring at the drop already shows ("Yol kopyalandı").
    static let confirmations: Set<String> = ["Yol kopyalandı"]

    struct Stack: Equatable {
        /// Newest first, at most `limit`.
        var cards: [UUID] = []
        /// Cards that would be shown but do not fit.
        var more = 0
    }

    enum Action: Hashable { case cancel, reveal, retry, close }

    private var firstSeen: [UUID: Date] = [:]
    private var long = Set<UUID>()
    /// Page jobs that finished while the page itself was on screen: the user has seen them there.
    private var seenOnPage = Set<UUID>()
    /// When each finished card that has been on screen goes away.
    private var expiry: [UUID: Date] = [:]
    private var closed = Set<UUID>()
    private var pausedAt: Date?

    init() {}

    /// The stack for this moment. `hovering` pauses every countdown: a card does not leave under the pointer.
    mutating func update(_ activities: [ConversionActivity], now: Date, settingsVisible: Bool, hovering: Bool = false) -> Stack {
        if hovering {
            if pausedAt == nil { pausedAt = now }
        } else if let pausedAt {
            let paused = max(0, now.timeIntervalSince(pausedAt))
            for id in expiry.keys { expiry[id]?.addTimeInterval(paused) }
            self.pausedAt = nil
        }
        // The manager keeps at most 20 finished activities; what it dropped is forgotten here too.
        let present = Set(activities.map(\.id))
        firstSeen = firstSeen.filter { present.contains($0.key) }
        expiry = expiry.filter { present.contains($0.key) }
        long.formIntersection(present); seenOnPage.formIntersection(present); closed.formIntersection(present)

        var candidates: [(id: UUID, seen: Date, order: Int)] = []
        for (order, activity) in activities.enumerated() {
            let id = activity.id, seen = firstSeen[id] ?? now
            firstSeen[id] = seen
            let finished = activity.phase == .finished
            if !finished, now.timeIntervalSince(seen) >= Self.showAfter { long.insert(id) }
            if finished, activity.origin == .page, settingsVisible, expiry[id] == nil { seenOnPage.insert(id) }
            guard !closed.contains(id), !seenOnPage.contains(id), !(activity.origin == .page && settingsVisible) else { continue }
            guard finished ? long.contains(id) || Self.isNoteworthy(activity) : long.contains(id) else { continue }
            if pausedAt == nil, let end = expiry[id], end <= now {
                closed.insert(id)
                continue
            }
            candidates.append((id, seen, order))
        }
        // Newest first; jobs that appeared together keep the manager's order.
        candidates.sort { $0.seen != $1.seen ? $0.seen > $1.seen : $0.order < $1.order }
        let visible = candidates.prefix(Self.limit).map(\.id)
        for id in visible where expiry[id] == nil {
            guard let activity = activities.first(where: { $0.id == id }), activity.phase == .finished else { continue }
            // A card's time starts when it is on screen, not when the job ended behind three others.
            expiry[id] = (pausedAt ?? now).addingTimeInterval(Self.isNoteworthy(activity) ? Self.troubledLife : Self.calmLife)
        }
        return Stack(cards: visible, more: candidates.count - visible.count)
    }

    /// The card is gone for good, whatever its job does next.
    mutating func close(_ id: UUID) { closed.insert(id); expiry[id] = nil }

    /// Something the user should read: a failure, a skip or a notice, other than a confirmation the small
    /// ring already gave.
    static func isNoteworthy(_ activity: ConversionActivity) -> Bool {
        if activity.failed > 0 || activity.skipped > 0 || !activity.problems.isEmpty || activity.moreProblems > 0 { return true }
        if case .donut = activity.origin { return activity.notices.contains { !confirmations.contains($0.key) } }
        return !activity.notices.isEmpty
    }

    // MARK: What a card says

    /// "3 dosya → PNG"; a key title is localized, a format label is shown as it is.
    static func title(_ activity: ConversionActivity, localizer: Localizer) -> String {
        let target = activity.titleIsKey ? localizer.text(activity.targetTitle) : activity.targetTitle
        return activity.count == 1 ? localizer.text("1 dosya → %@", target) : localizer.text("%d dosya → %@", activity.count, target)
    }

    /// "2 dönüştürüldü · 1 başarısız", the non-zero counts only; a cancelled job ends with "İptal edildi".
    /// nil when there is nothing to count (an action that only has a notice).
    static func outcome(_ activity: ConversionActivity, localizer: Localizer) -> String? {
        var parts: [String] = []
        if activity.converted > 0 { parts.append(localizer.text("%d dönüştürüldü", activity.converted)) }
        if activity.failed > 0 { parts.append(localizer.text("%d başarısız", activity.failed)) }
        if activity.skipped > 0 { parts.append(localizer.text("%d atlandı", activity.skipped)) }
        if activity.cancelled { parts.append(localizer.text("İptal edildi")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "ad — neden" for the first problems, then "%d tane daha" for the rest.
    static func problemLines(_ activity: ConversionActivity, localizer: Localizer) -> [String] {
        activity.problems.map { "\($0.name) — \($0.message.text(using: localizer))" }
            + (activity.moreProblems > 0 ? [localizer.text("%d tane daha", activity.moreProblems)] : [])
    }

    /// While a job runs only "İptal et"; once it is over "Finder’da göster" (when it published something),
    /// "Yeniden dene" (when its record has failed sources that still exist) and "Kapat".
    static func actions(for activity: ConversionActivity, retryable: Bool) -> [Action] {
        guard activity.phase == .finished else { return [.cancel] }
        return (activity.outputs.isEmpty ? [] : [.reveal]) + (retryable ? [.retry] : []) + [.close]
    }
}

/// The stack of cards under the menu bar for conversions from any origin, and the ring's one-time intro.
/// The app delegate makes one at launch and calls `stop()` when the app quits; it follows the manager by itself.
@MainActor final class ConversionCardsController: ObservableObject {
    /// The jobs that have a card right now, so the small ring at a drop can step aside for them.
    @Published private(set) var shown: Set<UUID> = []

    private let manager: ConverterManager
    private let model: AppModel
    private let settingsVisible: @MainActor () -> Bool
    private var policy = ConversionCardPolicy()
    private var panel: NSPanel?
    private var host: CardHost?
    private var content: Content?
    private var clock: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var refreshScheduled = false
    private var stopped = false
    /// Whether a record has failed sources that still exist, by record id: asking touches the disk.
    private var retryable: [UUID: Bool] = [:]

    private static let width: CGFloat = 320

    init(manager: ConverterManager, model: AppModel, settingsVisible: @escaping @MainActor () -> Bool = { AppModel.settingsWindowVisible() }) {
        self.manager = manager; self.model = model; self.settingsVisible = settingsVisible
        // `objectWillChange` fires before the new value is stored: read it on the next turn, once per burst.
        manager.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak self] _ in if self?.panel != nil { self?.scheduleRefresh() } }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel(); self?.refresh() }
        }
        refresh()
    }

    func stop() {
        stopped = true
        subscriptions.removeAll()
        clock?.invalidate(); clock = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        closePanel()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled, !stopped else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard !stopped else { return }
        let activities = manager.activities
        let hovering = panel.map { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) } ?? false
        let stack = policy.update(activities, now: Date(), settingsVisible: settingsVisible(), hovering: hovering)
        let records = Set(manager.history.map(\.id))
        retryable = retryable.filter { records.contains($0.key) }
        let cards = stack.cards.compactMap { id -> Card? in
            guard let activity = activities.first(where: { $0.id == id }) else { return nil }
            return Card(activity: activity, actions: ConversionCardPolicy.actions(for: activity, retryable: canRetry(activity)))
        }
        if Set(stack.cards) != shown { shown = Set(stack.cards) }
        let prefs = model.preferences
        let next = Content(cards: cards, more: stack.more, introGlyph: manager.introVisible ? prefs.converter.trigger.glyph : nil,
                           language: model.localizer.language, appearance: prefs.appearance)
        if cards.isEmpty && next.introGlyph == nil { closePanel() } else { show(next) }
        // Ticks find the 5 s mark, the end of a countdown and the pointer leaving the stack.
        let ticking = !cards.isEmpty || activities.contains { $0.phase != .finished }
        if ticking, clock == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        } else if !ticking {
            clock?.invalidate(); clock = nil
        }
    }

    private func canRetry(_ activity: ConversionActivity) -> Bool {
        guard activity.phase == .finished, let id = activity.recordID, let record = manager.history.first(where: { $0.id == id }) else { return false }
        if let known = retryable[id] { return known }
        let answer = !record.retryable().isEmpty
        retryable[id] = answer
        return answer
    }

    private func perform(_ command: Command) {
        switch command {
        case .card(let id, let action):
            guard let activity = manager.activities.first(where: { $0.id == id }) else { break }
            switch action {
            case .cancel: manager.cancel(id)
            case .reveal: manager.reveal(activity.outputs)
            case .retry:
                if let record = manager.history.first(where: { $0.id == activity.recordID }) { manager.retry(record) }
                policy.close(id); manager.dismiss(id)
            case .close: policy.close(id); manager.dismiss(id)
            }
        case .more: manager.onOpenConverter?([])
        case .introSettings: manager.onOpenConverter?([]); manager.dismissIntro()
        case .introClose: manager.dismissIntro()
        }
        refresh()
    }

    // MARK: Panel

    private func show(_ next: Content) {
        // Ticks come four times a second; a picture that did not change is not laid out again.
        if panel != nil, next == content { return }
        content = next
        let view = StackView(content: next) { [weak self] in self?.perform($0) }
        let host = self.host ?? CardHost(rootView: view)
        host.rootView = view
        let size = NSSize(width: Self.width, height: ceil(host.fittingSize.height))
        // The screen under the pointer when the stack opens; it stays there while it is open.
        guard let screen = panel?.screen ?? NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let rect = PanelPlacement.frame(size: size, visibleFrame: screen.visibleFrame, anchorX: screen.visibleFrame.maxX,
                                        top: screen.frame.maxY - max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) - 8)
        if let panel {
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            return
        }
        let window = CardPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = model.L("Dönüştürme durumu")
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isFloatingPanel = true; window.hidesOnDeactivate = false; window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.isReleasedWhenClosed = false
        // The panel is sized from the cards here; the hosting view must not resize it on its own.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: rect.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.setFrame(rect, display: true)
        // A card appears while the user works elsewhere: it must not take the keyboard.
        window.orderFrontRegardless()
        panel = window; self.host = host
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil; host = nil; content = nil
    }

    // MARK: Content

    enum Command: Equatable {
        case card(UUID, ConversionCardPolicy.Action)
        case more, introSettings, introClose
    }

    struct Card: Identifiable, Equatable {
        var id: UUID { activity.id }
        let activity: ConversionActivity
        let actions: [ConversionCardPolicy.Action]
    }

    /// Everything one picture of the stack needs, as plain values: the panel is sized from it before it is shown.
    struct Content: Equatable {
        var cards: [Card]
        var more = 0
        /// The trigger's glyph while the ring's intro is due, else nil.
        var introGlyph: String?
        var language: AppLanguage
        var appearance = "system"
    }

    struct StackView: View {
        let content: Content
        let act: (Command) -> Void

        private var localizer: Localizer { Localizer(language: content.language) }
        private func L(_ key: String, _ arguments: CVarArg...) -> String { localizer.text(key, arguments: arguments) }

        var body: some View {
            VStack(alignment: .trailing, spacing: 8) {
                if let glyph = content.introGlyph { intro(glyph) }
                ForEach(content.cards) { card($0) }
                if content.more > 0 {
                    Button(L("%d tane daha", content.more)) { act(.more) }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Palette.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.line))
                        .accessibilityIdentifier("cards-more")
                }
            }
            .frame(width: ConversionCardsController.width)
            .fixedSize(horizontal: false, vertical: true)
            .tint(Palette.accent)
            .preferredColorScheme(content.appearance == "dark" ? .dark : content.appearance == "light" ? .light : nil)
            .environment(\.locale, Locale(identifier: localizer.language.rawValue))
        }

        private func intro(_ glyph: String) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle.circle").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 20)
                    Text(L("Dosya sürüklerken %@ tuşuna basınca bu halka açılır. Bir dilime bırakırsan dosya dönüştürülür; sonuç özgün dosyanın yanına kaydedilir. Vazgeçmek için ortaya bırak ya da Esc’e bas.", glyph))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button(L("BStoeq ayarları…")) { act(.introSettings) }.accessibilityIdentifier("cards-intro-settings")
                    Button(L("Kapat")) { act(.introClose) }.accessibilityIdentifier("cards-intro-close")
                }.controlSize(.small)
            }.cardChrome()
        }

        private func card(_ card: Card) -> some View {
            let activity = card.activity
            return VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(activity).name).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(symbol(activity).color).frame(width: 18)
                    Text(ConversionCardPolicy.title(activity, localizer: localizer))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if activity.origin == .watch {
                        Text(L("İzlenen klasör")).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Palette.accent.opacity(0.1), in: Capsule())
                    }
                }
                switch activity.phase {
                case .waiting:
                    Text(L("Sırada bekliyor")).font(.system(size: 11)).foregroundStyle(.secondary)
                case .running:
                    if let fraction = activity.fraction {
                        ProgressView(value: min(1, max(0, fraction))).progressViewStyle(.linear).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                case .finished:
                    if let outcome = ConversionCardPolicy.outcome(activity, localizer: localizer) {
                        Text(outcome).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(ConversionCardPolicy.problemLines(activity, localizer: localizer).enumerated()), id: \.offset) { index, line in
                    // File names are user data: shown as they are, never looked up. The last line may count the rest.
                    Text(verbatim: line).font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(index < activity.problems.count ? .primary : .secondary)
                }
                ForEach(Array(activity.notices.enumerated()), id: \.offset) { _, notice in
                    Text(notice.text(using: localizer)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(card.actions, id: \.self) { action in
                        Button(title(action)) { act(.card(activity.id, action)) }.accessibilityIdentifier("cards-\(action)")
                    }
                }.controlSize(.small)
            }.cardChrome()
        }

        private func title(_ action: ConversionCardPolicy.Action) -> String {
            switch action {
            case .cancel: L("İptal et")
            case .reveal: L("Finder’da göster")
            case .retry: L("Yeniden dene")
            case .close: L("Kapat")
            }
        }

        private func symbol(_ activity: ConversionActivity) -> (name: String, color: Color) {
            switch activity.phase {
            case .waiting: return ("clock", .secondary)
            case .running: return ("arrow.triangle.2.circlepath", Palette.accent)
            case .finished:
                if activity.failed > 0 { return ("exclamationmark.triangle.fill", .orange) }
                if activity.cancelled { return ("xmark.circle.fill", .secondary) }
                if ConversionCardPolicy.isNoteworthy(activity) { return ("info.circle.fill", Palette.accent) }
                return ("checkmark.circle.fill", .green)
            }
        }
    }

    /// A first click on a card's button must act, not only bring the panel forward.
    private final class CardHost: NSHostingView<StackView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// Buttons need a key-capable panel; `becomesKeyOnlyIfNeeded` keeps the keyboard where it was.
    private final class CardPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

private extension View {
    /// The house card: `Palette.card`, radius 12, a `Palette.line` stroke.
    func cardChrome() -> some View {
        padding(12)
            .frame(width: 320, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    }
}
