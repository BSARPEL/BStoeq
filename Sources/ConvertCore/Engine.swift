import Foundation
import os

/// One for the whole process: the limits hold across every job, whoever started it.
/// Two pools, each first come first served: audio and video requests (an encoder uses every core by
/// itself), and everything else.
public final class ConversionLimiter: @unchecked Sendable {
    /// Touched only under `lock`.
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Bool, Never>?
        var abandoned = false
    }

    private let lock = NSLock()
    private var free: [Int]
    private var waiting: [[Waiter]] = [[], []]

    public init(media: Int = 2, other: Int = min(4, ProcessInfo.processInfo.activeProcessorCount)) {
        free = [max(1, media), max(1, other)]
    }

    /// Waits for a slot. False when the waiting task was cancelled; no slot is held then.
    func acquire(media: Bool) async -> Bool {
        let pool = media ? 0 : 1
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let answer: Bool? = lock.withLock {
                    // The cancellation handler may have run before this.
                    if waiter.abandoned { return false }
                    // A free slot means nobody is waiting: `release` hands a slot straight to the first in line.
                    if free[pool] > 0 { free[pool] -= 1; return true }
                    waiter.continuation = continuation
                    waiting[pool].append(waiter)
                    return nil
                }
                if let answer { continuation.resume(returning: answer) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
                waiter.abandoned = true
                guard let continuation = waiter.continuation else { return nil }
                waiter.continuation = nil
                waiting[pool].removeAll { $0 === waiter }
                return continuation
            }
            continuation?.resume(returning: false)
        }
    }

    func release(media: Bool) {
        let pool = media ? 0 : 1
        let next: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard !waiting[pool].isEmpty else { free[pool] += 1; return nil }
            let waiter = waiting[pool].removeFirst()
            defer { waiter.continuation = nil }
            return waiter.continuation
        }
        next?.resume(returning: true)
    }
}

/// A target for a set of files, as the ring and the page show it.
public struct TargetOffer: Identifiable, Equatable, Sendable {
    public var id: String { target.id }
    public let target: ConversionTarget
    /// `.available` if any file fits; else the first `.needs`.
    public let availability: TargetAvailability
    /// Files it applies to right now.
    public let fitting: Int
    public let total: Int
    /// The first note among the fitting files.
    public let noteKey: String?

    public init(target: ConversionTarget, availability: TargetAvailability, fitting: Int, total: Int, noteKey: String? = nil) {
        self.target = target; self.availability = availability; self.fitting = fitting; self.total = total; self.noteKey = noteKey
    }

    /// Enough files fit to start: a merge needs two.
    public var isUsable: Bool { availability == .available && fitting >= max(1, target.minimumInputs) }
}

/// What one drop or one press of the button asks for: these files, to this target, with these options.
public struct ConversionJob: Sendable {
    public let id: UUID
    public let sources: [URL]
    public let target: ConversionTarget
    /// Before the target's overrides.
    public let options: ConversionOptions
    /// Already resolved: the localized `suffixKey`, or `fixedSuffix`, or "".
    public let nameSuffix: String

    public init(id: UUID = UUID(), sources: [URL], target: ConversionTarget, options: ConversionOptions, nameSuffix: String = "") {
        self.id = id; self.sources = sources; self.target = target; self.options = options; self.nameSuffix = nameSuffix
    }

    /// The sources without repeats (by standardized path), order kept: what `run` works on, what the
    /// result lists and what event indices point into.
    public var distinctSources: [URL] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

/// How one source ended.
public enum ConversionOutcome: Equatable, Sendable {
    /// What was published: one file, or one folder holding several.
    case converted([URL])
    /// A reason key; not an error.
    case skipped(String)
    case failed(ConversionFailure)
    case cancelled
}

/// The index points into the job's `distinctSources`, which are its `sources` unless a file is listed twice.
public enum ConversionEvent: Equatable, Sendable {
    /// Sent once the request holds a slot and its work folder exists.
    case started(index: Int)
    case progress(index: Int, fraction: Double)
    case finished(index: Int, outcome: ConversionOutcome)
}

/// How a whole job ended: one outcome per source.
public struct ConversionResult: Sendable {
    public let job: ConversionJob
    /// After de-duplication; `outcomes` is parallel to this.
    public let sources: [URL]
    public let outcomes: [ConversionOutcome]
    /// Keys, each once: engine notices and converter notes.
    public let notices: [String]
    public let originalsTrashed: Bool

