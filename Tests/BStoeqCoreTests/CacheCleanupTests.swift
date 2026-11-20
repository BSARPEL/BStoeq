import Darwin
import XCTest
@testable import BStoeqCore

final class CacheCleanupTests: XCTestCase {
    private let manager = FileManager.default
    private let now = Date()
    private var home: URL!
    private var caches: URL!
    private var trash: URL!

    override func setUpWithError() throws {
        let base = try XCTUnwrap(DiskScanner.canonicalPath(manager.temporaryDirectory.path))
        home = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("barlet-cache-tests-\(UUID().uuidString)")
        caches = home.appendingPathComponent("Library/Caches")
        trash = home.appendingPathComponent("test-trash")
        try manager.createDirectory(at: caches, withIntermediateDirectories: true)
        try manager.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try manager.removeItem(at: home)
    }

    private func setAge(of url: URL, accessedDaysAgo: Int, modifiedDaysAgo: Int) throws {
        func timestamp(_ days: Int) -> timeval {
            timeval(tv_sec: Int(now.timeIntervalSince1970) - days * 86_400, tv_usec: 0)
        }
        let dates = [timestamp(accessedDaysAgo), timestamp(modifiedDaysAgo)]
        guard utimes(url.path, dates) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    @discardableResult
    private func write(_ path: String, in directory: URL? = nil, bytes: Int = 16_384,
                       accessedDaysAgo: Int = 45, modifiedDaysAgo: Int = 45) throws -> URL {
        let url = (directory ?? caches!).appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 43, count: bytes).write(to: url)
        try setAge(of: url, accessedDaysAgo: accessedDaysAgo, modifiedDaysAgo: modifiedDaysAgo)
        return url
    }

    private func scan(mounts: Set<String> = []) throws -> CacheScanResult {
        try CacheCleanup.scan(home: home.path, now: now, mountPoints: mounts)
    }

    private func moveToTestTrash(_ url: URL) throws {
        try manager.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    }

    func testGroupsContainOnlyOldLocalCacheFilesAndMeasureAllocatedSize() throws {
        let nested = try write("com.example.App/images/old.bin")
        let loose = try write("loose.bin")
        try write("com.example.App/recently-read.bin", accessedDaysAgo: 1)
        try write("com.example.App/recently-written.bin", modifiedDaysAgo: 1)
        try write("com.example.App/empty.bin", bytes: 0)
        try write("com.example.App/tools/Browser.app/Contents/MacOS/Browser")
        for name in ["cache.sqlite", "cache.sqlite-wal", "process.lock"] {
            try write("com.example.App/" + name)
        }
        let immutable = try write("com.example.App/immutable.bin")
        let didLock = chflags(immutable.path, UInt32(UF_IMMUTABLE)) == 0
        defer { if didLock { _ = chflags(immutable.path, 0) } }
        if !didLock {
            // Some file systems do not support macOS file flags.
            try manager.removeItem(at: immutable)
        }
        let linked = try write("com.example.App/linked.bin")
        try manager.linkItem(at: linked, to: home.appendingPathComponent("other-name.bin"))
        let document = try write("Documents/old.bin", in: home)
        try manager.createSymbolicLink(at: caches.appendingPathComponent("file-link"), withDestinationURL: document)
        try manager.createSymbolicLink(at: caches.appendingPathComponent("folder-link"),
                                       withDestinationURL: document.deletingLastPathComponent())

        let result = try scan()
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertEqual(Set(result.groups.map(\.id)), ["com.example.App", ""])
        let expected = ["com.example.App": nested, "": loose]
        for group in result.groups {
            let url = try XCTUnwrap(expected[group.id])
            XCTAssertEqual(group.files.map(\.path), [url.path])
            var status = stat()
            XCTAssertEqual(lstat(url.path, &status), 0)
            XCTAssertGreaterThan(group.bytes, 0)
            XCTAssertEqual(group.bytes, Int64(status.st_blocks) * 512)
            XCTAssertEqual(group.files.first?.bytes, group.bytes)
        }
    }

