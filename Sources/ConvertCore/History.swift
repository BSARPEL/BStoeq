import Foundation

/// One finished job as the history keeps it: enough to show it, to retry what failed and to undo what
/// it wrote without touching anything the user changed since.
public struct ConversionRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case donut, page, watch }

    /// A file inside a published folder, or a folder inside it that held nothing.
    public struct Entry: Codable, Equatable, Sendable {
        /// Relative to the folder. A path that ends in "/" is a folder that held no file ("./": the
        /// published folder itself was empty); its size and date are not compared.
        public var path: String
        public var bytes: Int64
        public var modified: Date

        public init(path: String, bytes: Int64, modified: Date) { self.path = path; self.bytes = bytes; self.modified = modified }

        private enum CodingKeys: String, CodingKey { case path, bytes, modified }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
            bytes = (try? c.decodeIfPresent(Int64.self, forKey: .bytes)) ?? -1
            modified = ConversionRecord.date((try? c.decodeIfPresent(Double.self, forKey: .modified)) ?? nil)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(modified.timeIntervalSinceReferenceDate, forKey: .modified)
        }
    }

    /// One published item: a file, or a folder holding several.
    public struct Output: Codable, Equatable, Sendable {
        public var path: String
        public var bytes: Int64
        public var modified: Date
        /// What a published folder held: every file below it and every folder that held nothing; empty
        /// for a single file. Finder's `.DS_Store` files are not listed.
        public var files: [Entry]

        public init(path: String, bytes: Int64, modified: Date, files: [Entry] = []) {
            self.path = path; self.bytes = bytes; self.modified = modified; self.files = files
        }

        /// What is at `url` right now: its size and date, and for a folder every file in it and every
        /// folder that holds nothing, so that an extracted archive can be recognised whole again.
        /// Nil when nothing is there. For results that did not come from the engine (archives).
        public init?(recording url: URL) {
            var status = stat()
            guard lstat(url.path, &status) == 0 else { return nil }
            var files: [Entry] = []
            if status.st_mode & S_IFMT == S_IFDIR {
                files = ConversionRecord.entries(in: url.path)
                if files.isEmpty { files = [Entry(path: "./", bytes: 0, modified: ConversionRecord.modified(status))] }
            }
            self.init(path: url.path, bytes: Int64(status.st_size), modified: ConversionRecord.modified(status), files: files)
        }

        private enum CodingKeys: String, CodingKey { case path, bytes, modified, files }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
            bytes = (try? c.decodeIfPresent(Int64.self, forKey: .bytes)) ?? -1
            modified = ConversionRecord.date((try? c.decodeIfPresent(Double.self, forKey: .modified)) ?? nil)
            files = ConversionRecord.list(c, .files)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(modified.timeIntervalSinceReferenceDate, forKey: .modified)
            try c.encode(files, forKey: .files)
        }
    }

    /// A source that was not converted, and why.
    public struct Problem: Codable, Equatable, Sendable {
        public var source: String
        public var key: String
        public var detail: String?
        /// False for a skip.
        public var failed: Bool

        public init(source: String, key: String, detail: String? = nil, failed: Bool) {
            self.source = source; self.key = key; self.detail = detail; self.failed = failed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
            key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
            detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
            failed = (try? c.decodeIfPresent(Bool.self, forKey: .failed)) ?? false
        }
    }

    /// Problems kept per record; `failures` and `skipped` still count them all.
    public static let problemLimit = 50

    public var id: UUID
    public var date: Date
    public var origin: Origin
    public var targetID: String
    public var targetTitle: String
    public var titleIsKey: Bool
    /// Paths.
    public var sources: [String]
    public var outputs: [Output]
    /// At most `problemLimit`.
    public var problems: [Problem]
    public var notices: [String]
    public var originalsTrashed: Bool
    /// Sources that were converted, that failed and that were skipped.
    public var converted: Int
    public var failures: Int
    public var skipped: Int
    public var wasCancelled: Bool

    /// The counts default to what the lists say.
    public init(id: UUID = UUID(), date: Date, origin: Origin, targetID: String, targetTitle: String, titleIsKey: Bool,
                sources: [String], outputs: [Output], problems: [Problem] = [], notices: [String] = [],
                originalsTrashed: Bool = false, converted: Int? = nil, failures: Int? = nil, skipped: Int? = nil,
                wasCancelled: Bool = false) {
        self.id = id; self.date = date; self.origin = origin; self.targetID = targetID; self.targetTitle = targetTitle
        self.titleIsKey = titleIsKey; self.sources = sources; self.outputs = outputs
        self.problems = Array(problems.prefix(Self.problemLimit)); self.notices = notices
        self.originalsTrashed = originalsTrashed; self.wasCancelled = wasCancelled
        let failed = failures ?? problems.filter(\.failed).count
        let passed = skipped ?? problems.count - problems.filter(\.failed).count
        self.failures = failed; self.skipped = passed
        self.converted = converted ?? max(0, sources.count - failed - passed)
    }

    // History written by another version must still load: every field falls back on its own.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let problems: [Problem] = Self.list(c, .problems)
        let sources = (try? c.decodeIfPresent([String].self, forKey: .sources)) ?? []
        self.init(id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  date: (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? .distantPast,
                  origin: Origin(rawValue: (try? c.decodeIfPresent(String.self, forKey: .origin)) ?? "") ?? .page,
                  targetID: (try? c.decodeIfPresent(String.self, forKey: .targetID)) ?? "",
                  targetTitle: (try? c.decodeIfPresent(String.self, forKey: .targetTitle)) ?? "",
                  titleIsKey: (try? c.decodeIfPresent(Bool.self, forKey: .titleIsKey)) ?? false,
                  sources: sources, outputs: Self.list(c, .outputs), problems: problems,
                  notices: (try? c.decodeIfPresent([String].self, forKey: .notices)) ?? [],
                  originalsTrashed: (try? c.decodeIfPresent(Bool.self, forKey: .originalsTrashed)) ?? false,
                  converted: (try? c.decodeIfPresent(Int.self, forKey: .converted)) ?? nil,
                  failures: (try? c.decodeIfPresent(Int.self, forKey: .failures)) ?? nil,
                  skipped: (try? c.decodeIfPresent(Int.self, forKey: .skipped)) ?? nil,
                  wasCancelled: (try? c.decodeIfPresent(Bool.self, forKey: .wasCancelled)) ?? false)
    }

    /// What may be undone: a single file that is still the file the conversion wrote (same size and
    /// date); a folder only when it holds exactly what was recorded, unchanged (Finder's .DS_Store files
    /// aside, wherever they are and whoever wrote them). Otherwise the unchanged files inside it, and the
    /// folder stays.
    public func unchangedOutputs() -> [URL] {
        outputs.flatMap { output -> [URL] in
            let url = URL(fileURLWithPath: output.path)
            guard !output.files.isEmpty else {
                return Self.isUnchanged(output.path, bytes: output.bytes, modified: output.modified) ? [url] : []
            }
            var status = stat()
            guard lstat(output.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return [] }
            // A stored path is data from disk: it must stay inside its folder.
            let entries = output.files.filter { !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") }
            let files = entries.filter { !$0.path.hasSuffix("/") && ($0.path as NSString).lastPathComponent != Self.finderFile }
            let unchanged = files.filter {
                Self.isUnchanged((output.path as NSString).appendingPathComponent($0.path), bytes: $0.bytes, modified: $0.modified)
            }
            // A folder that held nothing is still itself while it is a folder that holds nothing.
            let empty = Set(entries.filter { $0.path.hasSuffix("/") }.map { $0.path == "./" ? "" : String($0.path.dropLast()) })
            let recorded = Set(files.map(\.path))
            let complete = entries.count == output.files.count && unchanged.count == files.count
                && empty.allSatisfy { Self.isFolder((output.path as NSString).appendingPathComponent($0)) }
                && Self.holdsOnly(recorded, folders: Self.parents(of: recorded.union(empty)).union(empty), in: output.path)
            return complete ? [URL(fileURLWithPath: output.path, isDirectory: true)]
                            : unchanged.map { url.appendingPathComponent($0.path, isDirectory: false) }
        }
    }

    /// Failed sources that still exist.
    public func retryable() -> [URL] {
        var seen = Set<String>()
        return problems.compactMap { problem in
            var status = stat()
            guard problem.failed, lstat(problem.source, &status) == 0, seen.insert(problem.source).inserted else { return nil }
            return URL(fileURLWithPath: problem.source)
        }
    }

    /// The record of a finished job. Reads the size and date of what was published; it takes the job's id.
    public static func make(from result: ConversionResult, origin: Origin, date: Date) -> ConversionRecord {
        var problems: [Problem] = []
        for (source, outcome) in zip(result.sources, result.outcomes) {
            switch outcome {
            case .failed(let failure): problems.append(Problem(source: source.path, key: failure.key, detail: failure.detail, failed: true))
            case .skipped(let key): problems.append(Problem(source: source.path, key: key, failed: false))
            case .converted, .cancelled: break
            }
        }
        let outputs = result.outputs.compactMap { Output(recording: $0) }
        return ConversionRecord(id: result.job.id, date: date, origin: origin, targetID: result.job.target.id,
                                targetTitle: result.job.target.title, titleIsKey: result.job.target.titleIsKey,
                                sources: result.sources.map(\.path), outputs: outputs, problems: problems,
                                notices: result.notices, originalsTrashed: result.originalsTrashed,
                                converted: result.converted, failures: result.failed, skipped: result.skipped,
                                wasCancelled: result.wasCancelled)
    }

    // MARK: Pieces

    /// The date is stored as plain seconds, whatever date strategy the encoder was given: a rounded
    /// date would make every output look changed.
    private static func date(_ seconds: Double?) -> Date {
        seconds.map { Date(timeIntervalSinceReferenceDate: $0) } ?? .distantPast
    }

    /// One element of a stored list, read on its own so that a malformed one drops only itself.
    private struct Element<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private static func list<Value: Decodable, Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> [Value] {
        ((try? container.decodeIfPresent([Element<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    private static func modified(_ status: stat) -> Date {
        Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Still the regular file that was recorded: a link or anything else in its place is not.
    private static func isUnchanged(_ path: String, bytes: Int64, modified date: Date) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG && Int64(status.st_size) == bytes
            && abs(modified(status).timeIntervalSince(date)) < 0.001
    }

    /// Finder keeps its view settings in any folder it has shown and rewrites them as it likes: such a
    /// file is never part of a result, and never a change to one.
    private static let finderFile = ".DS_Store"

    private static func isFolder(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    /// Every regular file below `folder`, by relative path, and every folder that holds none (its path
    /// ends in "/"): without those an extracted tree with an empty folder would never be whole again.
    private static func entries(in folder: String, prefix: String = "") -> [Entry] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        return names.flatMap { name -> [Entry] in
            let path = (folder as NSString).appendingPathComponent(name)
            var status = stat()
            guard name != finderFile, lstat(path, &status) == 0 else { return [] }
            switch status.st_mode & S_IFMT {
            case S_IFREG: return [Entry(path: prefix + name, bytes: Int64(status.st_size), modified: modified(status))]
            case S_IFDIR:
                let below = entries(in: path, prefix: prefix + name + "/")
                return below.isEmpty ? [Entry(path: prefix + name + "/", bytes: 0, modified: modified(status))] : below
            default: return []
            }
        }
    }

    private static func parents(of paths: Set<String>) -> Set<String> {
        var folders = Set<String>()
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, folders.insert(parent).inserted { parent = (parent as NSString).deletingLastPathComponent }
        }
        return folders
    }

    /// Whether the folder holds nothing but the given files and the folders they need.
    private static func holdsOnly(_ files: Set<String>, folders: Set<String>, in folder: String, prefix: String = "") -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return false }
        for name in names {
            let relative = prefix + name
            var status = stat()
            guard lstat((folder as NSString).appendingPathComponent(name), &status) == 0 else { return false }
            switch status.st_mode & S_IFMT {
            case S_IFREG:
                if !files.contains(relative), name != finderFile { return false }
            case S_IFDIR:
                guard folders.contains(relative),
                      holdsOnly(files, folders: folders, in: (folder as NSString).appendingPathComponent(name), prefix: relative + "/") else { return false }
            default:
                return false
            }
        }
        return true
    }
}
