import Foundation

/// Tells a file drag in any app from a plain click, from what can be read without a permission: the
/// primary button, the drag pasteboard's change count and types, and the modifier keys. It says when the
/// ring opens and when it closes; the app's `DragMonitor` only gathers the samples and obeys.
/// Once open, the ring's life follows the button, not the key.
public struct DragTracker: Equatable, Sendable {
    /// One reading of the global state.
    public struct Sample: Equatable, Sendable {
        public var buttonDown: Bool
        public var changeCount: Int
        /// The drag pasteboard's types, read only when `wantsTypes` asked for them, else nil.
        public var types: [String]?
        /// The raw value of `NSEvent.modifierFlags`.
        public var modifiers: UInt
        /// Seconds on a clock that never goes back (system uptime).
        public var time: TimeInterval

        public init(buttonDown: Bool, changeCount: Int, types: [String]? = nil, modifiers: UInt = 0, time: TimeInterval = 0) {
            self.buttonDown = buttonDown; self.changeCount = changeCount; self.types = types
            self.modifiers = modifiers; self.time = time
        }
    }

    public enum Action: Equatable, Sendable { case none, open, close }
    /// `dismissed`: the ring was closed (Esc) while the button is still down; it opens again only after the
    /// key has been let go and pressed anew.
    public enum Phase: Equatable, Sendable { case idle, pressed, open, dismissed }

    /// What a file drag carries: Finder's file URLs, and the older name other file managers still write.
    public static let fileTypes: Set<String> = ["public.file-url", "NSFilenamesPboardType"]
    /// Present only on drags that come from Finder (and the Desktop).
    public static let finderType = "com.apple.finder.node"
    /// Shift, Control, Option and Command. Caps lock, fn, the numeric pad and help never count.
    public static let relevantModifiers: UInt = 1 << 17 | 1 << 18 | 1 << 19 | 1 << 20
    /// How long the trigger must be the only key held. Option on the way to Option-Command (Finder's
    /// "make alias" drag) must not open the ring.
    public static let settle: TimeInterval = 0.07
    /// Dragged files the ring takes at most.
    public static let fileLimit = 500

    public var trigger: DonutTrigger
    /// Only drags that start in Finder.
    public var finderOnly: Bool
    public private(set) var phase = Phase.idle

    /// The change count before this press: a drag writes the pasteboard, a click does not.
    private var baseline: Int
    private var verdict: Verdict?
    private var matchedSince: TimeInterval?

    private struct Verdict: Equatable, Sendable { let changeCount: Int; let files: Bool }

    public init(trigger: DonutTrigger = .option, finderOnly: Bool = true, changeCount: Int = 0) {
        self.trigger = trigger; self.finderOnly = finderOnly; baseline = changeCount
    }

    public var isOpen: Bool { phase == .open }

    /// A mouse-down was seen: the count read now is the baseline. A press that arrives while the ring is
    /// open means its release was missed, so the ring closes.
    public mutating func press(changeCount: Int) -> Action {
        let action: Action = phase == .open ? .close : .none
        phase = .pressed; baseline = changeCount; verdict = nil; matchedSince = nil
        return action
    }

    /// Whether the next sample should carry the pasteboard's types: only once its count has moved past the
    /// baseline and those types have not been judged yet. A pasteboard read between being cleared and being
    /// written has no types, so an empty answer is asked again.
    public func wantsTypes(changeCount: Int) -> Bool {
        (phase == .idle || phase == .pressed) && changeCount != baseline && verdict?.changeCount != changeCount
    }

    public mutating func update(_ sample: Sample) -> Action {
        guard sample.buttonDown else {
            // Between presses the count keeps moving (an app may write the drag pasteboard after a drop):
            // every reading with the button up is the next baseline.
            let wasOpen = phase == .open
            phase = .idle; baseline = sample.changeCount; verdict = nil; matchedSince = nil
            return wasOpen ? .close : .none
        }
        // A press whose mouse-down was not seen keeps the baseline of the last reading with the button up.
        if phase == .idle { phase = .pressed; verdict = nil }
        if sample.changeCount != baseline, verdict?.changeCount != sample.changeCount, let types = sample.types, !types.isEmpty {
            verdict = Verdict(changeCount: sample.changeCount, files: carriesFiles(types))
        }
        let matches = sample.modifiers & Self.relevantModifiers == trigger.modifierMask
        if matches { matchedSince = matchedSince ?? sample.time } else { matchedSince = nil }
        switch phase {
        case .open:
            return .none
        case .dismissed:
            if !matches { phase = .pressed }
            return .none
        case .idle, .pressed:
            guard let since = matchedSince, sample.time - since >= Self.settle,
                  sample.changeCount != baseline, verdict == Verdict(changeCount: sample.changeCount, files: true) else { return .none }
            phase = .open
            return .open
        }
    }

    /// The ring was closed while the button is still down (Esc, or nothing to show for these files).
    public mutating func dismiss() {
        if phase == .open { phase = .dismissed }
    }

    private func carriesFiles(_ types: [String]) -> Bool {
        !Self.fileTypes.isDisjoint(with: types) && (!finderOnly || types.contains(Self.finderType))
    }

    /// The dragged items the ring acts on: file URLs only, file reference URLs turned into paths, existing
    /// items only (a link counts as itself), each once, at most `limit`, in the order given. `total` counts
    /// every distinct existing item, also beyond the limit.
    public static func files(_ urls: [URL], limit: Int = fileLimit) -> (files: [URL], total: Int) {
        var seen = Set<String>(), files: [URL] = [], total = 0
        for url in urls where url.isFileURL {
            let resolved = (url as NSURL).filePathURL ?? url
            let path = resolved.standardizedFileURL.path
            var status = stat()
            guard path != "/", lstat(path, &status) == 0, seen.insert(path).inserted else { continue }
            total += 1
            if files.count < limit { files.append(resolved) }
        }
        return (files, total)
    }
}
