import XCTest
@testable import BStoeqCore

/// Scans real folders made for the test. Sizes are compared with what `lstat`
/// reports, never with fixed numbers, since allocation depends on the file system.
final class DiskScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The scanner reports the path it was given, so use the resolved one.
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("barlet-disk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        _ = chmod(root.appendingPathComponent("kilitli").path, 0o700)
        _ = chmod(root.appendingPathComponent("aranamaz").path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }
    private func allocated(_ relative: String) -> Int64 {
        var status = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent(relative).path, &status), 0, relative)
        return Int64(status.st_blocks) * 512
    }
    private func child(_ node: DiskNode, _ name: String) throws -> DiskNode {
        try XCTUnwrap(node.children.first { $0.name == name }, name)
    }

    func testFolderTotalsAddUpAndHardLinksCountOnce() throws {
        try write("a/buyuk.bin", bytes: 300_000)
        try write("a/alt/kucuk.bin", bytes: 10_000)
        try write("b/orta.bin", bytes: 50_000)
        try FileManager.default.linkItem(at: root.appendingPathComponent("a/buyuk.bin"),
                                         to: root.appendingPathComponent("b/kopya.bin"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("kisayol").path,
                                                   withDestinationPath: root.appendingPathComponent("a").path)

        let result = try XCTUnwrap(DiskScanner.scan(root.path))
        let a = try child(result.root, "a"), b = try child(result.root, "b")
        XCTAssertEqual(result.root.name, root.path)
        XCTAssertEqual(Set(result.root.children.map(\.name)), ["a", "b"], "A link to a folder is a file, not a folder")
        XCTAssertEqual(try child(a, "alt").size, allocated("a/alt") + allocated("a/alt/kucuk.bin"))
        XCTAssertGreaterThanOrEqual(allocated("a/buyuk.bin"), 300_000)

        // The linked file is charged to whichever folder is read first, and only once.
        let together = allocated("a") + allocated("a/alt") + allocated("a/alt/kucuk.bin") + allocated("a/buyuk.bin")
            + allocated("b") + allocated("b/orta.bin")
        XCTAssertEqual(a.size + b.size, together)
        XCTAssertEqual(a.fileCount + b.fileCount, 3)
        XCTAssertEqual(result.root.size, together + allocated("") + allocated("kisayol"))
        XCTAssertEqual(result.root.fileCount, 4)
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertEqual(result.skipped, 0)
    }

    func testTotalMatchesDu() throws {
        for index in 0..<40 { try write("d\(index % 5)/f\(index).bin", bytes: 1_000 + index * 7_919) }
        let result = try XCTUnwrap(DiskScanner.scan(root.path))
        let du = Process(), pipe = Pipe()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        du.arguments = ["-sk", root.path]; du.standardOutput = pipe
        try du.run(); du.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let kilobytes = try XCTUnwrap(Int64(output.split(whereSeparator: \.isWhitespace).first ?? ""))
        XCTAssertEqual(result.root.size, kilobytes * 1024)
        XCTAssertEqual(result.root.fileCount, 40)
    }

    func testUnreadableFolderIsReportedNotCountedAsEmpty() throws {
        try write("acik/dosya.bin", bytes: 20_000)
        try write("kilitli/gizli.bin", bytes: 20_000)
        XCTAssertEqual(chmod(root.appendingPathComponent("kilitli").path, 0), 0)

        let result = try XCTUnwrap(DiskScanner.scan(root.path))
        XCTAssertEqual(result.unreadable, 1)
        XCTAssertTrue(try child(result.root, "kilitli").unreadable)
        XCTAssertEqual(try child(result.root, "kilitli").fileCount, 0)
        XCTAssertFalse(try child(result.root, "acik").unreadable)
        XCTAssertEqual(result.root.fileCount, 1)
    }

    /// A folder that may be listed but not entered (mode 600) is as closed as one that
    /// may not be listed: it must not pass for an empty folder.
    func testListableButClosedFolderIsReportedOnce() throws {
        try write("aranamaz/bir.bin", bytes: 20_000)
        try write("aranamaz/iki.bin", bytes: 20_000)
        try write("acik/dosya.bin", bytes: 20_000)
        XCTAssertEqual(chmod(root.appendingPathComponent("aranamaz").path, 0o600), 0)

        let result = try XCTUnwrap(DiskScanner.scan(root.path))
        XCTAssertTrue(try child(result.root, "aranamaz").unreadable)
        XCTAssertEqual(result.unreadable, 1, "One closed folder, however many files it holds")
        XCTAssertFalse(result.root.unreadable)
        XCTAssertEqual(result.root.fileCount, 1)
    }

    func testHardLinksAreMarkedAndLeaveTheTotalsAlone() throws {
        try write("a/asil.bin", bytes: 300_000)
        try write("b/tek.bin", bytes: 10_000)
        try FileManager.default.linkItem(at: root.appendingPathComponent("a/asil.bin"), to: root.appendingPathComponent("b/kopya.bin"))
        let scanned = try XCTUnwrap(DiskScanner.scan(root.path)).root
        let b = try child(scanned, "b")
        let rows = DiskListing.rows(try DiskListing.items(at: root.path + "/b"), of: b, at: root.path + "/b")
        let copy = try XCTUnwrap(rows.first { $0.name == "kopya.bin" }), single = try XCTUnwrap(rows.first { $0.name == "tek.bin" })
        XCTAssertTrue(copy.linked)
        XCTAssertFalse(single.linked)
        XCTAssertFalse(copy.cloudOnly)
        // Whichever folder the scan charged, removing one name frees nothing.
        let before = [scanned.size, b.size, Int64(scanned.fileCount)]
        DiskTree.remove(copy, from: [scanned, b])
        XCTAssertEqual([scanned.size, b.size, Int64(scanned.fileCount)], before)
        DiskTree.remove(single, from: [scanned, b])
        XCTAssertEqual(scanned.size, before[0] - (single.size ?? 0))
    }

    func testAFolderThatGrewSinceTheScanIsMeasuredAgain() throws {
        try write("klasor/a.bin", bytes: 100_000)
        try write("diger/b.bin", bytes: 5_000)
        let scanned = try XCTUnwrap(DiskScanner.scan(root.path)).root
        func folderRow() throws -> DiskRow {
            let rows = DiskListing.rows(try DiskListing.items(at: root.path), of: scanned, at: root.path)
            return try XCTUnwrap(rows.first { $0.name == "klasor" })
        }
        let measured = try folderRow()
        guard case .current = DiskTree.check(measured) else { return XCTFail("Nothing changed yet") }
        let rootBefore = scanned.size, filesBefore = scanned.fileCount

        // Deep enough that the folder's own entry does not change.
        try write("klasor/derin/sonradan.bin", bytes: 900_000)
        let stale = try folderRow()
        XCTAssertEqual(stale.size, measured.size, "The listing still shows what the scan measured")
        guard case .changed(let fresh?) = DiskTree.check(stale) else { return XCTFail("The growth went unnoticed") }
        XCTAssertEqual(fresh.name, "klasor")
        XCTAssertEqual(fresh.size, ["klasor", "klasor/a.bin", "klasor/derin", "klasor/derin/sonradan.bin"].reduce(0) { $0 + allocated($1) })
        XCTAssertEqual(fresh.fileCount, 2)

        DiskTree.replace(stale, with: fresh, in: [scanned])
        XCTAssertEqual(scanned.size, rootBefore + fresh.size - (measured.size ?? 0))
        XCTAssertEqual(scanned.fileCount, filesBefore + 1)
        let current = try folderRow()
        XCTAssertEqual(current.size, fresh.size)
        XCTAssertEqual(current.fileCount, 2)
        guard case .current = DiskTree.check(current) else { return XCTFail("The new measurement is the folder's own") }

        // Files and folders without a measurement have nothing to compare.
        let rows = DiskListing.rows(try DiskListing.items(at: root.path + "/diger"), of: try child(scanned, "diger"), at: root.path + "/diger")
        guard case .current = DiskTree.check(try XCTUnwrap(rows.first)) else { return XCTFail("A file is not measured again") }
        try FileManager.default.removeItem(at: root.appendingPathComponent("klasor"))
        guard case .changed(nil) = DiskTree.check(current) else { return XCTFail("A missing folder cannot be current") }
    }

    func testAnUntouchedFolderWithAFileChargedElsewhereIsCurrent() throws {
        try write("a/ortak.bin", bytes: 300_000)
        try write("b/tek.bin", bytes: 10_000)
        try FileManager.default.linkItem(at: root.appendingPathComponent("a/ortak.bin"), to: root.appendingPathComponent("b/ortak.bin"))
        let scanned = try XCTUnwrap(DiskScanner.scan(root.path)).root
        // The scan charged the shared file to one folder; measured alone, each holds it.
        XCTAssertNotEqual(try child(scanned, "a").size + (try child(scanned, "b").size),
                          try XCTUnwrap(DiskScanner.scan(root.path + "/a")).root.size + (try XCTUnwrap(DiskScanner.scan(root.path + "/b")).root.size))
        for row in DiskListing.rows(try DiskListing.items(at: root.path), of: scanned, at: root.path) {
            guard case .current = DiskTree.check(row) else { return XCTFail("\(row.name) did not change") }
        }
    }

    func testAFileThatArrivedAfterTheScanLeavesTheTotalsAlone() throws {
        try write("eski.bin", bytes: 300_000)
        try write("alt/ic.bin", bytes: 40_000)
        let scanned = try XCTUnwrap(DiskScanner.scan(root.path)).root
        let before = scanned.size, files = scanned.fileCount
        try write("gec.bin", bytes: 2_000_000)
        let rows = DiskListing.rows(try DiskListing.items(at: root.path), of: scanned, at: root.path)
        let late = try XCTUnwrap(rows.first { $0.name == "gec.bin" }), old = try XCTUnwrap(rows.first { $0.name == "eski.bin" })
        XCTAssertEqual(late.size, allocated("gec.bin"))
        DiskTree.remove(late, from: [scanned])
        XCTAssertEqual([scanned.size, Int64(scanned.fileCount)], [before, Int64(files)], "It was never part of the totals")
        DiskTree.remove(old, from: [scanned])
        XCTAssertEqual([scanned.size, Int64(scanned.fileCount)], [before - (old.size ?? 0), Int64(files - 1)])
    }

    func testCancelledMissingAndFileRootsGiveNoResult() throws {
        try write("dosya.bin", bytes: 100)
        XCTAssertNil(DiskScanner.scan(root.path, isCancelled: { true }))
        XCTAssertNil(DiskScanner.scan(root.appendingPathComponent("yok").path))
        XCTAssertNil(DiskScanner.scan(root.appendingPathComponent("dosya.bin").path))
        XCTAssertNotNil(DiskScanner.scan(root.path))
    }

    func testProgressIsReportedDuringALongScan() throws {
        for index in 0..<2_100 { try write("cok/f\(index)", bytes: 0) }
        var reports: [DiskScanProgress] = []
        var checks = 0
        // Slow the walk down just enough for the reporting interval to pass.
        let result = DiskScanner.scan(root.path, isCancelled: { checks += 1; usleep(120_000); return false }) { reports.append($0) }
        XCTAssertEqual(result?.root.fileCount, 2_100)
        XCTAssertGreaterThanOrEqual(checks, 2)
        let last = try XCTUnwrap(reports.last)
        XCTAssertGreaterThan(last.files, 0)
        XCTAssertTrue(last.path.hasPrefix(root.path))
    }

    /// The system volumes under this folder are separate mounts on every Mac. The data
    /// volume shares its device number with the startup disk, so only its path tells.
    func testOtherVolumesAreLeftOut() throws {
        let mounts = DiskScanner.mountPoints()
        XCTAssertTrue(mounts.contains("/"))
        try XCTSkipUnless(mounts.contains("/System/Volumes/Data"), "No separate data volume on this system")
        let result = try XCTUnwrap(DiskScanner.scan("/System/Volumes", mountPoints: mounts))
        XCTAssertGreaterThanOrEqual(result.skipped, 1)
        XCTAssertFalse(result.root.children.contains { $0.name == "Data" })
        // What remains are the empty folders of volumes that are not mounted.
        XCTAssertFalse(result.root.children.contains { mounts.contains("/System/Volumes/" + $0.name) })
        XCTAssertLessThan(result.root.size, 1_000_000)

        // A volume mounted below the data volume is known by two names; both are left out.
        try write("disk/dosya.bin", bytes: 50_000)
        try write("kalan.bin", bytes: 10_000)
        let alias = try XCTUnwrap(DiskScanner.scan(root.path, mountPoints: ["/System/Volumes/Data" + root.path + "/disk"]))
        XCTAssertEqual(alias.skipped, 1)
        XCTAssertEqual(alias.root.fileCount, 1)
        XCTAssertTrue(alias.root.children.isEmpty)
        XCTAssertEqual(DiskScanner.scan(root.path, mountPoints: [root.path + "/diskx"])?.root.fileCount, 2)
    }

    func testRowsJoinLiveItemsWithTheScanLargestFirst() throws {
        try write("buyuk/a.bin", bytes: 400_000)
        try write("kucuk/b.bin", bytes: 5_000)
        try write("orta.bin", bytes: 100_000)
        let scanned = try XCTUnwrap(DiskScanner.scan(root.path)).root
        // Both appear after the scan: the file has a size of its own, the folder has none yet.
        try write("yeni/c.bin", bytes: 900_000)
        try write("sonradan.bin", bytes: 1)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("kisayol").path, withDestinationPath: "/")

        let rows = DiskListing.rows(try DiskListing.items(at: root.path), of: scanned, at: root.path)
        XCTAssertEqual(rows.prefix(3).map(\.name), ["buyuk", "orta.bin", "kucuk"])
        XCTAssertEqual(rows.last?.name, "yeni")
        XCTAssertNil(rows.last?.size)
        XCTAssertNil(rows.last?.node)
        XCTAssertEqual(rows.first?.size, allocated("buyuk") + allocated("buyuk/a.bin"))
        XCTAssertEqual(rows.first?.fileCount, 1)
        XCTAssertEqual(rows.first?.path, root.path + "/buyuk")
        let link = try XCTUnwrap(rows.first { $0.name == "kisayol" })
        XCTAssertFalse(link.isDirectory, "A link is never opened as the folder it points to")
        XCTAssertEqual(DiskListing.join("/", "Users"), "/Users")
        XCTAssertThrowsError(try DiskListing.items(at: root.appendingPathComponent("yok").path))
    }

    func testCanonicalPathResolvesLinksAndLetterCase() throws {
        try write("Gercek/dosya.bin", bytes: 10)
        let real = try XCTUnwrap(DiskScanner.canonicalPath(root.appendingPathComponent("Gercek").path))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("kisayol").path, withDestinationPath: real)
        XCTAssertEqual(DiskScanner.canonicalPath(root.appendingPathComponent("kisayol").path), real)
        XCTAssertEqual(DiskScanner.canonicalPath(root.appendingPathComponent("kisayol/../kisayol/").path), real)
        XCTAssertEqual(DiskScanner.canonicalPath("/tmp"), "/private/tmp")
        XCTAssertNil(DiskScanner.canonicalPath(root.appendingPathComponent("yok").path))
        // On the usual case-insensitive disk a differently typed name is the same folder.
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("GERCEK").path) {
            XCTAssertEqual(DiskScanner.canonicalPath(root.appendingPathComponent("GERCEK").path), real)
        }
        // A link given as the root is not walked at all; the caller resolves it first.
        XCTAssertNil(DiskScanner.scan(root.appendingPathComponent("kisayol").path))
    }

    func testRemovingAnItemLowersEveryFolderAboveIt() {
        let deep = DiskNode(name: "deep", size: 300, fileCount: 3)
        let open = DiskNode(name: "open", size: 1_000, fileCount: 10, children: [deep])
        let top = DiskNode(name: "top", size: 5_000, fileCount: 50, children: [open])
        let folder = DiskRow(name: "deep", path: "/top/open/deep", isDirectory: true, size: 300, fileCount: 3, unreadable: false, node: deep)
        DiskTree.remove(folder, from: [top, open])
        XCTAssertTrue(open.children.isEmpty)
        XCTAssertEqual([open.size, top.size], [700, 4_700])
        XCTAssertEqual([open.fileCount, top.fileCount], [7, 47])

        let file = DiskRow(name: "f", path: "/top/open/f", isDirectory: false, size: 200, fileCount: nil, unreadable: false, node: nil)
        DiskTree.remove(file, from: [top, open])
        XCTAssertEqual([open.size, top.size], [500, 4_500])
        XCTAssertEqual([open.fileCount, top.fileCount], [6, 46])

        // A folder the scan never measured has nothing to subtract.
        let unknown = DiskRow(name: "n", path: "/top/open/n", isDirectory: true, size: nil, fileCount: nil, unreadable: false, node: nil)
        DiskTree.remove(unknown, from: [top, open])
        XCTAssertEqual([open.size, top.size], [500, 4_500])
        let huge = DiskRow(name: "h", path: "/top/open/h", isDirectory: false, size: 9_999, fileCount: nil, unreadable: false, node: nil)
        DiskTree.remove(huge, from: [top, open])
        XCTAssertEqual([open.size, top.size], [0, 0], "Totals never go below zero")
    }

    func testFoldersTheSystemNeedsAreProtected() {
        let home = "/Users/deneme"
        func protected(_ path: String) -> Bool {
            DiskSafety.isProtected(path, home: home, volumes: ["/", "/Volumes/Yedek", home + "/is/kalip/birim"],
                                   ownBundle: "/Applications/BStoeq.app")
        }
        for path in ["/", "/System", "/System/Library/Fonts/Helvetica.ttc", "/usr/bin/swift", "/usr/local", "/Library",
                     "/Applications", "/Users", "/Users/baskasi", home, home + "/", home + "/Library", home + "/Documents",
                     home + "/Library/Application Support", home + "/.Trash", home + "/.Trash/eski.zip",
                     "/Volumes/Yedek", "/Volumes/Yedek/", "/private/var/db/receipts", "/Library/Apple/usr",
                     // A folder with another volume mounted somewhere inside it.
                     home + "/is", home + "/is/kalip", home + "/is/kalip/birim",
                     home + "/Library/Mobile Documents/com~apple~CloudDocs", home + "/Library/CloudStorage/Dropbox",
                     "/private/var/folders/xx", "/private/var/folders/xx/yyyy/T", "/var/folders/xx/yyyy/C",
                     "/Applications/BStoeq.app", "/Applications/BStoeq.app/Contents/MacOS/BStoeq",
                     "/System/Volumes/Data", "/System/Volumes/Data/Users/deneme/Documents", "/System/Volumes/Data/Applications",
                     "goreli/yol", home + "/Downloads/../Documents", ""] {
            XCTAssertTrue(protected(path), path)
        }
        for path in [home + "/Documents/rapor.pdf", home + "/Library/Caches/com.example.app", home + "/Downloads/film.mkv",
                     home + "/Library/Developer", home + "/Systematik", "/Applications/Xcode.app", "/Applications/BStoeq.app.zip",
                     "/usr/local/bin/arac", "/Library/Caches/com.example", "/Volumes/Yedek/arsiv", "/Users/Shared/oyun",
                     "/System/Volumes/Data/Users/deneme/Downloads/film.mkv", "/opt/homebrew",
                     home + "/isler", home + "/is/baska", home + "/is/kalip/birimler",
                     home + "/Library/Mobile Documents/com~apple~CloudDocs/eski.zip",
                     "/private/var/folders/xx/yyyy/T/onbellek", "/private/var/folders/xx/yyyy/C/com.example/veri"] {
            XCTAssertFalse(protected(path), path)
        }
    }

    /// Measures a real folder: `BSTOEQ_SCAN_PATH=/Applications swift test --filter RealFolder`.
    func testScanOfARealFolderWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["BSTOEQ_SCAN_PATH"] else {
            throw XCTSkip("Set BSTOEQ_SCAN_PATH to measure a real folder")
        }
        // The scanner's own peak memory; a figure for the whole test run would include the build.
        func peak() -> Int { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return usage.ru_maxrss / 1_048_576 }
        let before = peak()
        let start = Date()
        let result = try XCTUnwrap(DiskScanner.scan(path, mountPoints: DiskScanner.mountPoints()))
        print("PEAK MB before \(before) after \(peak())")
        var folders = 0
        func count(_ node: DiskNode) { folders += 1; node.children.forEach(count) }
        count(result.root)
        print(String(format: "SCAN %@: %lld bytes, %d files, %d folders, %d unreadable, %d skipped, %.2f s",
                     path, result.root.size, result.root.fileCount, folders, result.unreadable, result.skipped,
                     Date().timeIntervalSince(start)))
        for node in result.root.children.sorted(by: { $0.size > $1.size }).prefix(8) {
            print(String(format: "  %12lld  %@", node.size, node.name))
        }
    }
}
