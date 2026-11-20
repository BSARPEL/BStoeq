import Foundation

public enum ArchiveFormat: String, CaseIterable, Codable, Sendable {
    case zip, sevenZip = "7z", tar, tarGzip = "tar.gz", tarBzip = "tar.bz2", tarXZ = "tar.xz", rar
    public var supportsPassword: Bool { self == .zip || self == .sevenZip || self == .rar }
    public var supportsVolumes: Bool { self == .zip || self == .sevenZip || self == .rar }
}

public struct ArchiveOptions: Codable, Equatable, Sendable {
    public var format: ArchiveFormat = .zip
    public var level = 5
    public var solid = true
    public var encryptNames = true
    public var volumeMB = 0
    public var recoveryPercent = 0
    public init() {}
}

public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let packedSize: Int64
    public let isDirectory: Bool
    public let modified: String
    public let crc: String
    public let encrypted: Bool
    public let isLink: Bool
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String, size: Int64 = 0, packedSize: Int64 = 0, isDirectory: Bool = false,
                modified: String = "", crc: String = "", encrypted: Bool = false, isLink: Bool = false) {
        self.path = path; self.size = size; self.packedSize = packedSize; self.isDirectory = isDirectory
        self.modified = modified; self.crc = crc; self.encrypted = encrypted; self.isLink = isLink
    }
}

public struct ArchiveListing: Sendable {
    public var entries: [ArchiveEntry]
    public var metadata: [String: String]
    public var totalSize: Int64 { entries.reduce(0) { $0.addingReportingOverflow($1.size).overflow ? Int64.max : $0 + $1.size } }
    public var encrypted: Bool { entries.contains(where: \.encrypted) }
    public var format: String { metadata["Type"] ?? "" }
    public var isMultiVolume: Bool { metadata["Volumes"] != nil || metadata["Multivolume"] == "+" || metadata["Type"] == "Split" }
    public init(entries: [ArchiveEntry] = [], metadata: [String: String] = [:]) { self.entries = entries; self.metadata = metadata }

    public func children(of directory: String, search: String = "") -> [ArchiveEntry] {
        if !search.isEmpty { return entries.filter { $0.path.localizedCaseInsensitiveContains(search) } }
        let prefix = directory.isEmpty ? "" : directory + "/"
        var result: [String: ArchiveEntry] = [:]
        for entry in entries where entry.path.hasPrefix(prefix) {
            let remainder = String(entry.path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }
            let name = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? remainder
            let path = prefix + name
            if remainder.contains("/") {
                if result[path] == nil { result[path] = ArchiveEntry(path: path, isDirectory: true) }
            } else { result[path] = entry }
        }
        return result.values.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

public enum ArchiveError: LocalizedError {
    case message(String)
    case engine(Int32, String)
    case password
    case unsafePath(String)
    case linksUnsupported(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .engine(let code, let output): return "7-Zip (\(code))\n\(output)"
        case .password: return "PASSWORD_REQUIRED"
        case .unsafePath(let path): return "UNSAFE_PATH: \(path)"
        case .linksUnsupported(let path): return "LINK_UNSUPPORTED: \(path)"
        case .cancelled: return "CANCELLED"
        }
    }
}

public enum ListingParser {
    public static func parse(_ text: String) throws -> ArchiveListing {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let divider = normalized.range(of: "----------\n") else {
            throw ArchiveError.message("INVALID_ARCHIVE_LIST")
        }
        func fields(_ block: String) -> [String: String] {
            var values: [String: String] = [:]
            for line in block.components(separatedBy: "\n") {
                if let r = line.range(of: " = ") { values[String(line[..<r.lowerBound])] = String(line[r.upperBound...]) }
            }
            return values
        }
        let metadata = fields(String(normalized[..<divider.lowerBound]))
        let entries = String(normalized[divider.upperBound...]).components(separatedBy: "\n\n").compactMap { block -> ArchiveEntry? in
            let f = fields(block)
            let streamFormats = ["gzip", "bzip2", "xz", "lzma", "Z"]
            let implicitName = streamFormats.contains(metadata["Type"] ?? "") && f["Size"] != nil
                ? ((metadata["Path"] ?? "Archive") as NSString).lastPathComponent : nil
            guard let path = f["Path"] ?? implicitName.map({ ($0 as NSString).deletingPathExtension }), !path.isEmpty else { return nil }
            let attr = f["Attributes"] ?? ""
            let mode = f["Mode"] ?? ""
            return ArchiveEntry(path: path, size: max(0, Int64(f["Size"] ?? "") ?? 0),
                packedSize: max(0, Int64(f["Packed Size"] ?? "") ?? 0),
                isDirectory: f["Folder"] == "+" || attr.hasPrefix("D") || mode.hasPrefix("d"),
                modified: f["Modified"] ?? "", crc: f["CRC"] ?? "", encrypted: f["Encrypted"] == "+",
                isLink: !(f["Symbolic Link"] ?? "").isEmpty || !(f["Hard Link"] ?? "").isEmpty || mode.hasPrefix("l") || attr.contains(" lrwx"))
        }
        return ArchiveListing(entries: entries, metadata: metadata)
    }
}

public enum ArchiveSafety {
    public static func validatePath(_ path: String) throws {
        let portable = path.replacingOccurrences(of: "\\", with: "/")
        let components = portable.components(separatedBy: "/")
        if path.isEmpty || portable.hasPrefix("/") || components.contains("..") || path.contains(":") ||
            path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw ArchiveError.unsafePath(path)
        }
    }
    public static func validate(_ entries: [ArchiveEntry]) throws {
        for entry in entries {
            try validatePath(entry.path)
            if entry.isLink { throw ArchiveError.linksUnsupported(entry.path) }
        }
    }
    /// Reject archive paths that would overwrite one another on the destination volume.
    public static func validateDestinations(_ entries: [ArchiveEntry], caseSensitive: Bool) throws {
        var destinations: [String: Bool] = [:]
        func key(_ path: String) -> String {
            let normalized = path.precomposedStringWithCanonicalMapping
            return caseSensitive ? normalized : normalized.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        for entry in entries {
            try validatePath(entry.path)
            let components = entry.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }
            guard !components.isEmpty else {
                if entry.isDirectory { continue }
                throw ArchiveError.unsafePath(entry.path)
            }
            let destination = key(components.joined(separator: "/"))
            if destinations[destination] != nil { throw ArchiveError.message("ARCHIVE_PATH_CONFLICT: " + entry.path) }
            destinations[destination] = entry.isDirectory
        }
        for entry in entries {
            let components = entry.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                if destinations[key(components.prefix(count).joined(separator: "/"))] == false {
                    throw ArchiveError.message("ARCHIVE_PATH_CONFLICT: " + entry.path)
                }
            }
        }
    }
    public static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        for index in 2...100_000 {
            let next = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + " (\(index))")
            if !fm.fileExists(atPath: next.path) { return next }
        }
        return url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    }
}
