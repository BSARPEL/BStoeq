import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case video, audio
    public var title: String { self == .video ? "Video" : "Müzik" }
    public var symbol: String { self == .video ? "film" : "music.note" }
}

public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    case best, p1080, p720, p480
    /// `nil` means no upper limit.
    public var height: Int? {
        switch self {
        case .best: nil
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }
    public var title: String { height.map { "\($0)p" } ?? "En iyi kalite" }
}

public enum AudioFormat: String, Codable, CaseIterable, Sendable {
    case mp3, m4a
    public var title: String { rawValue.uppercased() }
}

/// Where a video sits in the playlist it was queued from.
public struct PlaylistPosition: Equatable, Sendable {
    public var index: Int
    public var count: Int
    public init(index: Int, count: Int) { self.index = index; self.count = count }
    /// "07" in a list of 90, shown in front of the title in the download list.
    public var label: String {
        let width = max(2, String(max(count, index)).count)
        let digits = String(max(0, index))
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

public struct MediaDownloadRequest: Equatable, Sendable {
    public var url: URL
    public var kind: MediaKind
    public var quality: VideoQuality
    public var audioFormat: AudioFormat
    public var destination: URL
    public var position: PlaylistPosition?
    public init(url: URL, kind: MediaKind, quality: VideoQuality, audioFormat: AudioFormat, destination: URL,
                position: PlaylistPosition? = nil) {
        self.url = url; self.kind = kind; self.quality = quality
        self.audioFormat = audioFormat; self.destination = destination; self.position = position
    }

    /// Identifies what this request produces: the video and the form it is saved in.
    /// A delivered file is marked with it, so the same request is recognised later
    /// even if the file was renamed, and never confused with another video's file.
    public func originKey(hasFFmpeg: Bool) -> String {
        let identifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value ?? url.absoluteString
        let form = kind == .video ? "video|\(quality.rawValue)" : "audio|\(audioFormat.rawValue)"
        // Without ffmpeg the result is a lesser file; installing ffmpeg must not hide that.
        return "\(identifier)|\(form)" + (hasFFmpeg ? "" : "|plain")
    }
}

/// What a pasted link points at. A watch link opened from a playlist carries both.
public struct MediaLinkTarget: Equatable, Sendable {
    public var video: URL?
    public var playlist: URL?
}

public enum MediaLink {
    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com"
    ]

    /// The single video a link points at, if any.
    public static func youtubeURL(from text: String) -> URL? { target(from: text)?.video }

    /// Accept a YouTube video and/or playlist link and return canonical forms. Channel
    /// and non-YouTube links are rejected, and everything except the identifiers is
    /// dropped, so pasted text can never reach the downloader as an option.
    public static func target(from text: String) -> MediaLinkTarget? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 2048,
              !candidate.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        let lowered = candidate.lowercased()
        if !lowered.hasPrefix("http://") && !lowered.hasPrefix("https://") {
            guard !candidate.contains("://") else { return nil }
            candidate = "https://" + candidate
        }
        guard let components = URLComponents(string: candidate), let host = components.host?.lowercased(),
              hosts.contains(host), components.user == nil, components.password == nil, components.port == nil else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        func query(_ name: String) -> String? { components.queryItems?.first(where: { $0.name == name })?.value }
        func valid(_ value: String?, _ length: ClosedRange<Int>) -> String? {
            guard let value, length.contains(value.utf8.count),
                  value.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }) else { return nil }
            return value
        }
        let rawVideo: String?
        var acceptsList = true
        if host.hasSuffix("youtu.be") {
            rawVideo = segments.count == 1 ? segments[0] : nil
        } else if segments == ["watch"] {
            rawVideo = query("v")
        } else if segments.count == 2, ["shorts", "live", "embed", "v"].contains(segments[0]) {
            // "embed/videoseries?list=…" is the embed form of a playlist, not a video.
            rawVideo = segments == ["embed", "videoseries"] ? nil : segments[1]
        } else {
            rawVideo = nil
            acceptsList = segments == ["playlist"]
        }
        // A link that names a video must name a valid one; do not quietly fall back.
        if rawVideo != nil && valid(rawVideo, 6...20) == nil { return nil }
        let video = valid(rawVideo, 6...20)
        var list = acceptsList ? valid(query("list"), 2...64) : nil
        // Mixes ("RD…") are endless, generated radio stations; Watch Later and Liked need
        // a login. YouTube Music's editorial lists ("RDCLAK…") are ordinary finite playlists.
        if let value = list, (value.hasPrefix("RD") && !value.hasPrefix("RDCLAK")) || ["WL", "LL", "LM"].contains(value) { list = nil }
        guard video != nil || list != nil else { return nil }
        let site = host == "music.youtube.com" ? host : "www.youtube.com"
        return MediaLinkTarget(video: video.flatMap { URL(string: "https://\(site)/watch?v=\($0)") },
                               playlist: list.flatMap { URL(string: "https://\(site)/playlist?list=\($0)") })
    }

    /// A playlist title as a folder name: no path separators, no hidden or empty names.
    public static func folderName(for title: String, fallback: String) -> String {
        let cleaned = String(title.unicodeScalars.map { scalar -> Character in
            let joiner = scalar == "\u{200C}" || scalar == "\u{200D}"
            return "/:\\".unicodeScalars.contains(scalar) || (CharacterSet.controlCharacters.contains(scalar) && !joiner)
                || CharacterSet.newlines.contains(scalar) ? "-" : Character(scalar)
        })
        var name = ""
        var bytes = 0
        for character in cleaned.drop(while: { $0 == "." || $0.isWhitespace }).prefix(100) {
            let width = character.utf8.count
            guard bytes + width <= 255 else { break }
            name.append(character)
            bytes += width
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : name
    }

    /// A free name for `name` in a folder: "Song.mp3", then "Song 2.mp3", "Song 3.mp3"…
    /// An existing file is never replaced and never taken for the new one.
    public static func availableName(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for number in 2...9999 {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !isTaken(candidate) { return candidate }
        }
        return ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
    }

    private static let identifierCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
}

