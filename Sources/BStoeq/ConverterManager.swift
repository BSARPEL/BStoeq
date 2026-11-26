import AppKit
import ArchiveCore
import BStoeqCore
import ConvertCore

/// One job as the small ring, the cards and the page show it: a conversion or an archive action, from
/// any origin. Finished activities keep their outcome until they are dismissed or pushed out.
struct ConversionActivity: Identifiable, Equatable {
    /// The point is the ring's centre, in Cocoa coordinates.
    enum Origin: Equatable { case donut(CGPoint), page, watch }
    enum Phase: Equatable { case waiting, running, finished }
    struct Problem: Equatable { let name: String; let message: UserMessage; let failed: Bool }
    let id: UUID
    let origin: Origin
    /// Files in the job.
    let count: Int
    let targetTitle: String
    let titleIsKey: Bool
    var phase = Phase.waiting
    /// nil while nothing has reported progress.
    var fraction: Double?
    var converted = 0, failed = 0, skipped = 0
    var cancelled = false
    var outputs: [URL] = []
    /// The first three.
    var problems: [Problem] = []
    var moreProblems = 0
    var notices: [UserMessage] = []
    /// The history record, once finished.
    var recordID: UUID?
}

/// Runs every conversion and archive action of the app, whoever asked for it (the ring, the page, a
/// watched folder), and keeps the page's draft, the recent activities and the history.
@MainActor final class ConverterManager: ObservableObject {
    @Published private(set) var environment = ConversionEnvironment() {
        didSet { if environment != oldValue { refreshOffers() } }
    }
    /// False until the first tool detection has finished: until then "no ffmpeg" is not known.
    @Published private(set) var toolsChecked = false
    /// Unfinished ones first, then the last finished (at most 20).
    @Published private(set) var activities: [ConversionActivity] = []
    /// Newest first, at most 50, defaults key "converter.history".
    @Published private(set) var history: [ConversionRecord] = []
    // The page's draft: page views are rebuilt on every page switch.
    @Published var pending: [URL] = [] {
        didSet { if pending != oldValue { refreshOffers() } }
    }
    @Published var targetID: String?
    @Published var draftResize = ImageResize.original
    @Published var draftMaxHeight = 0
    @Published var draftRemoveAudio = false
    /// Recomputed when `pending` or `environment` changes, so views never ask the engine from `body`.
    @Published private(set) var pendingOffers: [TargetOffer] = []
    @Published var problem: UserMessage?
    /// The first time the ring has opened, a card explains it once (defaults key "converter.donutIntroduced").
    @Published private(set) var introVisible = false

    /// Set by the app: show the page with these files waiting.
    var onOpenConverter: (([URL]) -> Void)?
    var onOpenArchive: ((URL) -> Void)?
    /// Where "copy path" writes. Tests hand in a pasteboard of their own.
    var pasteboard = NSPasteboard.general

    private let defaults: UserDefaults
    private let settings: () -> ConverterSettings
    private let localize: (String) -> String
    private let detect: @Sendable () -> ConversionEnvironment
    private let converters: [any Converter]
    private let limiter: ConversionLimiter
    private let fallbackFolder: URL
    private let archiveTool: URL?
    private let moveToTrash: @Sendable (URL) throws -> Void
    private var detection: Task<Void, Never>?
    private var detectionGeneration = 0
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var archiveControls: [UUID: JobControl] = [:]
    /// Files of the page's own jobs still running: pressing Convert again must not convert them twice.
    private var pageSources: [UUID: Set<String>] = [:]
    /// Archive names chosen for jobs still running: two quick ZIPs of one folder must not both pick "Arşiv.zip".
    private var claimedArchives: [UUID: String] = [:]
    /// Requests seen starting, per job: a new one means a new work folder to remember.
    private var starts: [UUID: Int] = [:]
    private var undoing = Set<UUID>()
    private var introArmed = false