    public init(job: ConversionJob, sources: [URL], outcomes: [ConversionOutcome], notices: [String] = [], originalsTrashed: Bool = false) {
        self.job = job; self.sources = sources; self.outcomes = outcomes; self.notices = notices; self.originalsTrashed = originalsTrashed
    }

    /// Distinct published items, in order.
    public var outputs: [URL] {
        var seen = Set<URL>(), items: [URL] = []
        for case .converted(let urls) in outcomes {
            for url in urls where seen.insert(url).inserted { items.append(url) }
        }
        return items
    }
    public var converted: Int { outcomes.filter { if case .converted = $0 { true } else { false } }.count }
    public var failed: Int { outcomes.filter { if case .failed = $0 { true } else { false } }.count }
    public var skipped: Int { outcomes.filter { if case .skipped = $0 { true } else { false } }.count }
    public var wasCancelled: Bool { outcomes.contains(.cancelled) }
}

/// Finds the converter for each file, gives it a private work folder and publishes what it wrote.
/// The file-safety promise lives here: nothing that exists is replaced, nothing is deleted but the
/// engine's own work folders, and the only way an original leaves is the injected Trash.
public struct ConversionEngine: Sendable {
    public let converters: [any Converter]
    public let environment: ConversionEnvironment
    public let limiter: ConversionLimiter
    /// Where a result goes when its own folder cannot be written.
    public let fallbackFolder: URL

    public init(converters: [any Converter], environment: ConversionEnvironment, limiter: ConversionLimiter,
                fallbackFolder: URL = ConversionEngine.downloadsFolder) {
        self.converters = converters; self.environment = environment; self.limiter = limiter; self.fallbackFolder = fallbackFolder
    }

    /// The user's Downloads folder. Naming it does not touch it.
    public static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Every built-in converter, by type name.
    public static func standardConverters() -> [any Converter] {
        [ImageConverter(), PDFConverter(), DocumentConverter(), SubtitleConverter(), DataConverter(), MediaConverter()]
    }

    // MARK: Asking

    /// A symbolic link fits nothing: `run` never follows one.
    public func availability(of target: ConversionTarget, for url: URL) -> TargetAvailability {
        guard !Self.isLink(url), let format = FormatRegistry.format(of: url) else { return .unsupported }
        return answer(target, format).availability
    }

    /// The best answer over every registered format: can anything be turned into this target here?
    public func availability(of target: ConversionTarget) -> TargetAvailability {
        var needs: String?
        for format in FormatRegistry.all {
            switch answer(target, format).availability {
            case .available: return .available
            case .needs(let tool): needs = needs ?? tool
            case .unsupported: continue
            }
        }
        return needs.map { .needs($0) } ?? .unsupported
    }

    /// Whether any converter turns any format of the family (of any family for nil) into the target on
    /// this Mac, or would with a missing tool. The ring leaves out what nothing claims.
    public func claims(_ target: ConversionTarget, family: FileFamily?) -> Bool {
        FormatRegistry.all.contains { (family == nil || $0.family == family) && answer(target, $0).availability != .unsupported }
    }

