import XCTest
import CoreGraphics
@testable import BStoeqCore

final class RevealModeTests: XCTestCase {
    private let rules: [String: ItemVisibility] = ["a": .hidden, "b": .hidden, "secret": .alwaysHidden,
        "own": .hidden, "com.apple.system": .hidden]
    private func hidden(_ mode: RevealMode, expanded: Bool = true, selected: String? = nil, all: Bool = false) -> Set<String> {
        VisibilityPlan.hiddenIDs(assignments: rules, expanded: expanded, revealAll: all,
            frontmost: nil, showWhenActive: false, ownID: "own", mode: mode, selectedAppID: selected)
    }
    func testPanelsKeepTopBarHiddenUntilAnAppIsSelected() {
        for mode in [RevealMode.bar, .list] {
            XCTAssertEqual(hidden(mode), ["a", "b", "secret"])
            XCTAssertEqual(hidden(mode, selected: "a"), ["b", "secret"])
            XCTAssertEqual(hidden(mode, selected: "secret"), ["a", "b", "secret"])
            XCTAssertEqual(hidden(mode, expanded: false, selected: "a"), ["a", "b", "secret"])
        }
    }
    func testInlineAndRecoveryStillRevealTheRightGroups() {
        XCTAssertEqual(hidden(.menuBar), ["secret"])
        for mode in RevealMode.allCases { XCTAssertTrue(hidden(mode, all: true).isEmpty) }
    }
    func testModeMigrationAndRoundTripPreserveExistingRules() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"assignments":{"a":"hidden"}}"#.utf8))
        XCTAssertEqual(old.revealMode, .menuBar)
        XCTAssertEqual(old.assignments["a"], .hidden)
        let invalid = try JSONDecoder().decode(Preferences.self, from: Data(#"{"revealMode":"unknown"}"#.utf8))
        XCTAssertEqual(invalid.revealMode, .menuBar)
        for mode in RevealMode.allCases {
            var preferences = old; preferences.revealMode = mode
            XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)), preferences)
        }
    }
    func testPanelPlacementClampsBothEdgesAndSecondaryScreenOrigins() {
        let screen = CGRect(x: -1440, y: 120, width: 1440, height: 860)
        for x: CGFloat in [-2000, -1440, -500, 0, 1000] {
            let frame = PanelPlacement.frame(size: CGSize(width: 500, height: 238), visibleFrame: screen, anchorX: x, top: 990)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.size, CGSize(width: 500, height: 238))
        }
    }
    func testPanelFitsSmallWorkArea() {
        let screen = CGRect(x: 200, y: -700, width: 340, height: 280)
        let frame = PanelPlacement.frame(size: CGSize(width: 500, height: 410), visibleFrame: screen, anchorX: 530, top: -400)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.size, CGSize(width: 324, height: 264))
    }
}
