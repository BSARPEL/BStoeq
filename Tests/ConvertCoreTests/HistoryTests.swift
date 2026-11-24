import XCTest
@testable import ConvertCore

/// Records are made from results whose files are real files of the fixture.
final class HistoryTests: XCTestCase {
    private let fm = FileManager.default
    private var fixture: ConversionFixture!

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "history") }
    override func tearDownWithError() throws { fixture.remove() }

    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func finished(_ sources: [URL], _ outcomes: [ConversionOutcome], target: String = "png", notices: [String] = [],
                        trashed: Bool = false) throws -> ConversionResult {
        ConversionResult(job: try fixture.job(sources, target: target), sources: sources, outcomes: outcomes, notices: notices,
                         originalsTrashed: trashed)
    }
    /// A later edit: more bytes and a newer date, as an editor that saves in place leaves them.
    private func edit(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("düzenlendi".utf8))
        try handle.close()
    }
    private func backdate(_ url: URL, seconds: Int) {
        let time = timeval(tv_sec: Int(Date().timeIntervalSince1970) - seconds, tv_usec: 0)
        XCTAssertEqual(utimes(url.path, [time, time]), 0)
    }
    private func pages(_ name: String, count: Int = 3) throws -> URL {
        let folder = try fixture.folder(name)
        for page in 1...count { try fixture.write("\(name)/rapor_p\(page).png", Data(repeating: UInt8(page), count: 100 * page)) }
        return folder
    }

    // MARK: Making

    func testARecordKeepsWhatHappenedToEverySource() throws {
        let sources = try ["a.heic", "b.heic", "c.heic", "d.heic", "e.heic"].map { try fixture.write("in/\($0)") }
        let output = try fixture.write("in/a.png", Data(repeating: 1, count: 321))
        let result = try finished(sources, [.converted([output]), .failed(ConversionFailure("Bu görüntü okunamadı.")),
                                          .skipped("Bu dosya bu biçime dönüştürülemiyor."),
                                          .failed(ConversionFailure("Dönüştürülemedi: %@", detail: "ayrıntı")), .cancelled],
                                notices: ["Yalnızca ilk kare dönüştürüldü."], trashed: true)
        let record = ConversionRecord.make(from: result, origin: .donut, date: date)
        XCTAssertEqual(record.id, result.job.id, "A record is found again by its job")
        XCTAssertEqual(record.date, date)
        XCTAssertEqual(record.origin, .donut)
        XCTAssertEqual([record.targetID, record.targetTitle], ["png", "PNG"])
        XCTAssertFalse(record.titleIsKey)
        XCTAssertEqual(record.sources, sources.map(\.path))
        XCTAssertEqual(record.outputs.map(\.path), [output.path])
        XCTAssertEqual(record.outputs[0].bytes, 321)
        XCTAssertTrue(record.outputs[0].files.isEmpty)
        XCTAssertEqual(record.problems, [
            ConversionRecord.Problem(source: sources[1].path, key: "Bu görüntü okunamadı.", failed: true),
            ConversionRecord.Problem(source: sources[2].path, key: "Bu dosya bu biçime dönüştürülemiyor.", failed: false),
            ConversionRecord.Problem(source: sources[3].path, key: "Dönüştürülemedi: %@", detail: "ayrıntı", failed: true)])
        XCTAssertEqual([record.converted, record.failures, record.skipped], [1, 2, 1])
        XCTAssertTrue(record.wasCancelled)
        XCTAssertEqual(record.notices, ["Yalnızca ilk kare dönüştürüldü."])
        XCTAssertTrue(record.originalsTrashed)

        let tool = ConversionRecord.make(from: try finished([sources[0]], [.skipped("Zaten yeterince küçük.")], target: "compress"),
                                         origin: .watch, date: date)
        XCTAssertEqual([tool.targetID, tool.targetTitle], ["compress", "Sıkıştır"])
        XCTAssertTrue(tool.titleIsKey)
        XCTAssertEqual(tool.origin, .watch)
        XCTAssertTrue(tool.outputs.isEmpty)
        XCTAssertFalse(tool.wasCancelled || tool.originalsTrashed)
    }

    func testAMergeIsOneOutputAndAFolderIsRecordedWithItsFiles() throws {
        let sources = try ["a.pdf", "b.pdf", "c.pdf"].map { try fixture.write("in/\($0)") }
        let merged = try fixture.write("in/a birleşik.pdf", Data(repeating: 2, count: 50))
        let merge = ConversionRecord.make(from: try finished(sources, Array(repeating: .converted([merged]), count: 3), target: "pdf.merge"),
                                          origin: .page, date: date)
        XCTAssertEqual(merge.outputs.count, 1, "Every participant reports the same output; it is recorded once")
        XCTAssertEqual(merge.converted, 3)

        let folder = try pages("in/rapor sayfalar")
        try fixture.write("in/rapor sayfalar/ek/not.txt", Data("ek".utf8))
        let split = ConversionRecord.make(from: try finished([sources[0]], [.converted([folder])], target: "pdf.split"), origin: .page, date: date)
        XCTAssertEqual(split.outputs.count, 1)
        XCTAssertEqual(split.outputs[0].path, folder.path)
        XCTAssertEqual(split.outputs[0].files.map(\.path), ["ek/not.txt", "rapor_p1.png", "rapor_p2.png", "rapor_p3.png"], "Relative paths, sorted")
        XCTAssertEqual(split.outputs[0].files.map(\.bytes), [2, 100, 200, 300])
        // The same reading is there for results the engine did not make, such as archives.
        XCTAssertEqual(ConversionRecord.Output(recording: folder), split.outputs[0])
        XCTAssertEqual(ConversionRecord.Output(recording: merged), merge.outputs[0])
        XCTAssertNil(ConversionRecord.Output(recording: fixture.url("in/never.png")))

        let gone = ConversionRecord.make(from: try finished([sources[0]], [.converted([fixture.url("in/never.png")])]), origin: .page, date: date)
        XCTAssertTrue(gone.outputs.isEmpty, "An output that is not there cannot be undone")
        XCTAssertEqual(gone.converted, 1)
    }

    func testProblemsAreCappedButStillCounted() throws {
        let sources = (0..<120).map { fixture.url("in/\($0).heic") }
        let outcomes: [ConversionOutcome] = (0..<120).map { $0 % 3 == 0 ? .skipped("Bu dosya bu biçime dönüştürülemiyor.") : .failed(ConversionFailure("Dosya bulunamadı.")) }
        let record = ConversionRecord.make(from: try finished(sources, outcomes), origin: .page, date: date)
        XCTAssertEqual(record.problems.count, ConversionRecord.problemLimit)
        XCTAssertEqual(ConversionRecord.problemLimit, 50)
        XCTAssertEqual(record.problems.first?.source, sources[0].path, "The first ones are kept")
        XCTAssertEqual([record.converted, record.failures, record.skipped], [0, 80, 40])

        let direct = ConversionRecord(date: date, origin: .page, targetID: "png", targetTitle: "PNG", titleIsKey: false,
                                      sources: ["/a", "/b", "/c"], outputs: [],
                                      problems: [ConversionRecord.Problem(source: "/a", key: "k", failed: true),
                                                 ConversionRecord.Problem(source: "/b", key: "k", failed: false)])
        XCTAssertEqual([direct.converted, direct.failures, direct.skipped], [1, 1, 1], "Without counts given, the lists are counted")
    }

    // MARK: Undo and retry

    func testASingleFileMayBeUndoneOnlyWhileItIsTheFileThatWasWritten() throws {
        let source = try fixture.write("in/a.heic")
        let kept = try fixture.write("in/a.png", Data(repeating: 1, count: 500))
        let edited = try fixture.write("in/b.png", Data(repeating: 2, count: 500))
        let touched = try fixture.write("in/c.png", Data(repeating: 3, count: 500))
        let replaced = try fixture.write("in/d.png", Data(repeating: 4, count: 500))
        let removed = try fixture.write("in/e.png", Data(repeating: 5, count: 500))
        let linked = try fixture.write("in/f.png", Data(repeating: 6, count: 500))
        let outputs = [kept, edited, touched, replaced, removed, linked]
        for output in outputs { backdate(output, seconds: 3600) }
        let record = ConversionRecord.make(from: try finished(Array(repeating: source, count: 6), outputs.map { .converted([$0]) }), origin: .page, date: date)
        XCTAssertEqual(record.unchangedOutputs(), outputs)

        try edit(edited)
        backdate(touched, seconds: 60)                                // same bytes, another date
        try fm.removeItem(at: replaced)
        try Data(repeating: 9, count: 500).write(to: replaced)        // another file of the same size
        try fm.removeItem(at: removed)
        try fm.moveItem(at: linked, to: fixture.url("in/elsewhere.png"))
        try fm.createSymbolicLink(at: linked, withDestinationURL: fixture.url("in/elsewhere.png"))
        XCTAssertEqual(record.unchangedOutputs(), [kept], "Anything the user changed, replaced or moved stays out of an undo")
    }

    func testAFolderMayBeUndoneWholeOnlyWhileItHoldsExactlyWhatWasWritten() throws {
        let source = try fixture.write("in/rapor.pdf")
        let folder = try pages("in/rapor sayfalar")
        let record = ConversionRecord.make(from: try finished([source], [.converted([folder])], target: "pdf.split"), origin: .page, date: date)
        func page(_ number: Int) -> URL { folder.appendingPathComponent("rapor_p\(number).png") }
        XCTAssertEqual(record.unchangedOutputs().map(\.path), [folder.path], "Untouched: the folder itself goes")

        // Finder's own file does not make the folder the user's.
        try fixture.write("in/rapor sayfalar/.DS_Store", Data([0, 1, 2]))
        XCTAssertEqual(record.unchangedOutputs().map(\.path), [folder.path])

        // The folder's own size and date do not change when a file inside is edited: the files decide.
        try edit(page(2))
        XCTAssertEqual(record.unchangedOutputs().map(\.path), [page(1).path, page(3).path], "The edited page and the folder stay")

        // A file the user added keeps the folder as well.
        let again = try pages("in/yeni sayfalar")
        let second = ConversionRecord.make(from: try finished([source], [.converted([again])], target: "pdf.split"), origin: .page, date: date)
        try fixture.write("in/yeni sayfalar/notlarım.txt", Data("benim".utf8))
        XCTAssertEqual(second.unchangedOutputs().map(\.lastPathComponent), ["rapor_p1.png", "rapor_p2.png", "rapor_p3.png"])
        try fm.removeItem(at: again.appendingPathComponent("notlarım.txt"))
        XCTAssertEqual(second.unchangedOutputs().map(\.path), [again.path])
        // So does an empty folder or a link inside, and a missing page.
        try fixture.folder("in/yeni sayfalar/alt")
        XCTAssertEqual(second.unchangedOutputs().count, 3)
        try fm.removeItem(at: again.appendingPathComponent("alt"))
        try fm.createSymbolicLink(at: again.appendingPathComponent("kısayol"), withDestinationURL: source)
        XCTAssertEqual(second.unchangedOutputs().count, 3)
        try fm.removeItem(at: again.appendingPathComponent("kısayol"))
        try fm.removeItem(at: again.appendingPathComponent("rapor_p1.png"))
        XCTAssertEqual(second.unchangedOutputs().map(\.lastPathComponent), ["rapor_p2.png", "rapor_p3.png"])
        // A folder that is gone, or replaced by a file, gives nothing.
        try fm.removeItem(at: again)
        XCTAssertTrue(second.unchangedOutputs().isEmpty)
        try Data("dosya".utf8).write(to: again)
        XCTAssertTrue(second.unchangedOutputs().isEmpty)
    }

    // An extracted archive is recorded through `Output(recording:)`: files in nested folders, folders
    // that hold nothing, and whatever `.DS_Store` files travelled in the archive.
    private func extracted(_ folder: URL) throws -> ConversionRecord {
        ConversionRecord(date: date, origin: .donut, targetID: "action.extract", targetTitle: DonutAction.extract.title, titleIsKey: true,
                         sources: [folder.path + ".zip"], outputs: [try XCTUnwrap(ConversionRecord.Output(recording: folder))])
    }

    func testAnExtractedTreeWithEmptyFoldersIsUndoneAsOneFolder() throws {
        let project = try fixture.folder("x/Proje")
        for index in 1...12 { try fixture.write("x/Proje/Kaynak/Modül \(index % 4)/\(index).swift", Data(repeating: 7, count: index)) }
        try fixture.write("x/Proje/BENİOKU.md")
        try fixture.write("x/Proje/.gizli")
        try fixture.folder("x/Proje/Çıktı")
        try fixture.folder("x/Proje/Kaynak/Boş/İç")
        let record = try extracted(project)
        let files = record.outputs[0].files.map(\.path)
        XCTAssertEqual(files.filter { $0.hasSuffix("/") }, ["Kaynak/Boş/İç/", "Çıktı/"], "A folder that holds nothing is written down as one")
        XCTAssertEqual(files.filter { !$0.hasSuffix("/") }.count, 14, "Hidden files are files")
        XCTAssertEqual(record.unchangedOutputs(), [project], "Nothing was touched: one item goes to the Trash, not every file by itself")
        let stored = try JSONDecoder().decode(ConversionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(stored.unchangedOutputs(), [project])

        // Something of the user's in a folder that was empty keeps the tree, as it does anywhere else.
        let added = try fixture.write("x/Proje/Çıktı/benim.txt")
        XCTAssertEqual(record.unchangedOutputs().count, 14, "The unchanged files; the folders stay")
        XCTAssertFalse(record.unchangedOutputs().contains { $0.path.hasPrefix(project.path + "/Çıktı") })
        try fm.removeItem(at: added)
        XCTAssertEqual(record.unchangedOutputs(), [project])
        // So does an empty folder that is gone, or that is a file now.
        try fm.removeItem(at: fixture.url("x/Proje/Kaynak/Boş/İç"))
        XCTAssertEqual(record.unchangedOutputs().count, 14)
        try fixture.write("x/Proje/Kaynak/Boş/İç")
        XCTAssertEqual(record.unchangedOutputs().count, 14)
        try fm.removeItem(at: fixture.url("x/Proje/Kaynak/Boş/İç"))
        try fixture.folder("x/Proje/Kaynak/Boş/İç")
        XCTAssertEqual(record.unchangedOutputs(), [project])
        // And a folder the user added.
        try fixture.folder("x/Proje/Yeni")
        XCTAssertEqual(record.unchangedOutputs().count, 14)
    }

    func testFindersOwnFilesAreNeverPartOfAResultNorAChangeToOne() throws {
        let folder = try fixture.folder("y/Proje")
        try fixture.write("y/Proje/a.txt")
        try fixture.write("y/Proje/.DS_Store", Data("from the archive".utf8))
        try fixture.write("y/Proje/alt/.DS_Store", Data("from the archive".utf8))
        let record = try extracted(folder)
        XCTAssertEqual(record.outputs[0].files.map(\.path), ["a.txt", "alt/"], "A folder with nothing but Finder's file holds nothing")
        // Finder rewrites its view settings when the user looks into the folder.
        try Data("rewritten by Finder, a little longer".utf8).write(to: fixture.url("y/Proje/.DS_Store"))
        try fm.removeItem(at: fixture.url("y/Proje/alt/.DS_Store"))
        XCTAssertEqual(record.unchangedOutputs(), [folder])

        // A record that lists such a file all the same is not held back by it.
        let page = try XCTUnwrap(record.outputs[0].files.first)
        let listed = ConversionRecord(date: date, origin: .page, targetID: "png", targetTitle: "PNG", titleIsKey: false, sources: [],
                                      outputs: [ConversionRecord.Output(path: folder.path, bytes: 0, modified: date, files: [
                                        page, ConversionRecord.Entry(path: "alt/", bytes: 0, modified: date),
                                        ConversionRecord.Entry(path: ".DS_Store", bytes: 16, modified: date)])])
        XCTAssertEqual(listed.unchangedOutputs(), [folder])
    }

    func testATreeOfFoldersOnlyAndAnEmptyFolderCanBeUndone() throws {
        let skeleton = try fixture.folder("z/İskelet")
        try fixture.folder("z/İskelet/a/b")
        try fixture.folder("z/İskelet/c")
        let record = try extracted(skeleton)
        XCTAssertEqual(record.outputs[0].files.map(\.path), ["a/b/", "c/"])
        XCTAssertEqual(record.unchangedOutputs(), [skeleton])
        try fixture.write("z/İskelet/a/b/benim.txt")
        XCTAssertTrue(record.unchangedOutputs().isEmpty, "Nothing in it is unchanged work of ours, and the folder is the user's now")

        let empty = try fixture.folder("z/Boş")
        let hollow = try extracted(empty)
        XCTAssertEqual(hollow.outputs[0].files.map(\.path), ["./"], "The published folder itself held nothing")
        XCTAssertEqual(hollow.unchangedOutputs(), [empty])
        try fixture.write("z/Boş/.DS_Store")
        XCTAssertEqual(hollow.unchangedOutputs(), [empty])
        try fixture.write("z/Boş/benim.txt")
        XCTAssertTrue(hollow.unchangedOutputs().isEmpty)
        try fm.removeItem(at: empty)
        try fixture.write("z/Boş", Data())
        XCTAssertTrue(hollow.unchangedOutputs().isEmpty, "A file where the folder was is not the folder")

        // A single file is never taken for a folder: a folder in its place gives nothing.
        let file = try fixture.write("z/tek.png", Data(repeating: 1, count: 10))
        let single = try extracted(file)
        XCTAssertTrue(single.outputs[0].files.isEmpty)
        try fm.removeItem(at: file)
        try fixture.folder("z/tek.png")
        XCTAssertTrue(single.unchangedOutputs().isEmpty)
    }

    func testStoredPathsCannotPointOutsideTheirFolder() throws {
        let folder = try pages("in/sayfalar", count: 1)
        let outside = try fixture.write("in/dışarıda.txt", Data("benim".utf8))
        var status = stat()
        XCTAssertEqual(lstat(outside.path, &status), 0)
        let modified = Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9)
        for path in ["../dışarıda.txt", outside.path, "x/../../dışarıda.txt", "../", "/", "../in/"] {
            let record = ConversionRecord(date: date, origin: .page, targetID: "png", targetTitle: "PNG", titleIsKey: false, sources: [],
                                          outputs: [ConversionRecord.Output(path: folder.path, bytes: 0, modified: date, files: [
                                            ConversionRecord.Entry(path: path, bytes: 5, modified: modified)])])
            XCTAssertTrue(record.unchangedOutputs().isEmpty, path)
        }
    }

    func testOnlyFailedSourcesThatStillExistCanBeRetried() throws {
        let failed = try fixture.write("in/a.heic"), gone = try fixture.write("in/b.heic"), skipped = try fixture.write("in/c.heic")
        let record = ConversionRecord.make(from: try finished([failed, gone, skipped, failed], [
            .failed(ConversionFailure("Bu görüntü okunamadı.")), .failed(ConversionFailure("Bu görüntü okunamadı.")),
            .skipped("Bu dosya bu biçime dönüştürülemiyor."), .failed(ConversionFailure("Bu görüntü okunamadı."))]), origin: .page, date: date)
        try fm.removeItem(at: gone)
        XCTAssertEqual(record.retryable(), [failed], "Each once; a skip is not a failure; a file that is gone cannot be tried")
    }

    // MARK: Stored form

    func testRecordsSurviveStorageWithAnyDateStrategyAndStillRecogniseTheirFiles() throws {
        let source = try fixture.write("in/a.heic")
        let file = try fixture.write("in/a.png", Data(repeating: 1, count: 500))
        let folder = try pages("in/rapor sayfalar")
        let record = ConversionRecord.make(from: try finished([source, source, source], [.converted([file]), .converted([folder]),
                                                                                       .failed(ConversionFailure("Dönüştürülemedi: %@", detail: "x"))],
                                                            notices: ["not"], trashed: true), origin: .watch, date: date)
        let plain = try JSONDecoder().decode(ConversionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(plain, record)
        XCTAssertEqual(plain.unchangedOutputs().map(\.path), [file.path, folder.path])

        // A strategy that rounds dates to seconds must not make every output look changed.
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
        let rounded = try decoder.decode(ConversionRecord.self, from: encoder.encode(record))
        XCTAssertEqual(rounded.date, date)
        XCTAssertEqual(rounded.outputs, record.outputs)
        XCTAssertEqual(rounded.unchangedOutputs().map(\.path), [file.path, folder.path])
        XCTAssertEqual(try JSONDecoder().decode([ConversionRecord].self, from: JSONEncoder().encode([record, record])).count, 2)
    }

    func testHistoryFromAnotherVersionStillLoads() throws {
        func decode(_ json: String) throws -> ConversionRecord { try JSONDecoder().decode(ConversionRecord.self, from: Data(json.utf8)) }
        let empty = try decode("{}")
        XCTAssertEqual(empty.origin, .page)
        XCTAssertEqual([empty.targetID, empty.targetTitle], ["", ""])
        XCTAssertTrue(empty.sources.isEmpty && empty.outputs.isEmpty && empty.problems.isEmpty && empty.notices.isEmpty)
        XCTAssertEqual([empty.converted, empty.failures, empty.skipped], [0, 0, 0])
        XCTAssertFalse(empty.titleIsKey || empty.originalsTrashed || empty.wasCancelled)
        XCTAssertTrue(empty.unchangedOutputs().isEmpty && empty.retryable().isEmpty)

        let odd = try decode(#"""
        {"id":"not-a-uuid","date":"yesterday","origin":"service","targetID":"png","targetTitle":7,"titleIsKey":"yes",
         "sources":["/a","/b","/c"],"notices":"none","originalsTrashed":1,"future":{"x":1},
         "outputs":[{"path":"/x/a.png","bytes":10,"modified":700000000.5,"files":[{"path":"p1.png","bytes":3,"modified":1}, 5, {"path":7}]},
                    "junk", {"path":"/x/b.png"}],
         "problems":[{"source":"/b","key":"Bu görüntü okunamadı.","failed":true}, 9, {"source":"/c","key":"k"}]}
        """#)
        XCTAssertEqual(odd.origin, .page, "An origin this version does not know")
        XCTAssertEqual(odd.targetID, "png")
        XCTAssertEqual(odd.targetTitle, "")
        XCTAssertEqual(odd.sources, ["/a", "/b", "/c"])
        XCTAssertTrue(odd.notices.isEmpty)
        XCTAssertEqual(odd.outputs.map(\.path), ["/x/a.png", "/x/b.png"], "A malformed element drops only itself")
        XCTAssertEqual(odd.outputs[0].files.map(\.path), ["p1.png", ""])
        XCTAssertEqual(odd.outputs[0].modified, Date(timeIntervalSinceReferenceDate: 700_000_000.5))
        XCTAssertEqual(odd.outputs[1].bytes, -1, "A size nobody wrote down matches no file")
        XCTAssertEqual(odd.problems.map(\.source), ["/b", "/c"])
        XCTAssertEqual(odd.problems.map(\.failed), [true, false])
        XCTAssertEqual([odd.converted, odd.failures, odd.skipped], [1, 1, 1], "Counts a file lacks are taken from its lists")
        XCTAssertTrue(odd.unchangedOutputs().isEmpty)
        XCTAssertThrowsError(try decode("5"), "Only something that is no record at all fails")
    }
}