    /// Every catalog target that fits at least one of the files (or would with a missing tool), in catalog order.
    public func offers(for urls: [URL]) -> [TargetOffer] {
        let formats = urls.compactMap { Self.isLink($0) ? nil : FormatRegistry.format(of: $0) }
        var counts: [FileFormat: Int] = [:], order: [FileFormat] = []
        for format in formats {
            if counts[format] == nil { order.append(format) }
            counts[format, default: 0] += 1
        }
        return TargetCatalog.all.compactMap { target in
            var fitting = 0, needs: String?, note: String?
            for format in order {
                let answer = answer(target, format)
                switch answer.availability {
                case .available:
                    fitting += counts[format] ?? 0
                    note = note ?? answer.converter?.note(for: target, source: format)
                case .needs(let tool): needs = needs ?? tool
                case .unsupported: continue
                }
            }
            if fitting > 0 { return TargetOffer(target: target, availability: .available, fitting: fitting, total: urls.count, noteKey: note) }
            return needs.map { TargetOffer(target: target, availability: .needs($0), fitting: 0, total: urls.count) }
        }
    }

    /// The ring for these files: their toolbar with this Mac's offers.
    public func faces(for urls: [URL]) -> DonutFaces {
        let family = DonutToolbar.family(of: urls)
        return DonutToolbar.faces(for: urls, offers: offers(for: urls), claimed: { claims($0, family: family) })
    }

    /// Whether converting a file of `source` to `target` moves the original to the Trash under these
    /// options: only format conversions inside one family do, never tools, merges or a change of family.
    public static func trashesOriginal(_ target: ConversionTarget, source: FileFormat, options: ConversionOptions) -> Bool {
        guard options.trashOriginals, target.kind == .convert, !target.combines else { return false }
        return (target.format == "*" ? source.family : FormatRegistry.format(id: target.format)?.family) == source.family
    }

    /// Work folders of requests that are running right now, in any engine of this process.
    public static func liveWorkFolders() -> [URL] { ledger.withLock { $0 } }

    // MARK: Running

    /// Converts the job's files and publishes the results. Never throws: every source gets an outcome.
    /// Cancelling the awaiting task stops new requests, tells the running ones and leaves no partial output.
    /// Events may arrive on any thread; for one index they are always started, progress…, finished.
    public func run(_ job: ConversionJob,
                    moveToTrash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                    events: @escaping @Sendable (ConversionEvent) -> Void = { _ in }) async -> ConversionResult {
        let sources = job.distinctSources
        var outcomes = [ConversionOutcome?](repeating: nil, count: sources.count)
        func settle(_ index: Int, _ outcome: ConversionOutcome) {
            outcomes[index] = outcome
            events(.finished(index: index, outcome: outcome))
        }

        var accepted: [(index: Int, format: FileFormat, converter: any Converter)] = []
        for (index, source) in sources.enumerated() {
            switch claim(job.target, source) {
            case .converter(let format, let converter): accepted.append((index, format, converter))
            case .outcome(let outcome): settle(index, outcome)
            }
        }

        var units: [Unit] = []
        if !job.target.combines {
            units = accepted.map { Unit(indices: [$0.index], sources: [sources[$0.index]], formats: [$0.format], converter: $0.converter) }
        } else if let first = accepted.first {
            // One request, handled by the converter that accepts the first file; what it rejects stays out.
            var members = [first]
            for candidate in accepted.dropFirst() {
                if first.converter.availability(of: job.target, for: candidate.format, in: environment) == .available {
                    members.append(candidate)
                } else {
                    settle(candidate.index, .skipped(Self.unfit))
                }
            }
            if members.count < max(1, job.target.minimumInputs) {
                for member in members { settle(member.index, .skipped("Birleştirmek için en az iki dosya gerekir.")) }
            } else {
                units = [Unit(indices: members.map(\.index), sources: members.map { sources[$0.index] },
                              formats: members.map(\.format), converter: first.converter)]
            }
        }

        // A job built by hand gets the same repairs as stored settings: a results folder cannot climb out.
        var merged = job.options.applying(job.target.overrides)
        merged.normalize()
        let options = merged
        let made = OSAllocatedUnfairLock(initialState: [URL]())
        let reports = await withTaskGroup(of: [Report].self) { group -> [Report] in
            // The two pools do not wait for each other.
            for media in [true, false] {
                let lane = units.filter { $0.usesMediaPool == media }
                guard !lane.isEmpty else { continue }
                group.addTask {
                    await self.work(through: lane, media: media, job: job, options: options, made: made, moveToTrash: moveToTrash, events: events)
                }
            }
            var all: [Report] = []
            for await reports in group { all += reports }
            return all
        }
        // A results folder this job made and nothing arrived in is not left beside the user's files.
        // `rmdir` takes an empty folder only, so results and whatever else is in it stay.
        let own = made.withLock { $0 }
        if !own.isEmpty { await ConversionWork.detached { for folder in own { rmdir(folder.path) } } }

        var notices: [String] = []
        var trashed = false
        for report in reports.sorted(by: { $0.indices[0] < $1.indices[0] }) {
            for index in report.indices { outcomes[index] = report.outcome }
            for notice in report.notices where !notices.contains(notice) { notices.append(notice) }
            trashed = trashed || report.trashed
        }
        return ConversionResult(job: job, sources: sources, outcomes: outcomes.map { $0 ?? .cancelled },
                                notices: notices, originalsTrashed: trashed)
    }

