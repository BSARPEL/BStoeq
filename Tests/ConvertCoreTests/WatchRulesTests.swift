import XCTest
import ConvertCore

/// What a watched folder takes and when: names, arrival and the same-format rule.
final class WatchRulesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func file(_ size: Int64 = 10, modified: TimeInterval = 0, created: Date? = nil, inode: UInt64 = 7) -> WatchRules.Entry {
        WatchRules.Entry(size: size, modified: start.addingTimeInterval(modified), created: created, inode: inode)
    }
    private func target(_ id: String) throws -> ConversionTarget { try XCTUnwrap(TargetCatalog.target(id: id)) }
    private func format(_ id: String) throws -> FileFormat { try XCTUnwrap(FormatRegistry.format(id: id)) }

    func testHiddenPartialAndScratchNamesAndEverythingButFilesAreIgnored() {
        for name in [".DS_Store", ".photo.png", "~$Rapor.docx", "Rapor.docx~", "Icon\r", "film.mp4.part", "a.PNG.crdownload",
                     "b.png.download", "c.tmp", "Dönüştürülenler", ""] {
            XCTAssertTrue(WatchRules.ignores(name: name, kind: .file, resultsFolder: "Dönüştürülenler"), name)
        }
        for kind in [WatchRules.Kind.folder, .link, .other] {
            XCTAssertTrue(WatchRules.ignores(name: "photo.png", kind: kind, resultsFolder: "Out"), "\(kind)")
        }
        for name in ["photo.png", "Rapor~1.docx", "a~b.txt", "tmp.png", "partial.mp4", "Out.png", "ğüşı.jpg"] {
            XCTAssertFalse(WatchRules.ignores(name: name, kind: .file, resultsFolder: "Out"), name)
        }
        // The disk hands names back decomposed; the results folder still matches.
        let decomposed = "Dönüştürülenler".decomposedStringWithCanonicalMapping
        XCTAssertTrue(WatchRules.ignores(name: decomposed, kind: .file, resultsFolder: "Dönüştürülenler"))
    }

    func testAFileArrivesOnlyAfterStayingTheSameForTheWholeInterval() {
        var candidate = WatchRules.Candidate(entry: file(-1), unchangedSince: start)
        XCTAssertEqual(WatchRules.settle(&candidate, now: file(10), at: start, interval: 5), .waiting, "The first look starts the wait")
        XCTAssertEqual(candidate.unchangedSince, start)
        XCTAssertEqual(WatchRules.settle(&candidate, now: file(10), at: start + 4.9, interval: 5), .waiting)
        XCTAssertEqual(WatchRules.settle(&candidate, now: file(20, modified: 4), at: start + 4.95, interval: 5), .waiting, "It grew")
        XCTAssertEqual(candidate.unchangedSince, start + 4.95)
        XCTAssertEqual(WatchRules.settle(&candidate, now: file(20, modified: 4), at: start + 9, interval: 5), .waiting)
        XCTAssertEqual(WatchRules.settle(&candidate, now: file(20, modified: 4), at: start + 10, interval: 5), .arrived)

        // A new date alone, or a new file saved over it under the same name, starts again.
        XCTAssertEqual(WatchRules.settle(&candidate, now: file(20, modified: 9), at: start + 10.5, interval: 5), .waiting)
        XCTAssertEqual(WatchRules.settle(&candidate, now: file(20, modified: 9, inode: 8), at: start + 16, interval: 5), .waiting)
        XCTAssertEqual(WatchRules.settle(&candidate, now: file(20, modified: 9, inode: 8), at: start + 21, interval: 5), .arrived)
        XCTAssertEqual(WatchRules.settleInterval, 5)
    }

    func testAnEmptyFileAndAFinderCopyInProgressKeepWaitingAndAGoneOneIsForgotten() {
        var empty = WatchRules.Candidate(entry: file(0), unchangedSince: start)
        XCTAssertEqual(WatchRules.settle(&empty, now: file(0), at: start + 60, interval: 5), .waiting)

        let copying = Date(timeIntervalSince1970: 443_779_200)
        XCTAssertEqual(WatchRules.finderCopyDate, copying)
        var copy = WatchRules.Candidate(entry: file(created: copying), unchangedSince: start)
        XCTAssertTrue(WatchRules.isBeingCopied(file(created: copying.addingTimeInterval(-8 * 3600))), "Midnight in UTC is the same day")
        XCTAssertEqual(WatchRules.settle(&copy, now: file(created: copying), at: start + 60, interval: 5), .waiting)
        // Finder sets the real creation date when the copy is done: from then the wait starts.
        let real = start.addingTimeInterval(-86_400)
        XCTAssertEqual(WatchRules.settle(&copy, now: file(created: real), at: start + 61, interval: 5), .waiting)
        XCTAssertEqual(WatchRules.settle(&copy, now: file(created: real), at: start + 66, interval: 5), .arrived)
        XCTAssertFalse(WatchRules.isBeingCopied(file(created: nil)))
        XCTAssertFalse(WatchRules.isBeingCopied(file(created: Date(timeIntervalSince1970: 443_779_200 + 3 * 86_400))))

        var gone = WatchRules.Candidate(entry: file(), unchangedSince: start)
        XCTAssertEqual(WatchRules.settle(&gone, now: nil, at: start + 9, interval: 5), .gone)
        var swapped = WatchRules.Candidate(entry: file(), unchangedSince: start)
        XCTAssertEqual(WatchRules.settle(&swapped, now: WatchRules.Entry(kind: .link, size: 10, modified: start, inode: 7), at: start + 9,
                                         interval: 5), .gone, "A file swapped for a link is not followed")
    }

    func testAFileIsNeverGivenTheFormatItAlreadyHas() throws {
        XCTAssertFalse(WatchRules.accepts(try target("png"), source: try format("png")))
        XCTAssertFalse(WatchRules.accepts(try target("pdf"), source: try format("pdf")))
        XCTAssertFalse(WatchRules.accepts(try target("m4r"), source: try format("m4r")))
        XCTAssertTrue(WatchRules.accepts(try target("png"), source: try format("heic")))
        XCTAssertTrue(WatchRules.accepts(try target("jpg"), source: try format("png")))
        // A variant marks its result, so it may keep the format.
        XCTAssertTrue(WatchRules.accepts(try target("mp4.720p"), source: try format("mp4")))
        XCTAssertTrue(WatchRules.accepts(try target("mp3.128k"), source: try format("mp3")))
        XCTAssertTrue(WatchRules.accepts(try target("alac"), source: try format("m4a")))
        // Tools are not for watched folders, and a file without a format fits nothing.
        XCTAssertFalse(WatchRules.accepts(try target("compress"), source: try format("png")))
        XCTAssertFalse(WatchRules.accepts(try target("png"), source: nil))
        let unmarked = ConversionTarget(id: "png.copy", title: "PNG", format: "png")
        XCTAssertFalse(WatchRules.accepts(unmarked, source: try format("png")))
    }
}
