import Foundation

/// The command lines `MediaConverter` gives ffmpeg and ffprobe, and the readers of what they print. Pure,
/// so every argument can be checked literally. Paths are absolute and carry the `file:` protocol, so no
/// file name can pass for an option or for another protocol ("concat:…"). Codecs and muxers are always
/// named: this ffmpeg build would put AC-3 into `.mkv` and FLAC into `.ogg` on its own.
enum FFmpegArguments {
    /// What ffprobe, ffmpeg's banner or AVFoundation says about a source. Nil is "not known".
    struct Source: Equatable, Sendable {
        var duration: Double?
        var hasVideo: Bool?
        var hasAudio: Bool?
        var width: Int?
        var height: Int?
        var pixelFormat: String?
        /// ffmpeg's names: "bt2020", "arib-std-b67", "bt2020nc".
        var primaries: String?
        var transfer: String?
        var matrix: String?

        init(duration: Double? = nil, hasVideo: Bool? = nil, hasAudio: Bool? = nil, width: Int? = nil, height: Int? = nil,
             pixelFormat: String? = nil, primaries: String? = nil, transfer: String? = nil, matrix: String? = nil) {
            self.duration = duration; self.hasVideo = hasVideo; self.hasAudio = hasAudio; self.width = width; self.height = height
            self.pixelFormat = pixelFormat; self.primaries = primaries; self.transfer = transfer; self.matrix = matrix
        }

        /// HLG or PQ: such a picture is never squeezed through an 8-bit encoder untouched.
        var isHDR: Bool { transfer == "arib-std-b67" || transfer == "smpte2084" }
    }

    /// One ffmpeg run.
    struct Command: Equatable, Sendable {
        let arguments: [String]
        /// The seconds the result is cut to (a ringtone, a GIF); nil for the whole source.
        let limit: Double?
        /// The target asked for H.264, and an HDR source was encoded as 10-bit HEVC instead.
        let keptHDRAsHEVC: Bool
    }

    // MARK: Asking

    /// ffprobe's JSON with the duration and, per stream, what the converter decides on.
    static func probe(_ url: URL) -> [String] {
        ["-v", "error", "-print_format", "json",
         "-show_entries", "format=duration:stream=codec_type,width,height,pix_fmt,color_primaries,color_transfer,color_space:stream_disposition=attached_pic",
         path(url)]
    }

    /// Without ffprobe: ffmpeg describes its input on stderr and stops for want of an output.
    static func banner(_ url: URL) -> [String] { ["-hide_banner", "-nostdin", "-i", path(url)] }

    /// The encoders a product needs, or nil when ffmpeg cannot make it at all.
    static func encoders(for product: MediaConverter.Product) -> Set<String>? {
        switch product {
        case .audio(let sound):
            return [audioCodec(sound)]
        case .video(let container, let codec, _, _, let removeAudio):
            let video: String
            switch container {
            case "mp4", "mov", "m4v": video = codec == .hevc ? "libx265" : "libx264"
            case "mkv": video = "libx264"
            case "webm": video = "libvpx-vp9"
            default: return nil
            }
            return removeAudio ? [video] : [video, container == "webm" ? "libopus" : "aac"]
        case .mute(let container):
            return muxers[container] == nil ? nil : []
        case .gif:
            return ["gif"]
        }
    }