    // MARK: Pieces

    private static let unfit = "Bu dosya bu biçime dönüştürülemiyor."
    private static let fallbackNotice = "Klasöre yazılamadığı için sonuç İndirilenler klasörüne kaydedildi."
    private static let trashNotice = "Bazı özgün dosyalar Çöp Sepeti’ne taşınamadı."
    private static let privacyFailure = ConversionFailure("BStoeq’in bu klasöre yazma izni yok. Ayarlar → İzinler bölümünden izin verebilirsin.")
    /// ImageIO fails to write names longer than this many bytes.
    private static let nameLimit = 240
    private static let ledger = OSAllocatedUnfairLock(initialState: [URL]())

    /// One request in the making.
    private struct Unit: Sendable {
        let indices: [Int]
        let sources: [URL]
        let formats: [FileFormat]
        let converter: any Converter
        var usesMediaPool: Bool { formats[0].family == .audio || formats[0].family == .video }
    }

    private struct Report: Sendable {
        let indices: [Int]
        let outcome: ConversionOutcome
        let notices: [String]
        let trashed: Bool
    }

    private enum Claim {
        case converter(FileFormat, any Converter)
        case outcome(ConversionOutcome)
    }

    private struct Place: Sendable {
        let folder: URL
        let work: URL
        let fellBack: Bool
        /// A results folder next to the source: the engine makes it, and makes it again if it is gone.
        let isResultsFolder: Bool
    }

    /// How a request ended once its files were checked and published.
    private struct Delivery: Sendable {
        var outcome: ConversionOutcome
        var notices: [String] = []
        var trashed = false
    }

    enum Refusal { case readOnly, privacy, other }

    private static func isLink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK
    }

    /// The first converter that does the pair; without one, the first tool that is missing for it.
    private func answer(_ target: ConversionTarget, _ format: FileFormat) -> (availability: TargetAvailability, converter: (any Converter)?) {
        var needs: String?
        for converter in converters {
            switch converter.availability(of: target, for: format, in: environment) {
            case .available: return (.available, converter)
            case .needs(let tool): needs = needs ?? tool
            case .unsupported: continue
            }
        }
        return (needs.map { .needs($0) } ?? .unsupported, nil)
    }

    private func claim(_ target: ConversionTarget, _ source: URL) -> Claim {
        var status = stat()
        guard lstat(source.path, &status) == 0 else { return .outcome(.failed(ConversionFailure("Dosya bulunamadı."))) }
        // Files and folders are sources; a link is never followed and so never converted or trashed.
        let kind = status.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR, let format = FormatRegistry.format(of: source) else { return .outcome(.skipped(Self.unfit)) }
        let answer = answer(target, format)
        if let converter = answer.converter { return .converter(format, converter) }
        if case .needs(let tool) = answer.availability {
            return .outcome(.failed(ConversionFailure("Bu dönüştürme için %@ gerekli.", detail: tool)))
        }
        return .outcome(.skipped(Self.unfit))
    }

