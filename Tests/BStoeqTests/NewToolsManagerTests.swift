import XCTest
import Darwin
import os
import BStoeqCore
@testable import BStoeq

final class NewToolsManagerTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!, trash: URL!

    override func setUpWithError() throws {
        let base = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        home = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("barlet-tools-\(UUID().uuidString)")
        trash = home.appendingPathComponent(".TestTrash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    @discardableResult
    private func write(_ relative: String, _ value: UInt8, bytes: Int = 20_000, age: Int = 0) throws -> String {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: value, count: bytes).write(to: url)
        if age > 0 {
            let time = timeval(tv_sec: Int(Date().timeIntervalSince1970) - age * 86_400, tv_usec: 0)
            XCTAssertEqual(utimes(url.path, [time, time]), 0)
        }
        return url.path
    }
    private func mover(deny: String? = nil) -> @Sendable (URL) throws -> Void {
        let trash = trash!
        return { url in
            if url.path == deny { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }
    @MainActor private func settle(_ busy: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while busy() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testDuplicateSelectionAlwaysLeavesOneCopyAndTrashUpdatesGroups() async throws {
        let oldest = try write("Docs/a.bin", 1, age: 9), middle = try write("Docs/b.bin", 1, age: 5)
        let newest = try write("Desk/c.bin", 1, age: 1)
        let pairA = try write("Docs/x.bin", 2, bytes: 5_000, age: 4), pairB = try write("Desk/y.bin", 2, bytes: 5_000, age: 2)
        let manager = DuplicateFinderManager(home: home.path, ownBundle: nil, mountPoints: { [] }, moveToTrash: mover(deny: pairB))
        manager.setMinimumBytes(77)
        XCTAssertEqual(manager.minimumBytes, 1_000_000, "Only offered sizes are accepted")
        manager.setMinimumBytes(1)
        manager.scan(home.appendingPathComponent("missing").path)
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNotNil(manager.problem)
        manager.scan(home.path)
        XCTAssertEqual(manager.phase, .scanning)
        XCTAssertNil(manager.problem)
        try await settle { manager.phase == .scanning }
        XCTAssertEqual(manager.groups.map { $0.files.map(\.path) }, [[oldest, middle, newest], [pairA, pairB]])
        XCTAssertEqual(manager.scannedFiles, 5)
        XCTAssertTrue(manager.selection.isEmpty)
        manager.trashSelection()
        XCTAssertEqual(manager.phase, .ready)

        let big = manager.groups[0]
        manager.toggle(big.files[0], in: big)
        manager.toggle(big.files[1], in: big)
        XCTAssertTrue(manager.isLastKept(big.files[2], in: big))
        manager.toggle(big.files[2], in: big)
        XCTAssertEqual(manager.selection, [oldest, middle], "The last unselected copy cannot be selected")
        manager.selectAllButOldest()
        XCTAssertEqual(manager.selection, [middle, newest, pairB])
        XCTAssertEqual(manager.selectedBytes, big.files[1].bytes + big.files[2].bytes + manager.groups[1].files[1].bytes)

        manager.trashSelection()
        XCTAssertEqual(manager.phase, .trashing)
        manager.scan(home.path)
        manager.toggle(big.files[1], in: big)
        try await settle { manager.phase == .trashing }
        let report = try XCTUnwrap(manager.report)
        XCTAssertEqual(report.movedCount, 2)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertFalse(report.wasStopped)
        XCTAssertEqual(manager.groups.map { $0.files.map(\.path) }, [[pairA, pairB]], "A failed copy stays for another try")
        XCTAssertTrue(manager.selection.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: oldest))
        XCTAssertFalse(fm.fileExists(atPath: middle))
        XCTAssertTrue(fm.fileExists(atPath: pairB))

        manager.close()
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNil(manager.folder)
        manager.scan(home.path)
        manager.cancelScan()
        XCTAssertEqual(manager.phase, .idle)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.groups.isEmpty, "A cancelled scan delivers nothing")
    }

    @discardableResult
    private func makeApp(_ name: String, id: String) throws -> URL {
        let root = home.appendingPathComponent("SharedApplications/\(name).app")
        let binary = root.appendingPathComponent("Contents/MacOS/fixture")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 37, count: 30_000).write(to: binary)
        XCTAssertEqual(chmod(binary.path, 0o755), 0)
        let values: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id, "CFBundleExecutable": "fixture",
                                     "CFBundleName": name, "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        return root
    }

    @MainActor func testUninstallReviewsSelectsExactMatchesAndRefusesRunningApps() async throws {
        let app = try makeApp("Sketch", id: "org.example.sketch")
        try makeApp("Other", id: "org.example.other")
        let support = URL(fileURLWithPath: try write("Library/Application Support/org.example.sketch/db", 3)).deletingLastPathComponent().path
        let preferences = try write("Library/Preferences/org.example.sketch.plist", 4, bytes: 2_000)
        let named = URL(fileURLWithPath: try write("Library/Caches/Sketch/blob", 5)).deletingLastPathComponent().path
        let foreign = try write("Library/Preferences/org.example.other.plist", 6, bytes: 2_000)
        let open = OSAllocatedUnfairLock(initialState: true)
        let manager = AppUninstallManager(home: home.path, applicationsRoot: home.appendingPathComponent("SharedApplications").path,
                                          running: { RunningAppSnapshot(identifiers: open.withLock { $0 } ? ["org.example.sketch"] : []) },
                                          moveToTrash: mover())
        manager.refresh()
        XCTAssertEqual(manager.phase, .listing)
        try await settle { manager.phase == .listing }
        XCTAssertEqual(manager.apps.map(\.name), ["Other", "Sketch"])
        XCTAssertEqual(manager.runningApps, [app.path])
        manager.uninstall()
        XCTAssertEqual(manager.phase, .list)

        let sketch = manager.apps[1]
        manager.inspect(sketch)
        manager.inspect(manager.apps[0])
        XCTAssertEqual(manager.current?.id, sketch.id)
        try await settle { manager.phase == .inspecting }
        XCTAssertEqual(manager.phase, .review)
        let plan = try XCTUnwrap(manager.plan)
        XCTAssertEqual(Set(plan.leftovers.map(\.path)), [support, preferences, named])
        XCTAssertEqual(manager.selection, [support, preferences], "A match by name alone is left for the user to tick")
        XCTAssertTrue(manager.isCurrentRunning)
        manager.toggle(plan.leftovers.first { $0.path == preferences }!)
        XCTAssertEqual(manager.selection, [support])

        manager.uninstall()
        try await settle { manager.phase == .removing }
        XCTAssertEqual(manager.report?.outcome, .running)
        XCTAssertEqual(manager.phase, .review)
        XCTAssertTrue(fm.fileExists(atPath: app.path))
        XCTAssertTrue(fm.fileExists(atPath: support))

        open.withLock { $0 = false }
        manager.refreshRunning()
        XCTAssertFalse(manager.isCurrentRunning)
        manager.uninstall()
        try await settle { manager.phase == .removing }
        let report = try XCTUnwrap(manager.report)
        XCTAssertEqual(report.outcome, .moved)
        XCTAssertEqual(report.movedCount, 2)
        XCTAssertGreaterThanOrEqual(report.movedBytes, 50_000)
        XCTAssertTrue(report.failedPaths.isEmpty)
        XCTAssertEqual(manager.phase, .list)
        XCTAssertEqual(manager.apps.map(\.name), ["Other"])
        XCTAssertNil(manager.plan)
        XCTAssertFalse(fm.fileExists(atPath: app.path))
        XCTAssertFalse(fm.fileExists(atPath: support))
        XCTAssertTrue([preferences, named, foreign].allSatisfy(fm.fileExists(atPath:)))

        manager.inspect(manager.apps[0])
        manager.back()
        XCTAssertEqual(manager.phase, .list)
        XCTAssertNil(manager.current)
    }
}
