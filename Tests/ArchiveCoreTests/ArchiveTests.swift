import XCTest
@testable import ArchiveCore

final class ArchiveTests: XCTestCase {
    var folder: URL!
    var service: ArchiveService!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bstoeq-archive-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        service = ArchiveService(tool: root.appendingPathComponent("Resources/Tools/7zz"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func file(_ name: String, contents: String = "Hello, Türkçe, Deutsch!\n") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url); return url
    }
    func create(_ files: [URL], name: String, format: ArchiveFormat = .zip, password: String = "", volume: Int = 0) async throws -> URL {
        var options = ArchiveOptions(); options.format = format; options.volumeMB = volume
        let result = try await service.create(files: files, at: folder.appendingPathComponent(name), options: options, password: password, control: JobControl())
        return try XCTUnwrap(result.first)
    }
    func testZIPRoundTripUnicodeNestedAndLiteralNames() async throws {
        _ = try file("source/İstanbul/bericht.txt")
        let literal = try file("source/[not-a-glob]*?.txt", contents: "literal")
        let archive = try await create([literal.deletingLastPathComponent()], name: "archive.zip")
        let listing = try await service.list(archive, control: JobControl())
        XCTAssertTrue(listing.entries.contains { $0.path == "source/[not-a-glob]*?.txt" })
        XCTAssertTrue(listing.entries.contains { $0.path == "source/İstanbul/bericht.txt" })
        _ = try await service.test(archive, control: JobControl())
        let out = try await service.extract(archive, to: folder, paths: ["source/[not-a-glob]*?.txt"], control: JobControl())
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("source/[not-a-glob]*?.txt"), encoding: .utf8), "literal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("source/İstanbul/bericht.txt").path))
    }
    func testEncrypted7zHeaderPasswordAndRoundTrip() async throws {
        let source = try file("secret.txt")
        let archive = try await create([source], name: "secret.7z", format: .sevenZip, password: "türkçe-password-42")
        do { _ = try await service.list(archive, control: JobControl()); XCTFail("Encrypted names must require password") }
        catch ArchiveError.password { }
        let listing = try await service.list(archive, password: "türkçe-password-42", control: JobControl())
        XCTAssertTrue(listing.encrypted)
        do { _ = try await service.test(archive, password: "wrong", control: JobControl()); XCTFail("Wrong password accepted") }
        catch ArchiveError.password { }
        let out = try await service.extract(archive, to: folder, password: "türkçe-password-42", control: JobControl())
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: out.appendingPathComponent("secret.txt")))
    }
    func testAESZIPPassword() async throws {
        let source = try file("protected.txt")
        let archive = try await create([source], name: "protected.zip", password: "secret-123")
        let listing = try await service.list(archive, control: JobControl())
        XCTAssertTrue(listing.encrypted)
        _ = try await service.test(archive, password: "secret-123", control: JobControl())
        let out = try await service.extract(archive, to: folder, password: "secret-123", control: JobControl())
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: out.appendingPathComponent("protected.txt")))
    }
    func testEditsAreRealAndOriginalIsBackedUp() async throws {
        let archive = try await create([file("a.txt"), file("b.txt")], name: "edit.zip")
        let original = try Data(contentsOf: archive)
        try await service.edit(archive, operation: .rename("a.txt", "renamed.txt"), control: JobControl())
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathExtension("backup")), original)
        try await service.edit(archive, operation: .delete(["b.txt"]), control: JobControl())
        try await service.edit(archive, operation: .add([file("c.txt")]), control: JobControl())
        let listing = try await service.list(archive, control: JobControl())
        XCTAssertEqual(Set(listing.entries.map(\.path)), ["renamed.txt", "c.txt"])
    }
    func testDuplicateDestinationDoesNotOverwrite() async throws {
        let archive = try await create([file("x.txt")], name: "safe.zip")
        let original = try Data(contentsOf: archive)
        do { _ = try await create([file("y.txt")], name: "safe.zip"); XCTFail("Overwrote archive") } catch { }
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let first = try await service.extract(archive, to: folder, control: JobControl())
        let second = try await service.extract(archive, to: folder, control: JobControl())
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("x.txt").path))
    }
    func testMultipart7z() async throws {
        let data = Data((0..<2_500_000).map { _ in UInt8.random(in: 0...255) })
        let source = folder.appendingPathComponent("random.bin"); try data.write(to: source)
        let archive = try await create([source], name: "split.7z", format: .sevenZip, volume: 1)
        XCTAssertEqual(archive.pathExtension, "001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("split.7z.002").path))
        _ = try await service.test(archive, control: JobControl())
        let result = try await service.extract(archive, to: folder, control: JobControl())
        XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("random.bin")), data)
    }
    func testTARAndCompressedTARCreation() async throws {
        for format in [ArchiveFormat.tar, .tarGzip, .tarBzip, .tarXZ] {
            let archive = try await create([file("file.txt")], name: "sample." + format.rawValue, format: format)
            _ = try await service.test(archive, control: JobControl())
            let listing = try await service.list(archive, control: JobControl())
            XCTAssertEqual(listing.entries.map(\.path), ["file.txt"])
            let out = try await service.extract(archive, to: folder, control: JobControl())
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("file.txt").path))
        }
    }
    func testRAR4AndRAR5ReadTestAndExtractWithoutRARLicense() async throws {
        for name in ["test_read_format_rar_windows", "test_read_format_rar5_stored", "test_read_format_rar5_compressed"] {
            let archive = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "rar", subdirectory: "Fixtures"))
            let listing = try await service.list(archive, control: JobControl())
            XCTAssertFalse(listing.entries.isEmpty)
            _ = try await service.test(archive, control: JobControl())
            let out = try await service.extract(archive, to: folder, control: JobControl())
            for entry in listing.entries where !entry.isDirectory {
                let data = try Data(contentsOf: out.appendingPathComponent(entry.path))
                XCTAssertEqual(data.count, Int(entry.size))
            }
        }
    }
    func testMaliciousZIPsFailWithoutPublishingOutput() async throws {
        for name in ["traversal", "symlink"] {
            let archive = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures"))
            do { _ = try await service.extract(archive, to: folder, control: JobControl()); XCTFail("Unsafe archive extracted") }
            catch ArchiveError.unsafePath { }
            catch ArchiveError.linksUnsupported { }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
    func testTraversalAndLinksAreRejected() throws {
        for path in ["../escape", "/etc/passwd", "folder/../../escape", "C:\\file.txt", "folder\\..\\file", "line\nbreak"] {
            XCTAssertThrowsError(try ArchiveSafety.validatePath(path))
        }
        XCTAssertThrowsError(try ArchiveSafety.validate([ArchiveEntry(path: "link", isLink: true)]))
        XCTAssertNoThrow(try ArchiveSafety.validatePath("folder/İstanbul [1].txt"))
    }
    func testCancelledCreationDoesNotPublishPartialArchive() async throws {
        let token = JobControl(); token.cancel()
        let dest = folder.appendingPathComponent("cancel.zip")
        do { _ = try await service.create(files: [file("a.txt")], at: dest, options: ArchiveOptions(), control: token); XCTFail("Cancelled operation ran") }
        catch ArchiveError.cancelled { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".bstoeq-archive-") })
    }
    func testSyntheticFoldersAndRecursiveSearch() {
        let list = ArchiveListing(entries: [ArchiveEntry(path: "a/b.txt"), ArchiveEntry(path: "a/c/d.txt"), ArchiveEntry(path: "z.txt")])
        XCTAssertEqual(list.children(of: "").map(\.path), ["a", "z.txt"])
        XCTAssertEqual(list.children(of: "a").map(\.path), ["a/c", "a/b.txt"])
        XCTAssertEqual(list.children(of: "", search: "d.txt").map(\.path), ["a/c/d.txt"])
    }
    func testPasswordMatchingFilenameDoesNotCorruptListing() async throws {
        let archive = try await create([file("secret.txt")], name: "redaction.7z", format: .sevenZip, password: "secret")
        let listing = try await service.list(archive, password: "secret", control: JobControl())
        XCTAssertEqual(listing.entries.map(\.path), ["secret.txt"])
    }
    func testRunningProcessCancellation() async throws {
        let token = JobControl()
        let task = Task { try await ProcessRunner.run(tool: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], control: token) }
        try await Task.sleep(for: .milliseconds(150))
        token.cancel()
        do { _ = try await task.value; XCTFail("Cancellation did not interrupt the process") }
        catch ArchiveError.cancelled { }
    }
}
