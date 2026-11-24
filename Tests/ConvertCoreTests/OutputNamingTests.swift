import os
import XCTest
@testable import ConvertCore

/// Publishing into real folders of the fixture. Volumes that cannot rename exclusively, and a
/// destination on another volume, are stood in for by the injected rename.
final class OutputNamingTests: XCTestCase {
    private let fm = FileManager.default
    private var fixture: ConversionFixture!
    private var staging: URL!, destination: URL!

    override func setUpWithError() throws {
        fixture = try ConversionFixture(area: "naming")
        staging = try fixture.folder("staging")
        destination = try fixture.folder("destination")
    }
    override func tearDownWithError() throws {
        _ = chmod(destination.path, 0o755)
        fixture.remove()
    }

    private func item(_ name: String, _ text: String) throws -> URL {
        let url = staging.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func hidden() -> [String] { ((try? fm.contentsOfDirectory(atPath: destination.path)) ?? []).filter { $0.hasPrefix(".") } }
    private static let real: @Sendable (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
    private static let unsupported: @Sendable (String, String) -> Int32 = { _, _ in ENOTSUP }
    /// Another volume for everything that does not already lie in the folder it is going to.
    private static let foreign: @Sendable (String, String) -> Int32 = { source, target in
        (source as NSString).deletingLastPathComponent == (target as NSString).deletingLastPathComponent ? real(source, target) : EXDEV
    }

    /// Publishes every source from a thread of its own, all let go at the same moment.
    private func race(_ sources: [URL], _ publish: @escaping @Sendable (URL) throws -> URL) -> [URL] {
        let gate = DispatchSemaphore(value: 0), done = DispatchGroup()
        let published = OSAllocatedUnfairLock(initialState: [URL]())
        for source in sources {
            done.enter()
            Thread.detachNewThread {
                gate.wait()
                if let url = try? publish(source) { published.withLock { $0.append(url) } }
                done.leave()
            }
        }
        for _ in sources { gate.signal() }
        done.wait()
        return published.withLock { $0 }
    }

    /// Eight publishers of one name must leave eight files, numbered without a gap, each with its own content.
    private func assertEightDistinct(rounds: Int, _ publish: @escaping @Sendable (URL, URL) throws -> URL,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = ["sonuç.txt"] + (2...8).map { "sonuç \($0).txt" }
        let destination = try fixture.folder("race-\(UUID().uuidString)")
        for round in 0..<rounds {
            let sources = try (0..<8).map { try item("\(round)-\($0).tmp", "\($0)") }
            let published = race(sources) { try publish($0, destination) }
            XCTAssertEqual(published.map(\.lastPathComponent).sorted(), expected.sorted(), "round \(round)", file: file, line: line)
            XCTAssertEqual(Set(published.compactMap(text)), Set((0..<8).map(String.init)), "No result may replace another (round \(round))", file: file, line: line)
            XCTAssertEqual(fixture.names(in: destination), expected.sorted(), file: file, line: line)
            XCTAssertTrue(fixture.names(in: staging).isEmpty, "Every source was moved", file: file, line: line)
            for url in published { try fm.removeItem(at: url) }
        }
    }

    // MARK: Publishing

    func testAResultTakesTheFirstFreeNameAndNeverReplacesWhatIsThere() throws {
        let first = try OutputNaming.publish(try item("a.tmp", "bir"), named: "rapor", extension: "pdf", in: destination)
        XCTAssertEqual(first.lastPathComponent, "rapor.pdf")
        XCTAssertEqual(text(first), "bir")
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("a.tmp").path), "Publishing moves")
        let second = try OutputNaming.publish(try item("b.tmp", "iki"), named: "rapor", extension: "pdf", in: destination)
        let third = try OutputNaming.publish(try item("c.tmp", "üç"), named: "rapor", extension: "pdf", in: destination)
        XCTAssertEqual([second.lastPathComponent, third.lastPathComponent], ["rapor 2.pdf", "rapor 3.pdf"])
        XCTAssertEqual([text(first), text(second), text(third)], ["bir", "iki", "üç"])

        // A gap is filled; a name held by a folder or by a link that leads nowhere is taken all the same.
        try fm.removeItem(at: second)
        XCTAssertEqual(try OutputNaming.publish(try item("d.tmp", "dört"), named: "rapor", extension: "pdf", in: destination).lastPathComponent, "rapor 2.pdf")
        try fm.createDirectory(at: destination.appendingPathComponent("klasör.txt"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: destination.appendingPathComponent("klasör 2.txt").path, withDestinationPath: "/nowhere/at/all")
        let beside = try OutputNaming.publish(try item("e.tmp", "beş"), named: "klasör", extension: "txt", in: destination)
        XCTAssertEqual(beside.lastPathComponent, "klasör 3.txt")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("klasör 2.txt").path), "/nowhere/at/all")