    private static let historyKey = "converter.history"
    private static let introKey = "converter.donutIntroduced"
    private static let workFoldersKey = "converter.workFolders"
    private static let historyLimit = 50
    private static let finishedLimit = 20
    private static let problemLines = 3

    init(defaults: UserDefaults = .standard,
         settings: @escaping () -> ConverterSettings = { ConverterSettings() },
         localize: @escaping (String) -> String = { $0 },
         detect: @escaping @Sendable () -> ConversionEnvironment = { ConversionEnvironment.detect(in: ConverterManager.toolDirectories()) },
         converters: [any Converter] = ConversionEngine.standardConverters(),
         limiter: ConversionLimiter = ConversionLimiter(),
         fallbackFolder: URL? = nil,
         archiveTool: URL? = Bundle.main.resourceURL?.appendingPathComponent("Tools/7zz"),
         moveToTrash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.defaults = defaults; self.settings = settings; self.localize = localize; self.detect = detect
        self.converters = converters; self.limiter = limiter
        self.fallbackFolder = fallbackFolder ?? ConversionEngine.downloadsFolder
        self.archiveTool = archiveTool; self.moveToTrash = moveToTrash
        history = Self.loadHistory(from: defaults)
    }

    /// The folders `MediaTools.defaultDirectories()` searches: apps launched from Finder do not inherit the shell's PATH.
    nonisolated static func toolDirectories() -> [String] { MediaTools.defaultDirectories() }

    var engine: ConversionEngine {
        ConversionEngine(converters: converters, environment: environment, limiter: limiter, fallbackFolder: fallbackFolder)
    }

    // MARK: Tools