    /// The whole command line for one product, or nil when the installed encoders cannot make it
    /// (an HDR picture without libx265, a container ffmpeg is not asked to write).
    static func command(_ product: MediaConverter.Product, input: URL, output: URL, source: Source, encoders: Set<String>) -> Command? {
        var body: [String]
        var limit: Double?
        var keptHDR = false
        let muxer: String
        switch product {
        case .audio(let sound):
            body = ["-map", "0:a:0", "-c:a", audioCodec(sound)]
            switch sound {
            case .aac(let kbps), .mp3(let kbps), .vorbis(let kbps), .opus(let kbps): body += ["-b:a", "\(kbps)k"]
            case .ringtone(let kbps): body += ["-b:a", "\(kbps)k", "-t", "30"]; limit = 30
            case .alac, .wav, .aiff, .flac: break
            }
            muxer = audioMuxer(sound)
            if muxer == "ipod" { body += ["-movflags", "+faststart"] }
        case .video(let container, let codec, let quality, let maxHeight, let removeAudio):
            guard let named = muxers[container] else { return nil }
            muxer = named
            let mp4Family = ["mp4", "mov", "m4v"].contains(container)
            let level = quality == .high ? 0 : quality == .balanced ? 1 : 2
            body = ["-map", "0:v:0"] + (removeAudio ? [] : ["-map", "0:a:0?"]) + ["-vf", scale(maxShortSide: maxHeight)]
            if container == "webm" {
                body += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", ["31", "35", "40"][level], "-deadline", "good", "-cpu-used", "4",
                         "-row-mt", "1"]
                body += source.isHDR ? ["-pix_fmt", "yuv420p10le", "-profile:v", "2"] + colourTags(source) : ["-pix_fmt", "yuv420p"]
                body += removeAudio ? ["-an"] : ["-c:a", "libopus", "-b:a", ["192k", "128k", "96k"][level]]
            } else {
                guard mp4Family || container == "mkv" else { return nil }
                let wantsHEVC = mp4Family && codec == .hevc
                // x264 at 8 bits would keep the HDR signalling on pixels it never converted: HEVC keeps both.
                let hevc = source.isHDR || (wantsHEVC && encoders.contains("libx265"))
                if source.isHDR && !encoders.contains("libx265") { return nil }
                keptHDR = source.isHDR && !wantsHEVC
                if hevc {
                    body += ["-c:v", "libx265", "-preset", "medium", "-crf", ["22", "26", "30"][level],
                             "-pix_fmt", source.isHDR ? "yuv420p10le" : "yuv420p", "-x265-params", "log-level=error"]
                    if mp4Family { body += ["-tag:v", "hvc1"] }
                    if source.isHDR { body += colourTags(source) }
                } else {
                    body += ["-c:v", "libx264", "-preset", "medium", "-crf", ["18", "23", "28"][level], "-pix_fmt", "yuv420p"]
                }
                body += removeAudio ? ["-an"] : ["-c:a", "aac", "-b:a", ["256k", "192k", "128k"][level]]
                if mp4Family { body += ["-movflags", "+faststart"] }
            }
        case .mute(let container):
            guard let named = muxers[container] else { return nil }
            muxer = named
            body = ["-map", "0:v", "-c", "copy"]
            if ["mp4", "mov", "m4v"].contains(container) { body += ["-movflags", "+faststart"] }
        case .gif(let quality):
            let fps = quality == .high ? 15 : quality == .balanced ? 12 : 10
            let side = MediaConverter.gifLongSide(quality)
            body = ["-map", "0:v:0", "-t", "60", "-vf",
                    "fps=\(fps),scale='if(gte(iw,ih),min(\(side),iw),-1)':'if(gte(iw,ih),-1,min(\(side),ih))':flags=lanczos,"
                        + "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                    "-loop", "0"]
            limit = 60
            muxer = "gif"
        }
        // `-stats_period` also paces `-progress`, so even a short encode reports before it ends.
        let head = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-progress", "pipe:1", "-stats_period", "0.25", "-n",
                    "-i", path(input)]
        return Command(arguments: head + body + ["-f", muxer, path(output)], limit: limit, keptHDRAsHEVC: keptHDR)
    }

    // MARK: Reading

    /// Seconds written so far, from one line of `-progress pipe:1`.
    static func progressSeconds(_ line: String) -> Double? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("out_time_us="), let micro = Double(line.dropFirst("out_time_us=".count)), micro.isFinite, micro >= 0 else { return nil }
        return micro / 1_000_000
    }

    /// The detail for a failed run: ffmpeg's last word on stderr.
    static func complaint(_ stderr: String) -> String {
        stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? "ffmpeg"
    }

    /// Nil when the output is not ffprobe's JSON.
    static func source(probe data: Data) -> Source? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var source = Source(hasVideo: false, hasAudio: false)
        if let format = root["format"] as? [String: Any], let text = format["duration"] as? String, let seconds = Double(text),
           seconds.isFinite, seconds > 0 { source.duration = seconds }
        for stream in root["streams"] as? [[String: Any]] ?? [] {
            switch stream["codec_type"] as? String {
            case "audio":
                source.hasAudio = true
            case "video" where source.hasVideo != true:
                // Cover art is a video stream too, one frame long.
                if let disposition = stream["disposition"] as? [String: Any], disposition["attached_pic"] as? Int == 1 { continue }
                source.hasVideo = true
                source.width = stream["width"] as? Int; source.height = stream["height"] as? Int
                source.pixelFormat = stream["pix_fmt"] as? String
                source.primaries = known(stream["color_primaries"] as? String)
                source.transfer = known(stream["color_transfer"] as? String)
                source.matrix = known(stream["color_space"] as? String)
            default: break
            }
        }
        return source
    }

    /// ffmpeg's description of its input, read as far as it goes: "Duration: 00:00:05.00, …" and
    /// "Stream #0:0: Video: hevc (Main 10) (hvc1 / …), yuv420p10le(tv, bt2020nc/bt2020/arib-std-b67), 640x360 …".
    static func source(banner text: String) -> Source {
        var source = Source()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Duration: ") {
                let clock = line.dropFirst("Duration: ".count).prefix { $0 != "," }.split(separator: ":").compactMap { Double($0) }
                if clock.count == 3 { source.duration = clock[0] * 3600 + clock[1] * 60 + clock[2] }
            } else if line.hasPrefix("Stream #") {
                if source.hasVideo == nil { source.hasVideo = false; source.hasAudio = false }
                if line.contains(": Audio: ") { source.hasAudio = true }
                guard let video = line.range(of: ": Video: "), source.hasVideo != true, !line.contains("(attached pic)") else { continue }
                source.hasVideo = true
                let parts = topLevelParts(String(line[video.upperBound...]))
                if parts.count > 1 {
                    let picture = parts[1]
                    source.pixelFormat = String(picture.prefix { $0 != "(" })
                    if let open = picture.firstIndex(of: "("), let close = picture.lastIndex(of: ")"), open < close {
                        for detail in picture[picture.index(after: open)..<close].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                            let names = detail.split(separator: "/").map(String.init)
                            if names.count == 3 {
                                source.matrix = known(names[0]); source.primaries = known(names[1]); source.transfer = known(names[2])
                            } else if names.count == 1, ["bt", "smpte", "arib"].contains(where: detail.hasPrefix) {
                                source.matrix = detail; source.primaries = detail; source.transfer = detail
                            }
                        }
                    }
                }
                for part in parts.dropFirst() {
                    let numbers = part.prefix { $0.isNumber || $0 == "x" }.split(separator: "x").compactMap { Int($0) }
                    if numbers.count == 2 { source.width = numbers[0]; source.height = numbers[1]; break }
                }
            }
        }
        return source
    }

    /// AVFoundation's colour names (`kCMFormatDescription…` values) as ffmpeg spells them.
    static func colourNames(primaries: String?, transfer: String?, matrix: String?) -> (primaries: String?, transfer: String?, matrix: String?) {
        (primaries.flatMap { ["ITU_R_2020": "bt2020", "ITU_R_709_2": "bt709", "SMPTE_C": "smpte170m", "EBU_3213": "bt470bg",
                              "P3_D65": "smpte432", "DCI_P3": "smpte431"][$0] },
         transfer.flatMap { ["ITU_R_2100_HLG": "arib-std-b67", "SMPTE_ST_2084_PQ": "smpte2084", "ITU_R_709_2": "bt709",
                             "ITU_R_2020": "bt2020-10", "SMPTE_240M_1995": "smpte240m", "Linear": "linear"][$0] },
         matrix.flatMap { ["ITU_R_2020": "bt2020nc", "ITU_R_709_2": "bt709", "ITU_R_601_4": "smpte170m", "SMPTE_240M_1995": "smpte240m"][$0] })
    }

    // MARK: Pieces

    private static let muxers = ["mp4": "mp4", "m4v": "mp4", "mov": "mov", "mkv": "matroska", "webm": "webm", "avi": "avi", "wmv": "asf",
                                 "flv": "flv", "ts": "mpegts", "mpg": "mpeg", "3gp": "3gp"]

    private static func path(_ url: URL) -> String { "file:" + url.path }

    private static func audioCodec(_ sound: MediaConverter.Sound) -> String {
        switch sound {
        case .aac, .ringtone: "aac"
        case .alac: "alac"
        case .wav: "pcm_s16le"
        case .aiff: "pcm_s16be"
        case .flac: "flac"
        case .mp3: "libmp3lame"
        case .vorbis: "libvorbis"
        case .opus: "libopus"
        }
    }

    private static func audioMuxer(_ sound: MediaConverter.Sound) -> String {
        switch sound {
        case .aac, .ringtone, .alac: "ipod"
        case .wav: "wav"
        case .aiff: "aiff"
        case .flac: "flac"
        case .mp3: "mp3"
        case .vorbis: "ogg"
        case .opus: "opus"
        }
    }

    /// Never larger, even dimensions for 4:2:0; a cap applies to the shorter side, so a portrait "720p" is
    /// 720 wide. The quotes keep the commas inside the expressions from splitting the filter chain.
    private static func scale(maxShortSide cap: Int) -> String {
        guard cap > 0 else { return "scale='2*trunc(iw/2)':'2*trunc(ih/2)'" }
        return "scale='if(gte(iw,ih),-2,min(\(cap),2*trunc(iw/2)))':'if(gte(iw,ih),min(\(cap),2*trunc(ih/2)),-2)'"
    }

    /// The source's own tags, with the BT.2020 defaults an HDR stream almost always has.
    private static func colourTags(_ source: Source) -> [String] {
        ["-color_primaries", source.primaries ?? "bt2020", "-color_trc", source.transfer ?? "arib-std-b67", "-colorspace", source.matrix ?? "bt2020nc"]
    }

    private static func known(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name != "unknown", name != "reserved", name != "unspecified" else { return nil }
        return name
    }

    /// "a (b, c), d" gives "a (b, c)" and "d".
    private static func topLevelParts(_ text: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for character in text {
            switch character {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue
            default: break
            }
            current.append(character)
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }
}
