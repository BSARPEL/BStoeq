import Darwin
import XCTest
@testable import BStoeqCore

final class CacheSourcesTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!
    // A forward clock lets fixture files have old creation and added-to-directory dates.
    private let future = Date().addingTimeInterval(60 * 86_400)

    override func setUpWithError() throws {
        let path = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        home = URL(fileURLWithPath: path).appendingPathComponent("barlet-cache-sources-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    @discardableResult
    private func write(_ path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 11, count: 8192).write(to: url)
        return url
    }

    func testScansOnlyAllowlistedLocationsAndKeepsGroupIDsDistinct() throws {
        let included: [(CacheSource, String)] = [
            (.userCaches, "Library/Caches/shared/image"),
            (.containerCaches, "Library/Containers/shared/Data/Library/Caches/chunk"),
            (.containerCaches, "Library/Containers/another/Data/Library/Caches/chunk"),
            (.groupContainerCaches, "Library/Group Containers/shared/Library/Caches/chunk"),
            (.logs, "Library/Logs/shared/run.log.2.gz"),
            (.logs, "Library/Logs/DiagnosticReports/Archived/BStoeq.ips"),
            (.developerCaches, ".npm/_cacache/tmp/partial"),
            (.developerCaches, ".cache/pip/wheels/ab/dist.whl"),
            (.developerCaches, ".gradle/caches/build-cache-1/" + String(repeating: "a", count: 32)),
            (.xcode, "Library/Developer/Xcode/DerivedData/ModuleCache.noindex/aaa.pcm"),
            (.xcode, "Library/Developer/Xcode/DerivedData/Project/Index.noindex/record"),
            (.xcode, "Library/Developer/Xcode/DerivedData/Project/Build/Intermediates.noindex/target.o"),
            (.installers, "Downloads/Tool.pkg"),
            (.installers, "Downloads/Image.dmg")
        ]
        let ignored = [
            "Library/Containers/shared/Data/Library/Application Support/settings",
            "Library/Containers/shared/Data/Documents/draft.txt",
            "Library/Group Containers/shared/Library/Preferences/keep.plist",
            "Library/Application Support/package/data",
            "Library/Logs/shared/current.log", "Library/Logs/Personal/doc.ips",
            "Library/Developer/Xcode/DerivedData/Project/Build/Products/tool",
            "Library/Developer/Xcode/DerivedData/Project/SourcePackages/checkouts/repo/file.swift",
            ".gradle/caches/build-cache-1/gc.properties", ".gradle/caches/modules-2/jar",
            ".npm/_cacache/content-v2/sha512/object", ".cache/pip/wheels/keep.json",
            "Library/Caches/Python/custom-environment/pyvenv.cfg",
            "Library/Caches/Python/custom-environment/bin/python",
            "Library/Caches/dev-tools/node_modules/module/index.js",
            "Downloads/Personal/archived.dmg", "Downloads/Notes.pdf", "Downloads/Folder.pkg/Contents/meta"
        ]
        for (_, path) in included { try write(path) }
        for path in ignored { try write(path) }

        var scanned: [CacheSource] = []
        let result = try CacheCleanup.scan(home: home.path, now: future, mountPoints: [], progress: { scanned.append($0) })
        XCTAssertEqual(scanned, CacheSource.allCases)
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertEqual(Set(result.groups.map(\.id)).count, result.groups.count)
        for source in CacheSource.allCases {
            let expected = included.filter { $0.0 == source }.map { home.appendingPathComponent($0.1).path }
            let files = result.groups.filter { $0.source == source }.flatMap(\.files)
            XCTAssertEqual(Set(files.map(\.path)), Set(expected), source.rawValue)
        }
        let cache = try XCTUnwrap(result.groups.first { $0.source == .containerCaches && $0.name == "shared" })
        let group = try XCTUnwrap(result.groups.first { $0.source == .groupContainerCaches && $0.name == "shared" })
        XCTAssertNotEqual(cache.id, group.id)
        XCTAssertEqual(cache.replacingFiles(cache.files).source, .containerCaches)
        XCTAssertEqual(cache.replacingFiles(cache.files).name, "shared")
        XCTAssertTrue(result.groups.filter { $0.source == .installers }.allSatisfy { $0.files.count == 1 })
    }

    func testMissingAndUnsafePrimaryCacheDoNotHideOtherSources() throws {
        let report = try write("Library/Logs/DiagnosticReports/old.crash")
        let outside = try write("Documents/private.bin").deletingLastPathComponent()
        let caches = home.appendingPathComponent("Library/Caches")
        func scan() throws -> CacheScanResult {
            try CacheCleanup.scan(home: home.path, now: future, mountPoints: [])
        }
        XCTAssertEqual(try scan().groups.flatMap(\.files).map(\.path), [report.path])
        try fm.createSymbolicLink(at: caches, withDestinationURL: outside)
        let result = try scan()
        XCTAssertGreaterThan(result.unreadable, 0)
        XCTAssertEqual(result.sources.map(\.source), CacheSource.allCases)
        XCTAssertEqual(result.sources.first { $0.source == .logs }?.scannedRoots, 1)
        XCTAssertEqual(result.sources.first { $0.source == .userCaches }?.unreadable, 1)
        XCTAssertEqual(result.sources.first { $0.source == .developerCaches }?.scannedRoots, 0)
        XCTAssertEqual(result.sources.first { $0.source == .developerCaches }?.unreadable, 0)
        XCTAssertEqual(result.groups.flatMap(\.files).map(\.path), [report.path])
    }

    func testContainerAndDownloadsLocationsAreRecheckedDuringCleanup() throws {
        let old = try write("Library/Group Containers/app/Library/Caches/item")
        let image = try write("Downloads/Tool.dmg")
        let scan = try CacheCleanup.scan(home: home.path, now: future, mountPoints: [])
        let files = scan.groups.flatMap(\.files)
        XCTAssertEqual(files.count, 2)
        let blocked = Set([old.deletingLastPathComponent().path, image.deletingLastPathComponent().path])
        let result = CacheCleanup.clean(files, home: home.path, now: future, mountPoints: blocked) { _ in
            XCTFail("An unapproved volume was passed to the mover")
        }
        XCTAssertEqual(result.skipped.count, 2)
        var moved: [URL] = []
        let allowed = CacheCleanup.clean(files.filter { $0.path == old.path }, home: home.path, now: future,
                                         mountPoints: []) { moved.append($0) }
        XCTAssertEqual(allowed.moved.count, 1)
        XCTAssertEqual(moved.map(\.path), [old.path])
    }

    func testRecentlyAddedInstallerWithOldContentDatesRemainsAlone() throws {
        let image = try write("Downloads/Backup.dmg")
        let date = timeval(tv_sec: Int(Date().timeIntervalSince1970) - 60 * 86_400, tv_usec: 0)
        XCTAssertEqual(utimes(image.path, [date, date]), 0)
        let scan = try CacheCleanup.scan(home: home.path, now: Date(), mountPoints: [])
        XCTAssertTrue(scan.groups.isEmpty)
    }

    func testStoppingCleanupReportsAttemptedFilesAndPreservesTheRest() throws {
        try write("Library/Caches/App/first")
        try write("Library/Caches/App/second")
        let files = try CacheCleanup.scan(home: home.path, now: future, mountPoints: []).groups.flatMap(\.files)
        var progress: [Int] = []
        let result = CacheCleanup.clean(files, home: home.path, now: future, mountPoints: [],
                                        isCancelled: { !progress.isEmpty }, progress: { progress.append($0) }) { _ in }
        XCTAssertEqual(progress, [1])
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testChromiumScanRequiresProfileAndDirectEntryShapeAndRechecksMarkers() throws {
        let prefix = "Library/Application Support/Editor/"
        let marker = try write(prefix + "Local State")
        let entries = ["Cache/Cache_Data/abcd0123456789ef_0", "Code Cache/js/abcd0123456789ef_1",
                       "GPUCache/f_009abc", "Code Cache/wasm/abcd0123456789ef_s"]
        for path in entries { try write(prefix + path) }
        for path in ["Cache/Cache_Data/index", "Cache/Cache_Data/Personal/report.txt",
                     "Cache/Cache_Data/Personal/abcd0123456789ef_0", "GPUCache/data_0",
                     "Database/abcd0123456789ef_0", "Default/Cache/Cache_Data/abcd0123456789ef_0"] {
            try write(prefix + path)
        }
        try write("Library/Application Support/Personal/Cache/Cache_Data/abcd0123456789ef_0")
        let scan = try CacheCleanup.scan(home: home.path, now: future, mountPoints: [])
        let files = scan.groups.filter { $0.source == .browserCaches }.flatMap(\.files)
        XCTAssertEqual(Set(files.map(\.path)), Set(entries.map { home.appendingPathComponent(prefix + $0).path }))
        try fm.removeItem(at: marker)
        let result = CacheCleanup.clean(files, home: home.path, now: future, mountPoints: []) { _ in
            XCTFail("The directory lost its profile marker")
        }
        XCTAssertEqual(result.skipped.count, entries.count)
    }
}
