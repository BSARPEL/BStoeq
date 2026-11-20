import XCTest
import Darwin
import BStoeqCore
@testable import BStoeq

final class CacheCleanupManagerTests: XCTestCase {
    private var home: URL!
    private var sharedApps: String { home.appendingPathComponent("SharedApplications").path }

    override func setUpWithError() throws {
        let base = try XCTUnwrap(DiskScanner.canonicalPath(FileManager.default.temporaryDirectory.path))
        home = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("barlet-cache-manager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    @discardableResult
    private func oldFile(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent("Library/Caches").appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 8192).write(to: url)
        let old = timeval(tv_sec: Int(Date().timeIntervalSince1970) - 45 * 86_400, tv_usec: 0)
        XCTAssertEqual(utimes(url.path, [old, old]), 0)
        return url
    }

    @MainActor private func settle(_ manager: CacheCleanupManager) async throws {
        let deadline = Date().addingTimeInterval(10)
        while manager.phase == .scanning || manager.phase == .cleaning {
            guard Date() < deadline else { return XCTFail("Timed out in phase \(manager.phase)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testOnlyApprovedGroupMovesAndFailedItemsCanBeRetried() async throws {
        let moved = try oldFile("Browser/image")
        try oldFile("Browser/collision")
        let changed = try oldFile("Browser/changed")
        let unselected = try oldFile("Editor/unused")
        let trash = home.appendingPathComponent("TestTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let collision = trash.appendingPathComponent("collision")
        try Data([1]).write(to: collision)
        let manager = CacheCleanupManager(home: home.path, applicationsRoot: sharedApps, moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        manager.scan()
        try await settle(manager)
        XCTAssertTrue(manager.selection.isEmpty)
        manager.cleanSelection()
        XCTAssertNil(manager.report)
        let group = try XCTUnwrap(manager.groups.first { $0.id == "Browser" })
        manager.toggle(group)
        XCTAssertEqual(manager.selectedCount, 3)
        XCTAssertEqual(manager.selectedBytes, group.bytes)
        let expectedBytes = try XCTUnwrap(group.files.first { $0.path == moved.path }).bytes
        try Data([3]).write(to: changed)
        manager.cleanSelection()
        manager.toggleAll()
        manager.scan()
        XCTAssertEqual(manager.phase, .cleaning)
        try await settle(manager)
        let report = try XCTUnwrap(manager.report)
        XCTAssertEqual(report.movedCount, 1)
        XCTAssertEqual(report.movedBytes, expectedBytes)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertTrue(manager.selection.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselected.path))
        let retryGroup = try XCTUnwrap(manager.groups.first { $0.id == "Browser" })
        XCTAssertEqual(retryGroup.fileCount, 1)
        try FileManager.default.removeItem(at: collision)
        manager.toggle(retryGroup)
        manager.cleanSelection()
        try await settle(manager)
        XCTAssertEqual(manager.report?.movedCount, 1)
        XCTAssertEqual(manager.report?.failedCount, 0)
        XCTAssertEqual(manager.groups.map(\.id), ["Editor"])
    }

    @MainActor func testScanCanBeCancelledAndRestartedAfterRootFailure() async throws {
        let manager = CacheCleanupManager(home: home.path, applicationsRoot: sharedApps,
                                          moveToTrash: { _ in XCTFail("A scan cannot move files") })
        manager.scan()
        try await settle(manager)
        XCTAssertTrue(manager.scanFailed)
        try oldFile("Example/file")
        manager.scan()
        manager.cancelScan()
        XCTAssertEqual(manager.phase, .idle)
        manager.scan()
        try await settle(manager)
        XCTAssertFalse(manager.scanFailed)
        XCTAssertEqual(manager.phase, .ready)
        XCTAssertEqual(manager.groups.map(\.id), ["Example"])
        manager.toggleAll()
        XCTAssertEqual(manager.selectedCount, 1)
        manager.toggleAll()
        XCTAssertEqual(manager.selectedCount, 0)
    }

    @MainActor func testBulkSelectionAndCleanupKeepInstallersAndAppsIndependent() async throws {
        let cached = try oldFile("Example/cache")
        let downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let image = downloads.appendingPathComponent("Backup.dmg")
        try Data(repeating: 3, count: 8192).write(to: image)
        let app = home.appendingPathComponent("Applications/Fixture.app")
        let binary = app.appendingPathComponent("Contents/MacOS/Fixture")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 4, count: 8192).write(to: binary)
        XCTAssertEqual(chmod(binary.path, 0o755), 0)
        let values = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "local.test.bulk",
                      "CFBundleExecutable": "Fixture", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let trash = home.appendingPathComponent("TestTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let date = Date().addingTimeInterval(400 * 86_400)
        let manager = CacheCleanupManager(home: home.path, applicationsRoot: sharedApps, now: { date },
                                          lastUsed: { _ in date.addingTimeInterval(-200 * 86_400) }) {
            try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent))
        }
        manager.scan()
        try await settle(manager)
        let installer = try XCTUnwrap(manager.groups.first { $0.source == .installers })
        let candidate = try XCTUnwrap(manager.apps.first)
        manager.toggleAll()
        XCTAssertEqual(manager.selectedCount, 1)
        XCTAssertFalse(manager.selection.contains(installer.id))
        XCTAssertTrue(manager.appSelection.isEmpty)
        manager.toggle(installer)
        manager.toggleAll()
        XCTAssertEqual(manager.selection, [installer.id])
        manager.toggleApp(candidate)
        manager.cleanSelectedApps()
        try await settle(manager)
        XCTAssertEqual(manager.report?.isApps, true)
        XCTAssertEqual(manager.report?.movedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Fixture.app").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertEqual(manager.selection, [installer.id])
        manager.cleanSelection()
        try await settle(manager)
        XCTAssertEqual(manager.report?.isApps, false)
        XCTAssertEqual(manager.report?.movedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Backup.dmg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        manager.toggleAll()
        let previousSelection = manager.selection
        let later = try oldFile("NewGroup/newFile")
        manager.setAppAgeDays(30)
        manager.cancelScan()
        XCTAssertEqual(manager.appAgeDays, 180)
        XCTAssertEqual(manager.phase, .ready)
        manager.setAppAgeDays(90)
        try await settle(manager)
        XCTAssertEqual(manager.phase, .ready)
        XCTAssertEqual(manager.appAgeDays, 90)
        XCTAssertEqual(manager.selection, previousSelection)
        XCTAssertFalse(manager.groups.flatMap(\.files).contains { $0.path == later.path })
    }

    @MainActor func testStopKeepsUnattemptedFilesForAnotherSelection() async throws {
        for n in 0..<3 { try oldFile("Example/file-\(n)") }
        let entered = expectation(description: "First move started")
        let finishFirst = DispatchSemaphore(value: 0)
        let manager = CacheCleanupManager(home: home.path, applicationsRoot: sharedApps, moveToTrash: { url in
            entered.fulfill()
            guard finishFirst.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("moved"))
        })
        manager.scan()
        try await settle(manager)
        manager.toggleAll()
        manager.cleanSelection()
        await fulfillment(of: [entered], timeout: 5)
        manager.stopCleaning()
        finishFirst.signal()
        try await settle(manager)
        XCTAssertEqual(manager.report?.wasStopped, true)
        XCTAssertEqual(manager.report?.movedCount, 1)
        XCTAssertEqual(manager.report?.skippedCount, 0)
        XCTAssertEqual(manager.groups.first?.fileCount, 2)
        XCTAssertTrue(manager.selection.isEmpty)
    }
}