    /// Detects off the main thread. Never called from `init`: building a manager must not launch ffmpeg.
    func refreshTools() {
        detectionGeneration += 1
        let generation = detectionGeneration, detect = detect
        detection = Task { [weak self] in
            // A tool search and ffmpeg's encoder list block: a queue of their own, not the concurrency pool.
            let found = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: detect()) }
            }
            guard let self, self.detectionGeneration == generation else { return }
            self.detection = nil
            if self.environment != found { self.environment = found }
            self.toolsChecked = true
        }
    }

    /// A newer detection replaces an older one; wait for whichever answers last.
    private func awaitDetection() async {
        while let current = detection {
            await current.value
            if detection == current { break }
        }
    }

    // MARK: Offers and the waiting list

    func offers(for urls: [URL]) -> [TargetOffer] { engine.offers(for: urls) }
    func faces(for urls: [URL]) -> DonutFaces { engine.faces(for: urls) }

    private func refreshOffers() {
        let offers = pending.isEmpty ? [] : engine.offers(for: pending)
        if offers != pendingOffers { pendingOffers = offers }
    }

    /// Existing items only, each once, in the order given after the ones already waiting.
    func add(_ urls: [URL]) {
        var known = Set(pending.map(\.standardizedFileURL.path)), added: [URL] = []
        // Compared standardized, kept as given: standardizing also drops "/private" from "/private/var/…".
        for url in urls where url.isFileURL {
            var status = stat()
            guard lstat(url.path, &status) == 0, known.insert(url.standardizedFileURL.path).inserted else { continue }
            added.append(url)
        }
        if !added.isEmpty { pending += added }
    }

    // MARK: Conversions

    /// nil options means the stored settings. Returns nil when no file fits the target (and sets `problem`
    /// for a page job).
    @discardableResult
    func start(_ urls: [URL], target: ConversionTarget, origin: ConversionActivity.Origin,
               options: ConversionOptions? = nil) -> UUID? {
        let engine = engine
        // Before a running detection has answered, a target that needs a tool may still turn out to be
        // available; the engine reports it as needed if it is not.
        let detecting = detection != nil
        var seen = Set<String>(), sources: [URL] = [], needs: String?
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            switch engine.availability(of: target, for: url) {
            case .available: sources.append(url)
            case .needs(let tool): if detecting { sources.append(url) } else { needs = needs ?? tool }
            case .unsupported: continue
            }
        }
        guard !sources.isEmpty, sources.count >= max(1, target.minimumInputs) else {
            if origin == .page {
                problem = !sources.isEmpty ? UserMessage("Birleştirmek için en az iki dosya gerekir.")
                    : needs.map { UserMessage("Bu dönüştürme için %@ gerekli.", detail: $0) } ?? UserMessage("Bu dosya bu biçime dönüştürülemiyor.")
            }
            return nil
        }
        // Finder hands over a drag in no useful order; the page's list is the order the user arranged.
        if target.combines, case .donut = origin {
            sources.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        let suffix = target.suffixKey.map(localize) ?? target.fixedSuffix ?? ""
        let job = ConversionJob(sources: sources, target: target, options: options ?? settings().options, nameSuffix: suffix)
        insert(ConversionActivity(id: job.id, origin: origin, count: job.distinctSources.count,
                                  targetTitle: target.title, titleIsKey: target.titleIsKey))
        if origin == .page { problem = nil; pageSources[job.id] = Set(sources.map(\.standardizedFileURL.path)) }
        let id = job.id
        jobs[id] = Task { [weak self] in
            await self?.awaitDetection()
            guard let self else { return }
            let relay = Relay { [weak self] state in self?.receive(state, for: id) }
            let result = await self.engine.run(job, moveToTrash: self.moveToTrash, events: { relay.record($0) })
            self.finish(result, origin: origin, submitted: urls)
        }
        return id
    }

    /// The page's button: `pending`, `targetID` and the draft fields.
    /// Some waiting file is already being converted by a page job.
    var isConvertingPending: Bool {
        let running = pageSources.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        return pending.contains { running.contains($0.standardizedFileURL.path) }
    }

    func startPending() {
        guard !pending.isEmpty, !isConvertingPending, let targetID, let target = TargetCatalog.target(id: targetID) else { return }
        var options = settings().options
        options.imageResize = draftResize; options.videoMaxHeight = draftMaxHeight; options.removeAudio = draftRemoveAudio
        guard start(pending, target: target, origin: .page, options: options) != nil else { return }
        // The job has taken them; the next one starts from the stored settings again.
        draftResize = .original; draftMaxHeight = 0; draftRemoveAudio = false
    }

    /// The ring's entry. `flip` and a greyed slice do nothing.
    func drop(_ urls: [URL], on slice: DonutSlice, at centre: CGPoint) {
        guard slice.enabled else { return }
        switch slice.content {
        case .flip: return
        case .target(let target): start(urls, target: target, origin: .donut(centre))
        case .action(let action): perform(action, on: urls, origin: .donut(centre))
        }
    }

    func cancel(_ id: UUID) {
        jobs[id]?.cancel()
        archiveControls[id]?.cancel()
    }

    /// A finished activity.
    func dismiss(_ id: UUID) {
        activities.removeAll { $0.id == id && $0.phase == .finished }
    }

    func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }

    private func receive(_ state: Relay.State, for id: UUID) {
        guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].phase != .finished else { return }
        var activity = activities[index]
        if !state.started.isEmpty { activity.phase = .running }
        if let fraction = state.fraction {
            activity.fraction = fraction
        } else if !state.progress.isEmpty {
            let done = (0..<activity.count).reduce(0.0) { $0 + (state.finished[$1] != nil ? 1 : state.progress[$1] ?? 0) }
            activity.fraction = min(1, done / Double(max(1, activity.count)))
        }
        let outcomes = Array(state.finished.values)
        activity.converted = outcomes.filter { if case .converted = $0 { true } else { false } }.count
        activity.failed = outcomes.filter { if case .failed = $0 { true } else { false } }.count
        activity.skipped = outcomes.filter { if case .skipped = $0 { true } else { false } }.count
        // Each file is published as it finishes; what is already on disk is known before the job ends.
        var published: [URL] = []
        for slot in state.finished.keys.sorted() {
            if case .converted(let urls)? = state.finished[slot] {
                for url in urls where !published.contains(url) { published.append(url) }
            }
        }
        activity.outputs = published
        if activity != activities[index] { activities[index] = activity }
        if state.started.count > starts[id] ?? 0 {
            starts[id] = state.started.count
            persistWorkFolders()
        }
    }

    private func finish(_ result: ConversionResult, origin: ConversionActivity.Origin, submitted: [URL]) {
        let id = result.job.id
        jobs[id] = nil; starts[id] = nil; pageSources[id] = nil
        var problems: [ConversionActivity.Problem] = []
        for (source, outcome) in zip(result.sources, result.outcomes) {
            switch outcome {
            case .failed(let failure):
                problems.append(.init(name: source.lastPathComponent, message: UserMessage(failure.key, detail: failure.detail), failed: true))
            case .skipped(let key):
                problems.append(.init(name: source.lastPathComponent, message: UserMessage(key), failed: false))
            case .converted, .cancelled: break
            }
        }
        // A job that was cancelled before it touched anything leaves no trace in the history.
        let touched = result.converted + result.failed + result.skipped > 0
        conclude(id, converted: result.converted, failed: result.failed, skipped: result.skipped, cancelled: result.wasCancelled,
                 outputs: result.outputs, problems: problems, notices: result.notices.map { UserMessage($0) },
                 record: touched ? ConversionRecord.make(from: result, origin: Self.recordOrigin(origin), date: Date()) : nil)
        if origin == .page {
            // What failed or was stopped stays waiting for another try; the rest of what was sent leaves the list.
            let kept = Set(zip(result.sources, result.outcomes).compactMap { source, outcome -> String? in
                switch outcome {
                case .failed, .cancelled: source.standardizedFileURL.path
                case .converted, .skipped: nil
                }
            })
            let done = Set(submitted.map(\.standardizedFileURL.path)).subtracting(kept)
            if pending.contains(where: { done.contains($0.standardizedFileURL.path) }) {
                pending.removeAll { done.contains($0.standardizedFileURL.path) }
            }
        }
        persistWorkFolders()
    }

    private func insert(_ activity: ConversionActivity) {
        activities.insert(activity, at: 0)
    }

    private func conclude(_ id: UUID, converted: Int, failed: Int, skipped: Int, cancelled: Bool, outputs: [URL],
                          problems: [ConversionActivity.Problem], notices: [UserMessage], record: ConversionRecord?) {
        if let record {
            history.insert(record, at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
            saveHistory()
        }
        // Built on a copy and published once: an observer must never see the job vanish in between.
        var list = activities
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        var activity = list.remove(at: index)
        activity.phase = .finished
        if activity.fraction != nil { activity.fraction = 1 }
        activity.converted = converted; activity.failed = failed; activity.skipped = skipped
        activity.cancelled = cancelled; activity.outputs = outputs
        activity.problems = Array(problems.prefix(Self.problemLines))
        activity.moreProblems = max(0, problems.count - Self.problemLines)
        activity.notices = notices; activity.recordID = record?.id
        // Unfinished ones first, then the finished ones, newest first.
        list.insert(activity, at: list.firstIndex { $0.phase == .finished } ?? list.endIndex)
        let finished = list.indices.filter { list[$0].phase == .finished }
        if finished.count > Self.finishedLimit {
            let extra = Set(finished.suffix(finished.count - Self.finishedLimit).map { list[$0].id })
            list.removeAll { extra.contains($0.id) }
        }
        activities = list
    }

    private static func recordOrigin(_ origin: ConversionActivity.Origin) -> ConversionRecord.Origin {
        switch origin {
        case .donut: .donut
        case .page: .page
        case .watch: .watch
        }
    }

    // MARK: Actions

    func perform(_ action: DonutAction, on urls: [URL], origin: ConversionActivity.Origin) {
        var seen = Set<String>()
        let files = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        guard !files.isEmpty else { return }
        let archives = files.filter { FormatRegistry.format(of: $0)?.family == .archive }
        switch action {
        case .zip, .sevenZip: compress(files, as: action, origin: origin)
        case .extract:
            guard !archives.isEmpty else {
                if origin == .page { problem = UserMessage("Bu dosya bu biçime dönüştürülemiyor.") }
                return
            }
            runArchive(action, steps: archives.map { archive in
                let work: ArchiveWork = { service, control, output in
                    [try await service.extract(archive, to: archive.deletingLastPathComponent(), control: control, output: output)]
                }
                return ([archive], work)
            }, origin: origin)
        case .openArchive:
            if let archive = archives.first { onOpenArchive?(archive) }
        case .copyPath:
            pasteboard.clearContents()
            pasteboard.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            announce(action, count: files.count, origin: origin, notice: UserMessage("Yol kopyalandı"))
        case .airDrop:
            if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) {
                service.perform(withItems: files)
            } else {
                announce(action, count: files.count, origin: origin, notice: UserMessage("AirDrop şu anda kullanılamıyor."))
            }
        case .openConverter: onOpenConverter?(files)
        }
    }

    /// An action that is over as soon as it is done, shown so the ring and the cards can say so.
    private func announce(_ action: DonutAction, count: Int, origin: ConversionActivity.Origin, notice: UserMessage) {
        let id = UUID()
        insert(ConversionActivity(id: id, origin: origin, count: count, targetTitle: action.title, titleIsKey: action.titleIsKey))
        conclude(id, converted: 0, failed: 0, skipped: 0, cancelled: false, outputs: [], problems: [], notices: [notice], record: nil)
    }

    /// One archive of all the files, next to them: named after the file when there is one, else "Arşiv".
    private func compress(_ files: [URL], as action: DonutAction, origin: ConversionActivity.Origin) {
        let parent = files[0].deletingLastPathComponent()
        // The archive keeps paths relative to the files' common folder: from two folders it would carry their names.
        guard files.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path }) else {
            if origin == .page { problem = UserMessage("Dosyalar aynı klasörde olmalı.") }
            return
        }
        let base = files.count == 1 ? OutputNaming.baseName(of: files[0], format: FormatRegistry.format(of: files[0])) : localize("Arşiv")
        var options = ArchiveOptions()
        options.format = action == .zip ? .zip : .sevenZip
        let format = options
        // `create` refuses a destination that exists, so a free name is chosen first; one that another
        // archive job of this app has chosen and not written yet counts as taken too.
        let ext = action == .zip ? "zip" : "7z", name = OutputNaming.cleaned(base)
        let claimed = Set(claimedArchives.values)
        var destination = OutputNaming.available(named: name, extension: ext, in: parent)
        var number = 2
        while claimed.contains(destination.path) {
            destination = OutputNaming.available(named: "\(name) \(number)", extension: ext, in: parent)
            number += 1
        }
        let chosen = destination
        let work: ArchiveWork = { service, control, output in
            try await service.create(files: files, at: chosen, options: format, control: control, output: output)
        }
        runArchive(action, steps: [(files, work)], origin: origin, claim: chosen.path)
    }

    private typealias ArchiveWork = @Sendable (ArchiveService, JobControl, @escaping @Sendable (String) -> Void) async throws -> [URL]

    /// Steps run one after another; each has its sources and either publishes items or fails for all of them.
    private func runArchive(_ action: DonutAction, steps: [(sources: [URL], work: ArchiveWork)], origin: ConversionActivity.Origin,
                            claim: String? = nil) {
        let id = UUID(), count = steps.reduce(0) { $0 + $1.sources.count }
        if let claim { claimedArchives[id] = claim }
        var activity = ConversionActivity(id: id, origin: origin, count: count, targetTitle: action.title, titleIsKey: action.titleIsKey)
        activity.phase = .running
        insert(activity)
        if origin == .page { problem = nil }
        guard let tool = archiveTool, FileManager.default.isExecutableFile(atPath: tool.path) else {
            let message = UserMessage("Arşiv işlemi başarısız: %@", detail: "7zz")
            concludeArchive(id, action: action, origin: origin, sources: steps.flatMap(\.sources), outputs: [], converted: 0,
                            failures: steps.flatMap { step in step.sources.map { ($0, message) } }, cancelled: false)
            return
        }
        let service = ArchiveService(tool: tool), control = JobControl()
        archiveControls[id] = control
        let relay = Relay { [weak self] state in self?.receive(state, for: id) }
        Task { [weak self] in
            var outputs: [URL] = [], failures: [(URL, UserMessage)] = [], converted = 0, cancelled = false, locked = false
            for (number, step) in steps.enumerated() {
                guard !cancelled else { break }
                let output: @Sendable (String) -> Void = { text in
                    guard let percent = Self.percent(in: text) else { return }
                    relay.update { $0.fraction = (Double(number) + percent) / Double(steps.count) }
                }
                do {
                    outputs += try await step.work(service, control, output)
                    converted += step.sources.count
                } catch {
                    if (try? control.check()) == nil || error is CancellationError { cancelled = true; break }
                    switch error {
                    case ArchiveError.cancelled: cancelled = true
                    // Nobody here can ask for a password; the archive manager can.
                    case ArchiveError.password:
                        locked = true
                        if let archive = step.sources.first { self?.onOpenArchive?(archive) }
                    default:
                        let message = Self.message(for: error)
                        failures += step.sources.map { ($0, message) }
                    }
                }
            }
            self?.concludeArchive(id, action: action, origin: origin, sources: steps.flatMap(\.sources), outputs: outputs,
                                  converted: converted, failures: failures, cancelled: cancelled,
                                  notices: locked ? [UserMessage("Arşiv parola korumalı; arşiv yöneticisinde açıldı.")] : [])
        }
    }

    private func concludeArchive(_ id: UUID, action: DonutAction, origin: ConversionActivity.Origin, sources: [URL], outputs: [URL],
                                 converted: Int, failures: [(URL, UserMessage)], cancelled: Bool, notices: [UserMessage] = []) {
        archiveControls[id] = nil; claimedArchives[id] = nil
        var record: ConversionRecord?
        if converted + failures.count > 0 {
            let problems = failures.map { ConversionRecord.Problem(source: $0.0.path, key: $0.1.key, detail: $0.1.detail, failed: true) }
            record = ConversionRecord(id: id, date: Date(), origin: Self.recordOrigin(origin), targetID: "action." + action.rawValue,
                                      targetTitle: action.title, titleIsKey: action.titleIsKey, sources: sources.map(\.path),
                                      outputs: outputs.compactMap { ConversionRecord.Output(recording: $0) },
                                      problems: Array(problems.prefix(ConversionRecord.problemLimit)),
                                      converted: converted, failures: failures.count, skipped: 0, wasCancelled: cancelled)
        }
        conclude(id, converted: converted, failed: failures.count, skipped: 0, cancelled: cancelled, outputs: outputs,
                 problems: failures.map { .init(name: $0.0.lastPathComponent, message: $0.1, failed: true) }, notices: notices, record: record)
    }

    /// ArchiveCore speaks in codes and raw 7-Zip output; only the code or the last line reaches the user.
    private static func message(for error: Error) -> UserMessage {
        let detail: String
        switch error {
        case ArchiveError.linksUnsupported(let name): return UserMessage("Kısayol içeren klasörler arşivlenemiyor: %@", detail: name)
        case ArchiveError.unsafePath: detail = "UNSAFE_PATH"
        case ArchiveError.message(let code): detail = code
        case ArchiveError.engine(let status, let output):
            detail = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
                .last { !$0.isEmpty } ?? "7-Zip (\(status))"
        default: detail = error.localizedDescription
        }
        return UserMessage("Arşiv işlemi başarısız: %@", detail: detail)
    }

    /// The last "42%" 7-Zip printed in this piece of output.
    nonisolated private static func percent(in text: String) -> Double? {
        guard let match = text.matches(of: #/(\d{1,3})%/#).last, let value = Double(match.output.1), value <= 100 else { return nil }
        return value / 100
    }

    // MARK: History

    /// Unchanged outputs go to the Trash and the record goes. Changed ones stay where they are, and
    /// `problem` says how many. If the Trash refuses an item, the record stays for another try.
    func undo(_ record: ConversionRecord) {
        guard let stored = history.first(where: { $0.id == record.id }), undoing.insert(stored.id).inserted else { return }
        let moveToTrash = moveToTrash
        // The Trash may take long on another volume or wait for a permission prompt.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = stored.unchangedOutputs()
            var refused: String?
            for item in items {
                do { try moveToTrash(item) } catch { refused = refused ?? item.lastPathComponent }
            }
            let left = Self.leftAlone(stored, moved: items)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishUndo(stored.id, left: left, refused: refused) }
            }
        }
    }

    private func finishUndo(_ id: UUID, left: Int, refused: String?) {
        undoing.remove(id)
        if let refused { problem = UserMessage("Çöp Sepeti’ne taşınamadı: %@", detail: refused); return }
        history.removeAll { $0.id == id }
        saveHistory()
        for index in activities.indices where activities[index].recordID == id { activities[index].recordID = nil }
        switch left {
        case 0: problem = nil
        case 1: problem = UserMessage("Değişen 1 dosya yerinde bırakıldı.")
        default: problem = UserMessage("Değişen %@ dosya yerinde bırakıldı.", detail: String(left))
        }
    }

    /// Recorded files that are still there and were not moved: what the user changed afterwards.
    nonisolated private static func leftAlone(_ record: ConversionRecord, moved: [URL]) -> Int {
        let movedPaths = Set(moved.map(\.path))
        func exists(_ path: String) -> Bool { var status = stat(); return lstat(path, &status) == 0 }
        return record.outputs.reduce(0) { total, output in
            guard !movedPaths.contains(output.path) else { return total }
            guard !output.files.isEmpty else { return total + (exists(output.path) ? 1 : 0) }
            let files = output.files.filter { !$0.path.hasSuffix("/") && ($0.path as NSString).lastPathComponent != ".DS_Store" }
                .map { (output.path as NSString).appendingPathComponent($0.path) }
            return total + files.filter { !movedPaths.contains($0) && exists($0) }.count
        }
    }

    /// Its failed sources that still exist, to the same target, as a page job.
    func retry(_ record: ConversionRecord) {
        let sources = record.retryable()
        guard !sources.isEmpty else { return }
        if record.targetID.hasPrefix("action."), let action = DonutAction(rawValue: String(record.targetID.dropFirst("action.".count))) {
            perform(action, on: sources, origin: .page)
        } else if let target = TargetCatalog.target(id: record.targetID) {
            var options = settings().options
            if record.origin == .watch {
                // A watched folder's file never goes to the Trash, and its result belongs in the rule's results folder.
                options.trashOriginals = false
                let folder = record.outputs.first.map { (($0.path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
                options.location = .subfolder(folder.flatMap { OutputLocation.isSafeName($0) ? $0 : nil } ?? localize("Dönüştürülenler"))
            }
            guard start(sources, target: target, origin: .page, options: options) != nil else { return }
        } else { return }
        // These files are in a new job now; the old record no longer offers them again.
        let retried = Set(sources.map(\.path))
        if let index = history.firstIndex(where: { $0.id == record.id }) {
            history[index].problems.removeAll { $0.failed && retried.contains($0.source) }
            saveHistory()
        }
    }

    func clearHistory() {
        history = []
        saveHistory()
        for index in activities.indices where activities[index].recordID != nil { activities[index].recordID = nil }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) }
    }

    /// Element by element: one record another version wrote badly drops only itself.
    private static func loadHistory(from defaults: UserDefaults) -> [ConversionRecord] {
        guard let data = defaults.data(forKey: historyKey),
              let stored = try? JSONDecoder().decode([StoredRecord].self, from: data) else { return [] }
        return Array(stored.compactMap(\.record).prefix(historyLimit))
    }

    private struct StoredRecord: Decodable {
        let record: ConversionRecord?
        init(from decoder: Decoder) throws { record = try? ConversionRecord(from: decoder) }
    }

    // MARK: The ring's introduction

    /// Arms the one-time intro.
    func donutOpened() {
        if !introVisible, !defaults.bool(forKey: Self.introKey) { introArmed = true }
    }

    /// Shows it, once: after the first ring has closed, so it never covers a drag.
    func donutClosed() {
        guard introArmed else { return }
        introArmed = false
        defaults.set(true, forKey: Self.introKey)
        introVisible = true
    }

    func dismissIntro() { introVisible = false }

    // MARK: Quit and launch

    /// Launch: leftovers of a crashed run. Only folders the engine made (`NSIRD_…` inside `TemporaryItems`).
    func discardStaleWorkFolders() {
        let live = Set(ConversionEngine.liveWorkFolders().map(\.path))
        for path in defaults.stringArray(forKey: Self.workFoldersKey) ?? [] where !live.contains(path) && Self.isWorkFolder(path) {
            var status = stat()
            guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
        persistWorkFolders()
    }

    /// Quit: the app exits right after this returns, so nothing may be left to a poll or a later callback.
    func stop() {
        for task in jobs.values { task.cancel() }
        for control in archiveControls.values { control.cancel() }
        ToolProcess.terminateAll()
        for folder in ConversionEngine.liveWorkFolders() { try? FileManager.default.removeItem(at: folder) }
        persistWorkFolders()
    }

    /// The live work folders, and the remembered ones that still exist, so a crash leaves a list behind.
    private func persistWorkFolders() {
        var paths: [String] = []
        for path in (defaults.stringArray(forKey: Self.workFoldersKey) ?? []) + ConversionEngine.liveWorkFolders().map(\.path)
        where Self.isWorkFolder(path) && !paths.contains(path) && FileManager.default.fileExists(atPath: path) {
            paths.append(path)
        }
        if paths != defaults.stringArray(forKey: Self.workFoldersKey) ?? [] { defaults.set(paths, forKey: Self.workFoldersKey) }
    }

    private static func isWorkFolder(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("NSIRD_") && path.contains("/TemporaryItems/")
    }

    // MARK: Events

    /// Gathers a job's events from the engine's threads and hands the latest state to the main actor at
    /// most 20 times a second. `record` returns at once: the engine sends progress under a lock.
    private final class Relay: @unchecked Sendable {
        struct State {
            var started = Set<Int>()
            var progress: [Int: Double] = [:]
            var finished: [Int: ConversionOutcome] = [:]
            /// An archive action's own measure.
            var fraction: Double?
        }
        private let lock = NSLock()
        private var state = State()
        private var scheduled = false
        private var delivered = DispatchTime(uptimeNanoseconds: 0)
        private let deliver: @MainActor (State) -> Void

        init(deliver: @escaping @MainActor (State) -> Void) { self.deliver = deliver }

        func record(_ event: ConversionEvent) {
            update { state in
                switch event {
                case .started(let index): state.started.insert(index)
                case .progress(let index, let fraction): state.progress[index] = fraction
                case .finished(let index, let outcome): state.finished[index] = outcome
                }
            }
        }

        func update(_ change: (inout State) -> Void) {
            lock.lock()
            change(&state)
            let due: DispatchTime? = scheduled ? nil : max(.now(), delivered + .milliseconds(50))
            scheduled = true
            lock.unlock()
            guard let due else { return }
            DispatchQueue.main.asyncAfter(deadline: due) { [self] in
                lock.lock()
                scheduled = false; delivered = .now()
                let snapshot = state
                lock.unlock()
                MainActor.assumeIsolated { deliver(snapshot) }
            }
        }
    }
}
