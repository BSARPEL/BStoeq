import AVFoundation
import CoreMedia
import ImageIO
import VideoToolbox
import XCTest
@testable import ConvertCore

/// MediaConverter against files the tests make: a WAV written sample by sample, clips written with
/// AVAssetWriter (noise, so that bitrates matter; one in HLG), and for the ffmpeg runs fixtures made by
/// the installed ffmpeg. Those runs are skipped when ffmpeg is missing.
final class MediaConverterTests: XCTestCase {
    private let converter = MediaConverter()
    private var fixture: ConversionFixture!

    private let unreadable = "Bu ses veya video dosyası okunamadı."
    private let silent = "Bu videoda ses yok."
    private let ringtoneNote = "Zil sesi ilk 30 saniyeden oluşturuldu."
    private let budgetNote = "Dosya boyutunu sınırlamak için GIF kısaltıldı."
    private let hdrNote = "HDR görüntüyü korumak için video HEVC olarak kodlandı."

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "media") }
    override func tearDownWithError() throws { fixture.remove() }

    // MARK: Availability

    func testNativeTargetsAreAvailableWithoutFFmpegAndTheRestNeedIt() throws {
        let none = ConversionEnvironment()
        for id in ["m4a", "alac", "wav", "aiff", "flac", "m4r"] {
            XCTAssertEqual(try availability(id, "mp3", none), .available, id)
        }
        XCTAssertEqual(try availability("m4a", "ogg", none), .available)
        for id in ["mp3", "mp3.128k", "ogg", "opus"] { XCTAssertEqual(try availability(id, "wav", none), .needs("ffmpeg"), id) }
        for id in ["mp4", "mp4.720p", "mp4.hevc", "gif", "m4a", "wav", "mute", "compress"] {
            XCTAssertEqual(try availability(id, "mov", none), .available, id)
        }
        for id in ["webm", "mkv", "mp3"] { XCTAssertEqual(try availability(id, "mov", none), .needs("ffmpeg"), id) }
        for id in ["mp4", "gif", "m4a", "mute"] { XCTAssertEqual(try availability(id, "mkv", none), .needs("ffmpeg"), id) }
        XCTAssertEqual(try availability("mp4.720p", "mp4", none), .available, "a variant of the own format is offered")
    }

    func testAnInstalledFFmpegWithoutTheEncoderIsUnsupported() throws {
        let bare = ConversionEnvironment(ffmpeg: URL(fileURLWithPath: "/opt/ffmpeg"), encoders: [])
        XCTAssertEqual(try availability("mp3", "wav", bare), .unsupported)
        XCTAssertEqual(try availability("webm", "mov", bare), .unsupported)
        XCTAssertEqual(try availability("mute", "mkv", bare), .available, "a stream copy needs no encoder")
        let homebrew = ConversionEnvironment(ffmpeg: URL(fileURLWithPath: "/opt/ffmpeg"),
                                             encoders: ["libmp3lame", "libopus", "vorbis", "libx264", "aac", "libvpx-vp9", "gif"])
        XCTAssertEqual(try availability("mp3", "wav", homebrew), .available)
        XCTAssertEqual(try availability("opus", "wav", homebrew), .available)
        XCTAssertEqual(try availability("ogg", "wav", homebrew), .unsupported, "ogg is written with libvorbis only")
        XCTAssertEqual(try availability("webm", "mov", homebrew), .available)
        XCTAssertEqual(try availability("mp4", "mkv", homebrew), .available)
        XCTAssertEqual(try availability("mp4.hevc", "mkv", homebrew), .unsupported, "no libx265")
        XCTAssertEqual(try availability("mp4.hevc", "mov", homebrew), .available, "AVFoundation writes HEVC itself")
        XCTAssertEqual(try availability("compress", "avi", homebrew), .unsupported, "no encoder is chosen for AVI")
    }

    func testSameFormatsForeignFamiliesAndOtherTargetsAreUnsupported() throws {
        let none = ConversionEnvironment()
        XCTAssertEqual(try availability("wav", "wav", none), .unsupported)
        XCTAssertEqual(try availability("mp4", "mp4", none), .unsupported)
        XCTAssertEqual(try availability("m4r", "m4r", none), .unsupported)
        for id in ["mp4", "gif", "mute", "compress", "webm"] { XCTAssertEqual(try availability(id, "wav", none), .unsupported, id) }
        for id in ["png", "pdf", "half", "ocr", "txt"] { XCTAssertEqual(try availability(id, "mov", none), .unsupported, id) }
        XCTAssertEqual(try availability("mp4", "png", none), .unsupported)
        XCTAssertEqual(try availability("m4a", "zip", none), .unsupported)
    }

    // MARK: Pure rules

    func testPictureSizeCapsTheShorterSideNeverEnlargesAndStaysEven() {
        XCTAssertTrue(MediaConverter.pictureSize(width: 1920, height: 1080, maxShortSide: 720) == (1280, 720))
        XCTAssertTrue(MediaConverter.pictureSize(width: 1080, height: 1920, maxShortSide: 720) == (720, 1280))
        XCTAssertTrue(MediaConverter.pictureSize(width: 960, height: 540, maxShortSide: 480) == (854, 480))
        XCTAssertTrue(MediaConverter.pictureSize(width: 640, height: 360, maxShortSide: 720) == (640, 360))
        XCTAssertTrue(MediaConverter.pictureSize(width: 641, height: 361, maxShortSide: 0) == (642, 362))
    }

    func testVideoBitratesFallWithTheQualityLevelAndTheSourceCaps() {
        func rate(_ quality: ConversionQuality, _ codec: ConversionVideoCodec = .h264, source: Double = 0) -> Int {
            MediaConverter.videoBitrate(width: 1920, height: 1080, frameRate: 30, codec: codec, quality: quality, sourceRate: source)
        }
        XCTAssertGreaterThan(rate(.high), rate(.balanced))
        XCTAssertGreaterThan(rate(.balanced), rate(.small))
        XCTAssertLessThan(rate(.balanced, .hevc), rate(.balanced))
        XCTAssertEqual(rate(.high, source: 2_000_000), 2_000_000, "never more than the source spends")
        XCTAssertEqual(rate(.small, source: 1_000_000), 450_000)
        XCTAssertEqual(MediaConverter.videoBitrate(width: 16, height: 16, frameRate: 1, codec: .h264, quality: .small, sourceRate: 0), 100_000)
    }

    func testGIFPlanLowersTheFrameRateFirstThenTheDuration() {
        let short = MediaConverter.gifPlan(duration: 3, width: 1920, height: 1080, longSide: 480)
        XCTAssertEqual(short, MediaConverter.GIFPlan(fps: 10, frames: 30, width: 480, height: 270, trimmedForBudget: false))
        let landscape = MediaConverter.gifPlan(duration: 120, width: 1920, height: 1080, longSide: 480)
        XCTAssertEqual(landscape.fps, 5)
        XCTAssertEqual(landscape.frames, 300, "60 s at 5 fps fits")
        XCTAssertFalse(landscape.trimmedForBudget)
        let portrait = MediaConverter.gifPlan(duration: 60, width: 1080, height: 1920, longSide: 640)
        XCTAssertEqual(portrait.width, 360); XCTAssertEqual(portrait.height, 640)
        XCTAssertEqual(portrait.fps, 5)
        XCTAssertTrue(portrait.trimmedForBudget)
        XCTAssertLessThanOrEqual(portrait.frames * portrait.width * portrait.height, 40_000_000)
        XCTAssertGreaterThan((portrait.frames + 1) * portrait.width * portrait.height, 40_000_000, "as long as the budget allows")
        let small = MediaConverter.gifPlan(duration: 30, width: 200, height: 100, longSide: 640)
        XCTAssertEqual(small, MediaConverter.GIFPlan(fps: 10, frames: 300, width: 200, height: 100, trimmedForBudget: false), "never enlarged")
    }

    func testTargetsMapToProducts() throws {
        let options = ConversionOptions(audioBitrate: 256)
        XCTAssertEqual(MediaConverter.product(try fixture.target("m4r"), output: "m4r", options: options), .audio(.ringtone(kbps: 256)))
        XCTAssertEqual(MediaConverter.product(try fixture.target("alac"), output: "m4a", options: options), .audio(.alac))
        XCTAssertEqual(MediaConverter.product(try fixture.target("ogg"), output: "ogg", options: options), .audio(.vorbis(kbps: 256)))
        var hevc = options.applying(try fixture.target("mp4.hevc").overrides); hevc.normalize()
        XCTAssertEqual(MediaConverter.product(try fixture.target("mp4.hevc"), output: "mp4", options: hevc),
                       .video(container: "mp4", codec: .hevc, quality: .balanced, maxHeight: 0, removeAudio: false))
        XCTAssertEqual(MediaConverter.product(try fixture.target("mute"), output: "mkv", options: options), .mute(container: "mkv"))
        XCTAssertNil(MediaConverter.product(try fixture.target("png"), output: "png", options: options))
    }

    // MARK: ffmpeg arguments

    private let head = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-progress", "pipe:1", "-stats_period", "0.25", "-n"]
    private let sdr = FFmpegArguments.Source(duration: 10, hasVideo: true, hasAudio: true, width: 1920, height: 1080, pixelFormat: "yuv420p")
    private let hlg = FFmpegArguments.Source(duration: 10, hasVideo: true, hasAudio: true, width: 1920, height: 1080, pixelFormat: "yuv420p10le",
                                             primaries: "bt2020", transfer: "arib-std-b67", matrix: "bt2020nc")
    private let all: Set<String> = ["libx264", "libx265", "aac", "libvpx-vp9", "libopus", "libmp3lame", "gif"]

    private func command(_ product: MediaConverter.Product, _ input: String, _ output: String, source: FFmpegArguments.Source? = nil,
                         encoders: Set<String>? = nil) -> FFmpegArguments.Command? {
        FFmpegArguments.command(product, input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output), source: source ?? sdr,
                                encoders: encoders ?? all)
    }

    func testAudioArgumentsAreBuiltLiterally() {
        XCTAssertEqual(command(.audio(.mp3(kbps: 192)), "/in/a b.wav", "/w/a b.mp3")?.arguments,
                       head + ["-i", "file:/in/a b.wav", "-map", "0:a:0", "-c:a", "libmp3lame", "-b:a", "192k", "-f", "mp3", "file:/w/a b.mp3"])
        let ringtone = command(.audio(.ringtone(kbps: 192)), "/in/-x.mkv", "/w/-x.m4r")
        XCTAssertEqual(ringtone?.arguments, head + ["-i", "file:/in/-x.mkv", "-map", "0:a:0", "-c:a", "aac", "-b:a", "192k", "-t", "30",
                                                    "-movflags", "+faststart", "-f", "ipod", "file:/w/-x.m4r"])
        XCTAssertEqual(ringtone?.limit, 30)
        XCTAssertEqual(command(.audio(.vorbis(kbps: 160)), "/in/a.wma", "/w/a.ogg")?.arguments,
                       head + ["-i", "file:/in/a.wma", "-map", "0:a:0", "-c:a", "libvorbis", "-b:a", "160k", "-f", "ogg", "file:/w/a.ogg"])
        XCTAssertEqual(command(.audio(.flac), "/in/a.webm", "/w/a.flac")?.arguments,
                       head + ["-i", "file:/in/a.webm", "-map", "0:a:0", "-c:a", "flac", "-f", "flac", "file:/w/a.flac"])
        XCTAssertEqual(command(.audio(.aiff), "/in/a.mkv", "/w/a.aiff")?.arguments,
                       head + ["-i", "file:/in/a.mkv", "-map", "0:a:0", "-c:a", "pcm_s16be", "-f", "aiff", "file:/w/a.aiff"])
    }

    func testVideoArgumentsAreBuiltLiterally() {
        XCTAssertEqual(command(.video(container: "mkv", codec: .h264, quality: .balanced, maxHeight: 0, removeAudio: false), "/in/a.mov", "/w/a.mkv")?.arguments,
                       head + ["-i", "file:/in/a.mov", "-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale='2*trunc(iw/2)':'2*trunc(ih/2)'",
                               "-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
                               "-f", "matroska", "file:/w/a.mkv"])
        XCTAssertEqual(command(.video(container: "mp4", codec: .hevc, quality: .small, maxHeight: 720, removeAudio: false), "/in/a.mkv", "/w/a.mp4")?.arguments,
                       head + ["-i", "file:/in/a.mkv", "-map", "0:v:0", "-map", "0:a:0?",
                               "-vf", "scale='if(gte(iw,ih),-2,min(720,2*trunc(iw/2)))':'if(gte(iw,ih),min(720,2*trunc(ih/2)),-2)'",
                               "-c:v", "libx265", "-preset", "medium", "-crf", "30", "-pix_fmt", "yuv420p", "-x265-params", "log-level=error",
                               "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", "-f", "mp4", "file:/w/a.mp4"])
        XCTAssertEqual(command(.video(container: "mov", codec: .h264, quality: .high, maxHeight: 0, removeAudio: true), "/in/a.avi", "/w/a.mov")?.arguments,
                       head + ["-i", "file:/in/a.avi", "-map", "0:v:0", "-vf", "scale='2*trunc(iw/2)':'2*trunc(ih/2)'",
                               "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-an",
                               "-movflags", "+faststart", "-f", "mov", "file:/w/a.mov"])
        XCTAssertEqual(command(.video(container: "webm", codec: .h264, quality: .small, maxHeight: 480, removeAudio: false), "/in/a.mp4", "/w/a.webm")?.arguments,
                       head + ["-i", "file:/in/a.mp4", "-map", "0:v:0", "-map", "0:a:0?",
                               "-vf", "scale='if(gte(iw,ih),-2,min(480,2*trunc(iw/2)))':'if(gte(iw,ih),min(480,2*trunc(ih/2)),-2)'",
                               "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "40", "-deadline", "good", "-cpu-used", "4", "-row-mt", "1",
                               "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "96k", "-f", "webm", "file:/w/a.webm"])
    }

    func testAnHDRSourceIsEncodedAsTenBitHEVCWithItsTagsNeverAsEightBitH264() {
        let mp4 = command(.video(container: "mp4", codec: .h264, quality: .balanced, maxHeight: 0, removeAudio: false), "/in/a.mkv", "/w/a.mp4", source: hlg)
        XCTAssertEqual(mp4?.arguments,
                       head + ["-i", "file:/in/a.mkv", "-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale='2*trunc(iw/2)':'2*trunc(ih/2)'",
                               "-c:v", "libx265", "-preset", "medium", "-crf", "26", "-pix_fmt", "yuv420p10le", "-x265-params", "log-level=error",
                               "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc",
                               "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-f", "mp4", "file:/w/a.mp4"])
        XCTAssertEqual(mp4?.keptHDRAsHEVC, true)
        XCTAssertEqual(command(.video(container: "mp4", codec: .hevc, quality: .balanced, maxHeight: 0, removeAudio: false), "/in/a.mkv", "/w/a.mp4",
                               source: hlg)?.keptHDRAsHEVC, false, "HEVC was asked for")
        XCTAssertNil(command(.video(container: "mkv", codec: .h264, quality: .balanced, maxHeight: 0, removeAudio: false), "/in/a.mkv", "/w/a.mkv",
                             source: hlg, encoders: ["libx264", "aac"]), "without libx265 an HDR picture is not converted")
        let webm = command(.video(container: "webm", codec: .h264, quality: .high, maxHeight: 0, removeAudio: true), "/in/a.mov", "/w/a.webm", source: hlg)
        XCTAssertEqual(webm?.arguments,
                       head + ["-i", "file:/in/a.mov", "-map", "0:v:0", "-vf", "scale='2*trunc(iw/2)':'2*trunc(ih/2)'",
                               "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "31", "-deadline", "good", "-cpu-used", "4", "-row-mt", "1",
                               "-pix_fmt", "yuv420p10le", "-profile:v", "2", "-color_primaries", "bt2020", "-color_trc", "arib-std-b67",
                               "-colorspace", "bt2020nc", "-an", "-f", "webm", "file:/w/a.webm"])
    }

    func testMuteAndGIFArgumentsAreBuiltLiterally() {
        XCTAssertEqual(command(.mute(container: "mkv"), "/in/a.mkv", "/w/a.mkv")?.arguments,
                       head + ["-i", "file:/in/a.mkv", "-map", "0:v", "-c", "copy", "-f", "matroska", "file:/w/a.mkv"])
        XCTAssertNil(command(.mute(container: "wav"), "/in/a.wav", "/w/a.wav"))
        let gif = command(.gif(.balanced), "/in/a.mkv", "/w/a.gif")
        XCTAssertEqual(gif?.arguments,
                       head + ["-i", "file:/in/a.mkv", "-map", "0:v:0", "-t", "60", "-vf",
                               "fps=12,scale='if(gte(iw,ih),min(480,iw),-1)':'if(gte(iw,ih),-1,min(480,ih))':flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                               "-loop", "0", "-f", "gif", "file:/w/a.gif"])
        XCTAssertEqual(gif?.limit, 60)
        XCTAssertTrue(command(.gif(.high), "/i.mp4", "/o.gif")?.arguments.contains { $0.hasPrefix("fps=15,") && $0.contains("min(640,iw)") } == true)
        XCTAssertTrue(command(.gif(.small), "/i.mp4", "/o.gif")?.arguments.contains { $0.hasPrefix("fps=10,") && $0.contains("min(320,iw)") } == true)
    }

    func testEncoderRequirementsNameEveryCodec() {
        XCTAssertEqual(FFmpegArguments.encoders(for: .audio(.mp3(kbps: 128))), ["libmp3lame"])
        XCTAssertEqual(FFmpegArguments.encoders(for: .audio(.vorbis(kbps: 128))), ["libvorbis"])
        XCTAssertEqual(FFmpegArguments.encoders(for: .audio(.opus(kbps: 128))), ["libopus"])
        XCTAssertEqual(FFmpegArguments.encoders(for: .video(container: "webm", codec: .h264, quality: .balanced, maxHeight: 0, removeAudio: false)),
                       ["libvpx-vp9", "libopus"])
        XCTAssertEqual(FFmpegArguments.encoders(for: .video(container: "mkv", codec: .hevc, quality: .balanced, maxHeight: 0, removeAudio: false)),
                       ["libx264", "aac"])
        XCTAssertEqual(FFmpegArguments.encoders(for: .video(container: "mp4", codec: .hevc, quality: .balanced, maxHeight: 0, removeAudio: true)),
                       ["libx265"])
        XCTAssertNil(FFmpegArguments.encoders(for: .video(container: "flv", codec: .h264, quality: .small, maxHeight: 1080, removeAudio: false)))
        XCTAssertEqual(FFmpegArguments.encoders(for: .mute(container: "avi")), [])
        XCTAssertEqual(FFmpegArguments.encoders(for: .gif(.small)), ["gif"])
    }

    func testProgressProbeAndBannerAreRead() throws {
        XCTAssertEqual(FFmpegArguments.progressSeconds("out_time_us=2500000"), 2.5)
        XCTAssertNil(FFmpegArguments.progressSeconds("out_time_us=N/A"))
        XCTAssertNil(FFmpegArguments.progressSeconds("out_time=00:00:02.500000"))
        XCTAssertEqual(FFmpegArguments.complaint("x\nUnknown encoder 'libfoo'\n\n"), "Unknown encoder 'libfoo'")
        XCTAssertEqual(FFmpegArguments.complaint(""), "ffmpeg")

        let json = """
        {"streams": [{"codec_type": "video", "width": 1280, "height": 720, "pix_fmt": "yuv420p10le", "color_primaries": "bt2020",
                      "color_transfer": "arib-std-b67", "color_space": "bt2020nc", "disposition": {"attached_pic": 0}},
                     {"codec_type": "audio"}],
         "format": {"duration": "12.480000"}}
        """
        XCTAssertEqual(FFmpegArguments.source(probe: Data(json.utf8)),
                       FFmpegArguments.Source(duration: 12.48, hasVideo: true, hasAudio: true, width: 1280, height: 720, pixelFormat: "yuv420p10le",
                                              primaries: "bt2020", transfer: "arib-std-b67", matrix: "bt2020nc"))
        let cover = #"{"streams": [{"codec_type": "audio"}, {"codec_type": "video", "disposition": {"attached_pic": 1}}], "format": {"duration": "3.0"}}"#
        XCTAssertEqual(FFmpegArguments.source(probe: Data(cover.utf8))?.hasVideo, false, "cover art is no picture")
        XCTAssertNil(FFmpegArguments.source(probe: Data("not json".utf8)))

        let banner = """
        Input #0, matroska,webm, from 'file:/x/clip.mkv':
          Duration: 00:01:02.50, start: 0.000000, bitrate: 2915 kb/s
          Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt2020nc/bt2020/arib-std-b67), 640x360 [SAR 1:1 DAR 16:9], 30 fps, 30 tbr
          Stream #0:1(eng): Audio: aac (LC), 44100 Hz, stereo, fltp
        At least one output file must be specified
        """
        let parsed = FFmpegArguments.source(banner: banner)
        XCTAssertEqual(parsed, FFmpegArguments.Source(duration: 62.5, hasVideo: true, hasAudio: true, width: 640, height: 360, pixelFormat: "yuv420p10le",
                                                      primaries: "bt2020", transfer: "arib-std-b67", matrix: "bt2020nc"))
        XCTAssertTrue(parsed.isHDR)
        let sdrBanner = "  Stream #0:0: Video: h264 (High), yuv420p(tv, bt709, progressive), 1920x1080, 25 fps\n"
        XCTAssertEqual(FFmpegArguments.source(banner: sdrBanner).transfer, "bt709")
        XCTAssertEqual(FFmpegArguments.source(banner: sdrBanner).hasAudio, false)
        XCTAssertNil(FFmpegArguments.source(banner: "garbage").hasAudio, "nothing said is nothing known")
        XCTAssertEqual(FFmpegArguments.colourNames(primaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG", matrix: "ITU_R_2020").transfer, "arib-std-b67")
    }

    // MARK: Native audio

    func testAWAVBecomesAACALACAIFFAndWAV() async throws {
        let wav = try writeWAV("tone.wav", seconds: 3)
        for (id, codec) in [("m4a", "aac "), ("alac", "alac"), ("aiff", "lpcm")] {
            let url = try await single(try fixture.request([wav], target: id))
            let back = try await read(url)
            XCTAssertEqual(back.codecs[.audio], codec, id)
            XCTAssertEqual(back.duration, 3, accuracy: 0.2, id)
            XCTAssertNil(back.codecs[.video], id)
        }
        let aiff = try await single(try fixture.request([wav], target: "aiff"))
        XCTAssertEqual(try Data(contentsOf: aiff).prefix(4), Data("FORM".utf8))
        let m4a = try await single(try fixture.request([wav], target: "m4a"))
        let back = try await single(try fixture.request([m4a], target: "wav"))
        XCTAssertEqual(try Data(contentsOf: back).prefix(4), Data("RIFF".utf8))
        let wavBack = try await read(back)
        XCTAssertEqual(wavBack.duration, 3, accuracy: 0.2)
    }

    func testTheAACBitrateFollowsTheSetting() async throws {
        let wav = try writeWAV("tone.wav", seconds: 4)
        let low = try await single(try fixture.request([wav], target: "m4a", options: ConversionOptions(audioBitrate: 64)))
        let high = try await single(try fixture.request([wav], target: "m4a", options: ConversionOptions(audioBitrate: 320)))
        XCTAssertLessThan(try size(low) * 3, try size(high))
        let mono = try writeWAV("mono.wav", seconds: 2, rate: 22_050, channels: 1)
        let url = try await single(try fixture.request([mono], target: "m4a", options: ConversionOptions(audioBitrate: 320)))
        let monoBack = try await read(url)
        XCTAssertEqual(monoBack.codecs[.audio], "aac ", "a bitrate too high for mono falls back")
    }

    func testFLACRoundTripKeepsEverySample() async throws {
        let wav = try writeWAV("tone.wav", seconds: 3)
        let flac = try await single(try fixture.request([wav], target: "flac"))
        XCTAssertEqual(try Data(contentsOf: flac).prefix(4), Data("fLaC".utf8))
        let back = try await single(try fixture.request([flac], target: "wav"))
        let (original, copy) = (try samples(wav), try samples(back))
        XCTAssertEqual(original.count, copy.count)
        XCTAssertEqual(zip(original, copy).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1e-6)
    }

    func testFLACFromAVideoTakesItsSound() async throws {
        let clip = try await writeClip("clip.mov", width: 320, height: 180, seconds: 2)
        let flac = try await single(try fixture.request([clip], target: "flac"))
        XCTAssertEqual(try read(flac.path).length, 88_200, accuracy: 2_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: flac.deletingLastPathComponent().path).count, 1, "the PCM staging file is gone")
    }

    func testARingtoneIsTheFirstThirtySecondsAndReadsBack() async throws {
        let wav = try writeWAV("long.wav", seconds: 40, rate: 22_050, channels: 1)
        let request = try fixture.request([wav], target: "m4r")
        let ringtone = try await single(request)
        XCTAssertEqual(ringtone.lastPathComponent, "long.m4r")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.workFolder.path), ["long.m4r"])
        let back = try await read(ringtone)
        XCTAssertEqual(back.codecs[.audio], "aac ")
        XCTAssertEqual(back.duration, 30, accuracy: 0.2)
        XCTAssertEqual(fixture.notes, [ringtoneNote])
        let wavAgain = try await single(try fixture.request([ringtone], target: "wav"))
        let wavAgainBack = try await read(wavAgain)
        XCTAssertEqual(wavAgainBack.duration, 30, accuracy: 0.2)
        let shortTone = try await single(try fixture.request([try writeWAV("short.wav", seconds: 3)], target: "m4r"))
        let shortBack = try await read(shortTone)
        XCTAssertEqual(shortBack.duration, 3, accuracy: 0.2)
        XCTAssertEqual(fixture.notes, [ringtoneNote], "a short source has no caveat")
    }

    // MARK: Native video

    func testAClipBecomesMP4WithH264AndAAC() async throws {
        let clip = try await writeClip("clip.mov", width: 640, height: 360, seconds: 2)
        let url = try await single(try fixture.request([clip], target: "mp4"))
        XCTAssertEqual(url.pathExtension, "mp4")
        let back = try await read(url)
        XCTAssertEqual(back.codecs[.video], "avc1")
        XCTAssertEqual(back.codecs[.audio], "aac ")
        XCTAssertEqual(back.duration, 2, accuracy: 0.2)
        XCTAssertEqual(back.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(fixture.progress.last ?? 0, 1, accuracy: 0.02)
        XCTAssertEqual(fixture.progress, fixture.progress.sorted(), "progress only grows")
    }

    func testHEVCIsTaggedHVC1AndMOVIsWritten() async throws {
        let clip = try await writeClip("clip.mp4", width: 640, height: 360, seconds: 1)
        let hevc = try await read(try await single(try fixture.request([clip], target: "mp4.hevc")))
        XCTAssertEqual(hevc.codecs[.video], "hvc1")
        let mov = try await single(try fixture.request([clip], target: "mov", options: ConversionOptions(videoCodec: .hevc)))
        XCTAssertEqual(mov.pathExtension, "mov")
        let movBack = try await read(mov)
        XCTAssertEqual(movBack.codecs[.video], "hvc1")
    }

    func testTheHeightCapScalesDownAndNeverEnlarges() async throws {
        let wide = try await writeClip("wide.mov", width: 960, height: 540, seconds: 1, audio: false)
        let capped = try await read(try await single(try fixture.request([wide], target: "mp4", options: ConversionOptions(videoMaxHeight: 480))))
        XCTAssertEqual(capped.size, CGSize(width: 854, height: 480))
        XCTAssertNil(capped.codecs[.audio])
        let small = try await read(try await single(try fixture.request([wide], target: "mp4.720p")))
        XCTAssertEqual(small.size, CGSize(width: 960, height: 540))
    }

    func testMuteRemovesTheSoundAndKeepsThePicture() async throws {
        let clip = try await writeClip("clip.mov", width: 320, height: 180, seconds: 2)
        let url = try await single(try fixture.request([clip], target: "mute"))
        XCTAssertEqual(url.pathExtension, "mov")
        let back = try await read(url)
        XCTAssertNil(back.codecs[.audio])
        XCTAssertEqual(back.codecs[.video], "avc1")
        XCTAssertEqual(back.duration, 2, accuracy: 0.2)
    }

    func testTheSoundOfAVideoBecomesM4AAndWAV() async throws {
        let clip = try await writeClip("clip.m4v", width: 320, height: 180, seconds: 2)
        for (id, codec) in [("m4a", "aac "), ("wav", "lpcm")] {
            let back = try await read(try await single(try fixture.request([clip], target: id)))
            XCTAssertEqual(back.codecs[.audio], codec, id)
            XCTAssertNil(back.codecs[.video], id)
            XCTAssertEqual(back.duration, 2, accuracy: 0.2, id)
        }
        let quiet = try await writeClip("quiet.mov", width: 320, height: 180, seconds: 1, audio: false)
        try await assertFailure(silent) { try await self.single(try self.fixture.request([quiet], target: "m4a")) }
    }

    func testThreeQualityLevelsGiveClearlyDifferentSizes() async throws {
        let clip = try await writeClip("clip.mov", width: 640, height: 360, seconds: 2, audio: false, bitrate: 8_000_000)
        var sizes: [Int] = []
        for quality in [ConversionQuality.high, .balanced, .small] {
            sizes.append(try size(try await single(try fixture.request([clip], target: "mp4", options: ConversionOptions(videoQuality: quality)))))
        }
        XCTAssertGreaterThan(Double(sizes[0]), Double(sizes[1]) * 1.3, "\(sizes)")
        XCTAssertGreaterThan(Double(sizes[1]), Double(sizes[2]) * 1.3, "\(sizes)")
        let compressed = try await single(try fixture.request([clip], target: "compress"))
        XCTAssertEqual(compressed.pathExtension, "mov")
        XCTAssertLessThan(try size(compressed), try size(clip) / 2)
    }

    func testAnHLGClipBecomesRec709ForH264AndStaysHLGForHEVC() async throws {
        let clip = try await writeClip("hlg.mov", width: 640, height: 360, seconds: 1, audio: false, hlg: true)
        let source = try await read(clip)
        XCTAssertEqual(source.transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String, "the fixture is HLG")
        let h264 = try await read(try await single(try fixture.request([clip], target: "mp4")))
        XCTAssertEqual(h264.codecs[.video], "avc1")
        XCTAssertEqual(h264.transfer, kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(h264.primaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        let hevc = try await read(try await single(try fixture.request([clip], target: "mp4.hevc")))
        XCTAssertEqual(hevc.codecs[.video], "hvc1")
        XCTAssertEqual(hevc.transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        XCTAssertEqual(hevc.bits, 10)
    }

    func testAnUnreadableFileFails() async throws {
        let broken = try fixture.write("broken.mp4", Data(repeating: 7, count: 4096))
        try await assertFailure(unreadable) { try await self.single(try self.fixture.request([broken], target: "mov")) }
        let noise = try fixture.write("noise.wav", Data(repeating: 1, count: 4096))
        try await assertFailure(unreadable) { try await self.single(try self.fixture.request([noise], target: "flac")) }
    }

    // MARK: Native GIF

    func testAPortraitMinuteBecomesAGIFWithinThePixelBudgetWithoutFFmpeg() async throws {
        let clip = try await writeClip("portrait.mov", width: 360, height: 640, seconds: 60, fps: 2, audio: false, bitrate: 600_000)
        let request = try fixture.request([clip], target: "gif", options: ConversionOptions(videoQuality: .high))
        XCTAssertNil(request.environment.ffmpeg)
        let url = try await single(request)
        let (frames, width, height) = try gifShape(url)
        XCTAssertEqual(width, 360); XCTAssertEqual(height, 640)
        XCTAssertLessThanOrEqual(frames * width * height, 40_000_000)
        // 173 frames at 5 fps fill the budget; the 2 fps source repeats each picture, which lengthens it instead.
        XCTAssertEqual(try gifSeconds(url), 34.6, accuracy: 0.3)
        XCTAssertEqual(fixture.notes, [budgetNote])
    }

    func testAShortClipBecomesAGIFAtTenFramesASecond() async throws {
        let clip = try await writeClip("clip.mov", width: 640, height: 360, seconds: 2, audio: false)
        let url = try await single(try fixture.request([clip], target: "gif"))
        let (frames, width, height) = try gifShape(url)
        XCTAssertEqual(frames, 20)
        XCTAssertEqual(width, 480); XCTAssertEqual(height, 270)
        XCTAssertEqual(try gifSeconds(url), 2, accuracy: 0.05)
        XCTAssertEqual(fixture.notes, [])
    }

    // MARK: Cancellation

    func testCancellingANativeTranscodeLeavesTheWorkFolderEmpty() async throws {
        let clip = try await writeClip("clip.mov", width: 640, height: 360, seconds: 3)
        for id in ["mp4", "gif", "m4a"] {
            let request = try fixture.request([clip], target: id)
            let result = await cancelledOnFirstProgress(request)
            XCTAssertTrue(isCancellation(result), "\(id): \(result)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.workFolder.path), [], id)
        }
    }

    // MARK: ffmpeg runs

    func testFFmpegWritesMP3WebMAndMKV() async throws {
        let environment = try installedFFmpeg()
        let wav = try writeWAV("tone.wav", seconds: 3)
        let mp3 = try await single(try fixture.request([wav], target: "mp3", environment: environment))
        let back = try await read(mp3)
        XCTAssertEqual(back.codecs[.audio], ".mp3")
        XCTAssertEqual(back.duration, 3, accuracy: 0.2)
        let clip = try await writeClip("clip.mov", width: 320, height: 180, seconds: 1)
        let webm = try await single(try fixture.request([clip], target: "webm", environment: environment))
        let webmStreams = try await streams(webm, environment)
        XCTAssertEqual(webmStreams, ["vp9,video", "opus,audio"])
        let mkv = try await single(try fixture.request([clip], target: "mkv", environment: environment))
        let mkvStreams = try await streams(mkv, environment)
        XCTAssertEqual(mkvStreams, ["h264,video", "aac,audio"])
        let muted = try await single(try fixture.request([mkv], target: "mute", environment: environment))
        XCTAssertEqual(muted.pathExtension, "mkv")
        let mutedStreams = try await streams(muted, environment)
        XCTAssertEqual(mutedStreams, ["h264,video"])
        XCTAssertGreaterThan(fixture.progress.count, 0)
    }

    func testAnOggFLACSourceGoesToFFmpegAndIsNeverTruncated() async throws {
        let environment = try installedFFmpeg()
        let wav = try writeWAV("tone.wav", seconds: 5)
        let oga = fixture.url("tone.oga")
        let made = try await ToolProcess.run(try XCTUnwrap(environment.ffmpeg),
                                             arguments: ["-hide_banner", "-loglevel", "error", "-i", wav.path, "-c:a", "flac", "-f", "ogg", oga.path])
        XCTAssertEqual(made.status, 0, made.stderrTail)
        let m4a = try await single(try fixture.request([oga], target: "m4a", environment: environment))
        let m4aBack = try await read(m4a)
        XCTAssertEqual(m4aBack.duration, 5, accuracy: 0.2)
        try await assertFailure(unreadable) { try await self.single(try self.fixture.request([oga], target: "m4a")) }
        // Ogg Opus, by contrast, AVFoundation reads in full: no ffmpeg needed.
        let opus = fixture.url("tone.ogg")
        let opusMade = try await ToolProcess.run(try XCTUnwrap(environment.ffmpeg),
                                                 arguments: ["-hide_banner", "-loglevel", "error", "-i", wav.path, "-c:a", "libopus", "-f", "ogg", opus.path])
        XCTAssertEqual(opusMade.status, 0, opusMade.stderrTail)
        let native = try await single(try fixture.request([opus], target: "m4a"))
        let nativeBack = try await read(native)
        XCTAssertEqual(nativeBack.duration, 5, accuracy: 0.2)
    }

    func testAnFFmpegOnlyVideoBecomesMP4AndAGIF() async throws {
        let environment = try installedFFmpeg()
        let clip = try await writeClip("clip.mov", width: 640, height: 360, seconds: 2)
        let mkv = try await remux(clip, to: "clip.mkv", environment)
        let mp4 = try await read(try await single(try fixture.request([mkv], target: "mp4", environment: environment)))
        XCTAssertEqual(mp4.codecs[.video], "avc1")
        XCTAssertEqual(mp4.codecs[.audio], "aac ")
        XCTAssertEqual(mp4.duration, 2, accuracy: 0.2)
        XCTAssertEqual(mp4.size, CGSize(width: 640, height: 360))
        let small = try await read(try await single(try fixture.request([mkv], target: "mp4", options: ConversionOptions(videoMaxHeight: 480),
                                                                       environment: environment)))
        XCTAssertEqual(small.size, CGSize(width: 640, height: 360), "never enlarged")
        let gif = try await single(try fixture.request([mkv], target: "gif", environment: environment))
        let (frames, width, height) = try gifShape(gif)
        XCTAssertEqual(width, 480); XCTAssertEqual(height, 270)
        XCTAssertEqual(Double(frames), 24, accuracy: 2, "12 fps for balanced")
        let m4r = try await single(try fixture.request([mkv], target: "m4r", environment: environment))
        let m4rBack = try await read(m4r)
        XCTAssertEqual(m4rBack.codecs[.audio], "aac ")
    }

    func testAnHDRSourceOnlyFFmpegOpensStaysTenBitHEVC() async throws {
        let environment = try installedFFmpeg()
        try XCTSkipUnless(environment.encoders.contains("libx265"), "this ffmpeg has no libx265")
        let clip = try await writeClip("hlg.mov", width: 640, height: 360, seconds: 1, audio: false, hlg: true)
        let mkv = try await remux(clip, to: "hlg.mkv", environment)
        let url = try await single(try fixture.request([mkv], target: "mp4", environment: environment))
        let back = try await read(url)
        XCTAssertEqual(back.codecs[.video], "hvc1")
        XCTAssertEqual(back.transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        XCTAssertEqual(fixture.notes, [hdrNote])
    }

    func testAMissingTrackIsReportedBeforeFFmpegRuns() async throws {
        let environment = try installedFFmpeg()
        let quiet = try await writeClip("quiet.mov", width: 320, height: 180, seconds: 1, audio: false)
        let mkv = try await remux(quiet, to: "quiet.mkv", environment)
        try await assertFailure(silent) { try await self.single(try self.fixture.request([mkv], target: "mp3", environment: environment)) }
        var noProbe = environment
        noProbe.ffprobe = nil
        try await assertFailure(silent) { try await self.single(try self.fixture.request([mkv], target: "m4a", environment: noProbe)) }
    }

    func testCancellingFFmpegStopsItAndLeavesTheWorkFolderEmpty() async throws {
        let environment = try installedFFmpeg()
        let clip = try await writeClip("clip.mov", width: 640, height: 360, seconds: 4)
        let request = try fixture.request([clip], target: "webm", options: ConversionOptions(videoQuality: .high), environment: environment)
        let result = await cancelledOnFirstProgress(request)
        XCTAssertTrue(isCancellation(result), "\(result)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.workFolder.path), [])
        XCTAssertEqual(ToolProcess.liveProcessIdentifiers, [])
    }

    // MARK: Helpers

    private func availability(_ target: String, _ source: String, _ environment: ConversionEnvironment) throws -> TargetAvailability {
        converter.availability(of: try fixture.target(target), for: try XCTUnwrap(FormatRegistry.format(id: source)), in: environment)
    }

    private func single(_ request: ConversionRequest) async throws -> URL {
        let urls = try await converter.convert(request, context: fixture.context())
        XCTAssertEqual(urls.count, 1)
        let url = try XCTUnwrap(urls.first)
        XCTAssertEqual(url.deletingLastPathComponent().path, request.workFolder.path)
        XCTAssertGreaterThan(try size(url), 0)
        return url
    }

    private func assertFailure(_ key: String, file: StaticString = #filePath, line: UInt = #line,
                               _ body: @escaping () async throws -> URL) async throws {
        do {
            _ = try await body()
            XCTFail("expected \(key)", file: file, line: line)
        } catch let failure as ConversionFailure {
            XCTAssertEqual(failure.key, key, file: file, line: line)
        }
    }

    private func size(_ url: URL) throws -> Int { try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) }

    private func installedFFmpeg() throws -> ConversionEnvironment {
        let environment = ConversionEnvironment.detect(in: ["/opt/homebrew/bin", "/usr/local/bin"])
        guard environment.ffmpeg != nil else { throw XCTSkip("ffmpeg is not installed") }
        return environment
    }

    private func remux(_ source: URL, to name: String, _ environment: ConversionEnvironment) async throws -> URL {
        let url = fixture.url(name)
        let made = try await ToolProcess.run(try XCTUnwrap(environment.ffmpeg),
                                             arguments: ["-hide_banner", "-loglevel", "error", "-i", source.path, "-map", "0", "-c", "copy", url.path])
        XCTAssertEqual(made.status, 0, made.stderrTail)
        return url
    }

    /// "codec,kind" per stream, in file order.
    private func streams(_ url: URL, _ environment: ConversionEnvironment) async throws -> [String] {
        guard let ffprobe = environment.ffprobe else { throw XCTSkip("ffprobe is not installed") }
        let output = try await ToolProcess.run(ffprobe, arguments: ["-v", "error", "-show_entries", "stream=codec_name,codec_type", "-of", "csv=p=0", url.path],
                                               capture: .data(limit: 1 << 20))
        return String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Converts with a context that cancels, as the engine does, at the first progress it hears.
    private func cancelledOnFirstProgress(_ request: ConversionRequest) async -> Result<[URL], Error> {
        let canceller = Canceller()
        let context = ConversionContext(isCancelled: { canceller.flag.isSet }, progress: { _ in canceller.fire() })
        let converter = converter
        let task = Task { try await converter.convert(request, context: context) }
        canceller.attach(task)
        return await task.result
    }

    private func isCancellation(_ result: Result<[URL], Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }

    private final class Canceller: @unchecked Sendable {
        let flag = ConversionFixture.Flag()
        private let lock = NSLock()
        private var task: Task<[URL], Error>?
        private var fired = false

        func attach(_ task: Task<[URL], Error>) { lock.withLock { self.task = task; if fired { task.cancel() } } }
        func fire() {
            flag.set()
            lock.withLock { fired = true; task?.cancel() }
        }
    }

    private struct Readback {
        var duration = 0.0
        var codecs: [AVMediaType: String] = [:]
        var size: CGSize?
        var transfer: String?, primaries: String?
        var bits: Int?
    }

    private func read(_ url: URL) async throws -> Readback {
        let asset = AVURLAsset(url: url)
        let (time, tracks) = try await asset.load(.duration, .tracks)
        var result = Readback(duration: time.seconds)
        for track in tracks {
            let (descriptions, size) = try await track.load(.formatDescriptions, .naturalSize)
            guard let description = descriptions.first else { continue }
            let code = CMFormatDescriptionGetMediaSubType(description)
            result.codecs[track.mediaType] = String(bytes: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xFF) }, encoding: .macOSRoman)
            if track.mediaType == .video {
                result.size = size
                result.transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                result.primaries = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
                result.bits = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
            }
        }
        return result
    }

    private func read(_ path: String) throws -> (length: Double, rate: Double) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        return (Double(file.length), file.fileFormat.sampleRate)
    }

    /// Every sample of every channel, as floats.
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        let data = try XCTUnwrap(buffer.floatChannelData)
        return (0..<channels).flatMap { channel in (0..<frames).map { data[channel][$0] } }
    }

    private func gifShape(_ url: URL) throws -> (frames: Int, width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (CGImageSourceGetCount(source), try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
                try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    private func gifSeconds(_ url: URL) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return (0..<CGImageSourceGetCount(source)).reduce(0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return total + (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0)
        }
    }

    // MARK: Fixtures

    /// 16-bit PCM written by hand: a chord, so every codec has something to encode.
    @discardableResult
    private func writeWAV(_ name: String, seconds: Double, rate: Int = 44_100, channels: Int = 2) throws -> URL {
        let frames = Int(seconds * Double(rate))
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = frames * channels * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(channels)); put(UInt32(rate)); put(UInt32(rate * channels * 2))
        put(UInt16(channels * 2)); put(UInt16(16)); data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        for frame in 0..<frames {
            let time = Double(frame) / Double(rate)
            for channel in 0..<channels {
                let value = 0.3 * sin(2 * .pi * 440 * time) + 0.2 * sin(2 * .pi * (660 + 110 * Double(channel)) * time)
                put(Int16(value * 32_000))
            }
        }
        return try fixture.write(name, data)
    }

    /// A clip of moving noise blocks (so bitrates matter), with a tone when `audio` is set. `hlg` writes
    /// 10-bit HEVC tagged BT.2020 / HLG.
    private func writeClip(_ name: String, width: Int, height: Int, seconds: Double, fps: Int = 30, audio: Bool = true,
                           hlg: Bool = false, bitrate: Int = 6_000_000) async throws -> URL {
        let url = fixture.url(name)
        let type: AVFileType = ["mp4": .mp4, "m4v": .m4v][url.pathExtension] ?? .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
        var settings: [String: Any] = [AVVideoCodecKey: hlg ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if hlg {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                                   AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        settings[AVVideoCompressionPropertiesKey] = compression
        let pictures = writer.inputPixelBufferReceiver(for: AVAssetWriterInput(mediaType: .video, outputSettings: settings), pixelBufferAttributes: nil)
        let sound = audio ? writer.inputReceiver(for: AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])) : nil
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let lanes = ClipLanes(pictures: pictures, sound: sound)
        let frames = Int(seconds * Double(fps)), samples = Int(seconds * 44_100)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<frames {
                    let frame = try Self.frame(index, width: width, height: height, hlg: hlg)
                    try await lanes.pictures.append(CVReadOnlyPixelBuffer(unsafeBuffer: frame), with: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
                }
                lanes.pictures.finish()
            }
            if let sound = lanes.sound {
                group.addTask {
                    var start = 0
                    while start < samples {
                        let count = min(4_410, samples - start)
                        try await sound.append(try Self.tone(start: start, count: count))
                        start += count
                    }
                    sound.finish()
                }
            }
            try await group.waitForAll()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionFixture.Missing(description: "the clip \(name)") }
        return url
    }

    private struct ClipLanes: @unchecked Sendable {
        let pictures: AVAssetWriterInput.PixelBufferReceiver
        let sound: AVAssetWriterInput.SampleBufferReceiver?
    }

    /// A gradient that moves, under fine grain that changes every frame: an encoder can spend few or many
    /// bits on it, so bitrates show. The same for every run.
    private static func frame(_ index: Int, width: Int, height: Int, hlg: Bool) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let format = hlg ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let buffer = made else { throw ConversionFixture.Missing(description: "a pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        func grey(_ x: Int, _ y: Int) -> UInt32 {
            var value = UInt32(truncatingIfNeeded: (x / 2) &* 73_856_093 ^ (y / 2) &* 19_349_663 ^ index &* 83_492_791)
            value ^= value >> 13; value = value &* 0x5BD1_E995; value ^= value >> 15
            return value & 0xFF
        }
        if hlg {
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<height {
                let row = (luma + y * lumaStride).bindMemory(to: UInt16.self, capacity: width)
                for x in 0..<width { row[x] = UInt16(64 + grey(x, y) * 876 / 255) << 6 }
            }
            let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!, chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in 0..<(height / 2) {
                let row = (chroma + y * chromaStride).bindMemory(to: UInt16.self, capacity: width)
                for x in 0..<width { row[x] = UInt16(512) << 6 }
            }
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        } else {
            let base = CVPixelBufferGetBaseAddress(buffer)!, stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = (base + y * stride).bindMemory(to: UInt32.self, capacity: width)
                for x in 0..<width {
                    let g = UInt32((x + index * 6) % width * 200 / width + 20) + grey(x, y) % 32
                    row[x] = 0xFF00_0000 | g << 16 | g << 8 | g
                }
            }
        }
        return buffer
    }

    /// Interleaved 16-bit stereo at 44.1 kHz, as a ready sample buffer.
    private static func tone(start: Int, count: Int) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        var basic = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                                mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &basic, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &description)
        let values = (0..<count).flatMap { offset -> [Int16] in
            let value = Int16(10_000 * sin(2 * .pi * 440 * Double(start + offset) / 44_100))
            return [value, value]
        }
        let length = values.count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block, let description else { throw ConversionFixture.Missing(description: "an audio buffer") }
        values.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        let buffer = try CMSampleBuffer(dataBuffer: block, formatDescription: description, numSamples: count,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 44_100), packetDescriptions: [])
        return CMReadySampleBuffer(unsafeBuffer: buffer)
    }
}
