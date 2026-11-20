import XCTest
@testable import BStoeqCore

final class LocalizationTests: XCTestCase {
    func testEveryEntryHasThreeNonemptyTranslationsAndMatchingPlaceholders() throws {
        XCTAssertGreaterThan(Localizer.catalog.count, 130)
        let regex = try NSRegularExpression(pattern: "%[@df]")
        func placeholders(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
        }
        for (key, values) in Localizer.catalog {
            for language in ["tr", "en", "de"] {
                let translation = try XCTUnwrap(values[language], "Missing \(language): \(key)")
                XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
                XCTAssertEqual(placeholders(translation), placeholders(key), key)
            }
        }
    }
    func testSystemLanguageResolutionHandlesRegionalIdentifiers() {
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["de-DE"]), .german)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["tr_TR"]), .turkish)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["en-GB"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.turkish.resolved(preferred: ["de-DE"]), .turkish)
    }
    func testLiveMessagesAndCountFormatting() {
        let message = UserMessage("Gizleme uygulanamadı: %@", detail: "example")
        XCTAssertEqual(message.text(using: Localizer(language: .english)), "Could not hide icons: example")
        XCTAssertEqual(message.text(using: Localizer(language: .german)), "Symbole konnten nicht ausgeblendet werden: example")
        XCTAssertEqual(Localizer(language: .english).seconds(1), "1 second")
        XCTAssertEqual(Localizer(language: .german).seconds(5), "5 Sekunden")
        XCTAssertEqual(Localizer(language: .turkish).seconds(4), "4 saniye")
    }
    func testSpaceShortcutUsesSelectedLanguage() {
        let shortcut = Shortcut(keyCode: 49, modifiers: 2304, label: "⌥ ⌘ Boşluk")
        XCTAssertEqual(shortcut.displayLabel(using: Localizer(language: .german)), "⌥ ⌘ Leertaste")
        XCTAssertEqual(shortcut.displayLabel(using: Localizer(language: .english)), "⌥ ⌘ Space")
    }
}
