import XCTest
@testable import ArchiveCore

final class FileOperationTests: XCTestCase {
    var folder: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent("bstoeq-archive-file-test-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: folder) }

    private func file(_ path: String, _ content: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    func testRenameNeverOverwritesAnotherEntry() throws {
        let source = try file("source.txt", "source")
        let destination = try file("existing.txt", "destination")
        XCTAssertThrowsError(try FileOperations.rename(source, to: "existing.txt"))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "destination")
        let brokenLink = folder.appendingPathComponent("broken.txt")
        try fm.createSymbolicLink(atPath: brokenLink.path, withDestinationPath: folder.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try FileOperations.rename(source, to: "broken.txt"))
        XCTAssertNoThrow(try fm.destinationOfSymbolicLink(atPath: brokenLink.path))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testCaseOnlyRenameSucceedsWithoutLosingContent() throws {
        let source = try file("notes.txt")
        let destination = try FileOperations.rename(source, to: "Notes.txt")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), ["Notes.txt"])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
    }

    func testInvalidNamesAreRejectedBeforeChangingFiles() throws {
        let source = try file("source.txt")
        for name in ["", " ", ".", "..", "a/b", "a\\b", "a:b", "bad\nname", "nul\0name"] {
            XCTAssertThrowsError(try FileOperations.rename(source, to: name), "Accepted \(name.debugDescription)")
            XCTAssertTrue(fm.fileExists(atPath: source.path))
        }
        XCTAssertNoThrow(try FileOperations.validateName("İstanbul Bericht (2).txt"))
    }

    func testCopyPreservesExistingFilesAndExtension() throws {
        let source = try file("input/Notes.txt", "new")
        let existing = try file("output/Notes.txt", "existing")
        _ = try file("output/Notes (2).txt", "existing 2")
        let output = try FileOperations.copy([source], to: existing.deletingLastPathComponent(), control: JobControl())
        XCTAssertEqual(output.map(\.lastPathComponent), ["Notes (3).txt"])
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: output[0], encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new")
    }

    func testCopyRejectsDirectoryIntoItselfIncludingRootAndSymlinkAlias() throws {
        let source = try file("source/nested/item.txt").deletingLastPathComponent().deletingLastPathComponent()
        let nested = source.appendingPathComponent("nested")
        let alias = folder.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: nested)
        for (input, destination) in [(source, source), (source, nested), (source, alias), (URL(fileURLWithPath: "/"), folder!)] {
            XCTAssertThrowsError(try FileOperations.copy([input], to: destination, control: JobControl())) { error in
                guard case ArchiveError.message("CANNOT_COPY_INTO_SELF") = error else { return XCTFail("Unexpected \(error)") }
            }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: nested.path), ["item.txt"])
    }

    func testCancellationRemovesPublishedCopiesAndHiddenStage() throws {
        let first = try file("input/first.txt")
        let second = first.deletingLastPathComponent().appendingPathComponent("many")
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        for index in 0..<600 { try Data("data".utf8).write(to: second.appendingPathComponent("\(index).txt")) }
        let destination = folder.appendingPathComponent("output")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let token = JobControl()
        let watcher = expectation(description: "Cancelled after first publication")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: destination.appendingPathComponent("first.txt").path) {
                    token.cancel()
                    watcher.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        XCTAssertThrowsError(try FileOperations.copy([first, second], to: destination, control: token)) { error in
            guard case ArchiveError.cancelled = error else { return XCTFail("Unexpected \(error)") }
        }
        wait(for: [watcher], timeout: 6)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: first.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: second.path).count, 600)
    }

    func testAlreadyCancelledCopyLeavesNoFiles() throws {
        let source = try file("input.txt")
        let control = JobControl(); control.cancel()
        XCTAssertThrowsError(try FileOperations.copy([source], to: folder, control: control))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), ["input.txt"])
    }
}
