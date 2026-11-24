import XCTest
import AppKit
import Darwin
import ArchiveCore
import BStoeqCore
import ConvertCore
@testable import BStoeq

final class ConverterManagerTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!, trash: URL!, fallback: URL!
    private var suite = "", defaults: UserDefaults!

    override func setUpWithError() throws {
        let base = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        root = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("barlet-converter-\(UUID().uuidString)")
        trash = root.appendingPathComponent(".TestTrash"); fallback = root.appendingPathComponent(".Downloads")
        for folder in [trash!, fallback!] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        suite = "local.barlet.tests.converter.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try fm.removeItem(at: root)
    }

    // MARK: Helpers

    private typealias Body = @Sendable (ConversionRequest, ConversionContext) async throws -> [URL]
    private typealias Accepts = @Sendable (ConversionTarget, FileFormat, ConversionEnvironment) -> TargetAvailability

    /// A converter for these source formats (any when nil) that does what the test says; left alone it
    /// writes one file holding the names of its sources, in the order it got them.
    private struct Stand: Converter {
        let accepts: Accepts
        let body: Body
        init(_ formats: Set<String>? = nil, body: @escaping Body = Stand.write) {
            self.init(accepts: { target, source, _ in
                formats?.contains(source.id) ?? true && target.id != source.id ? .available : .unsupported
            }, body: body)
        }
        init(accepts: @escaping Accepts, body: @escaping Body = Stand.write) { self.accepts = accepts; self.body = body }
        static let write: Body = { request, _ in
            let url = request.outputURL()
            try Data(request.sources.map(\.lastPathComponent).joined(separator: ",").utf8).write(to: url)
            return [url]
        }
        func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
            accepts(target, source, environment)
        }
        func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] { try await body(request, context) }
    }

    private final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        func change(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
    }

    private var sevenZip: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Tools/7zz")
    }

    @MainActor private func makeManager(_ converters: [any Converter], limiter: ConversionLimiter = ConversionLimiter(),
                                        detect: @escaping @Sendable () -> ConversionEnvironment = { ConversionEnvironment() }) -> ConverterManager {
        let trash = trash!
        return ConverterManager(defaults: defaults, settings: { ConverterSettings() }, detect: detect, converters: converters,
                                limiter: limiter, fallbackFolder: fallback, archiveTool: sevenZip, moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        })
    }

    @discardableResult
    private func write(_ relative: String, _ text: String = "data") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func names(in relative: String) -> Set<String> {
        Set(((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(relative).path)) ?? []).filter { !$0.hasPrefix(".") })
    }
    private func target(_ id: String) throws -> ConversionTarget { try XCTUnwrap(TargetCatalog.target(id: id)) }

    @MainActor private func activity(_ manager: ConverterManager, _ id: UUID) -> ConversionActivity? {
        manager.activities.first { $0.id == id }
    }
    @MainActor private func settle(_ what: String = "the condition", until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Jobs

    @MainActor func testActivityGoesFromWaitingThroughRunningToFinishedWithCountsProblemsAndNotices() async throws {
        let gate = Box(false)
        let stand = Stand(["png"]) { request, context in
            let name = request.sources[0].lastPathComponent
            if name.hasPrefix("hold") {
                context.progress(0.5)
                try await ConversionWork.run { while !gate.value { try context.checkCancelled(); usleep(5_000) } }
            }
            if name.hasPrefix("bad") { throw ConversionFailure("Dönüştürülemedi: %@", detail: "bozuk") }
            if name.hasPrefix("skip") { throw ConversionSkip("Zaten yeterince küçük.") }
            context.note("Bir not.")
            return try await Stand.write(request, context)
        }
        let manager = makeManager([stand], limiter: ConversionLimiter(media: 1, other: 1))
        let hold = try write("in/hold.png")
        let files = try ["ok.png", "bad1.png", "bad2.png", "bad3.png", "bad4.png", "skip.png"].map { try write("in/" + $0) }
        let first = try XCTUnwrap(manager.start([hold], target: target("jpg"), origin: .donut(CGPoint(x: 10, y: 20))))
        let second = try XCTUnwrap(manager.start(files, target: target("jpg"), origin: .page))
        XCTAssertEqual(manager.activities.map(\.id), [second, first], "Newest first")
        XCTAssertEqual(manager.activities.map(\.phase), [.waiting, .waiting])
        XCTAssertEqual(manager.activities.map(\.count), [6, 1])

        try await settle("progress") { activity(manager, first)?.fraction == 0.5 }
        XCTAssertEqual(activity(manager, first)?.phase, .running)
        XCTAssertEqual(activity(manager, second)?.phase, .waiting, "The only slot is taken")
        XCTAssertNil(activity(manager, second)?.fraction, "Nothing has reported progress")

        gate.value = true
        try await settle("both jobs") { manager.activities.allSatisfy { $0.phase == .finished } }
        let done = try XCTUnwrap(activity(manager, second))
        XCTAssertEqual([done.converted, done.failed, done.skipped], [1, 4, 1])
        XCTAssertFalse(done.cancelled)
        let failure = UserMessage("Dönüştürülemedi: %@", detail: "bozuk")
        XCTAssertEqual(done.problems, ["bad1.png", "bad2.png", "bad3.png"].map { ConversionActivity.Problem(name: $0, message: failure, failed: true) })
        XCTAssertEqual(done.moreProblems, 2)
        XCTAssertEqual(done.notices, [UserMessage("Bir not.")])
        XCTAssertEqual(done.outputs, [root.appendingPathComponent("in/ok.jpg")])
        XCTAssertEqual(done.recordID, second)
        XCTAssertEqual(manager.history.map(\.id), [second, first])
        XCTAssertEqual(manager.history.first?.origin, .page)
        XCTAssertEqual(manager.history.last?.origin, .donut)
        XCTAssertEqual(manager.history.first?.failures, 4)
        XCTAssertEqual(activity(manager, first)?.fraction, 1)
        XCTAssertEqual(activity(manager, first)?.origin, .donut(CGPoint(x: 10, y: 20)))
    }

    @MainActor func testOnlySourcesTheTargetFitsReachTheJobAndNothingFittingStartsNothing() async throws {
        let stand = Stand(accepts: { target, source, _ in
            guard source.id == "png", target.id != "png" else { return .unsupported }
            return target.id == "mp3" ? .needs("ffmpeg") : .available
        })
        let manager = makeManager([stand])
        let picture = try write("in/a.png"), text = try write("in/b.txt")
        let id = try XCTUnwrap(manager.start([picture, text, picture], target: target("jpg"), origin: .donut(.zero)))
        XCTAssertEqual(activity(manager, id)?.count, 1)
        try await settle { activity(manager, id)?.phase == .finished }
        XCTAssertEqual(manager.history.first?.sources, [picture.path])
        XCTAssertEqual(manager.history.first?.problems, [], "The ring already said the text file does not fit")
        XCTAssertEqual(activity(manager, id)?.skipped, 0)

        let jpg = try target("jpg"), merge = try target("pdf.merge"), mp3 = try target("mp3")
        XCTAssertNil(manager.start([text], target: jpg, origin: .donut(.zero)))
        XCTAssertNil(manager.problem)
        XCTAssertNil(manager.start([text], target: jpg, origin: .page))
        XCTAssertEqual(manager.problem, UserMessage("Bu dosya bu biçime dönüştürülemiyor."))
        XCTAssertNil(manager.start([picture, text], target: merge, origin: .page))
        XCTAssertEqual(manager.problem, UserMessage("Birleştirmek için en az iki dosya gerekir."))
        XCTAssertNil(manager.start([picture], target: mp3, origin: .page))
        XCTAssertEqual(manager.problem, UserMessage("Bu dönüştürme için %@ gerekli.", detail: "ffmpeg"))
        XCTAssertEqual(manager.activities.count, 1)
        XCTAssertEqual(manager.history.count, 1)
    }

    @MainActor func testTheRingSortsAMergeByNameAndThePageKeepsItsOrder() async throws {
        let manager = makeManager([Stand(["png"])])
        let files = try ["b10.png", "b2.png", "a.png"].map { try write("in/" + $0) }
        let ring = try XCTUnwrap(manager.start(files, target: target("pdf.merge"), origin: .donut(.zero)))
        try await settle { activity(manager, ring)?.phase == .finished }
        let merged = try XCTUnwrap(activity(manager, ring)?.outputs.first)
        XCTAssertEqual(merged.lastPathComponent, "a birleşik.pdf")
        XCTAssertEqual(try String(contentsOf: merged, encoding: .utf8), "a.png,b2.png,b10.png")

        let page = try XCTUnwrap(manager.start(files, target: target("pdf.merge"), origin: .page))
        try await settle { activity(manager, page)?.phase == .finished }
        let listed = try XCTUnwrap(activity(manager, page)?.outputs.first)
        XCTAssertEqual(listed.lastPathComponent, "b10 birleşik.pdf")
        XCTAssertEqual(try String(contentsOf: listed, encoding: .utf8), "b10.png,b2.png,a.png")
        XCTAssertEqual(activity(manager, page)?.converted, 3)
    }

    @MainActor func testCancelEndsTheJobAsCancelledWithoutOutputOrRecord() async throws {
        let stand = Stand(["png"]) { request, context in
            try await ConversionWork.run { () throws -> Void in
                while !context.isCancelled() { usleep(5_000) }
                try context.checkCancelled()
            }
            return try await Stand.write(request, context)
        }
        let manager = makeManager([stand])
        try write("in/a.png")
        let id = try XCTUnwrap(manager.start([root.appendingPathComponent("in/a.png")], target: target("jpg"), origin: .page))
        try await settle("the start") { activity(manager, id)?.phase == .running }
        manager.cancel(id)
        try await settle("the end") { activity(manager, id)?.phase == .finished }
        let done = try XCTUnwrap(activity(manager, id))
        XCTAssertTrue(done.cancelled)
        XCTAssertEqual(done.outputs, [])
        XCTAssertNil(done.recordID)
        XCTAssertTrue(manager.history.isEmpty, "Nothing was touched")
        XCTAssertEqual(names(in: "in"), ["a.png"])
        manager.dismiss(id)
        XCTAssertTrue(manager.activities.isEmpty)
    }

    @MainActor func testHistoryKeepsTheFiftyNewestAndSurvivesANewInstance() async throws {
        let records = (0..<55).map { number in
            ConversionRecord(date: Date(timeIntervalSinceReferenceDate: Double(1_000 - number)), origin: .page, targetID: "jpg",
                             targetTitle: "JPG", titleIsKey: false, sources: ["/nowhere/\(number).png"], outputs: [])
        }
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(records)) as? [Any])
        stored.insert(42, at: 3)
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: "converter.history")
        let manager = makeManager([Stand(["png"])])
        XCTAssertEqual(manager.history.map(\.id), records.prefix(50).map(\.id), "A malformed element drops only itself")

        let id = try XCTUnwrap(manager.start([try write("in/a.png")], target: target("jpg"), origin: .watch))
        try await settle { manager.history.first?.id == id }
        XCTAssertEqual(manager.history.count, 50)
        XCTAssertEqual(manager.history.first?.origin, .watch)
        XCTAssertEqual(manager.history.dropFirst().map(\.id), records.prefix(49).map(\.id))
        XCTAssertEqual(makeManager([]).history, manager.history)

        manager.clearHistory()
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertTrue(makeManager([]).history.isEmpty)
    }

    @MainActor func testUndoTrashesOnlyUnchangedOutputsAndLeavesAnEditedFolder() async throws {
        let stand = Stand(["pdf", "png"]) { request, context in
            guard request.target.id == "pdf.split" else { return try await Stand.write(request, context) }
            return try ["1", "2"].map { page in
                let url = request.outputURL(request.baseName + "_p" + page)
                try Data("page \(page)".utf8).write(to: url)
                return url
            }
        }
        let manager = makeManager([stand])
        let document = try write("in/doc.pdf"), picture = try write("in/a.png")
        let split = try XCTUnwrap(manager.start([document], target: target("pdf.split"), origin: .page))
        let single = try XCTUnwrap(manager.start([picture], target: target("jpg"), origin: .page))
        try await settle { manager.history.count == 2 }

        let pages = try XCTUnwrap(manager.history.first { $0.id == split })
        let folder = URL(fileURLWithPath: try XCTUnwrap(pages.outputs.first?.path), isDirectory: true)
        XCTAssertEqual(folder.lastPathComponent, "doc sayfalar")
        let edited = folder.appendingPathComponent("doc_p1.pdf"), untouched = folder.appendingPathComponent("doc_p2.pdf")
        let handle = try FileHandle(forWritingTo: edited)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" edited".utf8)); try handle.close()

        manager.undo(pages)
        try await settle("the first undo") { !manager.history.contains { $0.id == split } }
        XCTAssertEqual(manager.problem, UserMessage("Değişen 1 dosya yerinde bırakıldı."))
        XCTAssertTrue(fm.fileExists(atPath: edited.path), "The user's edit stays")
        XCTAssertFalse(fm.fileExists(atPath: untouched.path))

        let picked = try XCTUnwrap(manager.history.first { $0.id == single })
        manager.undo(picked)
        try await settle("the second undo") { manager.history.isEmpty }
        XCTAssertNil(manager.problem)
        XCTAssertEqual(names(in: "in"), ["a.png", "doc.pdf", "doc sayfalar"])
        XCTAssertEqual(Set(((try? fm.contentsOfDirectory(atPath: trash.path)) ?? []).map { String($0.dropFirst(37)) }), ["doc_p2.pdf", "a.jpg"])
        XCTAssertTrue(makeManager([]).history.isEmpty)
    }

    @MainActor func testRetryRunsTheFailedSourcesThatStillExistAsAPageJob() async throws {
        let failing = Box(true)
        let stand = Stand(["png"]) { request, context in
            if failing.value, request.sources[0].lastPathComponent.hasPrefix("bad") { throw ConversionFailure("Dönüştürülemedi: %@", detail: "x") }
            return try await Stand.write(request, context)
        }
        let manager = makeManager([stand])
        let ok = try write("in/ok.png"), bad = try write("in/bad.png"), gone = try write("in/bad-gone.png")
        _ = try XCTUnwrap(manager.start([ok, bad, gone], target: target("jpg"), origin: .donut(.zero)))
        try await settle { manager.history.count == 1 }
        let record = manager.history[0]
        XCTAssertEqual(record.retryable().map(\.path), [bad.path, gone.path])

        try fm.removeItem(at: gone)
        failing.value = false
        manager.retry(record)
        let retried = try XCTUnwrap(manager.activities.first)
        XCTAssertEqual(retried.origin, .page)
        XCTAssertEqual(retried.count, 1)
        try await settle { manager.history.count == 2 }
        XCTAssertEqual(manager.history[0].sources, [bad.path])
        XCTAssertEqual(manager.history[0].targetID, "jpg")
        XCTAssertEqual(manager.history[0].converted, 1)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("in/bad.jpg").path))
    }

    @MainActor func testAfterAPageJobTheListKeepsFailedAndCancelledFilesAndTheDraftResets() async throws {
        let seen = Box<[String]>([])
        let stand = Stand(["png"]) { request, context in
            seen.change { $0.append("\(request.options.imageResize.value) \(request.options.videoMaxHeight) \(request.options.removeAudio)") }
            let name = request.sources[0].lastPathComponent
            if name.hasPrefix("bad") { throw ConversionFailure("Dönüştürülemedi: %@", detail: "x") }
            if name.hasPrefix("slow") {
                try await ConversionWork.run { () throws -> Void in
                    while !context.isCancelled() { usleep(5_000) }
                    try context.checkCancelled()
                }
            }
            return try await Stand.write(request, context)
        }
        let manager = makeManager([stand], limiter: ConversionLimiter(media: 1, other: 3))
        let ok = try write("in/ok.png"), bad = try write("in/bad.png"), slow = try write("in/slow.png"), note = try write("in/note.txt")
        manager.add([ok, bad, slow, note])
        manager.targetID = "jpg"
        manager.draftResize = .half; manager.draftMaxHeight = 720; manager.draftRemoveAudio = true
        manager.startPending()
        XCTAssertEqual(manager.draftResize, .original)
        XCTAssertEqual(manager.draftMaxHeight, 0)
        XCTAssertFalse(manager.draftRemoveAudio)
        XCTAssertEqual(manager.targetID, "jpg")
        XCTAssertEqual(manager.pending.count, 4, "The list stays while the job runs")
        let id = try XCTUnwrap(manager.activities.first?.id)
        XCTAssertEqual(activity(manager, id)?.count, 3)

        try await settle("two outcomes") { activity(manager, id)?.converted == 1 && activity(manager, id)?.failed == 1 }
        manager.cancel(id)
        try await settle("the end") { activity(manager, id)?.phase == .finished }
        XCTAssertEqual(manager.pending.map(\.path), [bad.path, slow.path])
        XCTAssertEqual(seen.value, Array(repeating: "50 720 true", count: 3), "The draft reached the job")
        XCTAssertEqual(activity(manager, id)?.cancelled, true)
        XCTAssertEqual(manager.history.first?.problems.map(\.source), [bad.path])
    }

    @MainActor func testAddKeepsExistingFilesOnceInOrderAndOffersFollowTheList() throws {
        let manager = makeManager([Stand(["png"])])
        let a = try write("in/a.png"), b = try write("in/b.png"), c = try write("in/c.png")
        manager.add([a, b, a, root.appendingPathComponent("in/missing.png"), URL(fileURLWithPath: root.path + "/in/./b.png")])
        XCTAssertEqual(manager.pending.map(\.path), [a.path, b.path])
        XCTAssertEqual(manager.pendingOffers.first { $0.id == "jpg" }?.fitting, 2)
        XCTAssertNil(manager.pendingOffers.first { $0.id == "png" }, "A file is never offered its own format")
        manager.add([c, a])
        XCTAssertEqual(manager.pending.map(\.path), [a.path, b.path, c.path])
        XCTAssertEqual(manager.pendingOffers.first { $0.id == "jpg" }?.fitting, 3)
        manager.pending = []
        XCTAssertEqual(manager.pendingOffers, [])
    }

    @MainActor func testAJobStartedDuringDetectionWaitsForItAndUsesTheDetectedTools() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let ffmpeg = URL(fileURLWithPath: "/bin/echo")
        let stand = Stand(accepts: { target, source, environment in
            guard source.id == "wav", target.id == "mp3" else { return .unsupported }
            return environment.ffmpeg == nil ? .needs("ffmpeg") : .available
        })
        let manager = makeManager([stand], detect: { gate.wait(); return ConversionEnvironment(ffmpeg: ffmpeg) })
        let song = try write("in/song.wav")
        let mp3 = try target("mp3")
        XCTAssertNil(manager.start([song], target: mp3, origin: .page), "Nothing detected and nothing in flight: the tool is missing")
        XCTAssertFalse(manager.toolsChecked)

        manager.refreshTools()
        let id = try XCTUnwrap(manager.start([song], target: mp3, origin: .page))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(manager.toolsChecked)
        XCTAssertEqual(activity(manager, id)?.phase, .waiting)
        XCTAssertNil(manager.environment.ffmpeg)

        gate.signal()
        try await settle { activity(manager, id)?.phase == .finished }
        XCTAssertTrue(manager.toolsChecked)
        XCTAssertEqual(manager.environment.ffmpeg, ffmpeg)
        XCTAssertEqual(activity(manager, id)?.converted, 1)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("in/song.mp3").path))
    }

    @MainActor func testStopDuringAJobEndsTheToolAndRemovesTheWorkFolder() async throws {
        let tool = try write("tools/sleeper", "#!/bin/sh\necho $$\nexec /bin/sleep 30\n")
        XCTAssertEqual(chmod(tool.path, 0o755), 0)
        let pid = Box<Int32>(0)
        let stand = Stand(["png"]) { request, context in
            _ = try await ToolProcess.run(tool, arguments: [], capture: .lines { line in
                if let value = Int32(line) { pid.value = value }
            })
            return try await Stand.write(request, context)
        }
        let manager = makeManager([stand])
        let id = try XCTUnwrap(manager.start([try write("in/a.png")], target: target("jpg"), origin: .donut(.zero)))
        try await settle("the tool") { pid.value != 0 }
        let folders = ConversionEngine.liveWorkFolders()
        XCTAssertEqual(folders.count, 1)
        try await settle("the remembered work folder") { self.defaults.stringArray(forKey: "converter.workFolders") == folders.map(\.path) }

        manager.stop()
        XCTAssertTrue(folders.allSatisfy { !fm.fileExists(atPath: $0.path) }, "Gone before stop() returns")
        try await settle("the tool's end") { kill(pid.value, 0) != 0 }
        try await settle("the job's end") { activity(manager, id)?.phase == .finished }
        XCTAssertEqual(activity(manager, id)?.cancelled, true)
        XCTAssertEqual(activity(manager, id)?.outputs, [])
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertEqual(names(in: "in"), ["a.png"])
        XCTAssertEqual(defaults.stringArray(forKey: "converter.workFolders") ?? [], [])
    }

    @MainActor func testDiscardingStaleWorkFoldersRemovesOnlyTheEnginesLeftovers() throws {
        let stale = try write("x/TemporaryItems/NSIRD_BStoeq_1/partial.png").deletingLastPathComponent()
        let elsewhere = try write("x/Elsewhere/NSIRD_BStoeq_2/keep.png").deletingLastPathComponent()
        let named = try write("x/TemporaryItems/kept/keep.png").deletingLastPathComponent()
        let gone = root.appendingPathComponent("x/TemporaryItems/NSIRD_gone")
        defaults.set([stale, elsewhere, named, gone].map(\.path), forKey: "converter.workFolders")
        makeManager([]).discardStaleWorkFolders()
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.path))
        XCTAssertTrue(fm.fileExists(atPath: named.path))
        XCTAssertEqual(defaults.stringArray(forKey: "converter.workFolders"), [])
    }

    @MainActor func testTheIntroShowsOnceAfterTheFirstRingHasClosed() {
        let manager = makeManager([])
        manager.donutClosed()
        XCTAssertFalse(manager.introVisible)
        manager.donutOpened()
        XCTAssertFalse(manager.introVisible, "Never over a drag")
        manager.donutClosed()
        XCTAssertTrue(manager.introVisible)
        manager.dismissIntro()
        manager.donutOpened(); manager.donutClosed()
        XCTAssertFalse(manager.introVisible)
        let again = makeManager([])
        again.donutOpened(); again.donutClosed()
        XCTAssertFalse(again.introVisible)
    }

    // MARK: Ring and actions

    @MainActor func testADropStartsWhatTheSliceSaysAndIgnoresFlipAndGreyedSlices() async throws {
        let manager = makeManager([Stand(["png"])])
        let picture = try write("in/a.png")
        let faces = manager.faces(for: [picture])
        let jpg = try XCTUnwrap(faces.front.first { $0.id == "jpg" })
        XCTAssertTrue(jpg.enabled)
        manager.drop([picture], on: .flip, at: .zero)
        let greyed = DonutSlice(id: "jpg", content: .target(try target("jpg")), title: "JPG", shortTitle: "JPG", titleIsKey: false,
                                symbol: "photo", enabled: false)
        manager.drop([picture], on: greyed, at: .zero)
        XCTAssertTrue(manager.activities.isEmpty)
        manager.drop([picture], on: jpg, at: CGPoint(x: 300, y: 400))
        XCTAssertEqual(manager.activities.first?.origin, .donut(CGPoint(x: 300, y: 400)))
        try await settle { manager.history.count == 1 }
        XCTAssertEqual(manager.history.first?.origin, .donut)
    }

    @MainActor func testInstantActionsCopyPathsAndCallTheAppWithoutARecord() throws {
        let manager = makeManager([])
        let board = NSPasteboard(name: NSPasteboard.Name("local.barlet.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        manager.pasteboard = board
        let a = try write("in/a.txt"), b = try write("in/b.txt"), archive = try write("in/c.zip")
        manager.perform(.copyPath, on: [a, b, a], origin: .donut(CGPoint(x: 5, y: 6)))
        XCTAssertEqual(board.string(forType: .string), a.path + "\n" + b.path)
        let shown = try XCTUnwrap(manager.activities.first)
        XCTAssertEqual(shown.phase, .finished)
        XCTAssertEqual(shown.notices, [UserMessage("Yol kopyalandı")])
        XCTAssertEqual(shown.origin, .donut(CGPoint(x: 5, y: 6)))
        XCTAssertEqual(shown.count, 2)

        var opened: [[URL]] = [], archives: [URL] = []
        manager.onOpenConverter = { opened.append($0) }
        manager.onOpenArchive = { archives.append($0) }
        manager.perform(.openConverter, on: [a, b], origin: .donut(.zero))
        manager.perform(.openArchive, on: [a], origin: .donut(.zero))
        manager.perform(.openArchive, on: [a, archive], origin: .donut(.zero))
        XCTAssertEqual(opened, [[a, b]])
        XCTAssertEqual(archives, [archive])

        for _ in 0..<25 { manager.perform(.copyPath, on: [a], origin: .page) }
        XCTAssertEqual(manager.activities.count, 20, "The last twenty finished ones")
        XCTAssertTrue(manager.history.isEmpty)
    }

    @MainActor func testArchiveActionsWorkBesideTheFilesAndAreRecordedLikeConversions() async throws {
        try XCTSkipUnless(fm.isExecutableFile(atPath: sevenZip.path), "The bundled 7-Zip is missing")
        let manager = makeManager([])
        let a = try write("docs/a.txt", "alpha"), b = try write("docs/b.txt", "beta")
        manager.perform(.zip, on: [a, b], origin: .page)
        let zip = try XCTUnwrap(manager.activities.first)
        XCTAssertEqual(zip.phase, .running)
        XCTAssertEqual(zip.count, 2)
        XCTAssertEqual(zip.targetTitle, "Tek ZIP’te topla")
        XCTAssertTrue(zip.titleIsKey)
        try await settle("the zip") { activity(manager, zip.id)?.phase == .finished }
        XCTAssertEqual(activity(manager, zip.id)?.outputs, [root.appendingPathComponent("docs/Arşiv.zip")])
        XCTAssertEqual(activity(manager, zip.id)?.converted, 2)
        XCTAssertEqual(manager.history.first?.targetID, "action.zip")
        XCTAssertEqual(manager.history.first?.sources, [a.path, b.path])

        manager.perform(.sevenZip, on: [a], origin: .donut(.zero))
        manager.perform(.zip, on: [a, b], origin: .page)
        try await settle("two more") { manager.activities.allSatisfy { $0.phase == .finished } }
        XCTAssertEqual(names(in: "docs"), ["a.txt", "b.txt", "Arşiv.zip", "a.7z", "Arşiv 2.zip"])

        let archive = root.appendingPathComponent("docs/Arşiv.zip")
        manager.perform(.extract, on: [archive, a], origin: .donut(.zero))
        let extract = try XCTUnwrap(manager.activities.first)
        XCTAssertEqual(extract.count, 1, "Only archives are extracted")
        try await settle("the extraction") { activity(manager, extract.id)?.phase == .finished }
        let folder = try XCTUnwrap(activity(manager, extract.id)?.outputs.first)
        XCTAssertEqual(folder.lastPathComponent, "Arşiv")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("b.txt"), encoding: .utf8), "beta")
        let record = try XCTUnwrap(manager.history.first)
        XCTAssertEqual(record.targetID, "action.extract")
        XCTAssertEqual(record.unchangedOutputs().map(\.path), [folder.path])
        manager.undo(record)
        try await settle("the undo") { !manager.history.contains { $0.id == record.id } }
        XCTAssertFalse(fm.fileExists(atPath: folder.path))

        let other = try write("other/c.txt")
        let count = manager.activities.count
        manager.perform(.zip, on: [a, other], origin: .page)
        XCTAssertEqual(manager.problem, UserMessage("Dosyalar aynı klasörde olmalı."))
        XCTAssertEqual(manager.activities.count, count)
    }

    @MainActor func testArchiveErrorsBecomeMessagesAndALockedArchiveGoesToTheArchiveManager() async throws {
        try XCTSkipUnless(fm.isExecutableFile(atPath: sevenZip.path), "The bundled 7-Zip is missing")
        let manager = makeManager([])
        let linked = try write("docs/linked/real.txt").deletingLastPathComponent()
        try fm.createSymbolicLink(atPath: linked.appendingPathComponent("shortcut").path, withDestinationPath: "real.txt")
        manager.perform(.zip, on: [linked], origin: .page)
        let zip = try XCTUnwrap(manager.activities.first)
        try await settle("the zip") { activity(manager, zip.id)?.phase == .finished }
        XCTAssertEqual(activity(manager, zip.id)?.problems,
                       [.init(name: "linked", message: UserMessage("Kısayol içeren klasörler arşivlenemiyor: %@", detail: "shortcut"), failed: true)])
        XCTAssertEqual(manager.history.first?.retryable().map(\.path), [linked.path])
        XCTAssertEqual(names(in: "docs"), ["linked"])

        let secret = try write("locked/secret.txt"), locked = root.appendingPathComponent("locked/secret.zip")
        _ = try await ArchiveService(tool: sevenZip).create(files: [secret], at: locked, options: ArchiveOptions(), password: "pw", control: JobControl())
        var asked: [URL] = []
        manager.onOpenArchive = { asked.append($0) }
        manager.perform(.extract, on: [locked], origin: .page)
        let extract = try XCTUnwrap(manager.activities.first)
        try await settle("the extraction") { activity(manager, extract.id)?.phase == .finished }
        XCTAssertEqual(asked, [locked])
        XCTAssertEqual(activity(manager, extract.id)?.failed, 0)
        XCTAssertNil(activity(manager, extract.id)?.recordID)
        XCTAssertEqual(names(in: "locked"), ["secret.txt", "secret.zip"])
    }

    @MainActor func testTheModelOwnsAnInjectedConverter() {
        let manager = makeManager([])
        XCTAssertTrue(AppModel(defaults: defaults, converter: manager).converter === manager)
    }
}
