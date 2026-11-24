import XCTest
import BStoeqCore
import ConvertCore
@testable import BStoeq

/// The watch manager against a real temporary folder, with a short settle interval and a recording start.
@MainActor final class WatchFolderManagerTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!, folder: URL!
    private var calls: [(files: [String], target: String, options: ConversionOptions)] = []
    private var started: [UUID] = []
    /// What a started job published, once it has "finished"; until then the manager keeps asking.
    private var finished: [UUID: [URL]] = [:]
    private var fits: (ConversionTarget, URL) -> TargetAvailability = { _, url in url.pathExtension == "png" ? .available : .unsupported }
    private var targetFits: (ConversionTarget) -> TargetAvailability = { _ in .available }
    private var ready = true
    private static let settle: TimeInterval = 0.4

    override func setUpWithError() throws {
        let base = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        root = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("barlet-watch-\(UUID().uuidString)")
        folder = root.appendingPathComponent("Gelen", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func manager() -> WatchFolderManager {
        var stored = ConversionOptions()
        stored.location = .folder("/elsewhere"); stored.trashOriginals = true; stored.imageQuality = 0.5
        return WatchFolderManager(settleInterval: Self.settle, tickInterval: 0.05, options: { stored },
                                  availability: { [unowned self] in fits($0, $1) },
                                  targetAvailability: { [unowned self] in targetFits($0) },
                                  isReady: { [unowned self] in ready },
                                  outputs: { [unowned self] in finished[$0] },
                                  start: { [unowned self] files, target, options in
                                      calls.append((files.map(\.lastPathComponent), target.id, options))
                                      let id = UUID()
                                      started.append(id)
                                      return id
                                  })
    }
    private func rule(enabled: Bool = true, target: String = "jpg", in url: URL? = nil) -> WatchRule {
        WatchRule(id: UUID(uuidString: "6F1C2D3E-0000-4000-8000-000000000001")!, folder: (url ?? folder).path, targetID: target,
                  outputFolder: "Dönüştürülenler", enabled: enabled)
    }
    /// Applies the rule and waits until the folder has been read once, so what is written next is new.
    private func watching(_ manager: WatchFolderManager, _ rule: WatchRule) async throws {
        manager.apply([rule])
        try await wait { !manager.isListing }
    }
    @discardableResult
    private func write(_ name: String, _ text: String = "data", in url: URL? = nil) throws -> URL {
        let file = (url ?? folder).appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }
    private func append(_ text: String, to name: String) throws {
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent(name))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func pause(_ seconds: TimeInterval) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    /// Turns PNG into JPG by writing a small file: enough for the converter manager to run a real job.
    private struct PNGToJPG: Converter {
        func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
            source.id == "png" && target.id == "jpg" ? .available : .unsupported
        }
        func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
            let url = request.outputURL()
            try Data("jpg".utf8).write(to: url)
            return [url]
        }
    }

    func testTheConverterWiringRunsArrivalsAsWatchJobsIntoTheResultsFolderOnceToolsAreKnown() async throws {
        let suite = "barlet-watch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ConverterSettings()
        settings.options.trashOriginals = true
        let converter = ConverterManager(defaults: defaults, settings: { settings }, detect: { ConversionEnvironment() },
                                         converters: [PNGToJPG()], fallbackFolder: root.appendingPathComponent("Yedek"), archiveTool: nil,
                                         moveToTrash: { _ in throw CocoaError(.fileWriteNoPermission) })
        let manager = WatchFolderManager(converter: converter, settings: { settings }, settleInterval: Self.settle, tickInterval: 0.05)
        try await watching(manager, rule())
        XCTAssertEqual(manager.states[rule().id], .watching)
        let photo = try write("foto.png"); try write("not.txt")
        try await pause(Self.settle * 3)
        XCTAssertTrue(converter.activities.isEmpty, "Held until the first tool detection has answered")

        converter.refreshTools()
        try await wait { converter.history.count == 1 }
        let record = converter.history[0]
        XCTAssertEqual(record.origin, .watch)
        XCTAssertEqual(record.sources, [photo.path], "The text file does not fit and leaves no trace")
        XCTAssertEqual(converter.activities.map(\.origin), [.watch])
        let output = folder.appendingPathComponent("Dönüştürülenler/foto.jpg")
        XCTAssertEqual(record.outputs.map(\.path), [output.path])
        XCTAssertTrue(fm.fileExists(atPath: output.path))
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "Originals in a watched folder are never trashed")
        try await pause(Self.settle * 2)
        XCTAssertEqual(converter.history.count, 1)

        manager.apply([rule(target: "mp3")])
        XCTAssertEqual(manager.states[rule().id], .unavailable(nil), "No converter makes MP3 here")
        manager.stop()
    }

    func testAFileWrittenInPiecesIsTakenOnceAfterItSettlesWithTheRuleOptions() async throws {
        let manager = manager()
        try await watching(manager, rule())
        XCTAssertEqual(manager.states, [rule().id: .watching])
        try write("foto.png", "a")
        for piece in ["b", "c", "d"] {
            try await pause(Self.settle / 2)
            XCTAssertTrue(calls.isEmpty, "Still being written")
            try append(piece, to: "foto.png")
        }
        let lastWrite = Date()
        try await wait { !calls.isEmpty }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(lastWrite), Self.settle * 0.9)
        try await pause(Self.settle * 2)
        XCTAssertEqual(calls.map(\.files), [["foto.png"]], "Taken once")
        XCTAssertEqual(calls[0].target, "jpg")
        XCTAssertEqual(calls[0].options.location, .subfolder("Dönüştürülenler"))
        XCTAssertFalse(calls[0].options.trashOriginals)
        XCTAssertEqual(calls[0].options.imageQuality, 0.5, "The rest of the stored options stay")
        manager.stop()
    }

    func testFilesSettlingTogetherMakeOneJobAndFilesAlreadyThereAreLeftAlone() async throws {
        try write("eski.png")
        let manager = manager()
        try await watching(manager, rule())
        try write("b 10.png"); try write("b 9.png"); try write("a.png")
        try await wait { !calls.isEmpty }
        try await pause(Self.settle * 2)
        XCTAssertEqual(calls.map(\.files), [["a.png", "b 9.png", "b 10.png"]])
        manager.stop()
    }

    func testOwnOutputsHiddenPartialNamesFoldersAndLinksAreNotTaken() async throws {
        let manager = manager()
        try await watching(manager, rule())
        try write("ilk.png")
        try await wait { !calls.isEmpty }
        // The job's result lands in the watched folder itself (as a fallback would): it must not come back.
        let output = folder.appendingPathComponent("ilk 2.png")
        finished[started[0]] = [output]
        try await pause(0.2)
        try Data("out".utf8).write(to: output)
        try write(".gizli.png"); try write("~$kilit.png"); try write("yedek.png~"); try write("indirilen.png.crdownload")
        try fm.createDirectory(at: folder.appendingPathComponent("Dönüştürülenler"), withIntermediateDirectories: false)
        try fm.createDirectory(at: folder.appendingPathComponent("klasor.png"), withIntermediateDirectories: false)
        let outside = try write("dis.png", in: root)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("baglanti.png"), withDestinationURL: outside)
        // A download that finishes by being renamed counts under its final name.
        try fm.moveItem(at: folder.appendingPathComponent("indirilen.png.crdownload"), to: folder.appendingPathComponent("indirilen.png"))
        try await wait { calls.count == 2 }
        try await pause(Self.settle * 2)
        XCTAssertEqual(calls.map(\.files), [["ilk.png"], ["indirilen.png"]])
        manager.stop()
    }

    func testRenamingAFileInsideTheFolderIsNotAnArrivalAndAnEmptyFileWaitsUntilItIsFilled() async throws {
        try write("var.png")
        let manager = manager()
        try await watching(manager, rule())
        try fm.moveItem(at: folder.appendingPathComponent("var.png"), to: folder.appendingPathComponent("yeni ad.png"))
        try write("bos.png", "")
        try await pause(Self.settle * 3)
        XCTAssertTrue(calls.isEmpty)
        try append("dolu", to: "bos.png")
        try await wait { !calls.isEmpty }
        XCTAssertEqual(calls.map(\.files), [["bos.png"]])
        manager.stop()
    }

    func testAFileTheTargetDoesNotFitStartsNothingAndAMissingToolShowsOnTheRule() async throws {
        let manager = manager()
        try await watching(manager, rule())
        fits = { _, url in url.pathExtension == "mov" ? .needs("ffmpeg") : url.pathExtension == "png" ? .available : .unsupported }
        try write("metin.txt"); try write("film.mov"); try write("ayni.jpg")
        try await pause(Self.settle * 3)
        XCTAssertTrue(calls.isEmpty, "Nothing is started for a file the target does not fit")

        targetFits = { _ in .needs("ffmpeg") }
        manager.refreshStates()
        XCTAssertEqual(manager.states[rule().id], .unavailable("ffmpeg"))
        XCTAssertFalse(manager.isListing)
        try write("sonra.png")
        try await pause(Self.settle * 3)
        XCTAssertTrue(calls.isEmpty, "A rule whose target cannot be made does not watch")
        targetFits = { _ in .unsupported }
        manager.refreshStates()
        XCTAssertEqual(manager.states[rule().id], .unavailable(nil))
        manager.apply([rule(target: "compress")])
        XCTAssertEqual(manager.states[rule().id], .unavailable(nil), "Tools are not for watched folders")

        targetFits = { _ in .available }
        try await watching(manager, rule())
        XCTAssertEqual(manager.states[rule().id], .watching)
        try write("simdi.png")
        try await wait { !calls.isEmpty }
        XCTAssertEqual(calls.map(\.files), [["simdi.png"]], "Files from while it did not watch are not taken")
        manager.stop()
    }

    func testArrivedFilesWaitUntilTheToolsAreKnown() async throws {
        ready = false
        let manager = manager()
        try await watching(manager, rule())
        try write("bekle.png")
        try await pause(Self.settle * 3)
        XCTAssertTrue(calls.isEmpty)
        ready = true
        try await wait { !calls.isEmpty }
        XCTAssertEqual(calls.map(\.files), [["bekle.png"]])
        manager.stop()
    }

    func testDisablingStopsAndAnEnabledRuleStartsAgainWithoutTheFilesInBetween() async throws {
        let manager = manager()
        try await watching(manager, rule())
        try write("yarim.png")
        manager.apply([rule(enabled: false)])
        XCTAssertTrue(manager.states.isEmpty)
        try write("kapaliyken.png")
        try await pause(Self.settle * 3)
        XCTAssertTrue(calls.isEmpty, "Disabling drops what was still settling")
        try await watching(manager, rule())
        try write("acikken.png")
        try await wait { !calls.isEmpty }
        try await pause(Self.settle)
        XCTAssertEqual(calls.map(\.files), [["acikken.png"]])
        manager.apply([])
        XCTAssertTrue(manager.states.isEmpty)
        manager.stop()
    }

    func testARemovedFolderMarksTheRuleMissingAndIsTriedAgainWhenRulesAreApplied() async throws {
        let manager = manager()
        try await watching(manager, rule())
        try write("silinecek.png")
        try fm.removeItem(at: folder)
        try await wait { manager.states[rule().id] == .folderMissing }
        try await pause(Self.settle * 2)
        XCTAssertTrue(calls.isEmpty)

        manager.apply([rule()])
        XCTAssertEqual(manager.states[rule().id], .folderMissing, "Still missing")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try await watching(manager, rule())
        XCTAssertEqual(manager.states[rule().id], .watching)
        try write("geri.png")
        try await wait { !calls.isEmpty }
        XCTAssertEqual(calls.map(\.files), [["geri.png"]])

        // A folder moved away (to the Trash, say) is lost the same way.
        try fm.moveItem(at: folder, to: root.appendingPathComponent("Tasindi"))
        try await wait { manager.states[rule().id] == .folderMissing }
        manager.apply([rule(in: root.appendingPathComponent("yok"))])
        XCTAssertEqual(manager.states[rule().id], .folderMissing)
        manager.stop()
    }
}