    func testCleanUsesReviewedSnapshotAndSkipsNewlyUsedReplacedOrMissingFiles() throws {
        let keep = try write("sample/keep.bin")
        let read = try write("sample/read.bin")
        let replaced = try write("sample/replaced.bin")
        let gone = try write("sample/gone.bin")
        let rewritten = try write("sample/rewritten.bin")
        let reviewed = try scan().groups.flatMap(\.files)
        XCTAssertEqual(reviewed.count, 5)

        try setAge(of: read, accessedDaysAgo: 0, modifiedDaysAgo: 45)
        // Keep the original inode alive while creating the replacement with identical size and dates.
        try manager.moveItem(at: replaced, to: home.appendingPathComponent("original.bin"))
        try write("sample/replaced.bin")
        try manager.removeItem(at: gone)
        let new = try write("sample/after-scan.bin")
        // Overwrite one byte in place to retain the inode and size. It still meets the age cutoff.
        let handle = try FileHandle(forWritingTo: rewritten)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        try setAge(of: rewritten, accessedDaysAgo: 45, modifiedDaysAgo: 35)

        let result = CacheCleanup.clean(reviewed, home: home.path, now: now, mountPoints: [], moveToTrash: moveToTestTrash)
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(result.skipped.count, 4)
        XCTAssertEqual(result.failed.count, 0)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: trash.path), [keep.lastPathComponent])
        XCTAssertTrue(manager.fileExists(atPath: read.path))
        XCTAssertTrue(manager.fileExists(atPath: replaced.path))
        XCTAssertTrue(manager.fileExists(atPath: new.path))
        XCTAssertTrue(manager.fileExists(atPath: rewritten.path))
    }

    func testCandidateCannotBeMovedThroughReplacedParentSymlink() throws {
        let sample = try write("sample/nested/cache.bin")
        let reviewed = try scan().groups.flatMap(\.files)
        XCTAssertEqual(reviewed.map(\.path), [sample.path])
        let parent = sample.deletingLastPathComponent()
        let outside = home.appendingPathComponent("Documents")
        try manager.moveItem(at: parent, to: outside)
        try manager.createSymbolicLink(at: parent, withDestinationURL: outside)
        // The final file still has the reviewed device, inode and timestamps.
        let result = CacheCleanup.clean(reviewed, home: home.path, now: now, mountPoints: [], moveToTrash: moveToTestTrash)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(manager.fileExists(atPath: outside.appendingPathComponent("cache.bin").path))
    }

    func testScanRejectsLinkedCacheRootAndHonorsCancellation() throws {
        try write("sample/cache.bin")
        XCTAssertThrowsError(try CacheCleanup.scan(home: home.path, now: now, mountPoints: [], isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let outside = home.appendingPathComponent("Documents")
        try manager.moveItem(at: caches, to: outside)
        try manager.createSymbolicLink(at: caches, withDestinationURL: outside)
        XCTAssertThrowsError(try scan())
    }

    func testUnreadableSubfolderDoesNotHideResultsFromOtherFolders() throws {
        let locked = try write("sample/closed/private.bin").deletingLastPathComponent()
        let available = try write("sample/open/available.bin")
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o700) }
        try XCTSkipIf(geteuid() == 0, "Root can read a directory with no permission bits.")
        let result = try scan()
        XCTAssertGreaterThanOrEqual(result.unreadable, 1)
        XCTAssertEqual(result.groups.flatMap(\.files).map(\.path), [available.path])
    }

    func testMountedTreesAreExcludedDuringScanAndAtCleanup() throws {
        let otherVolume = try write("sample/mounted/other.bin")
        let ordinary = try write("sample/mounted-sibling/local.bin")
        let mounts: Set<String> = [otherVolume.deletingLastPathComponent().path]
        let reviewed = try scan().groups.flatMap(\.files)
        XCTAssertEqual(reviewed.count, 2)
        XCTAssertEqual(try scan(mounts: mounts).groups.flatMap(\.files).map(\.path), [ordinary.path])

        let result = CacheCleanup.clean(reviewed, home: home.path, now: now, mountPoints: mounts, moveToTrash: moveToTestTrash)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(manager.fileExists(atPath: otherVolume.path))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: trash.path), [ordinary.lastPathComponent])
    }

    func testFailureMovingOneFileLeavesItInPlaceAndAllowsOtherMoves() throws {
        let denied = try write("sample/a.bin")
        let allowed = try write("sample/b.bin")
        let reviewed = try scan().groups.flatMap(\.files).sorted { $0.path < $1.path }
        let result = CacheCleanup.clean(reviewed, home: home.path, now: now, mountPoints: []) { url in
            if url.path == denied.path { throw CocoaError(.fileWriteNoPermission) }
            try self.moveToTestTrash(url)
        }
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(manager.fileExists(atPath: denied.path))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: trash.path), [allowed.lastPathComponent])
    }
}
