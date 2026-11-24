import Foundation

/// What a watched folder takes and when: which names never count, when a file has finished arriving, and
/// which targets a file may be given. Pure: the app reads the disk and hands the entries in.
public enum WatchRules {
    /// What an entry of the folder is, by `lstat`: links are never followed.
    public enum Kind: Sendable { case file, folder, link, other }

    /// One entry as the disk describes it at one moment.
    public struct Entry: Equatable, Sendable {
        public var kind: Kind
        public var size: Int64
        public var modified: Date
        /// nil where the volume keeps no creation date.
        public var created: Date?
        /// A file saved over by another one under the same name has a new inode: it starts settling again.
        public var inode: UInt64
        public init(kind: Kind = .file, size: Int64, modified: Date, created: Date? = nil, inode: UInt64 = 0) {
            self.kind = kind; self.size = size; self.modified = modified; self.created = created; self.inode = inode
        }
    }

    /// A new file that has not finished arriving: what it looked like last and since when it has looked so.
    public struct Candidate: Equatable, Sendable {
        public var entry: Entry
        public var unchangedSince: Date
        public init(entry: Entry, unchangedSince: Date) { self.entry = entry; self.unchangedSince = unchangedSince }
    }

    public enum Verdict: Equatable, Sendable {
        case waiting
        /// Unchanged for the whole interval, not being copied, not empty: start it.
        case arrived
        /// Gone, or no longer a regular file: forget it.
        case gone
    }

    /// How long a file must stay the same. A paused copy and a finished one look alike; only the wait tells them apart.
    public static let settleInterval: TimeInterval = 5

    /// Partial downloads and scratch files: the finished file arrives under another name and counts then.
    public static let ignoredExtensions: Set<String> = ["tmp", "part", "crdownload", "download"]

    /// Finder gives a file this creation date (1984-01-24 08:00 UTC) while it is still copying it in, and
    /// the real one once the copy is done. The window covers the day in every time zone.
    public static let finderCopyDate = Date(timeIntervalSince1970: 443_779_200)
    private static let finderCopyWindow: TimeInterval = 36 * 3600

    /// Whether an entry never counts as an arrival: hidden names, Office lock files ("~$…"), editor backups
    /// ("…~"), the folder icon file, partial downloads, the rule's own results folder (by name, whether or
    /// not it exists right now), and anything that is not a regular file (folders, packages, links).
    public static func ignores(name: String, kind: Kind, resultsFolder: String) -> Bool {
        guard kind == .file else { return true }
        if name.isEmpty || name.hasPrefix(".") || name.hasPrefix("~$") || name.hasSuffix("~") || name == "Icon\r" { return true }
        if name == resultsFolder { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ignoredExtensions.contains(ext)
    }

    public static func isBeingCopied(_ entry: Entry) -> Bool {
        guard let created = entry.created else { return false }
        return abs(created.timeIntervalSince(finderCopyDate)) < finderCopyWindow
    }

    /// Brings the candidate up to date with what is there now and says whether it has arrived. Any change of
    /// size, date, creation date or inode starts the wait again. An empty file keeps waiting: an app may
    /// create it first and write it later.
    public static func settle(_ candidate: inout Candidate, now entry: Entry?, at date: Date,
                              interval: TimeInterval = settleInterval) -> Verdict {
        guard let entry, entry.kind == .file else { return .gone }
        if entry != candidate.entry {
            candidate = Candidate(entry: entry, unchangedSince: date)
            return .waiting
        }
        guard entry.size > 0, !isBeingCopied(entry), date.timeIntervalSince(candidate.unchangedSince) >= interval else { return .waiting }
        return .arrived
    }

    /// A file is never given the format it already has: a plain format target that would write the same
    /// kind of file under the same name. A variant that marks its result ("MP4 720p") may take its own
    /// format. Tools are not offered to watched folders at all. A file without a format fits nothing.
    public static func accepts(_ target: ConversionTarget, source: FileFormat?) -> Bool {
        guard target.kind == .convert, let source else { return false }
        let marked = !(target.fixedSuffix ?? "").isEmpty || !(target.suffixKey ?? "").isEmpty
        return target.id != source.id && (target.format != source.id || marked)
    }
}
