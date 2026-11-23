import XCTest
@testable import BStoeqCore

/// Works on real folders made for the test; the Trash is a folder of the fixture.
final class DuplicateFilesTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!, trash: URL!

    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        root = URL(fileURLWithPath: temporary).appendingPathComponent("barlet-duplicates-\(UUID().uuidString)")
        trash = root.appendingPathComponent(".TestTrash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    @discardableResult
    private func write(_ relative: String, _ data: Data, age: Int = 0) throws -> String {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if age > 0 {
            let time = timeval(tv_sec: Int(Date().timeIntervalSince1970) - age * 86_400, tv_usec: 0)
            XCTAssertEqual(utimes(url.path, [time, time]), 0)
        }
        return url.path
    }
    private func bytes(_ value: UInt8, _ count: Int, tail: UInt8? = nil) -> Data {
        var data = Data(repeating: value, count: count)
        if let tail { data[count - 1] = tail }
        return data
    }
    private func scan(minimum: Int64 = 1, home: String? = nil) throws -> DuplicateScanResult {
        try XCTUnwrap(DuplicateFinder.scan(root.path, home: home ?? root.appendingPathComponent("no-home").path,
                                           minimumBytes: minimum))
    }
    private func move(_ url: URL) throws {
        try fm.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
    }

    func testGroupsHoldIdenticalContentOnlyOldestFirst() throws {
        let big = DuplicateFinder.headLength * 3
        let newer = try write("a/photo.raw", bytes(1, big), age: 2)
        let oldest = try write("b/deep/photo copy.raw", bytes(1, big), age: 30)
        let third = try write("c/renamed.bin", bytes(1, big), age: 10)
        // Same length and same beginning, another ending: only a full read tells them apart.
        try write("a/almost.raw", bytes(1, big, tail: 9))
        // Same length, another beginning.
        try write("a/other.raw", bytes(2, big))
        let small = try write("notes/a.txt", Data("same words".utf8), age: 5)
        let smallCopy = try write("notes/b.txt", Data("same words".utf8), age: 1)
        try write("notes/c.txt", Data("different!".utf8))
        try write("unique.bin", bytes(3, 4_000))

        let result = try scan()
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups[0].files.map(\.path), [oldest, third, newer], "Largest saving first, oldest copy first")
        XCTAssertEqual(result.groups[1].files.map(\.path), [small, smallCopy])
        XCTAssertEqual(result.groups[0].reclaimable, result.groups[0].files.dropFirst().reduce(0) { $0 + $1.bytes })
        XCTAssertGreaterThanOrEqual(result.groups[0].reclaimable, Int64(big * 2))
        XCTAssertEqual(result.scannedFiles, 9)
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertNotEqual(result.groups[0].id, result.groups[1].id)

        XCTAssertEqual(try scan(minimum: 1_000).groups.map { $0.files.count }, [3], "Files below the minimum are not compared")
    }

    func testHiddenItemsPackagesLibraryLinksAndEmptyFilesAreLeftAlone() throws {
        let data = bytes(5, 20_000)
        let kept = try write("Documents/report.pdf", data)
        let copy = try write("Desktop/report.pdf", data)
        try write(".git/objects/report", data)
        try write("Documents/.hidden.pdf", data)
        try write("Tool.app/Contents/Resources/report.pdf", data)
        try write("Library/Application Support/Tool/report.pdf", data)
        try write("Documents/empty-1", Data())
        try write("Documents/empty-2", Data())
        // Another name of the same file is not a copy, and a link is not followed.
        try fm.linkItem(atPath: kept, toPath: root.appendingPathComponent("Documents/hardlink.pdf").path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Desktop/link.pdf").path, withDestinationPath: kept)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Desktop/folder-link").path,
                                  withDestinationPath: root.appendingPathComponent("Documents").path)

        let result = try scan(home: root.path)
        XCTAssertEqual(result.groups.count, 1)
        let paths = Set(result.groups[0].files.map(\.path))
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains(copy))
        XCTAssertTrue(paths.isSubset(of: [kept, copy, root.appendingPathComponent("Documents/hardlink.pdf").path]))

        // The Library of some other folder is an ordinary folder.
        let elsewhere = try scan()
        XCTAssertEqual(elsewhere.groups.first?.files.count, 3)
    }

    func testLibraryIsLeftAloneUnderTheDataVolumeNameToo() throws {
        let data = bytes(6, 20_000)
        try write("Documents/report.pdf", data)
        try write("Desktop/report.pdf", data)
        try write("Library/Application Support/Tool/report.pdf", data)
        // On the startup disk every folder is also reachable below the data volume.
        let alias = "/System/Volumes/Data" + root.path
        var first = stat(), second = stat()
        guard lstat(root.path, &first) == 0, lstat(alias, &second) == 0,
              first.st_dev == second.st_dev, first.st_ino == second.st_ino else {
            throw XCTSkip("The temporary folder is not on the startup disk's data volume")
        }
        let result = try XCTUnwrap(DuplicateFinder.scan(alias, home: root.path, minimumBytes: 1))
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.files.count, 2)
        XCTAssertFalse(result.groups.flatMap(\.files).contains { $0.path.contains("/Library/") })
        // The same holds when the home folder was given under that name.
        let aliasHome = try XCTUnwrap(DuplicateFinder.scan(root.path, home: alias, minimumBytes: 1))
        XCTAssertEqual(aliasHome.groups.first?.files.count, 2)
    }

    func testScanRefusesFilesAndStopsWhenCancelled() throws {
        let file = try write("single.bin", bytes(1, 10))
        XCTAssertNil(DuplicateFinder.scan(file))
        XCTAssertNil(DuplicateFinder.scan(root.appendingPathComponent("missing").path))
        try write("x/a.bin", bytes(4, 300_000))
        try write("x/b.bin", bytes(4, 300_000))
        XCTAssertNil(DuplicateFinder.scan(root.path, minimumBytes: 1, isCancelled: { true }))
        var stages: [DuplicateScanProgress.Stage] = []
        var last = 0.0
        let result = try XCTUnwrap(DuplicateFinder.scan(root.path, minimumBytes: 1) { progress in
            stages.append(progress.stage)
            XCTAssertGreaterThanOrEqual(progress.fraction, last)
            last = progress.fraction
        })
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(stages.last, .comparing)
        XCTAssertEqual(last, 1)
    }

    func testUnreadableFolderIsCountedNotGuessed() throws {
        try write("open/a.bin", bytes(6, 9_000))
        try write("open/b.bin", bytes(6, 9_000))
        try write("closed/c.bin", bytes(6, 9_000))
        let closed = root.appendingPathComponent("closed").path
        XCTAssertEqual(chmod(closed, 0), 0)
        defer { _ = chmod(closed, 0o700) }
        let result = try scan()
        XCTAssertEqual(result.groups.first?.files.count, 2)
        XCTAssertGreaterThan(result.unreadable, 0)
    }

    func testTrashNeverTakesTheLastUnchangedCopy() throws {
        let data = bytes(7, 50_000)
        let a = try write("a.bin", data, age: 9), b = try write("b.bin", data, age: 6), c = try write("c.bin", data, age: 3)
        let other = bytes(8, 70_000)
        let d = try write("d.bin", other, age: 4), e = try write("e.bin", other, age: 2)
        let groups = try scan().groups
        XCTAssertEqual(groups.count, 2)

        // Every copy selected: nothing would remain, so nothing moves.
        var result = DuplicateFinder.trash(groups, selection: [a, b, c], home: root.path, mountPoints: [], moveToTrash: move)
        XCTAssertEqual(result.skipped.count, 3)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue([a, b, c].allSatisfy(fm.fileExists(atPath:)))

        // The copy that was to stay changed after the scan: its group is left alone.
        try Data("edited".utf8).write(to: URL(fileURLWithPath: d))
        result = DuplicateFinder.trash(groups, selection: [e], home: root.path, mountPoints: [], moveToTrash: move)
        XCTAssertEqual(result.skipped.map(\.path), [e])
        XCTAssertTrue(fm.fileExists(atPath: e))

        // A selected copy that changed stays; the unchanged one goes; failures are reported.
        try Data("also edited".utf8).write(to: URL(fileURLWithPath: b))
        var progress: [Int] = []
        result = DuplicateFinder.trash(groups, selection: [b, c], home: root.path, mountPoints: [],
                                       progress: { progress.append($0) }, moveToTrash: move)
        XCTAssertEqual(result.moved.map(\.path), [c])
        XCTAssertEqual(result.skipped.map(\.path), [b])
        XCTAssertEqual(progress, [1, 2])
        XCTAssertTrue(fm.fileExists(atPath: a))
        XCTAssertFalse(fm.fileExists(atPath: c))

        let fresh = try scan().groups
        XCTAssertTrue(fresh.isEmpty, "One copy of each content is left")
    }

    func testTrashReportsFailuresAndStopsWhenCancelled() throws {
        let data = bytes(9, 30_000)
        let a = try write("a.bin", data, age: 3), b = try write("b.bin", data, age: 2), c = try write("c.bin", data, age: 1)
        let groups = try scan().groups
        var result = DuplicateFinder.trash(groups, selection: [b, c], home: root.path, mountPoints: []) { url in
            if url.path == b { throw CocoaError(.fileWriteNoPermission) }
            try self.move(url)
        }
        XCTAssertEqual(result.failed.map(\.path), [b])
        XCTAssertEqual(result.moved.map(\.path), [c])
        XCTAssertTrue(fm.fileExists(atPath: a))
        result = DuplicateFinder.trash(groups, selection: [b], home: root.path, mountPoints: [],
                                       isCancelled: { true }, moveToTrash: move)
        XCTAssertTrue(result.moved.isEmpty && result.skipped.isEmpty && result.failed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: b))
        XCTAssertNil(groups[0].keeping { $0.path == a })
        XCTAssertEqual(groups[0].keeping { $0.path != c }?.files.count, 2)
    }
}
