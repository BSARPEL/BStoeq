import Foundation

/// The optional tools found on this Mac. Without them the Apple frameworks still do most of the work.
public struct ConversionEnvironment: Equatable, Sendable {
    public var ffmpeg: URL?
    public var ffprobe: URL?
    /// Names from "ffmpeg -encoders"; empty without ffmpeg.
    public var encoders: Set<String>
    public var cwebp: URL?

    public init(ffmpeg: URL? = nil, ffprobe: URL? = nil, encoders: Set<String> = [], cwebp: URL? = nil) {
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; self.encoders = encoders; self.cwebp = cwebp
    }

    /// Looks in the given folders (first hit wins, regular executable files only) and asks ffmpeg what
    /// it can encode. Blocking; call it off the main thread.
    public static func detect(in directories: [String]) -> ConversionEnvironment {
        func locate(_ name: String) -> URL? {
            for directory in directories {
                let path = (directory as NSString).appendingPathComponent(name)
                var status = stat()
                // A Homebrew tool is a link into its cellar: follow it, but a folder of that name is no tool.
                if stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 {
                    return URL(fileURLWithPath: path)
                }
            }
            return nil
        }
        var environment = ConversionEnvironment(ffmpeg: locate("ffmpeg"), ffprobe: locate("ffprobe"), cwebp: locate("cwebp"))
        if let ffmpeg = environment.ffmpeg,
           let output = ToolProcess.collect(ffmpeg, arguments: ["-hide_banner", "-encoders"]), output.status == 0 {
            environment.encoders = encoders(in: String(decoding: output.stdout, as: UTF8.self))
        }
        return environment
    }

    /// "brew install ffmpeg" for "ffmpeg", "brew install webp" for "cwebp"; nil for anything else.
    public static func installCommand(for tool: String) -> String? {
        switch tool {
        case "ffmpeg": "brew install ffmpeg"
        case "cwebp": "brew install webp"
        default: nil
        }
    }

    /// The table "ffmpeg -encoders" prints: one line per encoder (" V....D libx264   H.264 …") below a
    /// legend whose lines have "=" where the name would be. The second column is the name.
    static func encoders(in listing: String) -> Set<String> {
        var names = Set<String>()
        for line in listing.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if columns.count >= 2, columns[0].count == 6, columns[0].allSatisfy({ $0 == "." || $0.isLetter }),
               columns[1] != "=" { names.insert(String(columns[1])) }
        }
        return names
    }
}

/// Whether a converter can do a pair of source and target on this Mac.
public enum TargetAvailability: Equatable, Sendable {
    case available
    /// The tool itself is not installed: "ffmpeg", "cwebp".
    case needs(String)
    /// Includes: ffmpeg is installed but lacks the encoder.
    case unsupported
}

/// One thing a file can be turned into: a format, a variant of one ("MP4 720p") or a tool ("Compress").
public struct ConversionTarget: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case convert, tool }
    /// "png", "mp4.720p", "pdf.merge", "compress".
    public let id: String
    public let kind: Kind
    /// For the status line, the page and the history: a format label ("PNG") or a localization key.
    public let title: String
    /// The slice label: a format label or a localization key.
    public let shortTitle: String
    /// True when `title` and `shortTitle` are keys.
    public let titleIsKey: Bool
    /// SF Symbol.
    public let symbol: String
    /// Output format id; "*" keeps the source's.
    public let format: String
    /// All inputs become one output.
    public let combines: Bool
    /// 1; 2 for merges.
    public let minimumInputs: Int
    /// A localized word added to the file name ("küçük").
    public let suffixKey: String?
    /// An untranslated one ("720p").
    public let fixedSuffix: String?
    public let overrides: OptionOverrides

    public init(id: String, kind: Kind = .convert, title: String, shortTitle: String? = nil, titleIsKey: Bool = false,
                symbol: String = "doc", format: String, combines: Bool = false, minimumInputs: Int = 1,
                suffixKey: String? = nil, fixedSuffix: String? = nil, overrides: OptionOverrides = OptionOverrides()) {
        self.id = id; self.kind = kind; self.title = title; self.shortTitle = shortTitle ?? title
        self.titleIsKey = titleIsKey; self.symbol = symbol; self.format = format; self.combines = combines
        self.minimumInputs = minimumInputs; self.suffixKey = suffixKey; self.fixedSuffix = fixedSuffix
        self.overrides = overrides
    }
}