/// Command line for yt-dlp. Machine-readable lines carry a private prefix so the
/// parser never depends on yt-dlp's human-readable (and changing) log format.
public enum YtDlpCommand {
    public static let progressPrefix = "BARLET-PROGRESS|"
    public static let metaPrefix = "BARLET-META|"
    public static let filePrefix = "BARLET-FILE|"
    public static let listPrefix = "BARLET-LIST|"
    public static let entryPrefix = "BARLET-ENTRY|"
    /// Larger lists are cut here; each entry becomes its own download.
    public static let playlistLimit = 500

    /// List a playlist without downloading anything.
    public static func playlistArguments(for playlist: URL) -> [String] {
        ["--ignore-config", "--flat-playlist", "--yes-playlist", "--encoding", "utf-8",
         "--playlist-end", String(playlistLimit),
         "--print", "\(listPrefix)%(playlist_count)s|%(playlist_title)s",
         "--print", "\(entryPrefix)%(id)s|%(title)s",
         "--", playlist.absoluteString]
    }

    /// Without ffmpeg separate video and audio streams cannot be merged and audio
    /// cannot be converted, so only ready-made single files are requested.
    public static func formatSelector(kind: MediaKind, quality: VideoQuality, audioFormat: AudioFormat, hasFFmpeg: Bool) -> String {
        switch kind {
        case .video:
            guard hasFFmpeg else {
                guard let height = quality.height else { return "b[ext=mp4]/b" }
                return "b[height<=\(height)][ext=mp4]/b[height<=\(height)]/b[ext=mp4]/b"
            }
            guard let height = quality.height else { return "bv*+ba/b" }
            // Prefer H.264 + AAC up to the limit: that pair plays in QuickTime everywhere.
            return "bv*[height<=\(height)][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=\(height)]+ba/b[height<=\(height)]/bv*+ba/b"
        case .audio:
            guard hasFFmpeg else { return "ba[ext=m4a]/ba" }
            return audioFormat == .m4a ? "ba[ext=m4a]/ba/b" : "ba/b"
        }
    }

