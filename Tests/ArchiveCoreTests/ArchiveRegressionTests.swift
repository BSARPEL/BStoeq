import XCTest
@testable import ArchiveCore

final class ArchiveRegressionTests: XCTestCase {
    var folder: URL!
    var service: ArchiveService!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bstoeq-archive-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        service = ArchiveService(tool: root.appendingPathComponent("Resources/Tools/7zz"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func file(_ name: String, contents: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
    private func create(_ source: URL, name: String = "archive.zip", options: ArchiveOptions = ArchiveOptions()) async throws -> URL {
        let outputs = try await service.create(files: [source], at: folder.appendingPathComponent(name), options: options, control: JobControl())
        return try XCTUnwrap(outputs.first)
    }
    private func assertConflict(_ operation: () async throws -> URL) async throws {
        do { _ = try await operation(); XCTFail("Archive paths would silently overwrite one another") }
        catch ArchiveError.message(let reason) { XCTAssertTrue(reason.hasPrefix("ARCHIVE_PATH_CONFLICT:"), reason) }
    }

    func testNestedSymlinksNeverReadFilesOutsideSelectedFolder() async throws {
        let secret = try file("outside.txt", contents: "private")
        let source = try file("source/normal.txt").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.txt"), withDestinationURL: secret)
        do { _ = try await create(source); XCTFail("Followed a nested symbolic link") }
        catch ArchiveError.linksUnsupported { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("archive.zip").path))
    }

    func testAddingFolderWithNestedLinkLeavesArchiveUnchanged() async throws {
        let archive = try await create(file("original.txt"))
        let original = try Data(contentsOf: archive)
        let source = try file("source/normal.txt").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: archive)
        do { try await service.edit(archive, operation: .add([source]), control: JobControl()); XCTFail("Added link target") }
        catch ArchiveError.linksUnsupported { }
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathExtension("backup").path))
    }

    func testNestedControlCharactersRejectedBeforeCreatingArchive() async throws {
        let source = try file("source/line\nbreak.txt").deletingLastPathComponent()
        do { _ = try await create(source); XCTFail("Created an archive whose entries cannot be selected reliably") }
        catch ArchiveError.unsafePath { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("archive.zip").path))
    }

    func testOutputNameCannotCollideWithInternalManifest() async throws {
        let archive = try await create(file("document.txt"), name: "inputs.txt")
        let listing = try await service.list(archive, control: JobControl())
        XCTAssertEqual(listing.entries.map(\.path), ["document.txt"])
        let result = try await service.extract(archive, to: folder, control: JobControl())
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("document.txt"), encoding: .utf8), "original")
    }

    func testExtractionKeepsAnArchiveExtensionThatIsPartOfTheBaseName() async throws {
        var options = ArchiveOptions()
        options.format = .sevenZip
        let archive = try await create(file("notes.txt"), name: "Project.zip.7z", options: options)
        let result = try await service.extract(archive, to: folder, control: JobControl())
        XCTAssertEqual(result.lastPathComponent, "Project.zip")
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("notes.txt"), encoding: .utf8), "original")
    }

    func testOrphanedVolumePreventsMixedOldAndNewArchives() async throws {
        let old = try file("split.7z.004", contents: "old volume")
        let source = try file("small.txt")
        var options = ArchiveOptions(); options.format = .sevenZip; options.volumeMB = 1
        do { _ = try await create(source, name: "split.7z", options: options); XCTFail("Mixed old and new volumes") }
        catch ArchiveError.message(let reason) { XCTAssertEqual(reason, "DESTINATION_EXISTS") }
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old volume")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("split.7z.001").path))
    }

    func testDuplicateAndFileDirectoryCollisionsDoNotPublishOutput() async throws {
        for names in [["same.txt", "same.txt"], ["parent", "parent/file.txt"]] {
            let archive = try storedZIP(names.map { ($0, "data") })
            try await assertConflict { try await self.service.extract(archive, to: self.folder, control: JobControl()) }
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(remaining.allSatisfy { $0.hasSuffix(".zip") })
    }

    func testCaseCollisionsRespectDestinationVolumeAndSelectedSubset() async throws {
        let archive = try storedZIP([("File.txt", "first"), ("file.txt", "second"), ("safe.txt", "selected")])
        let caseSensitive = try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        if !caseSensitive {
            try await assertConflict { try await self.service.extract(archive, to: self.folder, control: JobControl()) }
        }
        let result = try await service.extract(archive, to: folder, paths: ["safe.txt"], control: JobControl())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.path), ["safe.txt"])
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("safe.txt"), encoding: .utf8), "selected")
    }

    func testDestinationValidationCatchesNormalizationAndRejectsEmptyPaths() throws {
        XCTAssertThrowsError(try ArchiveSafety.validateDestinations([ArchiveEntry(path: "café.txt"), ArchiveEntry(path: "cafe\u{301}.txt")], caseSensitive: true))
        XCTAssertThrowsError(try ArchiveSafety.validateDestinations([ArchiveEntry(path: "folder"), ArchiveEntry(path: "FOLDER/child")], caseSensitive: false))
        XCTAssertNoThrow(try ArchiveSafety.validateDestinations([ArchiveEntry(path: "File"), ArchiveEntry(path: "file")], caseSensitive: true))
        XCTAssertThrowsError(try ArchiveSafety.validatePath(""))
        XCTAssertThrowsError(try ArchiveSafety.validateDestinations([ArchiveEntry(path: ".")], caseSensitive: true))
        XCTAssertNoThrow(try ArchiveSafety.validateDestinations([ArchiveEntry(path: "./", isDirectory: true), ArchiveEntry(path: "./file.txt")], caseSensitive: true))
    }

    func testChangedSelectionNeverPartiallyExtractsOrDeletes() async throws {
        let archive = try storedZIP([("Design/icon.txt", "icon"), ("readme.txt", "readme")])
        let original = try Data(contentsOf: archive)
        let selection = ["Design", "removed.txt"]
        do {
            _ = try await service.extract(archive, to: folder, paths: selection, control: JobControl())
            XCTFail("Extracted a partial selection")
        } catch ArchiveError.message(let key) { XCTAssertEqual(key, "ARCHIVE_CHANGED") }
        do {
            try await service.edit(archive, operation: .delete(selection), control: JobControl())
            XCTFail("Deleted a partial selection")
        } catch ArchiveError.message(let key) { XCTAssertEqual(key, "ARCHIVE_CHANGED") }
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [archive.lastPathComponent])

        let output = try await service.extract(archive, to: folder, paths: ["Design", "Design/icon.txt"], control: JobControl())
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("Design/icon.txt"), encoding: .utf8), "icon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("readme.txt").path))
    }

    func testRenameCannotTurnFileIntoParentOrMoveFolderInsideItself() async throws {
        let archive = try storedZIP([("parent", "original"), ("folder/item.txt", "item")])
        let original = try Data(contentsOf: archive)
        for operation in [ArchiveService.Edit.rename("folder", "parent/nested"), .rename("folder", "folder/nested")] {
            do { try await service.edit(archive, operation: operation, control: JobControl()); XCTFail("Created impossible directory layout") }
            catch ArchiveError.message { }
            XCTAssertEqual(try Data(contentsOf: archive), original)
        }
    }

    func testAddingArchiveParentCannotRecursivelyArchiveStagingFolder() async throws {
        let source = try file("source/original.txt")
        let archive = try await create(source, name: "source/archive.zip")
        let original = try Data(contentsOf: archive)
        do { try await service.edit(archive, operation: .add([source.deletingLastPathComponent()]), control: JobControl()); XCTFail("Recursively archived own output") }
        catch ArchiveError.message(let reason) { XCTAssertEqual(reason, "DESTINATION_INSIDE_SOURCE") }
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testSanitizedDisplayNameCannotReportEmptyExtractionAsSuccess() async throws {
        let archive = try storedZIP([("line\nbreak.txt", "payload")])
        let listing = try await service.list(archive, control: JobControl())
        let displayedPath = try XCTUnwrap(listing.entries.first?.path)
        do { _ = try await service.extract(archive, to: folder, paths: [displayedPath], control: JobControl()); XCTFail("Published empty extraction as success") }
        catch ArchiveError.message(let reason) { XCTAssertEqual(reason, "INVALID_ARCHIVE_LIST") }
        catch ArchiveError.unsafePath { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [archive.lastPathComponent])
    }

    func testRootDirectoryRejectedBeforeScanningOrCreatingOutput() async throws {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        do { _ = try await create(root); XCTFail("Root source includes every output destination") }
        catch ArchiveError.message(let reason) { XCTAssertEqual(reason, "DESTINATION_INSIDE_SOURCE") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        let archive = try await create(file("original.txt"))
        let original = try Data(contentsOf: archive)
        do { try await service.edit(archive, operation: .add([root]), control: JobControl()); XCTFail("Added archive's filesystem root") }
        catch ArchiveError.message(let reason) { XCTAssertEqual(reason, "DESTINATION_INSIDE_SOURCE") }
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testTarOfCurrentDirectoryShowsItsContentsAtTheBrowseRoot() async throws {
        _ = try file("source/Documents/notes.txt", contents: "notes")
        _ = try file("source/readme.txt", contents: "readme")
        let archive = folder.appendingPathComponent("example.tar")
        _ = try await ProcessRunner.run(tool: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["--no-mac-metadata", "--no-xattrs", "-cf", archive.path, "-C", folder.appendingPathComponent("source").path, "."],
            control: JobControl())
        let listing = try await service.list(archive, control: JobControl())
        let root = listing.children(of: "")
        XCTAssertEqual(root.map(\.name), ["Documents", "readme.txt"])
        let documents = try XCTUnwrap(root.first)
        XCTAssertEqual(listing.children(of: documents.path).map(\.name), ["notes.txt"])
        XCTAssertFalse(listing.children(of: "", search: ".").contains { $0.path == "." })
        let result = try await service.extract(archive, to: folder, paths: [documents.path], control: JobControl())
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("Documents/notes.txt"), encoding: .utf8), "notes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.appendingPathComponent("readme.txt").path))
    }

    func testTBZAliasReadsInnerTarAndExtractsItsContents() async throws {
        for (suffix, format) in [("tbz", ArchiveFormat.tarBzip), ("tbz2", .tarBzip), ("txz", .tarXZ), ("tgz", .tarGzip)] {
            var options = ArchiveOptions(); options.format = format
            let archive = try await create(file("document.txt"), name: "bundle." + suffix, options: options)
            let listing = try await service.list(archive, control: JobControl())
            XCTAssertEqual(listing.entries.map(\.path), ["document.txt"])
            _ = try await service.test(archive, control: JobControl())
            let extracted = try await service.extract(archive, to: folder, control: JobControl())
            XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("document.txt"), encoding: .utf8), "original")
        }
    }

    // Stored ZIPs allow duplicate/case-sensitive entry names even on a case-insensitive host.
    private func storedZIP(_ entries: [(String, String)]) throws -> URL {
        var data = Data(), directory = Data()
        func number<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for (name, contents) in entries {
            let filename = Data(name.utf8), payload = Data(contents.utf8)
            var crc: UInt32 = 0xffff_ffff
            for byte in payload {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            crc ^= 0xffff_ffff
            let offset = UInt32(data.count), size = UInt32(payload.count)
            number(UInt32(0x04034b50), into: &data)
            for value: UInt16 in [20, 0x800, 0, 0, 0] { number(value, into: &data) }
            number(crc, into: &data); number(size, into: &data); number(size, into: &data)
            number(UInt16(filename.count), into: &data); number(UInt16(0), into: &data)
            data.append(filename); data.append(payload)
            number(UInt32(0x02014b50), into: &directory)
            for value: UInt16 in [20, 20, 0x800, 0, 0, 0] { number(value, into: &directory) }
            number(crc, into: &directory); number(size, into: &directory); number(size, into: &directory)
            number(UInt16(filename.count), into: &directory)
            for value: UInt16 in [0, 0, 0, 0] { number(value, into: &directory) }
            number(UInt32(0), into: &directory); number(offset, into: &directory); directory.append(filename)
        }
        let offset = UInt32(data.count); data.append(directory)
        number(UInt32(0x06054b50), into: &data)
        number(UInt16(0), into: &data); number(UInt16(0), into: &data)
        number(UInt16(entries.count), into: &data); number(UInt16(entries.count), into: &data)
        number(UInt32(directory.count), into: &data); number(offset, into: &data); number(UInt16(0), into: &data)
        let url = folder.appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: url)
        return url
    }
}
