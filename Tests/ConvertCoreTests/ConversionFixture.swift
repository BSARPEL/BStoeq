import ConvertCore
import Foundation

/// What every ConvertCore test stands on: a temporary root of its own (`barlet-<area>-<UUID>`), work
/// folders, request and context builders, a cancel flag, a Trash and a Downloads folder that are folders
/// of the fixture, and a stand-in converter. Nothing here reaches the user's files.
///
///     private var fixture: ConversionFixture!
///     override func setUpWithError() throws { fixture = try ConversionFixture(area: "images") }
///     override func tearDownWithError() throws { fixture.remove() }
final class ConversionFixture: @unchecked Sendable {
    struct Missing: Error, CustomStringConvertible { let description: String }

    /// A flag that can be set from any thread.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Collects what an engine reports, from whatever thread it arrives on.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [ConversionEvent] = []
        var events: [ConversionEvent] { lock.withLock { seen } }
        /// Pass as `events:`.
        var record: @Sendable (ConversionEvent) -> Void { { [self] event in lock.withLock { seen.append(event) } } }
        func started(_ index: Int) -> Bool { events.contains(.started(index: index)) }
    }

    /// A converter that does what the test says. Left alone it follows the rule of every converter (a
    /// plain format target of the source's own format is unsupported), accepts everything else and
    /// writes one small file named `request.outputURL()`.
    ///
    ///     Fake()                                          // accepts everything, writes one file
    ///     Fake(sources: ["pdf"], targets: ["png"])        // only these format and target ids
    ///     Fake { request, context in … }                  // its own work
    ///     Fake(sources: ["pdf"]) { request, context in … }
    ///     Fake(accepts: { target, source, environment in … }, caveat: { target, source in … })
    ///     Fake(accepts: { … }) { request, context in … }
    struct Fake: Converter {
        typealias Accepts = @Sendable (ConversionTarget, FileFormat, ConversionEnvironment) -> TargetAvailability
        typealias Caveat = @Sendable (ConversionTarget, FileFormat) -> String?
        typealias Body = @Sendable (ConversionRequest, ConversionContext) async throws -> [URL]

        var accepts: Accepts
        var caveat: Caveat
        var body: Body

        init() { self.init(accepts: Fake.everything) }

        /// Accepts only these source formats and these targets (ids; nil means any).
        init(sources: Set<String>?, targets: Set<String>? = nil) { self.init(sources: sources, targets: targets, body: Fake.write) }

        init(sources: Set<String>? = nil, targets: Set<String>? = nil, body: @escaping Body) {
            self.init(accepts: { target, source, environment in
                guard sources?.contains(source.id) ?? true, targets?.contains(target.id) ?? true else { return .unsupported }
                return Fake.everything(target, source, environment)
            }, body: body)
        }

        init(accepts: @escaping Accepts, caveat: @escaping Caveat = { _, _ in nil }) { self.init(accepts: accepts, caveat: caveat, body: Fake.write) }

        init(accepts: @escaping Accepts, caveat: @escaping Caveat = { _, _ in nil }, body: @escaping Body) {
            self.accepts = accepts; self.caveat = caveat; self.body = body
        }

        static let everything: Accepts = { target, source, _ in target.id == source.id ? .unsupported : .available }
        static let write: Body = { request, _ in
            let url = request.outputURL()
            let names = request.sources.map(\.lastPathComponent).joined(separator: ", ")
            try Data("\(request.target.id) <- \(names)".utf8).write(to: url)
            return [url]
        }

        func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
            accepts(target, source, environment)
        }
        func note(for target: ConversionTarget, source: FileFormat) -> String? { caveat(target, source) }
        func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] { try await body(request, context) }
    }

    /// Canonical, because paths are compared and /var is a link to /private/var.
    let root: URL
    /// Stands in for the Trash.
    let trash: URL
    /// Stands in for the Downloads folder an engine falls back to.
    let fallback: URL
    /// What `context()` reports as cancelled.
    let cancel = Flag()

    private let lock = NSLock()
    private var seenProgress: [Double] = []
    private var seenNotes: [String] = []
    private var moved: [URL] = []
    private var running: [Task<[URL], Error>] = []

    init(area: String) throws {
        guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw Missing(description: "the temporary folder") }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("barlet-\(area)-\(UUID().uuidString)", isDirectory: true)
        trash = root.appendingPathComponent(".TestTrash", isDirectory: true)
        fallback = root.appendingPathComponent("Fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
    }

    /// For `tearDownWithError`.
    func remove() { try? FileManager.default.removeItem(at: root) }

    // MARK: Files

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative, isDirectory: false) }

    @discardableResult
    func write(_ relative: String, _ data: Data = Data("fixture".utf8)) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A new empty folder, as the engine hands one to a converter.
    func workFolder() throws -> URL { try folder("work/\(UUID().uuidString)") }

    /// A stand-in for a command-line tool: a shell script with this body. The first run of a new script
    /// can take a moment to begin, so a test that waits for it waits for something it prints.
    @discardableResult
    func tool(_ relative: String, _ script: String, mode: Int = 0o755) throws -> URL {
        let url = try write(relative, Data("#!/bin/sh\n\(script)\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    /// Names in a folder, sorted, without hidden ones.
    func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: Requests

    func target(_ id: String) throws -> ConversionTarget {
        guard let target = TargetCatalog.target(id: id) else { throw Missing(description: "the target \(id)") }
        return target
    }

    /// The request the engine would make for these sources: formats from their names, the target's
    /// overrides applied to the options, "*" resolved to the first source's format, the base name of the
    /// first source and a new work folder.
    func request(_ sources: [URL], target id: String, options: ConversionOptions = ConversionOptions(),
                 environment: ConversionEnvironment = ConversionEnvironment(), baseName: String? = nil) throws -> ConversionRequest {
        try request(sources, target: try target(id), options: options, environment: environment, baseName: baseName)
    }

    func request(_ sources: [URL], target: ConversionTarget, options: ConversionOptions = ConversionOptions(),
                 environment: ConversionEnvironment = ConversionEnvironment(), baseName: String? = nil) throws -> ConversionRequest {
        let formats = try sources.map { source -> FileFormat in
            guard let format = FormatRegistry.format(of: source) else { throw Missing(description: "a format for \(source.lastPathComponent)") }
            return format
        }
        guard let first = formats.first else { throw Missing(description: "sources") }
        guard let output = target.format == "*" ? first : FormatRegistry.format(id: target.format) else {
            throw Missing(description: "the format \(target.format)")
        }
        var merged = options.applying(target.overrides)
        merged.normalize()
        return ConversionRequest(sources: sources, formats: formats, target: target, outputFormat: output, options: merged,
                                 workFolder: try workFolder(),
                                 baseName: baseName ?? OutputNaming.cleaned(OutputNaming.baseName(of: sources[0], format: first)),
                                 environment: environment)
    }

    /// A context wired to the fixture: it reports `cancel`, and keeps progress and notes in `progress`
    /// and `notes`. The flag alone stops only work that polls it (`checkCancelled()`); a converter that
    /// awaits a tool or AVFoundation is stopped by cancelling its task, which the engine does at the
    /// same moment. `start` and `cancelAll()` do both.
    func context() -> ConversionContext {
        ConversionContext(isCancelled: { [cancel] in cancel.isSet },
                          progress: { [self] fraction in lock.withLock { seenProgress.append(fraction) } },
                          note: { [self] key in lock.withLock { seenNotes.append(key) } })
    }
    var progress: [Double] { lock.withLock { seenProgress } }
    var notes: [String] { lock.withLock { seenNotes } }

    /// Calls a converter the way the engine does: in a task of its own, with `context()`.
    func start(_ converter: any Converter, _ request: ConversionRequest) -> Task<[URL], Error> {
        let context = context()
        let task = Task { try await converter.convert(request, context: context) }
        lock.withLock { running.append(task) }
        return task
    }

    /// Cancels the way the engine does: sets `cancel` and cancels every task `start` made.
    func cancelAll() {
        cancel.set()
        for task in lock.withLock({ running }) { task.cancel() }
    }

    // MARK: Engine

    /// An engine whose fallback folder is the fixture's, never the user's Downloads.
    func engine(_ converters: [any Converter], environment: ConversionEnvironment = ConversionEnvironment(),
                limiter: ConversionLimiter = ConversionLimiter()) -> ConversionEngine {
        ConversionEngine(converters: converters, environment: environment, limiter: limiter, fallbackFolder: fallback)
    }

    func job(_ sources: [URL], target id: String, options: ConversionOptions = ConversionOptions(), suffix: String = "") throws -> ConversionJob {
        ConversionJob(sources: sources, target: try target(id), options: options, nameSuffix: suffix)
    }

    /// Pass as `moveToTrash:`. Moves into the fixture's Trash folder and remembers what went.
    var moveToTrash: @Sendable (URL) throws -> Void {
        { [self] url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)"))
            lock.withLock { moved.append(url) }
        }
    }
    var trashed: [URL] { lock.withLock { moved } }
}