    /// The requests of one pool, started in order as slots come free.
    private func work(through units: [Unit], media: Bool, job: ConversionJob, options: ConversionOptions,
                      made: OSAllocatedUnfairLock<[URL]>, moveToTrash: @escaping @Sendable (URL) throws -> Void,
                      events: @escaping @Sendable (ConversionEvent) -> Void) async -> [Report] {
        await withTaskGroup(of: Report.self) { group -> [Report] in
            var reports: [Report] = []
            for unit in units {
                guard await limiter.acquire(media: media) else {
                    reports.append(Self.report(unit, .cancelled, events: events))
                    continue
                }
                group.addTask {
                    defer { self.limiter.release(media: media) }
                    return await self.perform(unit, job: job, options: options, made: made, moveToTrash: moveToTrash, events: events)
                }
            }
            for await report in group { reports.append(report) }
            return reports
        }
    }

    /// One request, holding a slot: a work folder, the converter, then the checks, the publishing and the Trash.
    private func perform(_ unit: Unit, job: ConversionJob, options: ConversionOptions,
                         made: OSAllocatedUnfairLock<[URL]>, moveToTrash: @escaping @Sendable (URL) throws -> Void,
                         events: @escaping @Sendable (ConversionEvent) -> Void) async -> Report {
        if Task.isCancelled { return Self.report(unit, .cancelled, events: events) }
        // File work can wait for a slow volume or for a permission prompt: none of it sits on the concurrency pool.
        let place: Place
        switch await ConversionWork.detached({ self.place(for: unit.sources[0], location: options.location, made: made) }) {
        case .success(let found): place = found
        case .failure(let failure): return Self.report(unit, .failed(failure), events: events)
        }
        for index in unit.indices { events(.started(index: index)) }

        let outputFormat = job.target.format == "*" ? unit.formats[0] : FormatRegistry.format(id: job.target.format)
            ?? FileFormat(id: job.target.format, family: .other, label: job.target.format.uppercased(), extensions: [job.target.format])
        // Names are measured the way they reach the disk, decomposed: a localized word can be half as long again there.
        let word = OutputNaming.shortened(Self.onDisk(job.nameSuffix.trimmingCharacters(in: .whitespaces)), toBytes: 60)
        let suffix = word.isEmpty ? "" : " " + word
        // The longest name this request can produce adds to the base name its suffix, a page number
        // ("_p12345"), a number against a taken name (" 9999") and the extension.
        let reserved = suffix.utf8.count + 8 + 6 + 1 + max(10, outputFormat.id.utf8.count)
        let baseName = OutputNaming.shortened(Self.onDisk(OutputNaming.baseName(of: unit.sources[0], format: unit.formats[0])),
                                              toBytes: Self.nameLimit - reserved)
        let request = ConversionRequest(sources: unit.sources, formats: unit.formats, target: job.target, outputFormat: outputFormat,
                                        options: options, workFolder: place.work, baseName: baseName, environment: environment)

        // The flag is what blocking work polls: `Task.isCancelled` is always false on a dispatch thread.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        // What the converter says counts while `convert` runs. A reporter that outlives it (a poll, a timer)
        // is not heard any more: progress is sent under the lock that closes the gate, so none can follow `finished`.
        let heard = OSAllocatedUnfairLock(initialState: (open: true, remarks: [String]()))
        let indices = unit.indices
        let context = ConversionContext(
            isCancelled: { cancelled.withLock { $0 } },
            progress: { fraction in
                guard fraction.isFinite else { return }
                heard.withLock { state in
                    guard state.open else { return }
                    for index in indices { events(.progress(index: index, fraction: min(1, max(0, fraction)))) }
                }
            },
            note: { key in heard.withLock { if $0.open, !$0.remarks.contains(key) { $0.remarks.append(key) } } })
        var written: [URL] = []
        // A cancel that arrived while the folders were being prepared: the converter is not started for it.
        var ended: ConversionOutcome? = Task.isCancelled ? .cancelled : nil
        if ended == nil {
            do {
                // This runs in a child task of `run`, so cancelling `run` also cancels what the converter awaits.
                written = try await withTaskCancellationHandler {
                    try await unit.converter.convert(request, context: context)
                } onCancel: {
                    cancelled.withLock { $0 = true }
                }
            } catch {
                ended = Self.outcome(of: error, cancelled: cancelled.withLock { $0 })
            }
        }
        let remarks = heard.withLock { state -> [String] in
            state.open = false
            return state.remarks
        }

        // Once the converter has returned its files the result is complete: it is published even if
        // cancel was pressed in the last instant. The work folder goes however the request ended.
        let name = baseName + suffix, target = job.target
        var delivery = await ConversionWork.detached { [written, ended] () -> Delivery in
            defer {
                try? FileManager.default.removeItem(at: place.work)
                Self.ledger.withLock { folders in folders.removeAll { $0 == place.work } }
            }
            if let ended { return Delivery(outcome: ended) }
            // A converter's remark means the result is not the whole file ("only the first 30 s"): the original stays.
            return self.deliver(written, as: name, from: unit, target: target, options: options, to: place, made: made,
                                keepOriginals: !remarks.isEmpty, moveToTrash: moveToTrash)
        }
        if case .converted = delivery.outcome {
            for remark in remarks where !delivery.notices.contains(remark) { delivery.notices.append(remark) }
        }
        return Self.report(unit, delivery.outcome, notices: delivery.notices, trashed: delivery.trashed, events: events)
    }

