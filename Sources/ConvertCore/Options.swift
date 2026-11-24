import CoreGraphics
import Foundation

/// How hard a video is squeezed: the trade between how it looks and how big it is.
public enum ConversionQuality: String, Codable, CaseIterable, Sendable {
    case high, balanced, small
    public var titleKey: String {
        switch self {
        case .high: "Yüksek"
        case .balanced: "Dengeli"
        case .small: "Küçük dosya"
        }
    }
}

/// How much the Compress tool takes out of a PDF's images.
public enum CompressionLevel: String, Codable, CaseIterable, Sendable {
    case light, balanced, strong
    public var titleKey: String {
        switch self {
        case .light: "Hafif"
        case .balanced: "Dengeli"
        case .strong: "Güçlü"
        }
    }
}

/// The page a document is laid out on when it becomes a PDF.
public enum PaperSize: String, Codable, CaseIterable, Sendable {
    case a4, letter
    public var titleKey: String { self == .a4 ? "A4" : "ABD Letter" }
    /// Points.
    public var size: CGSize { self == .a4 ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792) }
    /// Letter in the United States, Canada and Mexico; A4 elsewhere.
    public static func regional(_ locale: Locale = .current) -> PaperSize {
        ["US", "CA", "MX"].contains(locale.region?.identifier ?? "") ? .letter : .a4
    }
}

/// What MP4 and MOV results are encoded with.
public enum ConversionVideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc
    /// A codec name, never translated.
    public var title: String { self == .h264 ? "H.264" : "HEVC" }
}

/// How much smaller an image result is than its source. It is never larger.
public struct ImageResize: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case original, percent, longEdge }
    public var mode: Mode
    /// Percent 1...100, or the long edge in pixels. An image is never enlarged.
    public var value: Int

    public init(mode: Mode = .original, value: Int = 0) { self.mode = mode; self.value = value }

    public static let original = ImageResize()
    public static let half = ImageResize(mode: .percent, value: 50)
    public static let quarter = ImageResize(mode: .percent, value: 25)
    public static let long1920 = ImageResize(mode: .longEdge, value: 1920)
    public static let long1280 = ImageResize(mode: .longEdge, value: 1280)
    /// The choices a picker offers, in order.
    public static let presets = [original, half, quarter, long1920, long1280]

    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        mode = Mode(rawValue: (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "") ?? .original
        value = (try? c.decodeIfPresent(Int.self, forKey: .value)) ?? 0
        normalize()
    }

    /// A choice that cannot shrink anything means the original size.
    public mutating func normalize() {
        switch mode {
        case .original: value = 0
        case .percent: if value < 1 { self = .original } else { value = min(100, value) }
        case .longEdge: if value < 1 { self = .original }
        }
    }

    /// The pixel size this choice gives an image of the given size: never larger than the image, never below one pixel.
    public func pixelSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let scale: Double
        switch mode {
        case .original: return (width, height)
        case .percent: scale = Double(min(100, max(1, value))) / 100
        case .longEdge: scale = value > 0 ? Double(value) / Double(max(width, height)) : 1
        }
        guard scale < 1 else { return (width, height) }
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}

/// Stored as two plain fields, `kind` ("beside" | "subfolder" | "folder") and `name` (the name or path), so that a
/// value from another version can never fail to decode: anything unknown means beside the source.
public enum OutputLocation: Codable, Hashable, Sendable {
    case besideSource
    /// A folder of this name next to the source (one safe path component).
    case subfolder(String)
    /// An absolute path.
    case folder(String)

    private enum CodingKeys: String, CodingKey { case kind, name }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = .besideSource; return }
        let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        switch (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "" {
        case "subfolder": self = .subfolder(name)
        case "folder": self = .folder(name)
        default: self = .besideSource
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .besideSource: try c.encode("beside", forKey: .kind); try c.encode("", forKey: .name)
        case .subfolder(let name): try c.encode("subfolder", forKey: .kind); try c.encode(name, forKey: .name)
        case .folder(let path): try c.encode("folder", forKey: .kind); try c.encode(path, forKey: .name)
        }
    }

    /// Whether `name` may be used as the name of a results folder: exactly one path component that is
    /// not hidden and cannot climb out of the folder it is made in.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 100 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }
}

