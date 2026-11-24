import AppKit
import XCTest
@testable import ConvertCore

/// Options and settings: defaults, repairs and a decoder that cannot be made to fail.
final class OptionsTests: XCTestCase {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    // MARK: Small types

    func testEnumsHaveTitlesAndPaperFollowsTheRegion() {
        XCTAssertEqual(ConversionQuality.allCases.map(\.titleKey), ["Yüksek", "Dengeli", "Küçük dosya"])
        XCTAssertEqual(CompressionLevel.allCases.map(\.titleKey), ["Hafif", "Dengeli", "Güçlü"])
        XCTAssertEqual(PaperSize.allCases.map(\.titleKey), ["A4", "ABD Letter"])
        XCTAssertEqual(ConversionVideoCodec.allCases.map(\.title), ["H.264", "HEVC"])
        XCTAssertEqual(DonutTrigger.allCases.map(\.titleKey), ["Option", "Shift"])
        XCTAssertEqual(DonutTrigger.allCases.map(\.glyph), ["⌥", "⇧"])
        XCTAssertEqual(DonutTrigger.option.modifierMask, NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(DonutTrigger.shift.modifierMask, NSEvent.ModifierFlags.shift.rawValue)

        XCTAssertEqual(PaperSize.a4.size, CGSize(width: 595, height: 842))
        XCTAssertEqual(PaperSize.letter.size, CGSize(width: 612, height: 792))
        for identifier in ["en_US", "en_CA", "fr_CA", "es_MX"] {
            XCTAssertEqual(PaperSize.regional(Locale(identifier: identifier)), .letter, identifier)
        }
        for identifier in ["tr_TR", "de_DE", "en_GB", "ja_JP", "en"] {
            XCTAssertEqual(PaperSize.regional(Locale(identifier: identifier)), .a4, identifier)
        }
    }

    func testResizeNeverEnlargesAndPresetsAreWhatTheyPromise() {
        XCTAssertEqual(ImageResize(), .original)
        XCTAssertEqual(ImageResize.half, ImageResize(mode: .percent, value: 50))
        XCTAssertEqual(ImageResize.quarter, ImageResize(mode: .percent, value: 25))
        XCTAssertEqual(ImageResize.long1920, ImageResize(mode: .longEdge, value: 1920))
        XCTAssertEqual(ImageResize.long1280, ImageResize(mode: .longEdge, value: 1280))
        XCTAssertEqual(ImageResize.presets, [.original, .half, .quarter, .long1920, .long1280])

        func size(_ resize: ImageResize, _ width: Int, _ height: Int) -> [Int] {
            let result = resize.pixelSize(width: width, height: height)
            return [result.width, result.height]
        }
        XCTAssertEqual(size(.original, 4032, 3024), [4032, 3024])
        XCTAssertEqual(size(.half, 4032, 3024), [2016, 1512])
        XCTAssertEqual(size(.quarter, 4032, 3024), [1008, 756])
        XCTAssertEqual(size(.long1920, 4032, 3024), [1920, 1440])
        XCTAssertEqual(size(.long1920, 3024, 4032), [1440, 1920], "The long edge, whichever it is")
        XCTAssertEqual(size(.long1920, 800, 600), [800, 600], "A small image is not enlarged")
        XCTAssertEqual(size(ImageResize(mode: .percent, value: 300), 800, 600), [800, 600])
        XCTAssertEqual(size(ImageResize(mode: .percent, value: 1), 30, 20), [1, 1], "Never below one pixel")
        XCTAssertEqual(size(.half, 3, 1), [2, 1])
        XCTAssertEqual(size(ImageResize(mode: .longEdge, value: 0), 800, 600), [800, 600])
        XCTAssertEqual(size(.half, 0, 0), [0, 0])

        var resize = ImageResize(mode: .percent, value: 250); resize.normalize()
        XCTAssertEqual(resize, ImageResize(mode: .percent, value: 100))
        resize = ImageResize(mode: .percent, value: 0); resize.normalize()
        XCTAssertEqual(resize, .original)
        resize = ImageResize(mode: .longEdge, value: -5); resize.normalize()
        XCTAssertEqual(resize, .original)
        resize = ImageResize(mode: .original, value: 77); resize.normalize()
        XCTAssertEqual(resize, .original, "The original size has one spelling")
    }

    func testResultsFolderNamesAreOnePlainComponent() {
        for name in ["Dönüştürülenler", "Converted", "çıktı 2024", "a.b", String(repeating: "a", count: 100)] {
            XCTAssertTrue(OutputLocation.isSafeName(name), name)
        }
        for name in ["", ".", "..", ".gizli", "a/b", "../x", "../../x", "/tmp", "a\0b", String(repeating: "a", count: 101),
                     String(repeating: "ğ", count: 51)] {
            XCTAssertFalse(OutputLocation.isSafeName(name), name.debugDescription)
        }
    }

    // MARK: Options

    func testDefaultsMatchTheContract() {
        let options = ConversionOptions()
        XCTAssertNil(options.imageQuality)
        XCTAssertTrue(options.keepMetadata)
        XCTAssertEqual(options.pdfDPI, 150)
        XCTAssertEqual(options.pdfCompression, .balanced)
        XCTAssertEqual(options.paper, PaperSize.regional())
        XCTAssertEqual(options.videoQuality, .balanced)
        XCTAssertEqual(options.videoCodec, .h264)
        XCTAssertEqual(options.audioBitrate, 192)
        XCTAssertEqual(options.location, .besideSource)
        XCTAssertFalse(options.trashOriginals)
        XCTAssertEqual(options.imageResize, .original)
        XCTAssertEqual(options.videoMaxHeight, 0)
        XCTAssertFalse(options.removeAudio)
        XCTAssertEqual(ConversionOptions.videoHeights, [0, 2160, 1080, 720, 480])

        let settings = ConverterSettings()
        XCTAssertTrue(settings.donutEnabled)
        XCTAssertEqual(settings.trigger, .option)
        XCTAssertTrue(settings.finderOnly)
        XCTAssertEqual(settings.options, options)
        XCTAssertTrue(settings.watch.isEmpty)
    }

    func testNormalizeClampsNumbersAndKeepsAResultsFolderWhereItBelongs() {
        var options = ConversionOptions(imageQuality: 7, pdfDPI: 5, audioBitrate: 9000, videoMaxHeight: 1440)
        options.normalize()
        XCTAssertEqual(options.imageQuality, 1)
        XCTAssertEqual(options.pdfDPI, 72)
        XCTAssertEqual(options.audioBitrate, 320)
        XCTAssertEqual(options.videoMaxHeight, 0, "Only the offered heights")
        options = ConversionOptions(imageQuality: -1, pdfDPI: 99_999, audioBitrate: 1, videoMaxHeight: 720)
        options.normalize()
        XCTAssertEqual(options.imageQuality, 0.1)
        XCTAssertEqual(options.pdfDPI, 600)
        XCTAssertEqual(options.audioBitrate, 64)
        XCTAssertEqual(options.videoMaxHeight, 720)
        for bad in [Double.nan, .infinity, -.infinity] {
            options.imageQuality = bad; options.normalize()
            XCTAssertNil(options.imageQuality, "A quality that is no number means automatic")
        }
        options.imageQuality = 0.82; options.normalize()
        XCTAssertEqual(options.imageQuality, 0.82)
        options.imageResize = ImageResize(mode: .percent, value: 900); options.normalize()
        XCTAssertEqual(options.imageResize, ImageResize(mode: .percent, value: 100))

        for name in ["../../x", "..", ".", ".gizli", "a/b", "", String(repeating: "x", count: 101)] {
            options.location = .subfolder(name); options.normalize()
            XCTAssertEqual(options.location, .besideSource, name)
        }
        options.location = .subfolder("Dönüştürülenler"); options.normalize()
        XCTAssertEqual(options.location, .subfolder("Dönüştürülenler"))
        for path in ["relative/folder", "", "~/Desktop", "C:\\x"] {
            options.location = .folder(path); options.normalize()
            XCTAssertEqual(options.location, .besideSource, path)
        }
        options.location = .folder("/Users/someone/Çıktılar"); options.normalize()
        XCTAssertEqual(options.location, .folder("/Users/someone/Çıktılar"))

        let before = options
        options.normalize()
        XCTAssertEqual(options, before, "Normalizing twice changes nothing")
    }

    func testOverridesReplaceOnlyWhatTheyName() {
        let base = ConversionOptions(imageQuality: 0.9, pdfDPI: 300, videoQuality: .high, audioBitrate: 256,
                                     location: .subfolder("x"), trashOriginals: true)
        XCTAssertEqual(base.applying(OptionOverrides()), base)
        let all = base.applying(OptionOverrides(imageQuality: 0.7, imageResize: .half, videoQuality: .small, videoMaxHeight: 720,
                                                videoCodec: .hevc, removeAudio: true, audioBitrate: 128))
        XCTAssertEqual(all.imageQuality, 0.7)
        XCTAssertEqual(all.imageResize, .half)
        XCTAssertEqual(all.videoQuality, .small)
        XCTAssertEqual(all.videoMaxHeight, 720)
        XCTAssertEqual(all.videoCodec, .hevc)
        XCTAssertTrue(all.removeAudio)
        XCTAssertEqual(all.audioBitrate, 128)
        XCTAssertEqual(all.pdfDPI, 300); XCTAssertEqual(all.location, .subfolder("x")); XCTAssertTrue(all.trashOriginals)
        let one = base.applying(OptionOverrides(audioBitrate: 128))
        XCTAssertEqual(one.imageQuality, 0.9); XCTAssertEqual(one.videoQuality, .high); XCTAssertEqual(one.audioBitrate, 128)
        XCTAssertEqual(Set([OptionOverrides(), OptionOverrides(imageResize: .half), OptionOverrides(imageResize: .half)]).count, 2)
    }

    // MARK: Stored form

    func testLocationIsStoredAsTwoPlainFieldsAndAnythingUnknownMeansBesideTheSource() throws {
        XCTAssertEqual(try object(OutputLocation.besideSource) as NSDictionary, ["kind": "beside", "name": ""])
        XCTAssertEqual(try object(OutputLocation.subfolder("Dönüştürülenler")) as NSDictionary, ["kind": "subfolder", "name": "Dönüştürülenler"])
        XCTAssertEqual(try object(OutputLocation.folder("/tmp/x")) as NSDictionary, ["kind": "folder", "name": "/tmp/x"])
        let stored = try object(ConversionOptions(location: .subfolder("x")))
        XCTAssertEqual(stored["location"] as? NSDictionary, ["kind": "subfolder", "name": "x"])

        for location in [OutputLocation.besideSource, .subfolder("a b"), .folder("/x/y")] {
            XCTAssertEqual(try JSONDecoder().decode(OutputLocation.self, from: JSONEncoder().encode(location)), location)
        }
        for json in [#"{"kind":"cloud","name":"x"}"#, #"{"subfolder":{"_0":"eski"}}"#, #"{}"#, #""beside""#, #"7"#, #"[1,2]"#, #"null"#,
                     #"{"kind":7,"name":"x"}"#] {
            XCTAssertEqual(try decode(OutputLocation.self, json), .besideSource, json)
        }
        XCTAssertEqual(try decode(OutputLocation.self, #"{"kind":"subfolder"}"#), .subfolder(""), "normalize() repairs an empty name")
        XCTAssertEqual(try decode(OutputLocation.self, #"{"kind":"folder","name":5}"#), .folder(""))
    }

    func testOptionsRoundTripAndEveryFieldFallsBackOnItsOwn() throws {
        var options = ConversionOptions(imageQuality: 0.55, keepMetadata: false, pdfDPI: 300, pdfCompression: .strong, paper: .letter,
                                        videoQuality: .high, videoCodec: .hevc, audioBitrate: 256, location: .folder("/x"),
                                        trashOriginals: true, imageResize: .long1280, videoMaxHeight: 1080, removeAudio: true)
        XCTAssertEqual(try JSONDecoder().decode(ConversionOptions.self, from: JSONEncoder().encode(options)), options)
        options.imageQuality = nil
        XCTAssertEqual(try JSONDecoder().decode(ConversionOptions.self, from: JSONEncoder().encode(options)), options)

        XCTAssertEqual(try decode(ConversionOptions.self, "{}"), ConversionOptions())
        for json in ["7", #""x""#, "[]", "null"] {
            XCTAssertEqual(try decode(ConversionOptions.self, json), ConversionOptions(), json)
        }
        // One unknown raw value in each enum; the neighbours survive.
        let enums = try decode(ConversionOptions.self, #"{"pdfCompression":"brutal","paper":"a3","videoQuality":"ultra","videoCodec":"av1","pdfDPI":300,"audioBitrate":128,"keepMetadata":false}"#)
        XCTAssertEqual(enums.pdfCompression, .balanced)
        XCTAssertEqual(enums.paper, PaperSize.regional())
        XCTAssertEqual(enums.videoQuality, .balanced)
        XCTAssertEqual(enums.videoCodec, .h264)
        XCTAssertEqual(enums.pdfDPI, 300); XCTAssertEqual(enums.audioBitrate, 128); XCTAssertFalse(enums.keepMetadata)
        // Wrongly typed values.
        let typed = try decode(ConversionOptions.self, #"{"imageQuality":"yüksek","keepMetadata":"no","pdfDPI":"300","pdfCompression":3,"audioBitrate":256.5,"location":"beside","trashOriginals":1,"imageResize":"half","videoMaxHeight":"720","removeAudio":null,"videoCodec":"hevc"}"#)
        XCTAssertNil(typed.imageQuality)
        XCTAssertTrue(typed.keepMetadata)
        XCTAssertEqual(typed.pdfDPI, 150)
        XCTAssertEqual(typed.pdfCompression, .balanced)
        XCTAssertEqual(typed.audioBitrate, 192)
        XCTAssertEqual(typed.location, .besideSource)
        XCTAssertFalse(typed.trashOriginals)
        XCTAssertEqual(typed.imageResize, .original)
        XCTAssertEqual(typed.videoMaxHeight, 0)
        XCTAssertFalse(typed.removeAudio)
        XCTAssertEqual(typed.videoCodec, .hevc, "The one good value in the file is kept")
        // Decoding repairs what normalize() would repair.
        let wild = try decode(ConversionOptions.self, #"{"imageQuality":40,"pdfDPI":1,"audioBitrate":5000,"videoMaxHeight":999,"location":{"kind":"subfolder","name":"../../x"},"imageResize":{"mode":"percent","value":500}}"#)
        XCTAssertEqual(wild.imageQuality, 1); XCTAssertEqual(wild.pdfDPI, 72); XCTAssertEqual(wild.audioBitrate, 320)
        XCTAssertEqual(wild.videoMaxHeight, 0); XCTAssertEqual(wild.location, .besideSource)
        XCTAssertEqual(wild.imageResize, ImageResize(mode: .percent, value: 100))

        XCTAssertEqual(try decode(ImageResize.self, #"{"mode":"squash","value":50}"#), .original)
        XCTAssertEqual(try decode(ImageResize.self, #"{"mode":"longEdge","value":"x"}"#), .original)
        XCTAssertEqual(try decode(ImageResize.self, #"{"mode":"longEdge","value":1280}"#), .long1280)
        XCTAssertEqual(try decode(ImageResize.self, #""half""#), .original)
    }

    func testSettingsRoundTripAndOneBadValueNeverResetsTheRest() throws {
        let rule = WatchRule(folder: "/Users/x/Gelen", targetID: "png", outputFolder: "Dönüştürülenler")
        var settings = ConverterSettings(donutEnabled: false, trigger: .shift, finderOnly: false,
                                         options: ConversionOptions(pdfDPI: 300, trashOriginals: true), watch: [rule])
        XCTAssertEqual(try JSONDecoder().decode(ConverterSettings.self, from: JSONEncoder().encode(settings)), settings)

        // The per-job choices are not kept with the settings.
        settings.options.imageResize = .half; settings.options.videoMaxHeight = 720; settings.options.removeAudio = true
        let stored = try JSONDecoder().decode(ConverterSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(stored.options.imageResize, .original)
        XCTAssertEqual(stored.options.videoMaxHeight, 0)
        XCTAssertFalse(stored.options.removeAudio)
        XCTAssertEqual(stored.options.pdfDPI, 300)

        XCTAssertEqual(try decode(ConverterSettings.self, "{}"), ConverterSettings())
        for json in ["3", #""x""#, "[]", "null"] {
            XCTAssertEqual(try decode(ConverterSettings.self, json), ConverterSettings(), json)
        }
        let unknownTrigger = try decode(ConverterSettings.self, #"{"donutEnabled":false,"trigger":"control","finderOnly":false}"#)
        XCTAssertEqual(unknownTrigger.trigger, .option)
        XCTAssertFalse(unknownTrigger.donutEnabled); XCTAssertFalse(unknownTrigger.finderOnly)
        let noOptions = try decode(ConverterSettings.self, #"{"donutEnabled":false,"trigger":"shift"}"#)
        XCTAssertFalse(noOptions.donutEnabled); XCTAssertEqual(noOptions.trigger, .shift)
        XCTAssertEqual(noOptions.options, ConversionOptions())
        let badOptions = try decode(ConverterSettings.self, #"{"trigger":"shift","options":"none","watch":"none","donutEnabled":"yes"}"#)
        XCTAssertEqual(badOptions.trigger, .shift)
        XCTAssertEqual(badOptions.options, ConversionOptions())
        XCTAssertTrue(badOptions.watch.isEmpty)
        XCTAssertTrue(badOptions.donutEnabled)
        let futureLocation = try decode(ConverterSettings.self, #"{"donutEnabled":false,"trigger":"shift","options":{"location":{"kind":"cloud"},"pdfDPI":300}}"#)
        XCTAssertFalse(futureLocation.donutEnabled); XCTAssertEqual(futureLocation.trigger, .shift)
        XCTAssertEqual(futureLocation.options.location, .besideSource); XCTAssertEqual(futureLocation.options.pdfDPI, 300)
    }

    func testOneMalformedRuleDropsOnlyItself() throws {
        let json = #"""
        {"trigger":"shift","watch":[
          {"id":"11111111-1111-1111-1111-111111111111","folder":"/a","targetID":"png","outputFolder":"Çıktı","enabled":false},
          "not a rule",
          {"folder":"/b","targetID":"jpg","outputFolder":"Çıktı"},
          {"folder":7,"targetID":"jpg","outputFolder":"Çıktı"},
          {"folder":"/c","targetID":"mp3","outputFolder":"Çıktı","enabled":"evet","id":"not-a-uuid"},
          42,
          {"folder":"/d","targetID":"png"}
        ]}
        """#
        let settings = try decode(ConverterSettings.self, json)
        XCTAssertEqual(settings.trigger, .shift)
        XCTAssertEqual(settings.watch.map(\.folder), ["/a", "/b", "/c"])
        XCTAssertEqual(settings.watch[0].id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertFalse(settings.watch[0].enabled)
        XCTAssertTrue(settings.watch[1].enabled, "A missing switch means on")
        XCTAssertTrue(settings.watch[2].enabled)
        XCTAssertThrowsError(try decode(WatchRule.self, "5"), "Something that is not an object is not a rule")
        XCTAssertEqual(try decode(WatchRule.self, "{}").folder, "")
    }

    func testNormalizeDropsRulesThatCannotBeWatchedSafely() {
        func rule(_ folder: String, _ target: String = "png", _ output: String = "Dönüştürülenler") -> WatchRule {
            WatchRule(folder: folder, targetID: target, outputFolder: output)
        }
        var settings = ConverterSettings(watch: [
            rule("/Users/x/Gelen"),
            rule("Gelen"),                                  // relative
            rule(""),
            rule("/Users/x/A", "usdz"),                     // unknown target
            rule("/Users/x/B", "png", "../../x"),          // unsafe results folder
            rule("/Users/x/C", "png", ""),
            rule("/Users/x/D", "png", ".gizli"),
            rule("/Users/x/Gelen", "jpg"),                  // the same folder again
            rule("/Users/x/./Gelen/", "jpg"),
            rule("/Users/x/Y/../Gelen", "jpg"),
            rule("/Users/x/Müzik", "mp3.128k", "Çıktı")
        ])
        settings.normalize()
        XCTAssertEqual(settings.watch.map(\.folder), ["/Users/x/Gelen", "/Users/x/Müzik"])
        XCTAssertEqual(settings.watch.map(\.targetID), ["png", "mp3.128k"])

        settings.watch = (0..<30).map { rule("/Users/x/\($0)") }
        settings.normalize()
        XCTAssertEqual(settings.watch.count, ConverterSettings.watchLimit)
        XCTAssertEqual(ConverterSettings.watchLimit, 20)
        XCTAssertEqual(settings.watch.first?.folder, "/Users/x/0", "The first twenty are kept")

        settings.options = ConversionOptions(pdfDPI: 9000, location: .subfolder("../x"), imageResize: .half, videoMaxHeight: 720, removeAudio: true)
        settings.normalize()
        XCTAssertEqual(settings.options.pdfDPI, 600)
        XCTAssertEqual(settings.options.location, .besideSource)
        XCTAssertEqual(settings.options.imageResize, .original)
        XCTAssertEqual(settings.options.videoMaxHeight, 0)
        XCTAssertFalse(settings.options.removeAudio)
    }
}
