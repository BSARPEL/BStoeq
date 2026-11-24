import ConvertCore
import XCTest
@testable import BStoeqCore

final class PreferencesValidationTests: XCTestCase {
    func testOldPreferencesRetainTurkishAndAssignments() throws {
        let data = Data(#"{"assignments":{"example.app":"hidden"}}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(preferences.language, .turkish)
        XCTAssertEqual(preferences.assignments["example.app"], .hidden)
        XCTAssertEqual(Preferences().language, .system)
    }
    func testLanguageRoundTrip() throws {
        for language in AppLanguage.allCases {
            var preferences = Preferences(); preferences.language = language
            let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.language, language)
        }
    }
    func testInvalidImportedValuesCannotRemoveControlIconOrClaimRecoveryShortcut() throws {
        let data = Data(#"{"language":"fr","icon":"not-a-symbol","appearance":"bad","toggleShortcut":{"keyCode":29,"modifiers":2304,"label":"bad"},"settingsShortcut":{"keyCode":999,"modifiers":0,"label":"bad"}}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertEqual(preferences.icon, Preferences.icons[0])
        XCTAssertEqual(preferences.appearance, "system")
        XCTAssertEqual(preferences.toggleShortcut, .toggle)
        XCTAssertEqual(preferences.settingsShortcut, .settings)
    }
    func testDuplicateShortcutComparisonIgnoresDisplayLabel() {
        var preferences = Preferences()
        preferences.toggleShortcut = .settings
        preferences.settingsShortcut.label = "A different label"
        preferences.normalize()
        XCTAssertEqual(preferences.toggleShortcut, .toggle)
        XCTAssertEqual(preferences.settingsShortcut, .settings)
    }
    func testModifierOnlyAndUnmodifiedKeysAreInvalid() {
        XCTAssertFalse(Shortcut(keyCode: 11, modifiers: 0, label: "B").isValid)
        XCTAssertFalse(Shortcut(keyCode: 56, modifiers: 256, label: "shift").isValid)
        XCTAssertFalse(Shortcut(keyCode: 11, modifiers: 0xFFFF, label: "bad").isValid)
        XCTAssertTrue(Shortcut.toggle.isValid)
    }
    func testLeftoverNamesFromRemovedRulesArePruned() throws {
        let data = Data(#"{"assignments":{"kept.app":"hidden"},"names":{"kept.app":"Kept","gone.app":"Gone"}}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(preferences.names, ["kept.app": "Kept"])
        XCTAssertEqual(preferences.assignments, ["kept.app": .hidden])
    }
    func testNonfiniteAndFractionalDelaysNormalize() {
        var preferences = Preferences(); preferences.autoHideDelay = .infinity; preferences.normalize()
        XCTAssertEqual(preferences.autoHideDelay, 5)
        preferences.autoHideDelay = 4.7; preferences.normalize()
        XCTAssertEqual(preferences.autoHideDelay, 5)
    }

    // MARK: Converter settings

    /// Everything outside the converter block that these files also carry, to see that it survives.
    private let rest = #""assignments":{"example.app":"hidden"},"downloadFolder":"/Users/x/Filmler","autoHideDelay":9"#
    private func decode(converter block: String?) throws -> Preferences {
        let json = "{\(rest)\(block.map { #","converter":\#($0)"# } ?? "")}"
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.assignments, ["example.app": .hidden], block ?? "no block")
        XCTAssertEqual(preferences.downloadFolder, "/Users/x/Filmler", block ?? "no block")
        XCTAssertEqual(preferences.autoHideDelay, 9, block ?? "no block")
        return preferences
    }

    func testAnOldSettingsFileWithoutTheConverterKeepsItsDefaults() throws {
        XCTAssertEqual(try decode(converter: nil).converter, ConverterSettings())
        XCTAssertEqual(Preferences().converter, ConverterSettings())
        XCTAssertTrue(Preferences().converter.donutEnabled)
        XCTAssertEqual(Preferences().converter.trigger, .option)
        // A block that is no block at all costs the converter its settings and nothing else.
        for block in ["7", #""on""#, "[1,2]", "null", "true"] {
            XCTAssertEqual(try decode(converter: block).converter, ConverterSettings(), block)
        }
    }

    func testConverterSettingsTravelWithAnExportedFile() throws {
        var preferences = Preferences()
        preferences.converter = ConverterSettings(
            donutEnabled: false, trigger: .shift, finderOnly: false,
            options: ConversionOptions(imageQuality: 0.6, keepMetadata: false, pdfDPI: 300, pdfCompression: .strong, paper: .letter,
                                       videoQuality: .high, videoCodec: .hevc, audioBitrate: 256,
                                       location: .subfolder("Dönüştürülenler"), trashOriginals: true),
            watch: [WatchRule(folder: "/Users/x/Gelen", targetID: "png", outputFolder: "Dönüştürülenler"),
                    WatchRule(folder: "/Users/x/Ses", targetID: "mp3.128k", outputFolder: "Çıktı", enabled: false)])
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.converter.watch.map(\.enabled), [true, false])

        // What is chosen for one job is not a preference: any change of the settings clears it.
        preferences.converter.options.imageResize = .half
        preferences.converter.options.videoMaxHeight = 720
        preferences.converter.options.removeAudio = true
        preferences.converter.options.pdfDPI = 5000
        preferences.normalize()
        XCTAssertEqual(preferences.converter.options.imageResize, .original)
        XCTAssertEqual(preferences.converter.options.videoMaxHeight, 0)
        XCTAssertFalse(preferences.converter.options.removeAudio)
        XCTAssertEqual(preferences.converter.options.pdfDPI, 600)
        XCTAssertEqual(preferences.converter.options.location, .subfolder("Dönüştürülenler"))
    }

