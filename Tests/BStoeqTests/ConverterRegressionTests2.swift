import XCTest
import ArchiveCore
import BStoeqCore
import ConvertCore
@testable import BStoeq

@MainActor final class ConverterRegressionTests2: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    override func setUpWithError() throws {
        let base = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        root = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("barlet-regression2-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }
    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Rule A watches X, rule B watches X/Dönüştürülenler. A job of rule A publishes its first result while it
    /// still runs; rule B must not take it.
    func testAnotherRuleNeverTakesTheOutputOfAJobStillRunning() async throws {
        let x = root.appendingPathComponent("X"), results = x.appendingPathComponent("Dönüştürülenler")
        try fm.createDirectory(at: results, withIntermediateDirectories: true)
        var calls: [[String]] = [], finished: [UUID: [URL]] = [:], partial: [UUID: [URL]] = [:], ids: [UUID] = []
        let manager = WatchFolderManager(settleInterval: 0.3, tickInterval: 0.05, options: { ConversionOptions() },
                                         availability: { _, _ in .available }, targetAvailability: { _ in .available },
                                         outputs: { finished[$0] }, partialOutputs: { partial[$0] ?? [] },
                                         start: { files, _, _ in calls.append(files.map(\.lastPathComponent)); let id = UUID(); ids.append(id); return id })
        let a = WatchRule(folder: x.path, targetID: "jpg", outputFolder: "Dönüştürülenler")
        let b = WatchRule(folder: results.path, targetID: "png", outputFolder: "Dönüştürülenler")
        manager.apply([a, b])
        try await wait("baseline") { !manager.isListing }
        try Data("1".utf8).write(to: x.appendingPathComponent("one.png"))
        try Data("2".utf8).write(to: x.appendingPathComponent("two.png"))
        try await wait("rule A's job") { !calls.isEmpty }
        // The engine publishes the first result; the second file is still converting.
        let first = results.appendingPathComponent("one.jpg")
        partial[ids[0]] = [first]
        try Data("out".utf8).write(to: first)
        try await Task.sleep(for: .milliseconds(1500))
        finished[ids[0]] = [first, results.appendingPathComponent("two.jpg")]
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, [["one.png", "two.png"]], "Rule B must not take rule A's output")
        manager.stop()
    }

    /// Two ZIP drops from one folder, close together, must not both pick "Arşiv.zip".
    func testTwoQuickZipsOfTheSameFolderGetTwoNames() async throws {
        let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Tools/7zz")
        try XCTSkipUnless(fm.isExecutableFile(atPath: tool.path))
        let suite = "local.barlet.regression2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ConverterManager(defaults: defaults, detect: { ConversionEnvironment() }, converters: [], archiveTool: tool)
        let docs = root.appendingPathComponent("docs")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        var files: [URL] = []
        for name in ["a", "b", "c", "d"] {
            let url = docs.appendingPathComponent(name + ".txt"); try Data(repeating: 1, count: 2_000_000).write(to: url); files.append(url)
        }
        manager.perform(.zip, on: [files[0], files[1]], origin: .donut(.zero))
        manager.perform(.zip, on: [files[2], files[3]], origin: .donut(.zero))
        try await wait("both") { manager.activities.count == 2 && manager.activities.allSatisfy { $0.phase == .finished } }
        let names = Set(manager.activities.flatMap(\.outputs).map(\.lastPathComponent))
        XCTAssertEqual(names, ["Arşiv.zip", "Arşiv 2.zip"])
        XCTAssertTrue(manager.activities.allSatisfy { $0.failed == 0 })
    }
}
