import XCTest
import AppKit
import Darwin
import BStoeqCore
import ConvertCore
@testable import BStoeq

final class ConverterRegressionTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!, trash: URL!, fallback: URL!
    private var suite = "", defaults: UserDefaults!

    override func setUpWithError() throws {
        let base = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        root = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("barlet-regression-\(UUID().uuidString)")
        trash = root.appendingPathComponent(".TestTrash"); fallback = root.appendingPathComponent(".Downloads")
        for folder in [trash!, fallback!] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        suite = "local.barlet.regression.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? fm.removeItem(at: root)
    }

    private typealias Body = @Sendable (ConversionRequest, ConversionContext) async throws -> [URL]
    private struct Stand: Converter {
        let body: Body
        func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
            source.id == "png" && target.id != source.id ? .available : .unsupported
        }
        func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] { try await body(request, context) }
    }
    private final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock(); private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
        func change(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
    }
    @discardableResult
    private func write(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: url)
        return url
    }
    @MainActor private func settle(_ what: String = "the condition", until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A failed watch job retried from the history keeps the rule's results folder and never trashes the watched file.
    @MainActor func testRetryOfAWatchRecordKeepsTheRuleFolderAndNeverTrashes() async throws {
        let failing = Box(true)
        let seen = Box<[String]>([])
        let stand = Stand { request, _ in
            seen.change { $0.append("\(request.options.location) trash=\(request.options.trashOriginals)") }
            if failing.value { throw ConversionFailure("Dönüştürülemedi: %@", detail: "x") }
            let url = request.outputURL()
            try Data("out".utf8).write(to: url)
            return [url]
        }
        var stored = ConversionOptions(); stored.trashOriginals = true
        let settings = ConverterSettings(options: stored)
        let trash = trash!
        let manager = ConverterManager(defaults: defaults, settings: { settings }, detect: { ConversionEnvironment() },
                                       converters: [stand], fallbackFolder: fallback, archiveTool: nil,
                                       moveToTrash: { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) })
        let photo = try write("watched/photo.png")
        var ruleOptions = stored
        ruleOptions.location = .subfolder("Dönüştürülenler"); ruleOptions.trashOriginals = false
        let png2jpg = try XCTUnwrap(TargetCatalog.target(id: "jpg"))
        _ = try XCTUnwrap(manager.start([photo], target: png2jpg, origin: .watch, options: ruleOptions))
        try await settle { manager.history.count == 1 }
        failing.value = false
        manager.retry(manager.history[0])
        try await settle { manager.history.count == 2 }
        XCTAssertEqual(seen.value.last, "subfolder(\"Dönüştürülenler\") trash=false")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "The watched original must not be trashed by a retry")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("watched/Dönüştürülenler/photo.jpg").path),
                      "Retry output should land in the rule's results folder")
    }

    /// The list is kept until the job ends; pressing Convert again meanwhile must not start a second job.
    @MainActor func testASecondPressOfConvertWhileTheJobRunsDoesNothing() async throws {
        let gate = Box(false)
        let stand = Stand { request, context in
            try await ConversionWork.run { while !gate.value { try context.checkCancelled(); usleep(5_000) } }
            let url = request.outputURL()
            try Data("out".utf8).write(to: url)
            return [url]
        }
        let manager = ConverterManager(defaults: defaults, settings: { ConverterSettings() }, detect: { ConversionEnvironment() },
                                       converters: [stand], fallbackFolder: fallback, archiveTool: nil)
        let photo = try write("in/photo.png")
        manager.add([photo]); manager.targetID = "jpg"
        manager.startPending()
        XCTAssertTrue(manager.isConvertingPending, "The button is disabled while these files convert")
        manager.startPending()
        gate.value = true
        try await settle { manager.activities.allSatisfy { $0.phase == .finished } && manager.history.count >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        let outputs = (try fm.contentsOfDirectory(atPath: root.appendingPathComponent("in").path)).sorted()
        XCTAssertEqual(outputs, ["photo.jpg", "photo.png"])
        XCTAssertEqual(manager.history.count, 1, "One press, one job")
    }


    /// After a retry, the old record no longer offers the same files again.
    @MainActor func testARetriedRecordNoLongerOffersTheSameFiles() async throws {
        let failing = Box(true)
        let stand = Stand { request, _ in
            if failing.value { throw ConversionFailure("Dönüştürülemedi: %@", detail: "x") }
            let url = request.outputURL()
            try Data("out".utf8).write(to: url)
            return [url]
        }
        let manager = ConverterManager(defaults: defaults, settings: { ConverterSettings() }, detect: { ConversionEnvironment() },
                                       converters: [stand], fallbackFolder: fallback, archiveTool: nil)
        let photo = try write("in/photo.png")
        _ = try XCTUnwrap(manager.start([photo], target: try XCTUnwrap(TargetCatalog.target(id: "jpg")), origin: .page))
        try await settle { manager.history.count == 1 }
        let old = manager.history[0]
        XCTAssertEqual(old.retryable(), [photo])
        failing.value = false
        manager.retry(old)
        XCTAssertEqual(manager.history.first { $0.id == old.id }?.retryable(), [])
        try await settle { manager.history.count == 2 }
    }
}
