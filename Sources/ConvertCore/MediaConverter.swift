import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Audio and video. AVFoundation makes everything it can read and write, also when ffmpeg is installed;
/// the user's ffmpeg makes the formats only it writes (MP3, Ogg, Opus, WebM, MKV) from the files only it
/// opens (MKV, WebM, AVI, Ogg FLAC…). A GIF prefers ffmpeg's palette and falls back to ImageIO frames.
public struct MediaConverter: Converter {
    public init() {}

    /// What a target asks of a media file, whichever route makes it.
    enum Product: Equatable, Sendable {
        case audio(Sound)
        /// `container` is the output format id; `compress` keeps the source's.
        case video(container: String, codec: ConversionVideoCodec, quality: ConversionQuality, maxHeight: Int, removeAudio: Bool)
        case mute(container: String)
        case gif(ConversionQuality)

        /// AVFoundation can write it (a GIF through ImageIO).
        var isNative: Bool {
            switch self {
            case .audio(let sound):
                switch sound {
                case .aac, .ringtone, .alac, .wav, .aiff, .flac: true
                case .mp3, .vorbis, .opus: false
                }
            case .video(let container, _, _, _, _), .mute(let container): WriterType(container: container) != nil
            case .gif: true
            }
        }

        var needsPicture: Bool {
            if case .audio = self { return false }
            return true
        }
    }

    enum Sound: Equatable, Sendable {
        case aac(kbps: Int), ringtone(kbps: Int), alac, wav, aiff, flac, mp3(kbps: Int), vorbis(kbps: Int), opus(kbps: Int)
    }

