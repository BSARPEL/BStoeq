import Foundation

/// What a file is to the converter: it picks the ring's toolbar and the limiter's pool.
public enum FileFamily: String, CaseIterable, Codable, Sendable {
    case image, pdf, document, data, audio, video, archive, subtitle, folder, other
}

/// One file type the converter knows by name. Whether it can be read or written is
/// decided by the converters, not here.
public struct FileFormat: Hashable, Sendable {
    /// Lowercase; also the extension written: "jpg", "tar.gz". Empty extension list for `folder`.
    public let id: String
    public let family: FileFamily
    /// Shown as is, never translated: the id in capitals ("JPG", "TAR.GZ"). Empty for `folder`.
    public let label: String
    /// Every spelling read, lowercase, the id first.
    public let extensions: [String]

    public init(id: String, family: FileFamily, label: String, extensions: [String]) {
        self.id = id; self.family = family; self.label = label; self.extensions = extensions
    }
}

/// Every format the converter knows, found by id or by a file's name.
public enum FormatRegistry {
    /// A folder that is not a package. It has no extension and no label of its own:
    /// views show their own word for it.
    public static let folder = FileFormat(id: "folder", family: .folder, label: "", extensions: [])

    public static let all: [FileFormat] = {
        func formats(_ family: FileFamily, _ entries: [(String, [String])]) -> [FileFormat] {
            entries.map { FileFormat(id: $0.0, family: family, label: $0.0.uppercased(), extensions: [$0.0] + $0.1) }
        }
        return formats(.image, [("jpg", ["jpeg", "jpe"]), ("png", []), ("heic", ["heif"]), ("avif", []), ("tiff", ["tif"]),
                                ("gif", []), ("bmp", []), ("jp2", ["j2k", "jpf"]), ("ico", []), ("icns", []), ("tga", []),
                                ("exr", []), ("psd", []), ("webp", []), ("jxl", []), ("svg", []), ("dng", []), ("cr2", []),
                                ("cr3", []), ("nef", []), ("arw", []), ("raf", []), ("orf", []), ("rw2", [])])
            + formats(.pdf, [("pdf", [])])
            + formats(.document, [("docx", []), ("doc", []), ("rtf", []), ("rtfd", []), ("odt", []), ("html", ["htm"]),
                                  ("webarchive", []), ("txt", ["text", "log"]), ("md", ["markdown"])])
            + formats(.data, [("csv", []), ("tsv", ["tab"]), ("json", []), ("xlsx", []), ("plist", [])])
            + formats(.audio, [("mp3", []), ("m4a", []), ("aac", []), ("wav", ["wave"]), ("aiff", ["aif"]), ("flac", []),
                               ("caf", []), ("ogg", ["oga"]), ("opus", []), ("m4r", []), ("wma", []), ("ac3", []), ("amr", [])])
            + formats(.video, [("mp4", []), ("mov", []), ("m4v", []), ("mkv", []), ("webm", []), ("avi", []), ("wmv", []),
                               ("flv", []), ("ts", ["mts", "m2ts"]), ("mpg", ["mpeg"]), ("3gp", [])])
            + formats(.archive, [("zip", []), ("7z", []), ("rar", []), ("tar", []), ("tar.gz", ["tgz"]),
                                 ("tar.bz2", ["tbz", "tbz2"]), ("tar.xz", ["txz"]), ("gz", []), ("bz2", []), ("xz", []),
                                 ("iso", []), ("cab", []), ("dmg", [])])
            + formats(.subtitle, [("srt", []), ("vtt", [])])
            + [folder]
    }()

    private static let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    private static let byExtension = Dictionary(all.flatMap { format in format.extensions.map { ($0, format) } },
                                                uniquingKeysWith: { first, _ in first })
    /// "tar.gz" must win over "gz".
    private static let compound = all.flatMap { format in format.extensions.filter { $0.contains(".") }.map { ($0, format) } }
    /// Formats whose files are folders on disk.
    private static let packages: Set<String> = ["rtfd"]

    public static func format(id: String) -> FileFormat? { byID[id] }

    /// By the name, compound extensions first ("a.tar.gz"); the one disk read is the directory flag:
    /// a plain folder is the `folder` format, a package (rtfd) is judged by its extension. Unknown: nil.
    /// A symbolic link is never followed: it is judged by its own name.
    public static func format(of url: URL) -> FileFormat? {
        let named = match(url.lastPathComponent)?.format
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return named }
        if let named, packages.contains(named.id) { return named }
        return folder
    }

    /// The format a file name spells, and the spelling it used.
    static func match(_ name: String) -> (format: FileFormat, spelling: String)? {
        for (spelling, format) in compound where ends(name, with: spelling) { return (format, spelling) }
        let spelling = (name as NSString).pathExtension.lowercased()
        guard !spelling.isEmpty, let format = byExtension[spelling] else { return nil }
        return (format, spelling)
    }

    /// Extensions are ASCII, so the tail of the name can be compared character by character.
    private static func ends(_ name: String, with spelling: String) -> Bool {
        name.count > spelling.count + 1 && name.suffix(spelling.count + 1).lowercased() == "." + spelling
    }
}
