import XCTest
import CoreGraphics
@testable import BStoeqCore

final class MenuActivationTests: XCTestCase {
    func testSecondaryClickNeverTurnsIntoPrimaryPress() {
        XCTAssertEqual(MenuActivation.contextMenu.accessibilityAction, "AXShowMenu")
        XCTAssertFalse(MenuActivation.contextMenu.supports(["AXPress"]))
        XCTAssertTrue(MenuActivation.contextMenu.supports(["AXPress", "AXShowMenu"]))
        XCTAssertEqual(MenuActivation.primary.accessibilityAction, "AXPress")
        XCTAssertFalse(MenuActivation.primary.supports(["AXShowMenu"]))
    }
    func testMouseFallbackRejectsUnknownAndOffscreenTargets() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        for rect in [CGRect.zero, CGRect(x: -80, y: 0, width: 24, height: 24),
                     CGRect(x: 100, y: 200, width: 24, height: 24),
                     CGRect(x: 1720, y: 0, width: 24, height: 24),
                     CGRect(x: 100, y: 0, width: 24, height: 200)] {
            XCTAssertFalse(MenuTargetGeometry.isOnMenuBar(rect, screens: [screen]))
        }
        XCTAssertTrue(MenuTargetGeometry.isOnMenuBar(CGRect(x: 1400, y: 4, width: 24, height: 24), screens: [screen]))
    }
    func testSecondaryDisplayUsesItsOwnMenuBarOrigin() {
        let screen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        XCTAssertTrue(MenuTargetGeometry.isOnMenuBar(CGRect(x: -100, y: -95, width: 24, height: 24), screens: [screen]))
        XCTAssertFalse(MenuTargetGeometry.isOnMenuBar(CGRect(x: -100, y: 50, width: 24, height: 24), screens: [screen]))
    }
}
