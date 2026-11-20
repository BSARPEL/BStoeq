import XCTest
import CoreGraphics
@testable import BStoeqCore

final class MenuBarReorderGeometryTests: XCTestCase {
    func testDragStaysAtSourceHeightOnSecondaryDisplay() {
        let screen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let source = CGRect(x: -300, y: -96, width: 30, height: 24)
        let target = CGRect(x: -200, y: -100, width: 24, height: 39)
        XCTAssertEqual(MenuBarReorderGeometry.destination(source: source, target: target, screen: screen, before: true),
                       CGPoint(x: -199, y: -84))
        XCTAssertEqual(MenuBarReorderGeometry.destination(source: source, target: target, screen: screen, before: false),
                       CGPoint(x: -177, y: -84))
    }
    func testRejectsOffscreenOtherDisplayAndTinySpacer() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let source = CGRect(x: 1300, y: 8, width: 24, height: 24)
        for target in [CGRect(x: -200, y: 8, width: 24, height: 24), CGRect(x: 1400, y: 100, width: 24, height: 24),
                       CGRect(x: 1400, y: 8, width: 2, height: 24), CGRect(x: 1720, y: 8, width: 24, height: 24)] {
            XCTAssertNil(MenuBarReorderGeometry.destination(source: source, target: target, screen: screen, before: true))
        }
    }
    func testUnchangedRelativeOrderDoesNotMasqueradeAsSuccessfulDrop() {
        XCTAssertFalse(MenuBarReorderGeometry.areAdjacent(sourceID: "a", targetID: "c", order: ["a", "b", "c"], before: true))
        XCTAssertTrue(MenuBarReorderGeometry.areAdjacent(sourceID: "a", targetID: "c", order: ["b", "a", "c"], before: true))
        XCTAssertTrue(MenuBarReorderGeometry.areAdjacent(sourceID: "a", targetID: "c", order: ["b", "c", "a"], before: false))
        XCTAssertFalse(MenuBarReorderGeometry.areAdjacent(sourceID: "a", targetID: "a", order: ["a"], before: false))
        XCTAssertFalse(MenuBarReorderGeometry.areAdjacent(sourceID: "missing", targetID: "c", order: ["b", "c"], before: true))
    }
    func testVerificationRejectsOverlappingStaleFrames() {
        let source = CGRect(x: 1500, y: 8, width: 30, height: 24)
        XCTAssertFalse(MenuBarReorderGeometry.hasRequestedOrder(source: source, target: source, before: true))
        XCTAssertFalse(MenuBarReorderGeometry.hasRequestedOrder(source: source, target: source, before: false))
        XCTAssertTrue(MenuBarReorderGeometry.hasRequestedOrder(source: source,
            target: CGRect(x: 1540, y: 8, width: 30, height: 24), before: true))
        XCTAssertTrue(MenuBarReorderGeometry.hasRequestedOrder(source: source,
            target: CGRect(x: 1460, y: 8, width: 30, height: 24), before: false))
    }
}