    func testOneUnknownValueInAnEnumFallsBackAloneAndTheRestOfTheFileSurvives() throws {
        let whole = #"{"donutEnabled":false,"trigger":"shift","finderOnly":false,"options":{"imageQuality":0.6,"keepMetadata":false,"pdfDPI":300,"pdfCompression":"strong","paper":"letter","videoQuality":"high","videoCodec":"hevc","audioBitrate":256,"location":{"kind":"folder","name":"/Users/x/Çıktı"},"trashOriginals":true},"watch":[{"id":"22222222-2222-2222-2222-222222222222","folder":"/Users/x/Gelen","targetID":"png","outputFolder":"Çıktı"}]}"#
        let expected = try decode(converter: whole).converter
        XCTAssertFalse(expected.donutEnabled)
        XCTAssertEqual(expected.trigger, .shift)
        XCTAssertEqual(expected.options.location, .folder("/Users/x/Çıktı"))
        XCTAssertEqual(expected.options.videoCodec, .hevc)
        XCTAssertEqual(expected.watch.map(\.folder), ["/Users/x/Gelen"])

        let changes: [(String, String, (inout ConverterSettings) -> Void)] = [
            (#""trigger":"shift""#, #""trigger":"control""#, { $0.trigger = .option }),
            (#""pdfCompression":"strong""#, #""pdfCompression":"brutal""#, { $0.options.pdfCompression = .balanced }),
            (#""paper":"letter""#, #""paper":"a3""#, { $0.options.paper = PaperSize.regional() }),
            (#""videoQuality":"high""#, #""videoQuality":"ultra""#, { $0.options.videoQuality = .balanced }),
            (#""videoCodec":"hevc""#, #""videoCodec":"av1""#, { $0.options.videoCodec = .h264 }),
            (#""kind":"folder""#, #""kind":"cloud""#, { $0.options.location = .besideSource }),
            (#""targetID":"png""#, #""targetID":"usdz""#, { $0.watch = [] })
        ]
        for (old, new, repair) in changes {
            XCTAssertTrue(whole.contains(old), old)
            var wanted = expected
            repair(&wanted)
            XCTAssertEqual(try decode(converter: whole.replacingOccurrences(of: old, with: new)).converter, wanted, new)
        }
    }

    func testAMissingKeyAtAnyLevelLeavesEverythingElseAlone() throws {
        let whole = #"{"donutEnabled":false,"trigger":"shift","finderOnly":false,"options":{"imageQuality":0.6,"keepMetadata":false,"pdfDPI":300,"audioBitrate":256,"location":{"kind":"subfolder","name":"Çıktı"},"trashOriginals":true},"watch":[{"folder":"/Users/x/Gelen","targetID":"png","outputFolder":"Çıktı","enabled":false}]}"#
        let expected = try decode(converter: whole).converter
        XCTAssertEqual(expected.options.location, .subfolder("Çıktı"))
        XCTAssertEqual(expected.watch.map(\.enabled), [false])

        let removals: [(String, (inout ConverterSettings) -> Void)] = [
            (#""donutEnabled":false,"#, { $0.donutEnabled = true }),
            (#""trigger":"shift","#, { $0.trigger = .option }),
            (#""finderOnly":false,"#, { $0.finderOnly = true }),
            (#""imageQuality":0.6,"#, { $0.options.imageQuality = nil }),
            (#""keepMetadata":false,"#, { $0.options.keepMetadata = true }),
            (#""pdfDPI":300,"#, { $0.options.pdfDPI = 150 }),
            (#""audioBitrate":256,"#, { $0.options.audioBitrate = 192 }),
            (#""location":{"kind":"subfolder","name":"Çıktı"},"#, { $0.options.location = .besideSource }),
            (#""kind":"subfolder","#, { $0.options.location = .besideSource }),
            (#","name":"Çıktı""#, { $0.options.location = .besideSource }),
            (#","trashOriginals":true"#, { $0.options.trashOriginals = false }),
            (#","enabled":false"#, { $0.watch[0].enabled = true }),
            (#","outputFolder":"Çıktı""#, { $0.watch = [] }),
            (#","watch":[{"folder":"/Users/x/Gelen","targetID":"png","outputFolder":"Çıktı","enabled":false}]"#, { $0.watch = [] })
        ]
        for (piece, repair) in removals {
            XCTAssertTrue(whole.contains(piece), piece)
            var wanted = expected
            repair(&wanted)
            var decoded = try decode(converter: whole.replacingOccurrences(of: piece, with: "")).converter
            // A rule without an id gets a new one each time it is read.
            if decoded.watch.count == wanted.watch.count { for index in decoded.watch.indices { decoded.watch[index].id = wanted.watch[index].id } }
            XCTAssertEqual(decoded, wanted, piece)
        }
        let withoutOptions = try decode(converter: #"{"donutEnabled":false,"trigger":"shift","watch":[{"folder":"/a","targetID":"jpg","outputFolder":"x"}]}"#).converter
        XCTAssertFalse(withoutOptions.donutEnabled)
        XCTAssertEqual(withoutOptions.trigger, .shift)
        XCTAssertEqual(withoutOptions.options, ConversionOptions())
        XCTAssertEqual(withoutOptions.watch.map(\.folder), ["/a"])
    }

    func testAWronglyTypedNumberCostsOnlyItself() throws {
        let converter = try decode(converter: #"{"donutEnabled":false,"trigger":"shift","options":{"pdfDPI":"300","audioBitrate":true,"imageQuality":"0.9","keepMetadata":false,"videoCodec":"hevc","trashOriginals":true}}"#).converter
        XCTAssertFalse(converter.donutEnabled)
        XCTAssertEqual(converter.trigger, .shift)
        XCTAssertEqual(converter.options.pdfDPI, 150)
        XCTAssertEqual(converter.options.audioBitrate, 192)
        XCTAssertNil(converter.options.imageQuality)
        XCTAssertFalse(converter.options.keepMetadata)
        XCTAssertEqual(converter.options.videoCodec, .hevc)
        XCTAssertTrue(converter.options.trashOriginals)
        // Numbers of the right type but out of range are clamped, not thrown out.
        let clamped = try decode(converter: #"{"options":{"pdfDPI":12,"audioBitrate":100000,"imageQuality":55}}"#).converter.options
        XCTAssertEqual([clamped.pdfDPI, clamped.audioBitrate], [72, 320])
        XCTAssertEqual(clamped.imageQuality, 1)
    }

    func testOneMalformedWatchRuleAmongGoodOnesIsTheOnlyOneDropped() throws {
        let converter = try decode(converter: #"{"trigger":"shift","watch":[{"id":"11111111-1111-1111-1111-111111111111","folder":"/Users/x/A","targetID":"png","outputFolder":"Çıktı"},"bozuk",{"folder":"B","targetID":"png","outputFolder":"Çıktı"},{"folder":"/Users/x/C","targetID":"jpg","outputFolder":"Çıktı","enabled":false},{"folder":"/Users/x/D"},17,{"folder":"/Users/x/E","targetID":"mp3","outputFolder":"../../x"}],"options":{"pdfDPI":300}}"#).converter
        XCTAssertEqual(converter.trigger, .shift)
        XCTAssertEqual(converter.options.pdfDPI, 300)
        XCTAssertEqual(converter.watch.map(\.folder), ["/Users/x/A", "/Users/x/C"])
        XCTAssertEqual(converter.watch.map(\.targetID), ["png", "jpg"])
        XCTAssertEqual(converter.watch.map(\.enabled), [true, false])
        XCTAssertEqual(converter.watch[0].id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    func testATraversalSubfolderIsNeverKeptAsAResultsFolder() throws {
        for name in ["../../x", "..", "../Library/LaunchAgents", "a/b", ".gizli", ""] {
            let block = #"{"donutEnabled":false,"trigger":"shift","options":{"location":{"kind":"subfolder","name":"\#(name)"},"pdfDPI":300,"trashOriginals":true}}"#
            let converter = try decode(converter: block).converter
            XCTAssertEqual(converter.options.location, .besideSource, name)
            XCTAssertEqual(converter.options.pdfDPI, 300, name)
            XCTAssertTrue(converter.options.trashOriginals, name)
            XCTAssertFalse(converter.donutEnabled, name)
            XCTAssertEqual(converter.trigger, .shift, name)
        }
        let relative = try decode(converter: #"{"trigger":"shift","options":{"location":{"kind":"folder","name":"Desktop/x"}}}"#).converter
        XCTAssertEqual(relative.options.location, .besideSource, "A chosen folder is an absolute path")
        XCTAssertEqual(relative.trigger, .shift)

        // The same repair on a value changed in memory, as every settings change runs it.
        var preferences = Preferences()
        preferences.converter.options.location = .subfolder("../../x")
        preferences.converter.watch = [WatchRule(folder: "/Users/x/A", targetID: "png", outputFolder: "../../x")]
        preferences.normalize()
        XCTAssertEqual(preferences.converter.options.location, .besideSource)
        XCTAssertTrue(preferences.converter.watch.isEmpty)
    }
}
