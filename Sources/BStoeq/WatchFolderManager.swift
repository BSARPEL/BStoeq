import Combine
import Darwin
import Foundation
import ConvertCore

/// Converts every new file that lands in a watched folder to the rule's target, into the rule's results
/// folder inside it. Only the folder's top level is watched, files already there when watching starts are
/// left alone, and a file starts only once it has stopped changing and its target fits it on this Mac:
/// one that does not fit leaves no activity and no record behind.
@MainActor final class WatchFolderManager: ObservableObject {
    enum State: Equatable {
        case watching
        case folderMissing
        /// The target cannot be made on this Mac; the tool that would make it, when one would.
        case unavailable(String?)
    }

    /// The shape of `ConverterManager.start` with the origin fixed: what the app hands in.
    typealias Start = (_ files: [URL], _ target: ConversionTarget, _ options: ConversionOptions) -> UUID?

    /// One per enabled rule, by rule id; a rule that is off has none.
    @Published private(set) var states: [UUID: State] = [:]

    /// True while a folder has not been read for the first time, or is being read again.
    var isListing: Bool { watches.values.contains { !$0.baselined || $0.listing } }

    private let options: () -> ConversionOptions
    private let availability: (ConversionTarget, URL) -> TargetAvailability
    private let targetAvailability: (ConversionTarget) -> TargetAvailability
    private let isReady: () -> Bool
    private let outputs: (UUID) -> [URL]?
    private let start: Start
    private let settleInterval: TimeInterval
    private let tickInterval: TimeInterval
    private var rules: [WatchRule] = []
    private var watches: [UUID: Watch] = [:]
    /// Jobs this manager started whose outputs are not known yet.
    private var jobs: [UUID] = []
    /// What those jobs wrote: never taken as an arrival, whichever folder it lands in.
    private var produced: [String] = []
    private var producedSet = Set<String>()
    private var timer: DispatchSourceTimer?
    private var subscriptions = Set<AnyCancellable>()

    private static let producedLimit = 500
    /// Folder reads and file checks: a slow or stalled volume must not hold up the main thread.
    nonisolated private static let queue = DispatchQueue(label: "local.barlet.watch", qos: .utility)

    /// - Parameters:
    ///   - options: the stored options; each job gets them with its rule's results folder and no Trash.
    ///   - availability: whether the target fits one file (the engine's per-file answer).
    ///   - targetAvailability: whether the target can be made here at all, for the rule's state.
    ///   - isReady: false holds files that have arrived (tools not detected yet) until it turns true.
    ///   - outputs: a started job's published items once it has finished, nil while it runs.
    init(settleInterval: TimeInterval = WatchRules.settleInterval, tickInterval: TimeInterval = 1,
         options: @escaping () -> ConversionOptions,
         availability: @escaping (ConversionTarget, URL) -> TargetAvailability,
         targetAvailability: @escaping (ConversionTarget) -> TargetAvailability,
         isReady: @escaping () -> Bool = { true },
         outputs: @escaping (UUID) -> [URL]? = { _ in [] },
         start: @escaping Start) {
        self.settleInterval = settleInterval; self.tickInterval = tickInterval
        self.options = options; self.availability = availability; self.targetAvailability = targetAvailability
        self.isReady = isReady; self.outputs = outputs; self.start = start
    }