/// The built-in targets. An id means the same thing for every family; converters claim the pairs they do.
public enum TargetCatalog {
    /// In display order: the formats family by family, their variants, then the tools.
    public static let all: [ConversionTarget] = {
        func plain(_ ids: [String]) -> [ConversionTarget] {
            ids.map { id in
                ConversionTarget(id: id, title: id.uppercased(), symbol: symbol(for: FormatRegistry.format(id: id)?.family), format: id)
            }
        }
        func variant(_ id: String, _ title: String, _ format: String, suffix: String? = nil, _ overrides: OptionOverrides = OptionOverrides()) -> ConversionTarget {
            ConversionTarget(id: id, title: title, symbol: symbol(for: FormatRegistry.format(id: format)?.family),
                             format: format, fixedSuffix: suffix, overrides: overrides)
        }
        func tool(_ id: String, _ title: String, _ shortTitle: String, _ symbol: String, _ format: String, suffix: String? = nil,
                  combines: Bool = false, _ overrides: OptionOverrides = OptionOverrides()) -> ConversionTarget {
            ConversionTarget(id: id, kind: .tool, title: title, shortTitle: shortTitle, titleIsKey: true, symbol: symbol,
                             format: format, combines: combines, minimumInputs: combines ? 2 : 1, suffixKey: suffix,
                             overrides: overrides)
        }
        var targets = plain(["jpg", "png", "heic", "avif", "tiff", "gif", "bmp", "jp2", "ico", "icns", "webp", "pdf",
                             "txt", "docx", "rtf", "odt", "html", "csv", "tsv", "xlsx", "json", "plist",
                             "mp4", "mov", "mkv", "webm", "mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "srt", "vtt"])
        targets += [
            variant("mp4.720p", "MP4 720p", "mp4", suffix: "720p", OptionOverrides(videoQuality: .small, videoMaxHeight: 720)),
            variant("mp4.hevc", "MP4 HEVC", "mp4", suffix: "HEVC", OptionOverrides(videoCodec: .hevc)),
            variant("mp3.128k", "MP3 128k", "mp3", suffix: "128k", OptionOverrides(audioBitrate: 128)),
            // Lossless in the same container; the ringtone is at most the first 30 seconds.
            variant("alac", "ALAC", "m4a", suffix: "ALAC"),
            variant("m4r", "M4R", "m4r")
        ]
        targets += [
            tool("pdf.merge", "Tek PDF’te birleştir", "Birleştir", "arrow.triangle.merge", "pdf", suffix: "birleşik", combines: true),
            tool("pdf.split", "Sayfalara böl", "Böl", "scissors", "pdf", suffix: "sayfalar"),
            tool("half", "Yarı boyuta küçült", "Yarı boyut", "arrow.down.right.and.arrow.up.left", "*", suffix: "küçük",
                 OptionOverrides(imageResize: .half)),
            // Images get the quality, videos the level and the height; a PDF uses the stored `pdfCompression`.
            tool("compress", "Sıkıştır", "Sıkıştır", "rectangle.compress.vertical", "*", suffix: "sıkıştırılmış",
                 OptionOverrides(imageQuality: 0.7, videoQuality: .small, videoMaxHeight: 1080)),
            tool("mute", "Sesi kaldır", "Sessiz", "speaker.slash", "*", suffix: "sessiz", OptionOverrides(removeAudio: true)),
            tool("nobg", "Arka planı sil", "Arka plan", "person.and.background.dotted", "png", suffix: "arka plansız"),
            tool("ocr", "Metni tanı (OCR)", "OCR", "text.viewfinder", "txt")
        ]
        return targets
    }()

    private static let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    public static func target(id: String) -> ConversionTarget? { byID[id] }

    private static func symbol(for family: FileFamily?) -> String {
        switch family {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .data: "tablecells"
        case .audio: "music.note"
        case .video: "film"
        case .subtitle: "captions.bubble"
        default: "doc"
        }
    }
}