    /// Checks what the converter wrote, publishes it and, where that is asked for, moves the originals to
    /// the Trash. Blocking.
    private func deliver(_ written: [URL], as name: String, from unit: Unit, target: ConversionTarget, options: ConversionOptions,
                         to place: Place, made: OSAllocatedUnfairLock<[URL]>, keepOriginals: Bool,
                         moveToTrash: (URL) throws -> Void) -> Delivery {
        guard let files = Self.checked(written, in: place.work) else {
            return Delivery(outcome: .failed(ConversionFailure("Dönüştürme boş bir dosya üretti.")))
        }
        if target.id == "compress", files.count == 1, unit.sources.count == 1,
           let produced = Self.size(of: files[0]), let original = Self.size(of: unit.sources[0]), produced >= original {
            return Delivery(outcome: .skipped("Zaten yeterince küçük."))
        }

        var notices = place.fellBack ? [Self.fallbackNotice] : []
        let published: URL
        do {
            // One file goes out under its own extension; several go out together as one folder.
            let item = files.count == 1 ? files[0] : try Self.gather(files, in: place.work)
            let ext = files.count == 1 ? Self.ownExtension(of: files[0]) : nil
            do {
                published = try Self.publish(item, named: name, extension: ext, to: place, made: made)
            } catch {
                switch Self.refusal(error) {
                case .readOnly where !place.fellBack:
                    // The work is done; it is kept rather than thrown away with the folder that refused it.
                    try? FileManager.default.createDirectory(at: fallbackFolder, withIntermediateDirectories: true)
                    published = try OutputNaming.publish(item, named: name, extension: ext, in: fallbackFolder)
                    notices.append(Self.fallbackNotice)
                case .privacy:
                    return Delivery(outcome: .failed(Self.privacyFailure))
                default:
                    throw error
                }
            }
        } catch {
            return Delivery(outcome: .failed(ConversionFailure("Dosya kayıt klasörüne taşınamadı: %@", detail: error.localizedDescription)))
        }

        var trashed = false
        for (source, format) in zip(unit.sources, unit.formats) where !keepOriginals && Self.trashesOriginal(target, source: format, options: options) {
            var status = stat()
            guard source.standardizedFileURL.path != published.standardizedFileURL.path, lstat(source.path, &status) == 0 else { continue }
            do { try moveToTrash(source); trashed = true } catch {
                if !notices.contains(Self.trashNotice) { notices.append(Self.trashNotice) }
            }
        }
        return Delivery(outcome: .converted([published]), notices: notices, trashed: trashed)
    }

