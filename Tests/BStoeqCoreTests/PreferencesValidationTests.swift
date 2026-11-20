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
}