/// Everything a converter may be told besides the target. The first ten are the user's standing
/// preferences; the last three are chosen for one job.
public struct ConversionOptions: Codable, Equatable, Sendable {
    // Standing preferences: stored, and shown on the page's settings card.
    /// `nil` is automatic per format (jpg 0.90, heic 0.80, avif 0.60, jp2 0.90); otherwise 0.1...1.
    public var imageQuality: Double?
    public var keepMetadata: Bool
    /// 72...600.
    public var pdfDPI: Int
    public var pdfCompression: CompressionLevel
    public var paper: PaperSize
    public var videoQuality: ConversionQuality
    public var videoCodec: ConversionVideoCodec
    /// kbps, 64...320.
    public var audioBitrate: Int
    public var location: OutputLocation
    /// Applies to format conversions inside one family only; see the engine.
    public var trashOriginals: Bool
    // Per-job choices: set by a target's overrides or by the page for one job. `ConverterSettings.normalize()`
    // resets them, so they are never stored with the settings.
    public var imageResize: ImageResize
    /// 0 keeps the source's height; otherwise one of `videoHeights`.
    public var videoMaxHeight: Int
    public var removeAudio: Bool

    /// What `videoMaxHeight` may be.
    public static let videoHeights = [0, 2160, 1080, 720, 480]

    public init(imageQuality: Double? = nil, keepMetadata: Bool = true, pdfDPI: Int = 150,
                pdfCompression: CompressionLevel = .balanced, paper: PaperSize = .regional(),
                videoQuality: ConversionQuality = .balanced, videoCodec: ConversionVideoCodec = .h264,
                audioBitrate: Int = 192, location: OutputLocation = .besideSource, trashOriginals: Bool = false,
                imageResize: ImageResize = .original, videoMaxHeight: Int = 0, removeAudio: Bool = false) {
        self.imageQuality = imageQuality; self.keepMetadata = keepMetadata; self.pdfDPI = pdfDPI
        self.pdfCompression = pdfCompression; self.paper = paper; self.videoQuality = videoQuality
        self.videoCodec = videoCodec; self.audioBitrate = audioBitrate; self.location = location
        self.trashOriginals = trashOriginals; self.imageResize = imageResize
        self.videoMaxHeight = videoMaxHeight; self.removeAudio = removeAudio
    }

    // A file from another version must not fail to import, and one bad value must not reset the others.
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        imageQuality = (try? c.decodeIfPresent(Double.self, forKey: .imageQuality)) ?? nil
        keepMetadata = (try? c.decodeIfPresent(Bool.self, forKey: .keepMetadata)) ?? true
        pdfDPI = (try? c.decodeIfPresent(Int.self, forKey: .pdfDPI)) ?? 150
        pdfCompression = CompressionLevel(rawValue: (try? c.decodeIfPresent(String.self, forKey: .pdfCompression)) ?? "") ?? .balanced
        paper = PaperSize(rawValue: (try? c.decodeIfPresent(String.self, forKey: .paper)) ?? "") ?? .regional()
        videoQuality = ConversionQuality(rawValue: (try? c.decodeIfPresent(String.self, forKey: .videoQuality)) ?? "") ?? .balanced
        videoCodec = ConversionVideoCodec(rawValue: (try? c.decodeIfPresent(String.self, forKey: .videoCodec)) ?? "") ?? .h264
        audioBitrate = (try? c.decodeIfPresent(Int.self, forKey: .audioBitrate)) ?? 192
        location = (try? c.decodeIfPresent(OutputLocation.self, forKey: .location)) ?? .besideSource
        trashOriginals = (try? c.decodeIfPresent(Bool.self, forKey: .trashOriginals)) ?? false
        imageResize = (try? c.decodeIfPresent(ImageResize.self, forKey: .imageResize)) ?? .original
        videoMaxHeight = (try? c.decodeIfPresent(Int.self, forKey: .videoMaxHeight)) ?? 0
        removeAudio = (try? c.decodeIfPresent(Bool.self, forKey: .removeAudio)) ?? false
        normalize()
    }

    /// Repairs values that decode but must not be used: out of range numbers, and a results folder that
    /// could leave the place it belongs to.
    public mutating func normalize() {
        if let quality = imageQuality { imageQuality = quality.isFinite ? min(1, max(0.1, quality)) : nil }
        pdfDPI = min(600, max(72, pdfDPI))
        audioBitrate = min(320, max(64, audioBitrate))
        if !Self.videoHeights.contains(videoMaxHeight) { videoMaxHeight = 0 }
        imageResize.normalize()
        switch location {
        case .besideSource: break
        case .subfolder(let name): if !OutputLocation.isSafeName(name) { location = .besideSource }
        case .folder(let path): if !path.hasPrefix("/") || path.contains("\0") { location = .besideSource }
        }
    }

    public func applying(_ overrides: OptionOverrides) -> ConversionOptions {
        var result = self
        if let value = overrides.imageQuality { result.imageQuality = value }
        if let value = overrides.imageResize { result.imageResize = value }
        if let value = overrides.videoQuality { result.videoQuality = value }
        if let value = overrides.videoMaxHeight { result.videoMaxHeight = value }
        if let value = overrides.videoCodec { result.videoCodec = value }
        if let value = overrides.removeAudio { result.removeAudio = value }
        if let value = overrides.audioBitrate { result.audioBitrate = value }
        return result
    }
}