    /// AVFoundation reads these; Ogg and Opus files only when their track is Vorbis or Opus (checked per file).
    static let nativeSources: Set<String> = ["mp4", "mov", "m4v", "wav", "aiff", "caf", "m4a", "m4r", "aac", "mp3", "flac", "ac3", "amr",
                                             "ogg", "opus"]
    /// Only ffmpeg opens these.
    static let ffmpegSources: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "ts", "mpg", "3gp", "wma"]

    static func product(_ target: ConversionTarget, output: String, options: ConversionOptions) -> Product? {
        let kbps = options.audioBitrate
        switch target.id {
        case "m4a": return .audio(.aac(kbps: kbps))
        case "m4r": return .audio(.ringtone(kbps: kbps))
        case "alac": return .audio(.alac)
        case "wav": return .audio(.wav)
        case "aiff": return .audio(.aiff)
        case "flac": return .audio(.flac)
        case "mp3", "mp3.128k": return .audio(.mp3(kbps: kbps))
        case "ogg": return .audio(.vorbis(kbps: kbps))
        case "opus": return .audio(.opus(kbps: kbps))
        case "mp4", "mov", "mkv", "webm", "mp4.720p", "mp4.hevc", "compress":
            return .video(container: output, codec: options.videoCodec, quality: options.videoQuality, maxHeight: options.videoMaxHeight,
                          removeAudio: options.removeAudio)
        case "mute": return .mute(container: output)
        case "gif": return .gif(options.videoQuality)
        default: return nil
        }
    }

    public func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
        guard Self.nativeSources.contains(source.id) || Self.ffmpegSources.contains(source.id),
              !(target.kind == .convert && target.id == source.id),
              let product = Self.product(target, output: target.format == "*" ? source.id : target.format,
                                         options: ConversionOptions().applying(target.overrides)),
              source.family == .video || !product.needsPicture
        else { return .unsupported }
        if Self.nativeSources.contains(source.id), product.isNative { return .available }
        guard let encoders = FFmpegArguments.encoders(for: product) else { return .unsupported }
        guard environment.ffmpeg != nil else { return .needs("ffmpeg") }
        return encoders.isSubset(of: environment.encoders) ? .available : .unsupported
    }

    public func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
        guard let url = request.sources.first, let format = request.formats.first,
              let product = Self.product(request.target, output: request.outputFormat.id, options: request.options)
        else { throw Self.unreadable }
        let native = Self.nativeSources.contains(format.id) ? await NativeSource.load(url, format: format) : nil
        try Self.checkCancelled(context)
        let environment = request.environment
        let ffmpegReady = environment.ffmpeg != nil
            && FFmpegArguments.encoders(for: product).map { $0.isSubset(of: environment.encoders) } == true
        if let native, product.isNative {
            if case .audio = product, native.audio == nil { throw format.family == .video ? Self.silent : Self.unreadable }
            var preferFFmpeg = false
            // ffmpeg's palette makes the better GIF, but an HDR picture needs the generator's tone mapping.
            if case .gif = product { preferFFmpeg = ffmpegReady && !native.isHDR }
            if !preferFFmpeg, native.canMake(product) {
                switch product {
                case .audio(.flac): return try await flac(native, request, format, context)
                case .audio(let sound): return try await audio(sound, native, request, context)
                case .video(let container, let codec, let quality, let maxHeight, let removeAudio):
                    return try await video(container, codec, quality, maxHeight, removeAudio, native, request, context)
                case .mute(let container): return try await mute(container, native, request, context)
                case .gif(let quality): return try await gif(quality, native, request, context)
                }
            }
        }
        guard ffmpegReady, let ffmpeg = environment.ffmpeg else { throw Self.unreadable }
        return try await viaFFmpeg(ffmpeg, product, native, request, format, context)
    }

    // MARK: Pure rules

    /// The longer side of a GIF: 640, 480 or 320 px.
    static func gifLongSide(_ quality: ConversionQuality) -> Int { quality == .high ? 640 : quality == .balanced ? 480 : 320 }

    struct GIFPlan: Equatable, Sendable {
        let fps: Double, frames: Int, width: Int, height: Int
        /// Cut shorter than the source and the 60 s limit, to stay within the pixel budget.
        let trimmedForBudget: Bool
    }

    /// ImageIO keeps every frame until it finalizes (600 portrait frames peaked at 2.6 GB), so frames ×
    /// width × height stays within 40 million pixels: the frame rate goes down first, not below 5 fps,
    /// then the duration. Never larger than the picture; at most 60 s.
    static func gifPlan(duration: Double, width: Int, height: Int, longSide: Int) -> GIFPlan {
        let budget = 40_000_000.0
        let scale = min(1, Double(longSide) / Double(max(width, height, 1)))
        let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
        let pixels = Double(w * h)
        let seconds = min(max(duration, 0), 60)
        var fps = 10.0
        if seconds * fps * pixels > budget { fps = max(5, min(10, (budget / (pixels * max(seconds, 0.1))).rounded(.down))) }
        var frames = max(1, Int((seconds * fps).rounded(.down)))
        var trimmed = false
        if Double(frames) * pixels > budget {
            frames = max(1, Int(budget / pixels))
            trimmed = true
        }
        return GIFPlan(fps: fps, frames: frames, width: w, height: h, trimmedForBudget: trimmed)
    }

    /// The written size: the shorter side capped (a portrait "720p" is 720 wide), never enlarged, even.
    static func pictureSize(width: Int, height: Int, maxShortSide: Int) -> (width: Int, height: Int) {
        let short = min(width, height)
        let scale = maxShortSide > 0 && short > maxShortSide ? Double(maxShortSide) / Double(short) : 1
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// Explicit bitrates, because quality presets barely shrink (720p came out at 8.8 Mbit/s): bits per
    /// pixel and frame for the level, HEVC needing less, and never more than a share of what the source spends.
    static func videoBitrate(width: Int, height: Int, frameRate: Double, codec: ConversionVideoCodec, quality: ConversionQuality,
                             sourceRate: Double) -> Int {
        let level = quality == .high ? 0 : quality == .balanced ? 1 : 2
        var rate = Double(width * height) * (frameRate > 0 ? frameRate : 30) * [0.10, 0.06, 0.03][level] * (codec == .hevc ? 0.6 : 1)
        if sourceRate > 0 { rate = min(rate, sourceRate * [1.0, 0.7, 0.45][level]) }
        return max(100_000, Int(rate))
    }

    // MARK: Native audio

    private func audio(_ sound: Sound, _ native: NativeSource, _ request: ConversionRequest, _ context: ConversionContext) async throws -> [URL] {
        guard let track = native.audio else { throw Self.unreadable }
        let output = request.outputURL()
        var written = output, range: CMTimeRange?, seconds = native.duration
        let type: WriterType
        switch sound {
        case .aac, .alac: type = .m4a
        case .ringtone:
            // The writer knows m4a, not m4r: the ringtone is written as m4a and renamed.
            type = .m4a
            written = request.workFolder.appendingPathComponent(".ringtone-\(UUID().uuidString).m4a")
            range = CMTimeRange(start: .zero, duration: CMTime(seconds: 30, preferredTimescale: 600))
            seconds = min(seconds, 30)
        case .wav: type = .wav
        case .aiff: type = .aiff
        case .flac, .mp3, .vorbis, .opus: throw Self.unreadable
        }
        try await Self.pump(native.asset, into: written, type: type, lanes: [Self.soundLane(track, native, sound)], range: range,
                            duration: seconds, context: context)
        if written != output {
            do { try FileManager.default.moveItem(at: written, to: output) } catch { try? FileManager.default.removeItem(at: written); throw error }
            if native.duration > 30.05 { context.note("Zil sesi ilk 30 saniyeden oluşturuldu.") }
        }
        return [output]
    }

    /// AVAssetWriter has no FLAC file type (and an unknown type aborts the app), so FLAC goes through
    /// AVAudioFile. It reads audio files only: the sound of a video, or a file it cannot open, is first
    /// written out as PCM.
    private func flac(_ native: NativeSource, _ request: ConversionRequest, _ format: FileFormat, _ context: ConversionContext) async throws -> [URL] {
        let output = request.outputURL()
        if format.family == .audio {
            let meter = Meter(context, duration: 1, span: 0...1)
            if try await ConversionWork.run({ [source = request.sources[0]] in try Self.encodeFLAC(source, to: output, context: context, meter: meter) }) {
                return [output]
            }
        }
        guard let track = native.audio else { throw Self.unreadable }
        let staging = request.workFolder.appendingPathComponent(".pcm-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Self.pump(native.asset, into: staging, type: .wav, lanes: [Self.soundLane(track, native, .wav)], range: nil,
                            duration: native.duration, context: context, span: 0...0.5)
        let meter = Meter(context, duration: 1, span: 0.5...1)
        guard try await ConversionWork.run({ try Self.encodeFLAC(staging, to: output, context: context, meter: meter) }) else { throw Self.unreadable }
        return [output]
    }

    /// False when AVAudioFile cannot open the source; nothing is written then.
    private static func encodeFLAC(_ source: URL, to output: URL, context: ConversionContext, meter: Meter) throws -> Bool {
        guard let file = try? AVAudioFile(forReading: source) else { return false }
        do {
            let format = file.processingFormat
            var settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: format.sampleRate,
                                           AVNumberOfChannelsKey: format.channelCount,
                                           AVLinearPCMBitDepthKey: file.fileFormat.streamDescription.pointee.mBitsPerChannel >= 24 ? 24 : 16]
            if format.channelCount > 2, let layout = format.channelLayout {
                settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
            }
            let out = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { throw unreadable }
            let total = Double(max(file.length, 1))
            while file.framePosition < file.length {
                try context.checkCancelled()
                do { try file.read(into: buffer) } catch let error as NSError where error.code == Int(kAudioFileEndOfFileError) && file.framePosition > 0 {
                    // Some compressed files (AC-3) announce more frames than they hold: their real end comes early.
                    break
                }
                if buffer.frameLength == 0 { break }
                try out.write(from: buffer)
                meter.report(Double(file.framePosition) / total)
            }
            out.close()
            return true
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: Native video

    private func video(_ container: String, _ codec: ConversionVideoCodec, _ quality: ConversionQuality, _ maxHeight: Int, _ removeAudio: Bool,
                       _ native: NativeSource, _ request: ConversionRequest, _ context: ConversionContext) async throws -> [URL] {
        guard let track = native.video, let type = WriterType(container: container) else { throw Self.unreadable }
        let size = Self.pictureSize(width: Int(abs(native.size.width).rounded()), height: Int(abs(native.size.height).rounded()),
                                    maxShortSide: maxHeight)
        let fps = Double(native.frameRate)
        // A 10-bit source stays 10-bit in HEVC with its colour; for anything else an HDR picture is
        // converted to Rec.709 by the reader, which is what makes the 8-bit result look right.
        let deep = codec == .hevc && native.isDeep
        let toSDR = native.isHDR && !deep
        var reader: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String:
                                        deep ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        if toSDR { reader[AVVideoColorPropertiesKey] = Self.rec709 }
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: Self.videoBitrate(width: size.width, height: size.height, frameRate: fps, codec: codec, quality: quality,
                                                        sourceRate: Double(native.videoRate)),
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(((fps > 0 ? fps : 30) * 2).rounded())),
            AVVideoProfileLevelKey: codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel
                : (deep ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
        ]
        let plain: [String: Any] = [AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
                                    AVVideoWidthKey: size.width, AVVideoHeightKey: size.height, AVVideoCompressionPropertiesKey: compression]
        var writer = [plain]
        if toSDR {
            writer.insert(plain.merging([AVVideoColorPropertiesKey: Self.rec709]) { $1 }, at: 0)
        } else if native.colour.count == 3 {
            writer.insert(plain.merging([AVVideoColorPropertiesKey: native.colour]) { $1 }, at: 0)
        }
        var lanes = [Lane(track: track, kind: .video, reader: reader, writer: writer, transform: native.transform)]
        if !removeAudio, let sound = native.audio, native.audioDecodable {
            lanes.append(Self.soundLane(sound, native, .aac(kbps: [256, 192, 128][quality == .high ? 0 : quality == .balanced ? 1 : 2])))
        }
        let output = request.outputURL()
        try await Self.pump(native.asset, into: output, type: type, lanes: lanes, range: nil, duration: native.duration, context: context)
        return [output]
    }

    /// The video track as it is, without re-encoding: a composition without the sound, passed through.
    private func mute(_ container: String, _ native: NativeSource, _ request: ConversionRequest, _ context: ConversionContext) async throws -> [URL] {
        guard let track = native.video, let type = WriterType(container: container) else { throw Self.unreadable }
        let composition = AVMutableComposition()
        guard let lane = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Self.unreadable }
        try lane.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        lane.preferredTransform = native.transform
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw Self.unreadable }
        let output = request.outputURL()
        let meter = Meter(context, duration: 1, span: 0...1)
        let states = session.states(updateInterval: 0.2)
        let watcher = Task {
            for await state in states { if case .exporting(let progress) = state { meter.report(progress.fractionCompleted) } }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: output, as: type.fileType)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Task.isCancelled || context.isCancelled() ? CancellationError() : error
        }
        return [output]
    }

    // MARK: Native GIF

    /// One native GIF at a time: each holds all its frames until it finalizes.
    private static let gifGate = Turnstile()

    private func gif(_ quality: ConversionQuality, _ native: NativeSource, _ request: ConversionRequest, _ context: ConversionContext) async throws -> [URL] {
        try await Self.gifGate.enter()
        do {
            let result = try await frames(quality, native, request, context)
            await Self.gifGate.leave()
            return result
        } catch {
            await Self.gifGate.leave()
            throw error
        }
    }

    private func frames(_ quality: ConversionQuality, _ native: NativeSource, _ request: ConversionRequest, _ context: ConversionContext) async throws -> [URL] {
        let shown = native.size.applying(native.transform)
        let plan = Self.gifPlan(duration: native.duration, width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
                                longSide: Self.gifLongSide(quality))
        let generator = AVAssetImageGenerator(asset: native.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: plan.width, height: plan.height)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let output = request.outputURL()
        // Through a consumer of its own: a destination made with the URL keeps a temporary file that an
        // unfinished GIF leaves behind.
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.gif.identifier as CFString, plan.frames, nil) else {
            throw ConversionFailure("Dönüştürülemedi: %@", detail: "GIF")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let box = Box(destination)
        let step = 1 / plan.fps
        let meter = Meter(context, duration: Double(plan.frames), span: 0...0.9)
        do {
            // A frame that cannot be made lengthens the one before it, so the timing holds. That is also how a
            // slow source comes out: the generator does not hand out one source frame twice in a row.
            var held: (image: CGImage, delay: Double)?
            var seen = 0
            let times = (0..<plan.frames).map { CMTime(seconds: Double($0) * step, preferredTimescale: 600) }
            for await element in generator.images(for: times) {
                try Self.checkCancelled(context)
                seen += 1
                meter.report(Double(seen))
                guard case .success(_, let image, _) = element else {
                    if let frame = held { held = (frame.image, frame.delay + step) }
                    continue
                }
                if let frame = held { try await Self.add(frame.image, delay: frame.delay, to: box) }
                held = (image, step)
            }
            // The sequence ends early, without an error, when its task is cancelled.
            try Self.checkCancelled(context)
            guard let last = held else { throw Self.unreadable }
            try await Self.add(last.image, delay: last.delay, to: box)
            guard try await ConversionWork.run({ CGImageDestinationFinalize(box.value) }) else {
                throw ConversionFailure("Dönüştürülemedi: %@", detail: "GIF")
            }
        } catch {
            generator.cancelAllCGImageGeneration()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        if plan.trimmedForBudget {
            context.note("Dosya boyutunu sınırlamak için GIF kısaltıldı.")
        } else if native.duration > 60.05 {
            context.note("GIF yalnızca ilk 60 saniyeyi içerir.")
        }
        return [output]
    }

    private static func add(_ image: CGImage, delay: Double, to box: Box<CGImageDestination>) async throws {
        try await ConversionWork.run {
            CGImageDestinationAddImage(box.value, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
    }

    // MARK: ffmpeg

    private func viaFFmpeg(_ ffmpeg: URL, _ product: Product, _ native: NativeSource?, _ request: ConversionRequest, _ format: FileFormat,
                           _ context: ConversionContext) async throws -> [URL] {
        let input = request.sources[0]
        let facts = await Self.facts(of: input, environment: request.environment, native: native)
        try Self.checkCancelled(context)
        if product.needsPicture {
            if facts.hasVideo == false { throw Self.unreadable }
        } else if facts.hasAudio == false {
            throw format.family == .video ? Self.silent : Self.unreadable
        }
        let output = request.outputURL()
        guard let command = FFmpegArguments.command(product, input: input, output: output, source: facts, encoders: request.environment.encoders) else {
            throw ConversionFailure("Bu dönüştürme için %@ gerekli.", detail: "libx265")
        }
        let duration = min(facts.duration ?? 0, command.limit ?? .infinity)
        let meter = Meter(context, duration: duration, span: 0...1)
        let result: ToolOutput
        do {
            result = try await ToolProcess.run(ffmpeg, arguments: command.arguments, capture: .lines { line in
                if let seconds = FFmpegArguments.progressSeconds(line) { meter.report(seconds) }
            })
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionFailure("Dönüştürülemedi: %@", detail: FFmpegArguments.complaint(result.stderrTail))
        }
        if command.keptHDRAsHEVC { context.note("HDR görüntüyü korumak için video HEVC olarak kodlandı.") }
        if let seconds = facts.duration, let limit = command.limit, seconds > limit + 0.05 {
            switch product {
            case .gif: context.note("GIF yalnızca ilk 60 saniyeyi içerir.")
            default: context.note("Zil sesi ilk 30 saniyeden oluşturuldu.")
            }
        }
        return [output]
    }

    /// ffprobe when it is there, else what AVFoundation found, else ffmpeg's own description.
    private static func facts(of url: URL, environment: ConversionEnvironment, native: NativeSource?) async -> FFmpegArguments.Source {
        if let ffprobe = environment.ffprobe,
           let output = try? await ToolProcess.run(ffprobe, arguments: FFmpegArguments.probe(url), capture: .data(limit: 8 << 20)),
           output.status == 0, let facts = FFmpegArguments.source(probe: output.stdout) { return facts }
        if let native { return native.facts }
        if let ffmpeg = environment.ffmpeg, let output = try? await ToolProcess.run(ffmpeg, arguments: FFmpegArguments.banner(url)) {
            return FFmpegArguments.source(banner: output.stderrTail)
        }
        return FFmpegArguments.Source()
    }

    // MARK: The reader and writer

    /// One track's way through: what the reader decodes to, and the writer settings to try in order.
    private struct Lane {
        let track: AVAssetTrack
        let kind: AVMediaType
        let reader: [String: Any]
        let writer: [[String: Any]]
        var transform = CGAffineTransform.identity
    }

    /// Writer file types are a closed list: `AVAssetWriter` raises an Objective-C exception, which Swift
    /// cannot catch, for any other type, and the whole app would go down with it.
    private enum WriterType {
        case mp4, mov, m4v, m4a, wav, aiff

        init?(container: String) {
            switch container {
            case "mp4": self = .mp4
            case "mov": self = .mov
            case "m4v": self = .m4v
            default: return nil
            }
        }

        var fileType: AVFileType {
            switch self {
            case .mp4: .mp4
            case .mov: .mov
            case .m4v: .m4v
            case .m4a: .m4a
            case .wav: .wav
            case .aiff: .aiff
            }
        }
    }

    private static let rec709: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                 AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                 AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]

    /// Decoded to float PCM at the rate and channel count the encoder gets: AAC takes 8 to 48 kHz and at
    /// most stereo; lossless targets keep the source's channels (up to 8) and its bit depth (16 or 24).
    private static func soundLane(_ track: AVAssetTrack, _ native: NativeSource, _ sound: Sound) -> Lane {
        let lossless = sound == .alac || sound == .wav || sound == .aiff
        let channels = min(max(native.channels, 1), lossless ? 8 : 2)
        let depth = native.bits > 16 ? 24 : 16
        let source = native.sampleRate > 0 ? native.sampleRate : 44_100
        var rate = source
        if case .aac = sound { rate = aacRate(source) } else if case .ringtone = sound { rate = aacRate(source) }
        var layout = AudioChannelLayout()
        // Apple Lossless takes only the layouts its format defines for 3 to 8 channels; PCM takes any.
        let alacLayouts: [Int: AudioChannelLayoutTag] = [3: kAudioChannelLayoutTag_MPEG_3_0_B, 4: kAudioChannelLayoutTag_MPEG_4_0_B,
                                                         5: kAudioChannelLayoutTag_MPEG_5_0_D, 6: kAudioChannelLayoutTag_MPEG_5_1_D,
                                                         7: kAudioChannelLayoutTag_AAC_6_1, 8: kAudioChannelLayoutTag_MPEG_7_1_B]
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2 ? kAudioChannelLayoutTag_Stereo
            : sound == .alac ? alacLayouts[channels] ?? kAudioChannelLayoutTag_Stereo
            : kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
        let common: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                     AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)]
        let reader = common.merging([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                     AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]) { $1 }
        let writer: [[String: Any]]
        switch sound {
        case .aac(let kbps), .ringtone(let kbps):
            writer = [common.merging([AVFormatIDKey: kAudioFormatMPEG4AAC,
                                      AVEncoderBitRateKey: aacBitrate(kbps * 1000, rate: rate, channels: channels)]) { $1 }]
        case .alac:
            writer = [common.merging([AVFormatIDKey: kAudioFormatAppleLossless, AVEncoderBitDepthHintKey: depth]) { $1 }]
        default:
            writer = [common.merging([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: depth, AVLinearPCMIsFloatKey: false,
                                      AVLinearPCMIsBigEndianKey: sound == .aiff, AVLinearPCMIsNonInterleaved: false]) { $1 }]
        }
        return Lane(track: track, kind: .audio, reader: reader, writer: writer)
    }

    /// The writer accepts any AAC bitrate and then fails on the first buffer (mono at 22 kHz tops out near
    /// 64 kbit/s), so the encoder is asked what it takes: the nearest bitrate at or below the wish.
    private static func aacBitrate(_ wanted: Int, rate: Double, channels: Int) -> Int {
        var input = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                                 mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                                 mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return wanted }
        defer { AudioConverterDispose(converter) }
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr, size > 0 else { return wanted }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr else { return wanted }
        let rates = ranges.map { Int($0.mMaximum) }.filter { $0 > 0 }.sorted()
        return rates.last { $0 <= wanted } ?? rates.first ?? wanted
    }

    private static func aacRate(_ rate: Double) -> Double {
        [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000].contains(rate) ? rate : rate > 48_000 ? 48_000 : 44_100
    }

    /// Reader to writer with the async API of this SDK. Progress follows the first lane. Whatever stops it
    /// (a cancel, a failed lane) cancels both ends at once, so no lane waits for one that has stopped, and
    /// the partial file is removed.
    private static func pump(_ asset: AVAsset, into url: URL, type: WriterType, lanes: [Lane], range: CMTimeRange?, duration: Double,
                             context: ConversionContext, span: ClosedRange<Double> = 0...1) async throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw unreadable }
        if let range { reader.timeRange = range }
        let writer = try AVAssetWriter(outputURL: url, fileType: type.fileType)
        // The second pass that moves the index forward leaves a ".sb-" file behind for a moment; worth it
        // for a video that may be streamed, not for a song.
        writer.shouldOptimizeForNetworkUse = type == .mp4 || type == .mov || type == .m4v
        var pipes: [Pipe] = []
        for lane in lanes {
            guard let settings = lane.writer.first(where: { writer.canApply(outputSettings: $0, forMediaType: lane.kind) }) else {
                throw ConversionFailure("Dönüştürülemedi: %@", detail: lane.kind == .video ? "video settings" : "audio settings")
            }
            let output = AVAssetReaderTrackOutput(track: lane.track, outputSettings: lane.reader)
            let input = AVAssetWriterInput(mediaType: lane.kind, outputSettings: settings)
            input.transform = lane.transform
            pipes.append(Pipe(provider: reader.outputProvider(for: output), receiver: writer.inputReceiver(for: input), clock: pipes.isEmpty))
        }
        let session = Session(reader: reader, writer: writer)
        let meter = Meter(context, duration: duration, span: span)
        let start = range?.start ?? .zero
        do {
            do { try reader.start() } catch { throw unreadable }
            try writer.start()
            writer.startSession(atSourceTime: start)
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for pipe in pipes {
                        group.addTask {
                            do {
                                while let buffer = try await pipe.provider.next() {
                                    try checkCancelled(context)
                                    if pipe.clock { meter.report((buffer.presentationTimeStamp - start).seconds) }
                                    try await pipe.receiver.append(buffer)
                                }
                                pipe.receiver.finish()
                            } catch {
                                session.stop()
                                throw error
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            } onCancel: {
                session.stop()
            }
            // A provider may end early instead of throwing when its task is cancelled.
            try checkCancelled(context)
            if reader.status == .failed { throw unreadable }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw ConversionFailure("Dönüştürülemedi: %@", detail: writer.error?.localizedDescription ?? "AVAssetWriter")
            }
        } catch {
            session.stop()
            try? FileManager.default.removeItem(at: url)
            throw Task.isCancelled || context.isCancelled() ? CancellationError() : error
        }
    }

    /// A reader output and a writer input, handed to the lane's own task.
    private struct Pipe: @unchecked Sendable {
        let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        let receiver: AVAssetWriterInput.SampleBufferReceiver
        let clock: Bool
    }

    /// Both ends of one transcode, stopped once from whichever side notices first.
    private final class Session: @unchecked Sendable {
        private let reader: AVAssetReader, writer: AVAssetWriter
        private let lock = NSLock()
        private var stopped = false

        init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }

        func stop() {
            guard lock.withLock({ () -> Bool in defer { stopped = true }; return !stopped }) else { return }
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    // MARK: Support

    /// What AVFoundation found in a file it opened. Nil from `load` when it should not be read natively:
    /// it does not open, it reports no duration, or it is an Ogg file whose track is neither Vorbis nor
    /// Opus (Ogg FLAC opens and then decodes a fraction of the sound).
    private struct NativeSource: @unchecked Sendable {
        let asset: AVURLAsset
        let duration: Double
        var audio: AVAssetTrack?
        var video: AVAssetTrack?
        var audioDecodable = false, videoDecodable = false
        var size = CGSize.zero
        var transform = CGAffineTransform.identity
        var frameRate: Float = 0, videoRate: Float = 0
        /// `AVVideoColorPropertiesKey` entries, when the format description names them.
        var colour: [String: String] = [:]
        var isHDR = false, isDeep = false
        var sampleRate = 0.0, channels = 0, bits = 0

        static func load(_ url: URL, format: FileFormat) async -> NativeSource? {
            let asset = AVURLAsset(url: url)
            do {
                let (time, tracks) = try await asset.load(.duration, .tracks)
                guard time.seconds.isFinite, time.seconds > 0 else { return nil }
                var source = NativeSource(asset: asset, duration: time.seconds)
                for track in tracks {
                    if track.mediaType == .video, source.video == nil {
                        let (descriptions, decodable, size, transform, rate, dataRate) = try await track.load(
                            .formatDescriptions, .isDecodable, .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
                        source.video = track; source.videoDecodable = decodable; source.size = size; source.transform = transform
                        source.frameRate = rate; source.videoRate = dataRate
                        if let description = descriptions.first { source.describe(description) }
                    } else if track.mediaType == .audio, source.audio == nil {
                        let (descriptions, decodable) = try await track.load(.formatDescriptions, .isDecodable)
                        guard let description = descriptions.first else { continue }
                        let subtype = CMFormatDescriptionGetMediaSubType(description)
                        if format.id == "ogg" || format.id == "opus", subtype != kAudioFormatOpus, subtype != 0x766F_7262 /* 'vorb' */ { return nil }
                        source.audio = track; source.audioDecodable = decodable
                        if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                            source.sampleRate = basic.mSampleRate; source.channels = Int(basic.mChannelsPerFrame)
                            // A lossless compressed track has no bits per channel; its flags say what it was made from.
                            source.bits = basic.mBitsPerChannel > 0 ? Int(basic.mBitsPerChannel)
                                : (basic.mFormatID == kAudioFormatAppleLossless || basic.mFormatID == kAudioFormatFLAC)
                                    ? [1: 16, 2: 20, 3: 24, 4: 32][Int(basic.mFormatFlags)] ?? 0 : 0
                        }
                    }
                }
                return source
            } catch {
                return nil
            }
        }

        private mutating func describe(_ description: CMFormatDescription) {
            func value(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(description, extensionKey: key) as? String }
            let pairs = [(AVVideoColorPrimariesKey, value(kCMFormatDescriptionExtension_ColorPrimaries)),
                         (AVVideoTransferFunctionKey, value(kCMFormatDescriptionExtension_TransferFunction)),
                         (AVVideoYCbCrMatrixKey, value(kCMFormatDescriptionExtension_YCbCrMatrix))]
            for case let (key, name?) in pairs { colour[key] = name }
            let transfer = colour[AVVideoTransferFunctionKey]
            isHDR = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            let depth = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
            isDeep = (depth ?? 8) >= 10 || isHDR
        }

        func canMake(_ product: Product) -> Bool {
            switch product {
            case .audio: audio != nil && audioDecodable
            case .video, .gif: video != nil && videoDecodable
            case .mute: video != nil
            }
        }

        /// The same in ffmpeg's words, for an ffmpeg run without ffprobe.
        var facts: FFmpegArguments.Source {
            let shown = size.applying(transform)
            let names = FFmpegArguments.colourNames(primaries: colour[AVVideoColorPrimariesKey], transfer: colour[AVVideoTransferFunctionKey],
                                                    matrix: colour[AVVideoYCbCrMatrixKey])
            return FFmpegArguments.Source(duration: duration, hasVideo: video != nil, hasAudio: audio != nil,
                                          width: video == nil ? nil : Int(abs(shown.width).rounded()),
                                          height: video == nil ? nil : Int(abs(shown.height).rounded()),
                                          primaries: names.primaries, transfer: names.transfer, matrix: names.matrix)
        }
    }

    /// Progress for one request, sent when it has moved by a percent.
    private final class Meter: @unchecked Sendable {
        private let context: ConversionContext
        private let duration: Double
        private let span: ClosedRange<Double>
        private let lock = NSLock()
        private var last = -1.0

        init(_ context: ConversionContext, duration: Double, span: ClosedRange<Double>) {
            self.context = context; self.duration = duration; self.span = span
        }

        /// `position` in the unit of `duration`: seconds, frames, or a fraction against a duration of 1.
        func report(_ position: Double) {
            guard duration > 0, position.isFinite else { return }
            let fraction = span.lowerBound + (span.upperBound - span.lowerBound) * min(max(position / duration, 0), 1)
            let send = lock.withLock { () -> Bool in
                guard fraction - last >= 0.01 || (fraction == span.upperBound && last < fraction) else { return false }
                last = fraction
                return true
            }
            if send { context.progress(fraction) }
        }
    }

    /// First come, first served, one at a time; a wait ends when its task is cancelled.
    private actor Turnstile {
        private var busy = false
        private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

        func enter() async throws {
            guard busy else { busy = true; return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiting.append((id, continuation)) }
                }
            } onCancel: {
                Task { await self.withdraw(id) }
            }
        }

        func leave() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().continuation.resume() }
        }

        private func withdraw(_ id: UUID) {
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    /// Hands an ImageIO destination to the work queue; only one call uses it at a time.
    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static var unreadable: ConversionFailure { ConversionFailure("Bu ses veya video dosyası okunamadı.") }
    private static var silent: ConversionFailure { ConversionFailure("Bu videoda ses yok.") }

    /// The engine's flag, or the awaiting task: whichever says stop first.
    private static func checkCancelled(_ context: ConversionContext) throws {
        try Task.checkCancellation()
        try context.checkCancelled()
    }
}
