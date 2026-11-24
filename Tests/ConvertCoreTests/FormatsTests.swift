import AppKit
import XCTest
@testable import ConvertCore

/// Formats, targets and tool detection. Files exist only in the fixture; the tools are stand-in scripts.
final class FormatsTests: XCTestCase {
    private var fixture: ConversionFixture!

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "formats") }
    override func tearDownWithError() throws { fixture.remove() }

    private func id(_ name: String) -> String? { FormatRegistry.format(of: fixture.url(name))?.id }

    // MARK: Formats

    func testEverySpellingOfTheContractIsRegisteredOnceAndFindsItsFormat() {
        let expected: [(FileFamily, [String: [String]])] = [
            (.image, ["jpg": ["jpeg", "jpe"], "png": [], "heic": ["heif"], "avif": [], "tiff": ["tif"], "gif": [], "bmp": [],
                      "jp2": ["j2k", "jpf"], "ico": [], "icns": [], "tga": [], "exr": [], "psd": [], "webp": [], "jxl": [],
                      "svg": [], "dng": [], "cr2": [], "cr3": [], "nef": [], "arw": [], "raf": [], "orf": [], "rw2": []]),
            (.pdf, ["pdf": []]),
            (.document, ["docx": [], "doc": [], "rtf": [], "rtfd": [], "odt": [], "html": ["htm"], "webarchive": [],
                         "txt": ["text", "log"], "md": ["markdown"]]),
            (.data, ["csv": [], "tsv": ["tab"], "json": [], "xlsx": [], "plist": []]),
            (.audio, ["mp3": [], "m4a": [], "aac": [], "wav": ["wave"], "aiff": ["aif"], "flac": [], "caf": [], "ogg": ["oga"],
                      "opus": [], "m4r": [], "wma": [], "ac3": [], "amr": []]),
            (.video, ["mp4": [], "mov": [], "m4v": [], "mkv": [], "webm": [], "avi": [], "wmv": [], "flv": [],
                      "ts": ["mts", "m2ts"], "mpg": ["mpeg"], "3gp": []]),
            (.archive, ["zip": [], "7z": [], "rar": [], "tar": [], "tar.gz": ["tgz"], "tar.bz2": ["tbz", "tbz2"],
                        "tar.xz": ["txz"], "gz": [], "bz2": [], "xz": [], "iso": [], "cab": [], "dmg": []]),
            (.subtitle, ["srt": [], "vtt": []])
        ]
        var count = 0
        for (family, formats) in expected {
            for (id, others) in formats {
                count += 1
                let format = FormatRegistry.format(id: id)
                XCTAssertEqual(format?.family, family, id)
                XCTAssertEqual(format?.label, id.uppercased(), "A label is the id in capitals")
                XCTAssertEqual(format?.extensions.first, id, "The id is the first spelling")
                XCTAssertEqual(Set(format?.extensions ?? []), Set([id] + others), id)
                for spelling in [id] + others {
                    XCTAssertEqual(self.id("Dosya adı.\(spelling)"), id, spelling)
                    XCTAssertEqual(self.id("BÜYÜK.\(spelling.uppercased())"), id, "Spellings are read in any case")
                }
            }
        }
        XCTAssertEqual(FormatRegistry.all.count, count + 1, "Nothing but the contract's formats and the folder")
        XCTAssertEqual(Set(FormatRegistry.all.map(\.id)).count, FormatRegistry.all.count, "Ids are unique")
        let spellings = FormatRegistry.all.flatMap(\.extensions)
        XCTAssertEqual(Set(spellings).count, spellings.count, "No spelling belongs to two formats")
        XCTAssertTrue(spellings.allSatisfy { $0 == $0.lowercased() })
        XCTAssertNil(FormatRegistry.format(id: "PNG"), "Ids are lowercase")
        XCTAssertNil(FormatRegistry.format(id: "jpeg"), "A spelling is not an id")
    }

    func testCompoundExtensionsWinAndUnknownNamesHaveNoFormat() {
        XCTAssertEqual(id("yedek.tar.gz"), "tar.gz")
        XCTAssertEqual(id("yedek.TAR.BZ2"), "tar.bz2")
        XCTAssertEqual(id("yedek.tar.xz"), "tar.xz")
        XCTAssertEqual(id("yedek.gz"), "gz")
        XCTAssertEqual(id("yedek.tar"), "tar")
        XCTAssertEqual(id("tar.gz"), "gz", "Without a name in front it is a file called tar")
        XCTAssertEqual(id("arşiv.v2.zip"), "zip")
        XCTAssertNil(id("notlar"))
        XCTAssertNil(id("notlar.xyz"))
        XCTAssertNil(id(".png"), "A hidden file without an extension")
        XCTAssertNil(id("nokta."))
        XCTAssertEqual(FormatRegistry.match("Rapor.TAR.GZ")?.spelling, "tar.gz")
        XCTAssertEqual(FormatRegistry.match("foto.JPEG")?.spelling, "jpeg")
    }

    func testAFolderIsAFolderUnlessItIsAPackageAndALinkIsJudgedByItsName() throws {
        let plain = try fixture.folder("Belgeler")
        let dotted = try fixture.folder("tatil.2024.png")
        let package = try fixture.folder("Notlar.rtfd")
        let file = try fixture.write("yazı.rtfd")
        XCTAssertEqual(FormatRegistry.format(of: plain), FormatRegistry.folder)
        XCTAssertEqual(FormatRegistry.format(of: dotted)?.id, "folder", "A folder is not an image because of its name")
        XCTAssertEqual(FormatRegistry.format(of: package)?.id, "rtfd", "A package is judged by its extension")
        XCTAssertEqual(FormatRegistry.format(of: file)?.id, "rtfd")
        XCTAssertEqual(FormatRegistry.folder.family, .folder)
        XCTAssertTrue(FormatRegistry.folder.extensions.isEmpty)
        XCTAssertTrue(FormatRegistry.all.contains(FormatRegistry.folder))
        XCTAssertEqual(FormatRegistry.format(id: "folder"), FormatRegistry.folder)

        let link = fixture.url("kısayol")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plain)
        XCTAssertNil(FormatRegistry.format(of: link), "A link to a folder is not followed")
        let named = fixture.url("kısayol.png")
        try FileManager.default.createSymbolicLink(at: named, withDestinationURL: plain)
        XCTAssertEqual(FormatRegistry.format(of: named)?.id, "png")
        XCTAssertEqual(FormatRegistry.format(of: fixture.url("yok/olmayan.mp4"))?.id, "mp4", "A missing file is judged by its name")
    }

    // MARK: Targets

    func testTheCatalogHoldsTheContractsTargetsInDisplayOrder() {
        XCTAssertEqual(TargetCatalog.all.map(\.id), [
            "jpg", "png", "heic", "avif", "tiff", "gif", "bmp", "jp2", "ico", "icns", "webp", "pdf",
            "txt", "docx", "rtf", "odt", "html", "csv", "tsv", "xlsx", "json", "plist",
            "mp4", "mov", "mkv", "webm", "mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "srt", "vtt",
            "mp4.720p", "mp4.hevc", "mp3.128k", "alac", "m4r",
            "pdf.merge", "pdf.split", "half", "compress", "mute", "nobg", "ocr"])
        XCTAssertEqual(Set(TargetCatalog.all.map(\.id)).count, TargetCatalog.all.count)
        for target in TargetCatalog.all {
            XCTAssertEqual(TargetCatalog.target(id: target.id), target)
            XCTAssertTrue(target.format == "*" || FormatRegistry.format(id: target.format) != nil, "\(target.id) writes a registered format")
            XCTAssertEqual(target.titleIsKey, target.kind == .tool, target.id)
            XCTAssertEqual(target.minimumInputs, target.combines ? 2 : 1, target.id)
            XCTAssertFalse(target.title.isEmpty || target.shortTitle.isEmpty || target.symbol.isEmpty, target.id)
            XCTAssertFalse(target.suffixKey != nil && target.fixedSuffix != nil, "\(target.id) has one kind of suffix")
        }
        XCTAssertNil(TargetCatalog.target(id: "usdz"))
        XCTAssertNil(TargetCatalog.target(id: "PNG"))
    }

    func testFormatTargetsCarryTheirLabelAndVariantsTheirOverridesAndSuffix() throws {
        for id in ["jpg", "png", "webp", "pdf", "docx", "xlsx", "mp4", "opus", "vtt"] {
            let target = try XCTUnwrap(TargetCatalog.target(id: id))
            XCTAssertEqual(target.kind, .convert)
            XCTAssertEqual(target.title, id.uppercased())
            XCTAssertEqual(target.shortTitle, target.title)
            XCTAssertEqual(target.format, id)
            XCTAssertNil(target.suffixKey); XCTAssertNil(target.fixedSuffix)
            XCTAssertEqual(target.overrides, OptionOverrides())
            XCTAssertFalse(target.combines)
        }
        func variant(_ id: String) throws -> ConversionTarget {
            let target = try XCTUnwrap(TargetCatalog.target(id: id))
            XCTAssertEqual(target.kind, .convert, "A variant is a format target")
            XCTAssertFalse(target.titleIsKey)
            return target
        }
        let small = try variant("mp4.720p")
        XCTAssertEqual([small.title, small.format, small.fixedSuffix ?? ""], ["MP4 720p", "mp4", "720p"])
        XCTAssertEqual(small.overrides, OptionOverrides(videoQuality: .small, videoMaxHeight: 720))
        let hevc = try variant("mp4.hevc")
        XCTAssertEqual([hevc.title, hevc.format, hevc.fixedSuffix ?? ""], ["MP4 HEVC", "mp4", "HEVC"])
        XCTAssertEqual(hevc.overrides, OptionOverrides(videoCodec: .hevc))
        let low = try variant("mp3.128k")
        XCTAssertEqual([low.title, low.format, low.fixedSuffix ?? ""], ["MP3 128k", "mp3", "128k"])
        XCTAssertEqual(low.overrides, OptionOverrides(audioBitrate: 128))
        let lossless = try variant("alac")
        XCTAssertEqual([lossless.title, lossless.format, lossless.fixedSuffix ?? ""], ["ALAC", "m4a", "ALAC"])
        XCTAssertEqual(lossless.overrides, OptionOverrides())
        let ringtone = try variant("m4r")
        XCTAssertEqual([ringtone.title, ringtone.format], ["M4R", "m4r"])
        XCTAssertNil(ringtone.fixedSuffix)
    }

    func testToolsCarryTheirKeysSuffixesAndOverrides() throws {
        func tool(_ id: String, _ title: String, _ short: String, _ format: String, _ suffix: String?) throws -> ConversionTarget {
            let target = try XCTUnwrap(TargetCatalog.target(id: id))
            XCTAssertEqual(target.kind, .tool)
            XCTAssertEqual([target.title, target.shortTitle, target.format], [title, short, format], id)
            XCTAssertEqual(target.suffixKey, suffix, id)
            XCTAssertNil(target.fixedSuffix)
            return target
        }
        let merge = try tool("pdf.merge", "Tek PDF’te birleştir", "Birleştir", "pdf", "birleşik")
        XCTAssertTrue(merge.combines)
        XCTAssertEqual(merge.minimumInputs, 2)
        XCTAssertFalse(try tool("pdf.split", "Sayfalara böl", "Böl", "pdf", "sayfalar").combines)
        XCTAssertEqual(try tool("half", "Yarı boyuta küçült", "Yarı boyut", "*", "küçük").overrides, OptionOverrides(imageResize: .half))
        XCTAssertEqual(try tool("compress", "Sıkıştır", "Sıkıştır", "*", "sıkıştırılmış").overrides,
                       OptionOverrides(imageQuality: 0.7, videoQuality: .small, videoMaxHeight: 1080))
        XCTAssertEqual(try tool("mute", "Sesi kaldır", "Sessiz", "*", "sessiz").overrides, OptionOverrides(removeAudio: true))
        XCTAssertEqual(try tool("nobg", "Arka planı sil", "Arka plan", "png", "arka plansız").overrides, OptionOverrides())
        XCTAssertEqual(try tool("ocr", "Metni tanı (OCR)", "OCR", "txt", nil).overrides, OptionOverrides())
        XCTAssertEqual(TargetCatalog.all.filter { $0.combines }.map(\.id), ["pdf.merge"])
    }

    func testEverySymbolOfATargetOrAnActionExistsOnThisSystem() {
        let symbols = Set(TargetCatalog.all.map(\.symbol) + DonutAction.allCases.map(\.symbol) + [DonutSlice.flip.symbol])
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testACustomTargetGetsSensibleDefaults() {
        let target = ConversionTarget(id: "x", title: "X", format: "png")
        XCTAssertEqual(target.kind, .convert)
        XCTAssertEqual(target.shortTitle, "X")
        XCTAssertFalse(target.titleIsKey || target.combines)
        XCTAssertEqual(target.minimumInputs, 1)
        XCTAssertNil(target.suffixKey); XCTAssertNil(target.fixedSuffix)
    }

    // MARK: Tools

    func testDetectionTakesTheFirstRegularExecutableAndAsksItForItsEncoders() throws {
        let listing = """
        Encoders:
         V..... = Video
         A..... = Audio
         S..... = Subtitle
         .F.... = Frame-level multithreading
         ..S... = Slice-level multithreading
         ...X.. = Codec is experimental
         ....B. = Supports draw_horiz_band
         .....D = Supports direct rendering method 1
         ------
         V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
         V....D libx265              libx265 H.265 / HEVC (codec hevc)
         A....D aac                  AAC (Advanced Audio Coding)
         A....D libmp3lame           libmp3lame MP3 (MPEG audio layer 3) (codec mp3)
         A..X.D vorbis               Vorbis
         S..... srt                  SubRip subtitle (codec subrip)
        """
        XCTAssertEqual(ConversionEnvironment.encoders(in: listing), ["libx264", "libx265", "aac", "libmp3lame", "vorbis", "srt"])
        XCTAssertTrue(ConversionEnvironment.encoders(in: "").isEmpty)
        XCTAssertTrue(ConversionEnvironment.encoders(in: "ffmpeg: command not found").isEmpty)

        // First folder: a folder called ffmpeg and a file that may not be run. Neither is a tool.
        try fixture.folder("one/ffmpeg")
        try fixture.tool("one/cwebp", "exit 0", mode: 0o644)
        // Second folder: a link to the real thing, as Homebrew installs it.
        let real = try fixture.tool("cellar/ffmpeg-real", "[ \"$1\" = -hide_banner ] && [ \"$2\" = -encoders ] || exit 9\ncat <<'EOF'\n\(listing)\nEOF")
        try fixture.folder("two")
        try FileManager.default.createSymbolicLink(at: fixture.url("two/ffmpeg"), withDestinationURL: real)
        let probe = try fixture.tool("two/ffprobe", "exit 0")
        // Third folder: found only for what the earlier folders lack.
        try fixture.tool("three/ffmpeg", "echo ' V....D wrong  Wrong'")
        let webp = try fixture.tool("three/cwebp", "exit 0")

        let found = ConversionEnvironment.detect(in: ["one", "missing", "two", "three"].map { fixture.url($0).path })
        XCTAssertEqual(found.ffmpeg, fixture.url("two/ffmpeg"), "First hit wins, links are followed")
        XCTAssertEqual(found.ffprobe, probe)
        XCTAssertEqual(found.cwebp, webp, "A file without the execute bit is passed over")
        XCTAssertEqual(found.encoders, ["libx264", "libx265", "aac", "libmp3lame", "vorbis", "srt"])

        XCTAssertEqual(ConversionEnvironment.detect(in: []), ConversionEnvironment())
        XCTAssertEqual(ConversionEnvironment.detect(in: [fixture.url("one").path]), ConversionEnvironment())
    }

    func testAnFFmpegThatFailsOrSaysNothingLeavesNoEncoders() throws {
        try fixture.tool("bad/ffmpeg", "echo ' V....D libx264  x'\nexit 1")
        let failing = ConversionEnvironment.detect(in: [fixture.url("bad").path])
        XCTAssertNotNil(failing.ffmpeg)
        XCTAssertTrue(failing.encoders.isEmpty, "Output of a failed run is not trusted")
        XCTAssertNil(failing.ffprobe); XCTAssertNil(failing.cwebp)
    }

    func testInstallCommandsNameTheHomebrewFormula() {
        XCTAssertEqual(ConversionEnvironment.installCommand(for: "ffmpeg"), "brew install ffmpeg")
        XCTAssertEqual(ConversionEnvironment.installCommand(for: "cwebp"), "brew install webp")
        XCTAssertNil(ConversionEnvironment.installCommand(for: "ffprobe"))
        XCTAssertNil(ConversionEnvironment.installCommand(for: ""))
    }
}
