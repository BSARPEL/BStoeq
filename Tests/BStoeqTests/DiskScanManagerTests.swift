import XCTest
import BStoeqCore
@testable import BStoeq

/// Drives the manager against real folders made for the test. The Trash is replaced
/// by a folder of the test's own, so nothing reaches the user's Trash.
final class DiskScanManagerTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("taranan", isDirectory: true) }
    private var bin: URL { directory.appendingPathComponent("cop", isDirectory: true) }

    override func setUpWithError() throws {
        // The manager works with the folder's one true path (/private/var/…, not /var/…).
        let temporary = try XCTUnwrap(DiskScanner.canonicalPath(FileManager.default.temporaryDirectory.path))
        directory = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("barlet-disk-manager-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try write("projeler/eski/derleme.bin", bytes: 600_000)
        try write("projeler/notlar.txt", bytes: 4_000)
        try write("film.mkv", bytes: 250_000)
        try write("kucuk.txt", bytes: 100)
        try write("Uygulama.app/Contents/ikili", bytes: 30_000)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }
    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    /// Stands in for the list of mounted volumes, which a test cannot change for real.
    private final class Mounts: @unchecked Sendable {
        private let lock = NSLock()
        private var paths = Set<String>()
        var value: Set<String> {
            get { lock.lock(); defer { lock.unlock() }; return paths }
            set { lock.lock(); paths = newValue; lock.unlock() }
        }
    }
    private let mounts = Mounts()

    /// `Uygulama.app` plays the part of BStoeq's own bundle, which must never be trashed.
    @MainActor private func makeManager(failing: Set<String> = [], home: String? = nil) -> DiskScanManager {
        let bin = bin, mounts = mounts
        return DiskScanManager(home: home ?? directory.appendingPathComponent("ev").path,
                               ownBundle: root.appendingPathComponent("Uygulama.app").path,
                               mountPoints: { mounts.value }) { url in
            if failing.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        }
    }
    @MainActor private var target: DiskTarget { DiskTarget(path: root.path, name: "Taranan", kind: .folder) }

    @MainActor private func wait(_ manager: DiskScanManager, seconds: Double = 20,
                                 until done: @MainActor (DiskScanManager) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(manager) {
            guard Date() < deadline else { XCTFail("Timed out in phase \(manager.phase), rows \(manager.rows.map(\.name))"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor private func settled(_ manager: DiskScanManager) async throws {
        try await wait(manager) { $0.phase == .finished && !$0.loading && !$0.trashing }
    }
    @MainActor private func row(_ manager: DiskScanManager, _ name: String) throws -> DiskRow {
        try XCTUnwrap(manager.rows.first { $0.name == name }, name)
    }

    @MainActor func testScanListsLargestFirstAndBrowsesFolders() async throws {
        let manager = makeManager()
        manager.scan(target)
        XCTAssertEqual(manager.phase, .scanning)
        try await settled(manager)

        XCTAssertEqual(manager.rows.map(\.name), ["projeler", "film.mkv", "Uygulama.app", "kucuk.txt"])
        XCTAssertEqual(manager.currentPath, root.path)
        XCTAssertEqual(manager.currentSize, manager.scannedSize)
        XCTAssertEqual(manager.trail.first?.fileCount, 5)
        XCTAssertEqual(manager.unreadable, 0)

        manager.open(try row(manager, "film.mkv"))
        XCTAssertEqual(manager.trail.count, 1, "A file is not a place to go")
        manager.open(try row(manager, "projeler"))
        try await settled(manager)
        XCTAssertEqual(manager.rows.map(\.name), ["eski", "notlar.txt"])
        XCTAssertEqual(manager.currentPath, root.path + "/projeler")
        manager.open(try row(manager, "eski"))
        try await settled(manager)
        XCTAssertEqual(manager.rows.map(\.name), ["derleme.bin"])
        manager.goUp(to: 0)
        try await settled(manager)
        XCTAssertEqual(manager.currentPath, root.path)
        XCTAssertEqual(manager.rows.count, 4)
    }

    @MainActor func testTrashMovesOnlyTheChosenRowsAndLowersTheTotals() async throws {
        let manager = makeManager()
        manager.scan(target)
        try await settled(manager)
        let before = manager.scannedSize
        manager.open(try row(manager, "projeler"))
        try await settled(manager)
        let folderBefore = manager.currentSize
        let old = try row(manager, "eski")
        let oldSize = try XCTUnwrap(old.size)

        manager.toggle(old)
        XCTAssertEqual(manager.selectedRows.map(\.name), ["eski"])
        XCTAssertEqual(DiskScanManager.totalSize(of: manager.selectedRows), oldSize)
        manager.trash(manager.selectedRows)
        XCTAssertTrue(manager.trashing)
        manager.goUp(to: 0)
        XCTAssertEqual(manager.trail.count, 2, "The folder stays put while its items are moving")
        try await settled(manager)

        XCTAssertFalse(exists("projeler/eski"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("eski/derleme.bin").path))
        XCTAssertTrue(exists("projeler/notlar.txt"))
        XCTAssertEqual(manager.rows.map(\.name), ["notlar.txt"])
        XCTAssertEqual(manager.trashed, oldSize)
        XCTAssertEqual(manager.currentSize, folderBefore - oldSize)
        XCTAssertEqual(manager.scannedSize, before - oldSize)
        XCTAssertTrue(manager.selection.isEmpty)
        XCTAssertNil(manager.problem)

        // A single file, from the top folder: every total above it follows.
        manager.goUp(to: 0)
        try await settled(manager)
        XCTAssertEqual(manager.rows.first?.name, "film.mkv", "The emptied folder is no longer the largest")
        let film = try row(manager, "film.mkv")
        manager.trash([film])
        try await settled(manager)
        XCTAssertFalse(exists("film.mkv"))
        XCTAssertEqual(manager.scannedSize, before - oldSize - (film.size ?? 0))
        XCTAssertEqual(manager.trail.first?.fileCount, 3)
    }

    @MainActor func testProtectedAndForeignRowsAreNeverTrashed() async throws {
        let manager = makeManager()
        manager.scan(target)
        try await settled(manager)
        let app = try row(manager, "Uygulama.app")
        XCTAssertTrue(manager.isProtected(app))
        manager.toggle(app)
        XCTAssertTrue(manager.selection.isEmpty)
        // Not a row of the open folder, though it lies inside the scanned one.
        let stranger = DiskRow(name: "notlar.txt", path: root.path + "/projeler/notlar.txt", isDirectory: false,
                               size: 4_096, fileCount: nil, unreadable: false, node: nil)
        manager.selection = [app.id, stranger.id]
        XCTAssertTrue(manager.selectedRows.isEmpty)
        manager.trash([app, stranger])
        XCTAssertFalse(manager.trashing)
        try await settled(manager)
        XCTAssertTrue(exists("Uygulama.app/Contents/ikili"))
        XCTAssertTrue(exists("projeler/notlar.txt"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [])
    }

    @MainActor func testAFailedMoveIsReportedAndLeavesTheTotalsAlone() async throws {
        let manager = makeManager(failing: ["film.mkv"])
        manager.scan(target)
        try await settled(manager)
        let before = manager.scannedSize
        let small = try row(manager, "kucuk.txt")
        manager.trash([try row(manager, "film.mkv"), small])
        try await settled(manager)
        XCTAssertTrue(exists("film.mkv"))
        XCTAssertFalse(exists("kucuk.txt"))
        XCTAssertEqual(manager.problem?.key, "Çöp Sepeti’ne taşınamadı: %@")
        XCTAssertEqual(manager.problem?.detail?.hasPrefix("film.mkv — "), true)
        XCTAssertEqual(manager.scannedSize, before - (small.size ?? 0))
        XCTAssertEqual(manager.rows.map(\.name), ["projeler", "film.mkv", "Uygulama.app"])
    }

    /// A folder reached through a link must be judged by where it really is: otherwise
    /// "link/Documents" would not be recognised as the protected Documents folder.
    @MainActor func testAScanStartedThroughALinkUsesTheRealPath() async throws {
        let home = directory.appendingPathComponent("ev", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5_000).write(to: home.appendingPathComponent("Documents/rapor.pdf"))
        try Data(repeating: 1, count: 9_000).write(to: home.appendingPathComponent("eski.zip"))
        let link = directory.appendingPathComponent("kisayol")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)

        let manager = makeManager()
        manager.scan(DiskTarget(path: link.path, name: "Kısayol", kind: .folder))
        XCTAssertEqual(manager.target?.path, home.path)
        try await settled(manager)
        XCTAssertEqual(manager.currentPath, home.path)
        XCTAssertEqual(manager.rows.map(\.name), ["eski.zip", "Documents"])
        let documents = try row(manager, "Documents")
        XCTAssertEqual(documents.path, home.path + "/Documents")
        XCTAssertTrue(manager.isProtected(documents))
        XCTAssertFalse(manager.isProtected(try row(manager, "eski.zip")))
        manager.trash([documents])
        try await settled(manager)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/rapor.pdf").path))
    }

    /// The home folder may itself be named through a link; rows carry real paths.
    @MainActor func testHomeGivenThroughALinkStillProtectsItsFolders() async throws {
        let home = directory.appendingPathComponent("ev", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("kisayol")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        let manager = makeManager(home: link.path)
        manager.scan(DiskTarget(path: home.path, name: "Ev", kind: .home))
        try await settled(manager)
        XCTAssertEqual(manager.lock(for: try row(manager, "Documents")), .required)
    }

    /// The previous folder's rows must not stay clickable while the next folder is read:
    /// a double-click would otherwise open the same folder inside itself.
    @MainActor func testRowsOfTheFolderJustLeftCannotBeUsed() async throws {
        let manager = makeManager()
        manager.scan(target)
        try await settled(manager)
        let projects = try row(manager, "projeler"), film = try row(manager, "film.mkv")
        manager.open(projects)
        XCTAssertTrue(manager.rows.isEmpty)
        manager.open(projects)
        manager.trash([film])
        XCTAssertEqual(manager.trail.count, 2)
        XCTAssertFalse(manager.trashing)
        try await settled(manager)
        XCTAssertEqual(manager.currentPath, root.path + "/projeler")
        XCTAssertEqual(manager.rows.map(\.name), ["eski", "notlar.txt"])

        let old = try row(manager, "eski")
        manager.goUp(to: 0)
        XCTAssertTrue(manager.rows.isEmpty)
        manager.trash([old])
        manager.open(old)
        try await settled(manager)
        XCTAssertEqual(manager.currentPath, root.path)
        XCTAssertTrue(exists("projeler/eski/derleme.bin"))
        XCTAssertTrue(exists("film.mkv"))
        XCTAssertNil(manager.problem)

        // A listing on its way when the result is replaced and the scan stopped.
        manager.reload()
        manager.scan(target)
        manager.cancelScan()
        XCTAssertFalse(manager.loading)
    }

    /// The scan leaves a mounted volume out, so the folder holding it looks almost
    /// empty; trashing that folder would take the whole volume along.
    @MainActor func testAFolderWithAVolumeMountedInsideIsLocked() async throws {
        mounts.value = [root.path + "/projeler/eski"]
        let manager = makeManager()
        manager.scan(target)
        try await settled(manager)
        XCTAssertEqual(manager.skipped, 1)
        let projects = try row(manager, "projeler")
        XCTAssertEqual(manager.lock(for: projects), .required)
        manager.trash([projects])
        XCTAssertFalse(manager.trashing)
        manager.open(projects)
        try await settled(manager)
        let volume = try row(manager, "eski")
        XCTAssertNil(volume.size)
        XCTAssertNotNil(manager.lock(for: volume))
        XCTAssertNil(manager.lock(for: try row(manager, "notlar.txt")))

        // A disk connected after the scan is noticed when something is about to move.
        manager.goUp(to: 0)
        try await settled(manager)
        let film = try row(manager, "film.mkv")
        XCTAssertNil(manager.lock(for: film))
        mounts.value.insert(film.path)
        manager.trash([film])
        XCTAssertFalse(manager.trashing)
        XCTAssertTrue(exists("film.mkv"))
        XCTAssertTrue(exists("projeler/eski/derleme.bin"))
    }

    @MainActor func testUnmeasuredChangedAndLinkedItemsAreHandledSafely() async throws {
        try FileManager.default.linkItem(at: root.appendingPathComponent("film.mkv"), to: root.appendingPathComponent("projeler/film-kopya.mkv"))
        let manager = makeManager()
        manager.scan(target)
        try await settled(manager)
        let before = manager.scannedSize

        // A folder created after the scan has no total: nothing is known about it.
        try write("sonradan/buyuk.bin", bytes: 700_000)
        manager.reload()
        try await settled(manager)
        let late = try row(manager, "sonradan")
        XCTAssertEqual(manager.lock(for: late), .unmeasured)
        manager.toggle(late)
        XCTAssertTrue(manager.selection.isEmpty)
        manager.trash([late])
        XCTAssertFalse(manager.trashing)
        XCTAssertEqual(manager.lock(for: DiskRow(name: "bulut.pdf", path: root.path + "/bulut.pdf", isDirectory: false, size: 0,
                                                 fileCount: nil, unreadable: false, node: nil, cloudOnly: true)), .unmeasured)

        // The name the user approved now belongs to something else.
        let small = try row(manager, "kucuk.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("kucuk.txt"))
        try write("kucuk.txt/icerik.bin", bytes: 50_000)
        manager.trash([small])
        try await settled(manager)
        XCTAssertTrue(exists("kucuk.txt/icerik.bin"))
        XCTAssertEqual(manager.problem?.key, "Taramadan sonra değiştiği için taşınmadı: %@")
        XCTAssertEqual(manager.problem?.detail, "kucuk.txt")
        XCTAssertEqual(manager.scannedSize, before)

        // One name of a hard-linked file: gone from the list, nothing claimed as freed.
        manager.open(try row(manager, "projeler"))
        try await settled(manager)
        let copy = try row(manager, "film-kopya.mkv")
        XCTAssertTrue(copy.linked)
        manager.trash([copy])
        try await settled(manager)
        XCTAssertFalse(exists("projeler/film-kopya.mkv"))
        XCTAssertTrue(exists("film.mkv"))
        XCTAssertEqual(manager.trashed, 0)
        XCTAssertEqual(manager.scannedSize, before)
        XCTAssertFalse(manager.rows.contains { $0.name == "film-kopya.mkv" })
    }

    @MainActor func testStoppingAndClosingReturnToTheStart() async throws {
        let manager = makeManager()
        manager.scan(target)
        manager.cancelScan()
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNil(manager.target)
        // The stopped scan must not deliver a result later.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertTrue(manager.trail.isEmpty)

        manager.scan(target)
        try await settled(manager)
        manager.close()
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertTrue(manager.rows.isEmpty)
        XCTAssertTrue(manager.trail.isEmpty)

        manager.scan(DiskTarget(path: root.path + "/yok", name: "Yok", kind: .folder))
        try await wait(manager) { $0.phase == .idle }
        XCTAssertEqual(manager.problem?.key, "Bu klasör taranamadı. BStoeq’in bu klasöre erişim izni olmayabilir.")
    }
}