    /// Publishes into the request's folder. Another job that made the same results folder removes it when
    /// it ends with nothing in it; a result that arrives after that makes the folder once more.
    private static func publish(_ item: URL, named name: String, extension ext: String?, to place: Place,
                                made: OSAllocatedUnfairLock<[URL]>) throws -> URL {
        var attempts = 0
        while true {
            do { return try OutputNaming.publish(item, named: name, extension: ext, in: place.folder) } catch {
                guard place.isResultsFolder, attempts < 3, code(of: error) == ENOENT,
                      makeFolder(place.folder, chosen: false, made: made) == 0 else { throw error }
                attempts += 1
            }
        }
    }

    /// The name as it reaches the disk: cleaned, and decomposed the way a file URL hands names back.
    private static func onDisk(_ name: String) -> String {
        OutputNaming.cleaned(name).decomposedStringWithCanonicalMapping
    }

    private static func report(_ unit: Unit, _ outcome: ConversionOutcome, notices: [String] = [], trashed: Bool = false,
                               events: @Sendable (ConversionEvent) -> Void) -> Report {
        for index in unit.indices { events(.finished(index: index, outcome: outcome)) }
        return Report(indices: unit.indices, outcome: outcome, notices: notices, trashed: trashed)
    }

    /// A converter stopped by the cancel may report whatever its tool said on the way out: that is still a cancel.
    private static func outcome(of error: Error, cancelled: Bool) -> ConversionOutcome {
        if cancelled || error is CancellationError { return .cancelled }
        if let failure = error as? ConversionFailure { return .failed(failure) }
        if let skip = error as? ConversionSkip { return .skipped(skip.key) }
        return .failed(ConversionFailure("Dönüştürülemedi: %@", detail: error.localizedDescription))
    }

    /// Where the result goes and where it is made. A folder that is read-only is replaced by the fallback
    /// folder here, before any work starts; the work folder is on the destination's volume, so publishing
    /// is one rename. Blocking.
    private func place(for source: URL, location: OutputLocation, made: OSAllocatedUnfairLock<[URL]>) -> Result<Place, ConversionFailure> {
        let beside = source.deletingLastPathComponent()
        var folder = beside
        var refused: Int32 = 0
        var isResultsFolder = false
        switch location {
        case .besideSource: break
        case .subfolder(let name):
            folder = beside.appendingPathComponent(name, isDirectory: true)
            refused = Self.makeFolder(folder, chosen: false, made: made)
            isResultsFolder = true
        case .folder(let path):
            folder = URL(fileURLWithPath: path, isDirectory: true)
            refused = Self.makeFolder(folder, chosen: true, made: made)
        }
        // Only what the file modes say is decided this early. A privacy refusal is left to the write itself:
        // that is what makes macOS ask the user, and its answer is the one that counts.
        if refused == 0, access(folder.path, W_OK) != 0, errno == EACCES || errno == EROFS { refused = errno }
        var fellBack = false
        if refused != 0 {
            switch Self.refusal(NSError(domain: NSPOSIXErrorDomain, code: Int(refused))) {
            case .readOnly: fellBack = true
            case .privacy: return .failure(Self.privacyFailure)
            case .other: return .failure(ConversionFailure("Kayıt klasörü kullanılamıyor: %@", detail: String(cString: strerror(refused))))
            }
        }
        while true {
            if fellBack {
                folder = fallbackFolder
                isResultsFolder = false
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            do {
                let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                // Listed from the moment it exists, so a quit in the middle knows what to remove.
                Self.ledger.withLock { $0.append(work) }
                return .success(Place(folder: folder, work: work, fellBack: fellBack, isResultsFolder: isResultsFolder))
            } catch {
                switch Self.refusal(error) {
                case .readOnly where !fellBack: fellBack = true
                case .privacy where !fellBack: return .failure(Self.privacyFailure)
                default: return .failure(ConversionFailure("Kayıt klasörü kullanılamıyor: %@", detail: error.localizedDescription))
                }
            }
        }
    }

    /// Answers 0 or an errno. A results folder next to the source must be a real folder: a link in its
    /// place is not followed; one that this call made is noted in `made`, for the job to remove if it
    /// stays empty. A folder the user chose is taken as given and made if it is gone: that one is theirs.
    private static func makeFolder(_ url: URL, chosen: Bool, made: OSAllocatedUnfairLock<[URL]>) -> Int32 {
        var status = stat()
        if chosen {
            if stat(url.path, &status) == 0 { return status.st_mode & S_IFMT == S_IFDIR ? 0 : ENOTDIR }
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return 0 } catch {
                return code(of: error) ?? EIO
            }
        }
        if mkdir(url.path, 0o755) == 0 {
            made.withLock { if !$0.contains(url) { $0.append(url) } }
            return 0
        }
        let code = errno
        guard code == EEXIST else { return code }
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR ? 0 : ENOTDIR
    }

