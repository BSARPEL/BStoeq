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
    func testPointerOnTheTopRowIsOnItsScreenAndInTheMenuBar() {
        // Cocoa coordinates: the top row of a screen is reported at frame.maxY.
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let above = CGRect(x: 0, y: 1117, width: 1728, height: 1117)
        let top = CGPoint(x: 1500, y: 1117)
        XCTAssertFalse(main.contains(top))
        XCTAssertTrue(ScreenGeometry.contains(main, pointer: top))
        XCTAssertTrue(ScreenGeometry.isInMenuBar(top, frame: main, topInset: 0))
        XCTAssertTrue(ScreenGeometry.isInMenuBar(CGPoint(x: 1500, y: 1085), frame: main, topInset: 37))
        XCTAssertFalse(ScreenGeometry.isInMenuBar(CGPoint(x: 1500, y: 1085), frame: main, topInset: 0))
        // The shared row belongs to the lower screen only, and the edges stay outside.
        XCTAssertFalse(ScreenGeometry.contains(above, pointer: top))
        XCTAssertFalse(ScreenGeometry.isInMenuBar(top, frame: above, topInset: 0))
        XCTAssertFalse(ScreenGeometry.contains(main, pointer: CGPoint(x: 1728, y: 500)))
        XCTAssertFalse(ScreenGeometry.contains(main, pointer: CGPoint(x: 1500, y: 1117.5)))
    }
    func testSecondaryDisplayUsesItsOwnMenuBarOrigin() {
        let screen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        XCTAssertTrue(MenuTargetGeometry.isOnMenuBar(CGRect(x: -100, y: -95, width: 24, height: 24), screens: [screen]))
        XCTAssertFalse(MenuTargetGeometry.isOnMenuBar(CGRect(x: -100, y: 50, width: 24, height: 24), screens: [screen]))
    }
}