        // No extension, or an empty one.
        XCTAssertEqual(try OutputNaming.publish(try item("f.tmp", "x"), named: "adsız", extension: nil, in: destination).lastPathComponent, "adsız")
        XCTAssertEqual(try OutputNaming.publish(try item("g.tmp", "y"), named: "adsız", extension: "", in: destination).lastPathComponent, "adsız 2")
        XCTAssertEqual(try OutputNaming.publish(try item("h.tmp", "z"), named: "Türkçe şğü İı", extension: "tar.gz", in: destination).lastPathComponent,
                       "Türkçe şğü İı.tar.gz")
    }

    func testAFolderIsPublishedByTheSameSingleRename() throws {
        func pages(_ name: String) throws -> URL {
            let folder = staging.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("1".utf8).write(to: folder.appendingPathComponent("rapor_p1.png"))
            try Data("2".utf8).write(to: folder.appendingPathComponent("rapor_p2.png"))
            return folder
        }
        let first = try OutputNaming.publish(try pages("a"), named: "rapor sayfalar", extension: nil, in: destination)
        XCTAssertEqual(first.lastPathComponent, "rapor sayfalar")
        XCTAssertEqual(fixture.names(in: first), ["rapor_p1.png", "rapor_p2.png"])
        let second = try OutputNaming.publish(try pages("b"), named: "rapor sayfalar", extension: nil, in: destination)
        XCTAssertEqual(second.lastPathComponent, "rapor sayfalar 2")
        XCTAssertEqual(fixture.names(in: first).count, 2, "The first folder was not merged into or replaced")

        // An empty folder of that name is somebody's folder too.
        try fm.createDirectory(at: destination.appendingPathComponent("boş"), withIntermediateDirectories: false)
        XCTAssertEqual(try OutputNaming.publish(try pages("c"), named: "boş", extension: nil, in: destination).lastPathComponent, "boş 2")
        XCTAssertTrue(fixture.names(in: destination.appendingPathComponent("boş")).isEmpty)
        // And so is a file.
        try Data("dosya".utf8).write(to: destination.appendingPathComponent("ad"))
        XCTAssertEqual(try OutputNaming.publish(try pages("d"), named: "ad", extension: nil, in: destination).lastPathComponent, "ad 2")
        XCTAssertEqual(text(destination.appendingPathComponent("ad")), "dosya")
    }

    func testTheSameNamePublishedFromEightThreadsFiveHundredTimesGivesEightDistinctFilesEveryTime() throws {
        try assertEightDistinct(rounds: 500) { try OutputNaming.publish($0, named: "sonuç", extension: "txt", in: $1) }
    }

    func testAVolumeWithoutExclusiveRenameClaimsTheNameFirst() throws {
        try Data("eski".utf8).write(to: destination.appendingPathComponent("foto.png"))
        let published = try OutputNaming.publish(try item("a.tmp", "yeni"), named: "foto", extension: "png", in: destination, exclusive: Self.unsupported)
        XCTAssertEqual(published.lastPathComponent, "foto 2.png")
        XCTAssertEqual(text(published), "yeni", "The claim was replaced by the result")
        XCTAssertEqual(text(destination.appendingPathComponent("foto.png")), "eski")
        XCTAssertEqual(try OutputNaming.publish(try item("b.tmp", "ilk"), named: "başka", extension: "png", in: destination, exclusive: Self.unsupported).lastPathComponent, "başka.png")

        // Folders: the claim is an empty folder, and only that is renamed over.
        let pages = staging.appendingPathComponent("pages", isDirectory: true)
        try fm.createDirectory(at: pages, withIntermediateDirectories: false)
        try Data("1".utf8).write(to: pages.appendingPathComponent("p1.png"))
        try fm.createDirectory(at: destination.appendingPathComponent("sayfalar"), withIntermediateDirectories: false)
        let folder = try OutputNaming.publish(pages, named: "sayfalar", extension: nil, in: destination, exclusive: Self.unsupported)
        XCTAssertEqual(folder.lastPathComponent, "sayfalar 2")
        XCTAssertEqual(fixture.names(in: folder), ["p1.png"])
        XCTAssertTrue(fixture.names(in: destination.appendingPathComponent("sayfalar")).isEmpty)

        // A rename that fails gives its claim back and leaves the item where it was.
        let lost = staging.appendingPathComponent("never-written.tmp")
        XCTAssertThrowsError(try OutputNaming.publish(lost, named: "yok", extension: "png", in: destination, exclusive: Self.unsupported)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("yok.png").path), "No empty claim is left behind")

        try assertEightDistinct(rounds: 150) { try OutputNaming.publish($0, named: "sonuç", extension: "txt", in: $1, exclusive: Self.unsupported) }
    }

    func testAnotherVolumeIsReachedThroughAHiddenCopyInTheDestination() throws {
        try Data("eski".utf8).write(to: destination.appendingPathComponent("film.mp4"))
        let source = try item("a.tmp", "yeni")
        let published = try OutputNaming.publish(source, named: "film", extension: "mp4", in: destination, exclusive: Self.foreign)
        XCTAssertEqual(published.lastPathComponent, "film 2.mp4")
        XCTAssertEqual(text(published), "yeni")
        XCTAssertEqual(text(destination.appendingPathComponent("film.mp4")), "eski")
        XCTAssertFalse(fm.fileExists(atPath: source.path), "The work copy is gone once the result is in place")
        XCTAssertTrue(hidden().isEmpty, "Nothing hidden stays in the user's folder")

        let pages = staging.appendingPathComponent("pages", isDirectory: true)
        try fm.createDirectory(at: pages, withIntermediateDirectories: false)
        try Data("1".utf8).write(to: pages.appendingPathComponent("p1.png"))
        let folder = try OutputNaming.publish(pages, named: "sayfalar", extension: nil, in: destination, exclusive: Self.foreign)
        XCTAssertEqual(fixture.names(in: folder), ["p1.png"])
        XCTAssertFalse(fm.fileExists(atPath: pages.path))
        XCTAssertTrue(hidden().isEmpty)

        // Both at once: copied over, then claimed.
        let both = try OutputNaming.publish(try item("b.tmp", "iki"), named: "film", extension: "mp4", in: destination) { source, target in
            (source as NSString).deletingLastPathComponent == (target as NSString).deletingLastPathComponent ? ENOTSUP : EXDEV
        }
        XCTAssertEqual(both.lastPathComponent, "film 3.mp4")
        XCTAssertEqual(text(both), "iki")
        XCTAssertTrue(hidden().isEmpty)

        // A volume that keeps refusing: the error comes out, the item stays, no copy is left.
        let kept = try item("c.tmp", "üç")
        XCTAssertThrowsError(try OutputNaming.publish(kept, named: "film", extension: "mp4", in: destination) { _, _ in EXDEV }) { error in
            XCTAssertEqual((error as NSError).code, Int(EXDEV))
        }
        XCTAssertEqual(text(kept), "üç")
        XCTAssertTrue(hidden().isEmpty)
    }

    func testARefusalCarriesItsPOSIXCodeAndLeavesTheItemWhereItWas() throws {
        let source = try item("a.tmp", "x")
        XCTAssertThrowsError(try OutputNaming.publish(source, named: "a", extension: "txt", in: fixture.url("no/such/folder"))) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
        XCTAssertEqual(text(source), "x")
        guard getuid() != 0 else { throw XCTSkip("Root may write anywhere") }
        XCTAssertEqual(chmod(destination.path, 0o555), 0)
        XCTAssertThrowsError(try OutputNaming.publish(source, named: "a", extension: "txt", in: destination)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EACCES))
        }
        XCTAssertThrowsError(try OutputNaming.publish(source, named: "a", extension: "txt", in: destination, exclusive: Self.foreign),
                             "The hidden copy cannot be written either")
        XCTAssertEqual(text(source), "x")
        XCTAssertEqual(chmod(destination.path, 0o755), 0)
        XCTAssertTrue(fixture.names(in: destination).isEmpty)
        XCTAssertTrue(hidden().isEmpty)
    }

    // MARK: Names

    func testAvailableNamesAreOnlyAHint() throws {
        XCTAssertEqual(OutputNaming.available(named: "Arşiv", extension: "zip", in: destination).lastPathComponent, "Arşiv.zip")
        try Data().write(to: destination.appendingPathComponent("Arşiv.zip"))
        try fm.createSymbolicLink(atPath: destination.appendingPathComponent("Arşiv 2.zip").path, withDestinationPath: "/nowhere/at/all")
        XCTAssertEqual(OutputNaming.available(named: "Arşiv", extension: "zip", in: destination).lastPathComponent, "Arşiv 3.zip")
        XCTAssertEqual(OutputNaming.available(named: "Klasör", extension: nil, in: destination).lastPathComponent, "Klasör")
        XCTAssertEqual(fixture.names(in: destination), ["Arşiv 2.zip", "Arşiv.zip"], "Asking takes nothing")
    }

    func testBaseNamesDropTheExtensionTheFormatWasRecognisedBy() throws {
        func base(_ name: String, _ id: String?) -> String {
            OutputNaming.baseName(of: URL(fileURLWithPath: "/x/\(name)"), format: id.flatMap(FormatRegistry.format(id:)))
        }
        XCTAssertEqual(base("foto.JPEG", "jpg"), "foto")
        XCTAssertEqual(base("yedek.tar.gz", "tar.gz"), "yedek")
        XCTAssertEqual(base("yedek.TGZ", "tar.gz"), "yedek")
        XCTAssertEqual(base("a.b.c.png", "png"), "a.b.c")
        XCTAssertEqual(base("Tatil.2024", "folder"), "Tatil.2024", "A folder keeps its whole name")
        XCTAssertEqual(base("notlar.xyz", nil), "notlar")
        XCTAssertEqual(base("adsız", nil), "adsız")
        XCTAssertEqual(base("a.png", "jpg"), "a")
        XCTAssertEqual(base("İstanbul gezisi.heic", "heic"), "İstanbul gezisi")
        XCTAssertEqual(OutputNaming.cleaned("a/b:c"), "a-b-c")
        XCTAssertEqual(OutputNaming.cleaned("12:30 toplantı"), "12-30 toplantı")
        XCTAssertEqual(OutputNaming.cleaned("düz ad"), "düz ad")
    }

    func testNamesAreCutBetweenCharactersNeverInsideOne() {
        XCTAssertEqual(OutputNaming.shortened("abcdef", toBytes: 4), "abcd")
        XCTAssertEqual(OutputNaming.shortened("abcdef", toBytes: 6), "abcdef")
        XCTAssertEqual(OutputNaming.shortened("abcdef", toBytes: 600), "abcdef")
        XCTAssertEqual(OutputNaming.shortened("ğğğğ", toBytes: 5), "ğğ", "Two bytes each: the third does not fit")
        XCTAssertEqual(OutputNaming.shortened("ae\u{301}b", toBytes: 2), "a", "A letter and its accent stay together")
        XCTAssertEqual(OutputNaming.shortened("ab👨‍👩‍👧‍👦cd", toBytes: 10), "ab", "A family is one character of 25 bytes")
        XCTAssertEqual(OutputNaming.shortened("abc def", toBytes: 4), "abc", "No space is left at the cut")
        XCTAssertEqual(OutputNaming.shortened("    x", toBytes: 2), "  ", "A name of spaces is not emptied")
        let family = OutputNaming.shortened("👨‍👩‍👧‍👦", toBytes: 10)
        XCTAssertFalse(family.isEmpty, "One character longer than the limit is cut inside rather than dropped")
        XCTAssertLessThanOrEqual(family.utf8.count, 10)
        XCTAssertEqual(OutputNaming.shortened("abc", toBytes: 0), "")

        // The same names on every run: a fixed sequence, not the system's random numbers.
        struct Sequence: RandomNumberGenerator {
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
        let pieces = ["a", "ğ", "İ", "ş", " ", "日本", "👍🏽", "e\u{301}", "🇹🇷", "x"]
        var generator = Sequence()
        for _ in 0..<300 {
            let name = (0..<Int.random(in: 1...60, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            let limit = Int.random(in: 8...80, using: &generator)
            let cut = OutputNaming.shortened(name, toBytes: limit)
            XCTAssertLessThanOrEqual(cut.utf8.count, limit, name)
            XCTAssertTrue(name.hasPrefix(cut), "A cut name is the beginning of the name: \(name.debugDescription) -> \(cut.debugDescription)")
            if name.utf8.count <= limit { XCTAssertEqual(cut, name) }
        }
    }
}