    /// The POSIX code behind an error, if it has one.
    private static func code(of error: Error) -> Int32? {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, let code = code(of: underlying) { return code }
        guard error.domain == NSCocoaErrorDomain else { return nil }
        switch error.code {
        case NSFileWriteVolumeReadOnlyError: return EROFS
        case NSFileWriteNoPermissionError: return EACCES
        default: return nil
        }
    }

    /// Why a folder refused: read-only (the result goes to the fallback folder), a privacy refusal
    /// (EPERM: the user has to allow the folder), or anything else.
    static func refusal(_ error: Error) -> Refusal {
        switch code(of: error) {
        case EROFS, EACCES: .readOnly
        case EPERM: .privacy
        default: .other
        }
    }

    /// The converter's files, each once, or nil unless every one is a non-empty regular file inside the work folder.
    private static func checked(_ files: [URL], in work: URL) -> [URL]? {
        guard !files.isEmpty, let root = resolved(work.path) else { return nil }
        var seen = Set<String>(), result: [URL] = []
        for file in files {
            var status = stat()
            guard lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size > 0,
                  let parent = resolved(file.deletingLastPathComponent().path),
                  parent == root || parent.hasPrefix(root + "/") else { return nil }
            let path = (parent as NSString).appendingPathComponent(file.lastPathComponent)
            if seen.insert(path).inserted { result.append(URL(fileURLWithPath: path, isDirectory: false)) }
        }
        return result
    }

    private static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func size(of url: URL) -> Int64? {
        var status = stat()
        return lstat(url.path, &status) == 0 ? Int64(status.st_size) : nil
    }

    /// The extension a result is published under: its own, as the converter wrote it ("tar.gz" is one extension).
    private static func ownExtension(of file: URL) -> String? {
        let name = file.lastPathComponent
        if let spelling = FormatRegistry.match(name)?.spelling { return String(name.suffix(spelling.count)) }
        return file.pathExtension.isEmpty ? nil : file.pathExtension
    }

    /// Several results are put together inside the work folder, so the folder appears in one piece.
    private static func gather(_ files: [URL], in work: URL) throws -> URL {
        let folder = work.appendingPathComponent(".gathered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for file in files {
            let ext = ownExtension(of: file)
            let base = ext.map { String(file.lastPathComponent.dropLast($0.count + 1)) } ?? file.lastPathComponent
            _ = try OutputNaming.publish(file, named: base, extension: ext, in: folder)
        }
        return folder
    }
}