    /// The app's wiring: jobs go to the converter as watch jobs, and the states follow its tool detection.
    convenience init(converter: ConverterManager, settings: @escaping () -> ConverterSettings,
                     settleInterval: TimeInterval = WatchRules.settleInterval, tickInterval: TimeInterval = 1) {
        self.init(settleInterval: settleInterval, tickInterval: tickInterval, options: { settings().options },
                  availability: { [weak converter] target, url in converter?.engine.availability(of: target, for: url) ?? .unsupported },
                  targetAvailability: { [weak converter] target in
                      guard let converter else { return .unsupported }
                      let answer = converter.engine.availability(of: target)
                      // Before the first detection has answered, a missing tool is not known to be missing.
                      if case .needs = answer, !converter.toolsChecked { return .available }
                      return answer
                  },
                  isReady: { [weak converter] in converter?.toolsChecked ?? false },
                  outputs: { [weak converter] id in
                      guard let converter else { return [] }
                      if let activity = converter.activities.first(where: { $0.id == id }) {
                          return activity.phase == .finished ? activity.outputs : nil
                      }
                      // Pushed out of the activities already: the record keeps what was published.
                      return converter.history.first { $0.id == id }?.outputs.map { URL(fileURLWithPath: $0.path) } ?? []
                  },
                  start: { [weak converter] files, target, options in
                      converter?.start(files, target: target, origin: .watch, options: options)
                  })
        // `@Published` announces a change before it is made: look again once it has been.
        converter.$environment.map { _ in () }.merge(with: converter.$toolsChecked.map { _ in () })
            .dropFirst(2).receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refreshStates() } }
            .store(in: &subscriptions)
    }

    // MARK: Rules

    /// Starts, keeps or stops a watch for every rule. A folder that was missing is tried again.
    func apply(_ rules: [WatchRule]) {
        self.rules = rules
        let wanted = rules.filter(\.enabled)
        let ids = Set(wanted.map(\.id))
        for (id, watch) in watches where !ids.contains(id) { end(watch) }
        var next: [UUID: State] = [:]
        for rule in wanted { next[rule.id] = evaluate(rule) }
        if next != states { states = next }
        updateTimer()
    }

    /// The tools changed: a target may have become possible, or impossible.
    func refreshStates() { apply(rules) }

    func stop() {
        for watch in Array(watches.values) { end(watch) }
        jobs = []
        updateTimer()
    }

    private func evaluate(_ rule: WatchRule) -> State {
        guard let target = TargetCatalog.target(id: rule.targetID), target.kind == .convert else {
            if let watch = watches[rule.id] { end(watch) }
            return .unavailable(nil)
        }
        switch targetAvailability(target) {
        case .available: break
        case .needs(let tool):
            if let watch = watches[rule.id] { end(watch) }
            return .unavailable(tool)
        case .unsupported:
            if let watch = watches[rule.id] { end(watch) }
            return .unavailable(nil)
        }
        if let watch = watches[rule.id] {
            if watch.rule == rule { return .watching }
            end(watch)
        }
        return begin(rule, target: target)
    }

    // MARK: Watching

    private func begin(_ rule: WatchRule, target: ConversionTarget) -> State {
        // An event-only descriptor does not keep the volume from being ejected.
        let descriptor = open(rule.folder, O_EVTONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return .folderMissing }
        let watch = Watch(rule: rule, target: target)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak watch, weak source] in
            let events = source?.data ?? []
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                self.changed(watch, events: events)
            }
        }
        source.setCancelHandler { close(descriptor) }
        watch.source = source
        watches[rule.id] = watch
        source.resume()
        list(watch)
        return .watching
    }

    private func end(_ watch: Watch) {
        watch.source?.cancel()
        watch.source = nil
        if watches[watch.rule.id] === watch { watches[watch.rule.id] = nil }
    }

    private func changed(_ watch: Watch, events: DispatchSource.FileSystemEvent) {
        guard watches[watch.rule.id] === watch else { return }
        // The folder itself was deleted, moved (to the Trash too) or its volume went away.
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) { return lost(watch) }
        list(watch)
    }

    private func lost(_ watch: Watch) {
        end(watch)
        if states[watch.rule.id] != nil, states[watch.rule.id] != .folderMissing { states[watch.rule.id] = .folderMissing }
        updateTimer()
    }

    /// Reads the folder off the main thread; a change while it reads is read again afterwards.
    private func list(_ watch: Watch) {
        guard !watch.listing else { watch.again = true; return }
        watch.listing = true
        let path = watch.rule.folder
        Self.queue.async { [weak self] in
            let entries = Self.read(path)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.listed(entries, for: watch) } }
        }
    }

    private func listed(_ entries: [Listed]?, for watch: Watch) {
        guard watches[watch.rule.id] === watch else { return }
        watch.listing = false
        guard let entries else { return lost(watch) }
        var current: [String: UInt64] = [:]
        let inodes = Set(watch.known.values), now = Date()
        for entry in entries where !WatchRules.ignores(name: entry.name, kind: entry.kind, resultsFolder: watch.rule.outputFolder) {
            current[entry.name] = entry.inode
            // The first reading is what was there before; a name already counted is not new either.
            guard watch.baselined, watch.known[entry.name] == nil else { continue }
            // Renamed inside the folder: the same file under a new name is not an arrival.
            guard !inodes.contains(entry.inode), !producedSet.contains(watch.url(entry.name).path) else { continue }
            // The first check fills in the real entry and starts the wait from there.
            watch.candidates[entry.name] = WatchRules.Candidate(entry: WatchRules.Entry(size: -1, modified: .distantPast, inode: entry.inode),
                                                                unchangedSince: now)
        }
        // A name that went away and comes back later is a new arrival.
        watch.candidates = watch.candidates.filter { current[$0.key] != nil }
        watch.known = current
        watch.baselined = true
        if watch.again {
            watch.again = false
            list(watch)
        }
        updateTimer()
    }

    // MARK: Settling

    private func updateTimer() {
        let busy = !jobs.isEmpty || watches.values.contains { !$0.candidates.isEmpty }
        if busy, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
            timer.resume()
            self.timer = timer
        } else if !busy, let timer {
            timer.cancel()
            self.timer = nil
        }
    }

    private func tick() {
        jobs.removeAll { id in
            guard let items = outputs(id) else { return false }
            remember(items)
            return true
        }
        for watch in watches.values where !watch.candidates.isEmpty && !watch.checking {
            watch.checking = true
            let paths = watch.candidates.keys.map { ($0, watch.url($0).path) }
            Self.queue.async { [weak self] in
                var entries: [String: WatchRules.Entry] = [:]
                for (name, path) in paths { entries[name] = Self.entry(at: path) }
                let found = entries
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.checked(found, names: paths.map(\.0), for: watch) } }
            }
        }
        updateTimer()
    }

    private func checked(_ entries: [String: WatchRules.Entry], names: [String], for watch: Watch) {
        guard watches[watch.rule.id] === watch else { return }
        watch.checking = false
        let now = Date()
        var arrived: [String] = []
        for name in names {
            // A reading in between may have seen it go.
            guard var candidate = watch.candidates[name] else { continue }
            switch WatchRules.settle(&candidate, now: entries[name], at: now, interval: settleInterval) {
            case .gone: watch.candidates[name] = nil
            case .waiting: watch.candidates[name] = candidate
            case .arrived: watch.candidates[name] = candidate; arrived.append(name)
            }
        }
        // Arrived files wait, still arrived, until the tools are known.
        if !arrived.isEmpty, isReady() { launch(arrived, for: watch) }
        updateTimer()
    }

    /// Everything of one rule that arrived in the same tick is one job.
    private func launch(_ names: [String], for watch: Watch) {
        for name in names { watch.candidates[name] = nil }
        let target = watch.target
        let files = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(watch.url).filter { url in
            !producedSet.contains(url.path) && WatchRules.accepts(target, source: FormatRegistry.format(of: url))
                && availability(target, url) == .available
        }
        guard !files.isEmpty else { return }
        var options = options()
        options.location = .subfolder(watch.rule.outputFolder)
        // A watched folder is the user's own: nothing in it goes to the Trash.
        options.trashOriginals = false
        if let id = start(files, target, options) { jobs.append(id) }
    }

    private func remember(_ items: [URL]) {
        for path in items.map(\.path) where producedSet.insert(path).inserted { produced.append(path) }
        if produced.count > Self.producedLimit {
            let dropped = produced.prefix(produced.count - Self.producedLimit)
            producedSet.subtract(dropped)
            produced.removeFirst(dropped.count)
        }
    }

    // MARK: Disk

    private struct Listed: Sendable {
        let name: String
        let inode: UInt64
        let kind: WatchRules.Kind
    }

    /// The folder's names with their inode and kind, straight from the directory: no per-file read.
    /// nil when the folder cannot be read (gone, or no longer allowed).
    nonisolated private static func read(_ path: String) -> [Listed]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var result: [Listed] = []
        while let pointer = readdir(directory) {
            let entry = pointer.pointee, length = Int(entry.d_namlen)
            let name = withUnsafeBytes(of: entry.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            guard name != ".", name != ".." else { continue }
            let kind: WatchRules.Kind
            switch Int32(entry.d_type) {
            case DT_REG: kind = .file
            case DT_DIR: kind = .folder
            case DT_LNK: kind = .link
            // Some volumes do not say; ask the entry itself.
            case DT_UNKNOWN: kind = Self.entry(at: (path as NSString).appendingPathComponent(name))?.kind ?? .other
            default: kind = .other
            }
            result.append(Listed(name: name, inode: entry.d_ino, kind: kind))
        }
        return result
    }

    nonisolated private static func entry(at path: String) -> WatchRules.Entry? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        let kind: WatchRules.Kind
        switch status.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .folder
        case S_IFLNK: kind = .link
        default: kind = .other
        }
        func date(_ time: timespec) -> Date { Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9) }
        let created = status.st_birthtimespec.tv_sec > 0 ? date(status.st_birthtimespec) : nil
        return WatchRules.Entry(kind: kind, size: Int64(status.st_size), modified: date(status.st_mtimespec), created: created,
                                inode: UInt64(status.st_ino))
    }

    /// One enabled rule being watched. Replaced, not changed, when the rule changes, so a late reading of
    /// an old watch is recognised and dropped.
    @MainActor private final class Watch {
        let rule: WatchRule
        let target: ConversionTarget
        let folder: URL
        var source: DispatchSourceFileSystemObject?
        /// Names counted at the last reading, with their inode.
        var known: [String: UInt64] = [:]
        var baselined = false
        var listing = false, again = false, checking = false
        var candidates: [String: WatchRules.Candidate] = [:]

        init(rule: WatchRule, target: ConversionTarget) {
            self.rule = rule; self.target = target
            folder = URL(fileURLWithPath: rule.folder, isDirectory: true)
        }

        func url(_ name: String) -> URL { folder.appendingPathComponent(name, isDirectory: false) }
    }
}