    /// yt-dlp works only inside `outputDirectory`, a private working folder. It never
    /// sees the user's folder: BStoeq moves the finished file there itself, under a
    /// free name, so nothing the user already has can be skipped over or replaced.
    public static func arguments(for request: MediaDownloadRequest, ffmpegDirectory: String?,
                                 outputDirectory: String) -> [String] {
        let hasFFmpeg = ffmpegDirectory != nil
        var arguments = [
            "--ignore-config", "--no-playlist", "--no-simulate", "--progress", "--newline",
            "--encoding", "utf-8", "--no-mtime",
            "--progress-template", "download:\(progressPrefix)%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--print", "before_dl:\(metaPrefix)%(format_id)s|%(title)s",
            "--print", "after_move:\(filePrefix)%(filepath)s",
            "--paths", outputDirectory,
            "--output", "%(title).150B.%(ext)s",
            "--format", formatSelector(kind: request.kind, quality: request.quality,
                                       audioFormat: request.audioFormat, hasFFmpeg: hasFFmpeg)
        ]
        if let ffmpegDirectory {
            arguments += ["--ffmpeg-location", ffmpegDirectory]
            switch request.kind {
            case .video:
                arguments += ["--merge-output-format", "mp4/mkv"]
            case .audio:
                arguments += ["--extract-audio", "--audio-format", request.audioFormat.rawValue,
                              "--audio-quality", "0", "--embed-metadata"]
            }
        }
        // Everything after "--" is a URL, never an option.
        return arguments + ["--", request.url.absoluteString]
    }
}

public enum YtDlpEvent: Equatable, Sendable {
    case meta(title: String, parts: Int)
    case progress(downloaded: Double?, total: Double?, speed: Double?, eta: Double?, finished: Bool)
    case file(String)
    case error(String)
    /// One line per entry: the playlist's title and its full length, when known.
    case playlist(title: String?, count: Int?)
    case playlistEntry(id: String, title: String)
}

public enum YtDlpOutput {
    public static func parse(_ rawLine: String) -> YtDlpEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(YtDlpCommand.progressPrefix) {
            let fields = line.dropFirst(YtDlpCommand.progressPrefix.count)
                .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6 else { return nil }
            func number(_ text: String) -> Double? {
                guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
                return value
            }
            return .progress(downloaded: number(fields[1]), total: number(fields[2]) ?? number(fields[3]),
                             speed: number(fields[4]), eta: number(fields[5]), finished: fields[0] == "finished")
        }
        if line.hasPrefix(YtDlpCommand.metaPrefix) {
            let fields = line.dropFirst(YtDlpCommand.metaPrefix.count)
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { return nil }
            return .meta(title: fields[1], parts: max(1, fields[0].split(separator: "+").count))
        }
        if line.hasPrefix(YtDlpCommand.filePrefix) {
            let path = String(line.dropFirst(YtDlpCommand.filePrefix.count))
            return path.hasPrefix("/") ? .file(path) : nil
        }
        if line.hasPrefix(YtDlpCommand.listPrefix) {
            let fields = line.dropFirst(YtDlpCommand.listPrefix.count)
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { return nil }
            let title = fields[1].isEmpty || fields[1] == "NA" ? nil : fields[1]
            let count = Int(fields[0]).flatMap { $0 > 0 ? $0 : nil }
            return title == nil && count == nil ? nil : .playlist(title: title, count: count)
        }
        if line.hasPrefix(YtDlpCommand.entryPrefix) {
            let fields = line.dropFirst(YtDlpCommand.entryPrefix.count)
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            // The identifier is used to build a link; accept only what a link accepts.
            guard fields.count == 2, MediaLink.youtubeURL(from: "https://www.youtube.com/watch?v=\(fields[0])") != nil else { return nil }
            return .playlistEntry(id: fields[0], title: fields[1])
        }
        if line.hasPrefix("ERROR:") {
            let message = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
            return message.isEmpty ? nil : .error(String(message.prefix(300)))
        }
        return nil
    }
}

/// A video is usually two downloads (picture, then sound) followed by a merge.
/// Fold them into one fraction that never moves backwards.
public struct DownloadProgressTracker: Equatable, Sendable {
    public private(set) var parts = 1
    public private(set) var fraction = 0.0
    /// All parts are downloaded; yt-dlp is merging or converting.
    public private(set) var processing = false
    private var partIndex = 0
    private var partFraction = 0.0
    private var partFinished = false

    public init() {}

    public mutating func setParts(_ count: Int) { parts = max(1, count) }

    public mutating func update(downloaded: Double?, total: Double?, finished: Bool) {
        if partFinished && !finished {
            partIndex += 1; partFraction = 0; partFinished = false
        }
        if finished {
            partFraction = 1; partFinished = true
        } else if let downloaded, let total, total > 0 {
            partFraction = min(1, downloaded / total)
        }
        let expected = Double(max(parts, partIndex + 1))
        fraction = min(1, max(fraction, (Double(partIndex) + partFraction) / expected))
        processing = partFinished && partIndex + 1 >= parts
    }
}
