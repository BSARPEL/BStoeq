import XCTest
@testable import BStoeqCore

final class VisibilityTests: XCTestCase {
    let own = "local.barlet.app"
    let rules: [String: ItemVisibility] = ["a": .hidden, "b": .alwaysHidden, "c": .visible,
                                       "local.barlet.app": .alwaysHidden, "com.apple.controlcenter": .hidden]
    func hidden(_ expanded: Bool = false, all: Bool = false, active: String? = nil) -> Set<String> {
        VisibilityPlan.hiddenIDs(assignments: rules, expanded: expanded, revealAll: all,
            frontmost: active, showWhenActive: true, ownID: own)
    }
    func testCollapsedProtectsOwnAndSystemItems() { XCTAssertEqual(hidden(), ["a", "b"]) }
    func testExpandedKeepsAlwaysHidden() { XCTAssertEqual(hidden(true), ["b"]) }
    func testEmergencyRevealIncludesAlwaysHidden() { XCTAssertEqual(hidden(all: true), []) }
    func testActiveAppDoesNotOverrideAlwaysHidden() {
        XCTAssertEqual(hidden(active: "a"), ["b"])
        XCTAssertEqual(hidden(active: "b"), ["a", "b"])
    }
    func testNewlyLaunchedAppsStayVisible() {
        XCTAssertEqual(VisibilityPlan.allowedIDs(running: ["a", "new"], hidden: ["a"], ownID: own), ["new", own])
    }
    func testPartialPreferencesMigration() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data("{\"assignments\":{\"a\":\"hidden\"},\"autoHideDelay\":-10}".utf8))
        XCTAssertEqual(p.assignments["a"], .hidden)
        XCTAssertEqual(p.autoHideDelay, 1)
        XCTAssertTrue(p.autoHide)
    }
    func testRoundTripPreservesShortcutAndAssignments() throws {
        var p = Preferences(); p.assignments = rules; p.toggleShortcut.keyCode = 4
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p)), p)
    }
}