/// The fields a built-in target fixes, whatever the user's settings say ("MP4 720p", "Half size").
public struct OptionOverrides: Hashable, Sendable {
    public var imageQuality: Double?
    public var imageResize: ImageResize?
    public var videoQuality: ConversionQuality?
    public var videoMaxHeight: Int?
    public var videoCodec: ConversionVideoCodec?
    public var removeAudio: Bool?
    public var audioBitrate: Int?

    public init(imageQuality: Double? = nil, imageResize: ImageResize? = nil, videoQuality: ConversionQuality? = nil,
                videoMaxHeight: Int? = nil, videoCodec: ConversionVideoCodec? = nil, removeAudio: Bool? = nil,
                audioBitrate: Int? = nil) {
        self.imageQuality = imageQuality; self.imageResize = imageResize; self.videoQuality = videoQuality
        self.videoMaxHeight = videoMaxHeight; self.videoCodec = videoCodec; self.removeAudio = removeAudio
        self.audioBitrate = audioBitrate
    }
}

/// The key that opens the ring while files are being dragged.
public enum DonutTrigger: String, Codable, CaseIterable, Sendable {
    case option, shift
    public var titleKey: String { self == .option ? "Option" : "Shift" }
    public var glyph: String { self == .option ? "⌥" : "⇧" }
    /// The raw value of the matching `NSEvent.ModifierFlags` member.
    public var modifierMask: UInt { self == .option ? 1 << 19 : 1 << 17 }
}

/// A folder whose new files are converted to one target as they arrive.
public struct WatchRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Absolute path.
    public var folder: String
    public var targetID: String
    /// Name of the results folder inside `folder`, fixed when the rule is made.
    public var outputFolder: String
    public var enabled: Bool

    public init(id: UUID = UUID(), folder: String, targetID: String, outputFolder: String, enabled: Bool = true) {
        self.id = id; self.folder = folder; self.targetID = targetID; self.outputFolder = outputFolder; self.enabled = enabled
    }

    // Only something that is not a rule at all fails; `ConverterSettings.normalize()` drops what is incomplete.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? ""
        targetID = (try? c.decodeIfPresent(String.self, forKey: .targetID)) ?? ""
        outputFolder = (try? c.decodeIfPresent(String.self, forKey: .outputFolder)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }
}

/// What `Preferences` stores for the converter. It travels with an exported settings file.
public struct ConverterSettings: Codable, Equatable, Sendable {
    public var donutEnabled: Bool
    public var trigger: DonutTrigger
    /// Open the ring only for drags that start in Finder.
    public var finderOnly: Bool
    public var options: ConversionOptions
    public var watch: [WatchRule]

    /// Watched folders kept at most.
    public static let watchLimit = 20

    public init(donutEnabled: Bool = true, trigger: DonutTrigger = .option, finderOnly: Bool = true,
                options: ConversionOptions = ConversionOptions(), watch: [WatchRule] = []) {
        self.donutEnabled = donutEnabled; self.trigger = trigger; self.finderOnly = finderOnly
        self.options = options; self.watch = watch
    }

    /// One element of a stored list, read on its own so that a malformed one drops only itself.
    private struct Element<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        donutEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .donutEnabled)) ?? true
        trigger = DonutTrigger(rawValue: (try? c.decodeIfPresent(String.self, forKey: .trigger)) ?? "") ?? .option
        finderOnly = (try? c.decodeIfPresent(Bool.self, forKey: .finderOnly)) ?? true
        options = (try? c.decodeIfPresent(ConversionOptions.self, forKey: .options)) ?? ConversionOptions()
        watch = ((try? c.decodeIfPresent([Element<WatchRule>].self, forKey: .watch)) ?? []).compactMap(\.value)
        normalize()
    }

    /// Runs on every settings change, so it reads nothing from disk: a folder nobody asked about is not touched.
    public mutating func normalize() {
        options.normalize()
        options.imageResize = .original; options.videoMaxHeight = 0; options.removeAudio = false
        var folders = Set<String>()
        watch = Array(watch.filter { rule in
            rule.folder.hasPrefix("/") && !rule.folder.contains("\0") && TargetCatalog.target(id: rule.targetID) != nil
                && OutputLocation.isSafeName(rule.outputFolder) && folders.insert(Self.tidied(rule.folder)).inserted
        }.prefix(Self.watchLimit))
    }

    /// The path without empty, "." and ".." components, so two spellings of one folder count as one.
    private static func tidied(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}
