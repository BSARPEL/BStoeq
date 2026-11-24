import os
import XCTest
@testable import ConvertCore

/// The engine against real folders of the fixture, with stand-in converters. The Trash and the
/// fallback folder are folders of the fixture; nothing reaches the user's Downloads.
final class EngineTests: XCTestCase {
    private typealias Fake = ConversionFixture.Fake
    private typealias Flag = ConversionFixture.Flag

    private let fm = FileManager.default
    private var fixture: ConversionFixture!
    private var recorder: ConversionFixture.Recorder!

    private let unfit = "Bu dosya bu biçime dönüştürülemiyor."
    private let fallbackNotice = "Klasöre yazılamadığı için sonuç İndirilenler klasörüne kaydedildi."

    override func setUpWithError() throws {
        fixture = try ConversionFixture(area: "engine")
        recorder = ConversionFixture.Recorder()
    }
    override func tearDownWithError() throws { fixture.remove() }

    private func run(_ sources: [URL], _ target: String, converters: [any Converter] = [Fake()],
                     options: ConversionOptions = ConversionOptions(), suffix: String = "",
                     environment: ConversionEnvironment = ConversionEnvironment()) async throws -> ConversionResult {
        await fixture.engine(converters, environment: environment)
            .run(try fixture.job(sources, target: target, options: options, suffix: suffix), moveToTrash: fixture.moveToTrash, events: recorder.record)
    }
    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func paths(_ result: ConversionResult) -> [String] { result.outputs.map(\.path) }
    private func index(of event: ConversionEvent) -> Int {
        switch event {
        case .started(let index), .progress(let index, _), .finished(let index, _): index
        }
    }
    private func starts() -> [Int] {
        recorder.events.compactMap { event -> Int? in
            if case .started(let index) = event { return index }
            return nil
        }
    }
    private func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }
    private func wait(for what: String, seconds: Double = 10, until done: @Sendable () -> Bool) async throws {
        let start = DispatchTime.now()
        while !done() {
            if self.seconds(since: start) > seconds { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Counts how many requests are inside a converter at once.
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var inside = [0, 0], most = [0, 0], mostTogether = 0
        func enter(media: Bool) {
            lock.withLock {
                inside[media ? 0 : 1] += 1
                most[media ? 0 : 1] = max(most[media ? 0 : 1], inside[media ? 0 : 1])
                mostTogether = max(mostTogether, inside[0] + inside[1])
            }
        }
        func leave(media: Bool) { lock.withLock { inside[media ? 0 : 1] -= 1 } }
        func reset() { lock.withLock { most = [0, 0]; mostTogether = 0 } }
        var peakMedia: Int { lock.withLock { most[0] } }
        var peakOther: Int { lock.withLock { most[1] } }
        var peak: Int { lock.withLock { mostTogether } }
    }

    // MARK: Sources

    func testAJobWithoutSourcesIsAnEmptyResult() async throws {
        let result = try await run([], "png")
        XCTAssertTrue(result.sources.isEmpty && result.outcomes.isEmpty && result.outputs.isEmpty && result.notices.isEmpty)
        XCTAssertEqual([result.converted, result.failed, result.skipped], [0, 0, 0])
        XCTAssertFalse(result.wasCancelled || result.originalsTrashed)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testAFileListedTwiceIsConvertedOnce() async throws {
        let a = try fixture.write("in/a.heic"), b = try fixture.write("in/b.heic")
        let again = fixture.url("in/alt/../a.heic")
        let job = try fixture.job([a, b, again, a], target: "png")
        XCTAssertEqual(job.distinctSources, [a, b])
        let result = await fixture.engine([Fake()]).run(job, events: recorder.record)
        XCTAssertEqual(result.sources, [a, b], "Order kept, the first spelling kept")
        XCTAssertEqual(result.outcomes.count, 2)
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a.heic", "a.png", "b.heic", "b.png"])
        XCTAssertEqual(Set(recorder.events.map(index(of:))), [0, 1], "Events point into the list without repeats")
    }

    func testEverySourceGetsTheOutcomeItsKindDeserves() async throws {
        let good = try fixture.write("in/iyi.heic")
        let missing = fixture.url("in/yok.heic")
        let folder = try fixture.folder("in/Klasör")
        let unknown = try fixture.write("in/bilinmeyen.xyz")
        let unread = try fixture.write("in/katman.psd")
        let needy = try fixture.write("in/ses.wma")
        let link = fixture.url("in/kısayol.heic")
        try fm.createSymbolicLink(at: link, withDestinationURL: good)
        let folderLink = fixture.url("in/klasör kısayolu")
        try fm.createSymbolicLink(at: folderLink, withDestinationURL: folder)
        let converter = Fake(accepts: { _, source, environment in
            if source.id == "wma" { return environment.ffmpeg == nil ? .needs("ffmpeg") : .available }
            return source.id == "heic" ? .available : .unsupported
        })
        let sources = [missing, folder, unknown, unread, needy, link, folderLink, good]
        let options = ConversionOptions(trashOriginals: true)
        let result = try await run(sources, "png", converters: [converter], options: options)
        XCTAssertEqual(result.outcomes, [
            .failed(ConversionFailure("Dosya bulunamadı.")),
            .skipped(unfit), .skipped(unfit), .skipped(unfit),
            .failed(ConversionFailure("Bu dönüştürme için %@ gerekli.", detail: "ffmpeg")),
            .skipped(unfit), .skipped(unfit),
            .converted([fixture.url("in/iyi.png")])])
        XCTAssertEqual([result.converted, result.failed, result.skipped], [1, 2, 5])
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(starts(), [7], "Only what becomes a request starts")
        XCTAssertEqual(recorder.events.filter { if case .finished = $0 { true } else { false } }.count, sources.count)
        XCTAssertEqual(fixture.trashed, [good], "A link or a folder that was passed over is never trashed")
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), good.path)

        let tools = ConversionEnvironment(ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        let withTool = try await run([needy], "mp3", converters: [converter], environment: tools)
        XCTAssertEqual(paths(withTool), [fixture.url("in/ses.mp3").path])
    }

    func testAFolderOrAPackageIsASourceWhenAConverterClaimsItsFormat() async throws {
        let folder = try fixture.folder("in/Belgeler"), package = try fixture.folder("in/Notlar.rtfd")
        try fixture.write("in/Belgeler/a.txt")
        try fixture.write("in/Notlar.rtfd/TXT.rtf")
        let result = try await run([folder, package], "txt", converters: [Fake(sources: ["folder", "rtfd"])])
        XCTAssertEqual(paths(result), [fixture.url("in/Belgeler.txt").path, fixture.url("in/Notlar.txt").path])
        XCTAssertEqual(text(fixture.url("in/Belgeler.txt")), "txt <- Belgeler")
        let other = try await run([folder], "txt", converters: [Fake(sources: ["rtfd"])])
        XCTAssertEqual(other.outcomes, [.skipped(unfit)])
    }

    func testTheFirstConverterThatIsAvailableDoesTheWork() async throws {
        let source = try fixture.write("in/a.heic")
        func named(_ name: String, _ sources: Set<String>?) -> Fake {
            Fake(sources: sources) { request, _ in
                let url = request.outputURL()
                try Data(name.utf8).write(to: url)
                return [url]
            }
        }
        var result = try await run([source], "png", converters: [named("first", ["jpg"]), named("second", nil), named("third", nil)])
        XCTAssertEqual(text(try XCTUnwrap(result.outputs.first)), "second")
        result = try await run([source], "jpg", converters: [named("first", nil), named("second", nil)])
        XCTAssertEqual(text(try XCTUnwrap(result.outputs.first)), "first")
    }

    // MARK: Merging

    func testAMergeIsOneRequestNamedAfterAndPlacedBesideItsFirstSource() async throws {
        let b = try fixture.write("x/b.pdf"), a = try fixture.write("y/a.pdf"), c = try fixture.write("z/c.png")
        let seen = OSAllocatedUnfairLock(initialState: [[String]]())
        let converter = Fake { request, context in
            seen.withLock { $0.append(request.sources.map(\.lastPathComponent)) }
            XCTAssertEqual(request.formats.map(\.id), ["pdf", "pdf", "png"])
            XCTAssertEqual(request.baseName, "b")
            XCTAssertEqual(request.outputFormat.id, "pdf")
            XCTAssertEqual(request.target.id, "pdf.merge")
            context.progress(0.5)
            return try await Fake.write(request, context)
        }
        let result = try await run([b, a, c], "pdf.merge", converters: [converter], suffix: "birleşik")
        XCTAssertEqual(seen.withLock { $0 }, [["b.pdf", "a.pdf", "c.png"]], "One request, in the order given")
        let merged = fixture.url("x/b birleşik.pdf")
        XCTAssertEqual(result.outcomes, Array(repeating: .converted([merged]), count: 3), "Every participant gets the same outcome")
        XCTAssertEqual(result.outputs, [merged], "One output, listed once")
        XCTAssertEqual(result.converted, 3)
        XCTAssertEqual(text(merged), "pdf.merge <- b.pdf, a.pdf, c.png")
        for index in 0..<3 {
            XCTAssertEqual(recorder.events.filter { self.index(of: $0) == index },
                           [.started(index: index), .progress(index: index, fraction: 0.5), .finished(index: index, outcome: .converted([merged]))])
        }
        XCTAssertTrue(fixture.names(in: fixture.url("y")) == ["a.pdf"] && fixture.names(in: fixture.url("z")) == ["c.png"])
    }

    func testWhatTheMergingConverterRejectsIsSkippedAndOneFileIsNotAMerge() async throws {
        let a = try fixture.write("in/a.pdf"), b = try fixture.write("in/b.png"), c = try fixture.write("in/c.pdf")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let documents = Fake(sources: ["pdf"]) { request, context in
            calls.withLock { $0 += 1 }
            return try await Fake.write(request, context)
        }
        let images = Fake(sources: ["png"]) { _, _ in
            XCTFail("The converter of the first file handles the whole merge")
            return []
        }
        let merged = fixture.url("in/a birleşik.pdf")
        var result = try await run([a, b, c], "pdf.merge", converters: [documents, images], suffix: "birleşik")
        XCTAssertEqual(result.outcomes, [.converted([merged]), .skipped(unfit), .converted([merged])])
        XCTAssertEqual(text(merged), "pdf.merge <- a.pdf, c.pdf")

        result = try await run([a, b], "pdf.merge", converters: [documents, images], suffix: "birleşik")
        XCTAssertEqual(result.outcomes, [.skipped("Birleştirmek için en az iki dosya gerekir."), .skipped(unfit)])
        result = try await run([fixture.url("in/yok.pdf"), a], "pdf.merge", converters: [documents, images], suffix: "birleşik")
        XCTAssertEqual(result.outcomes, [.failed(ConversionFailure("Dosya bulunamadı.")), .skipped("Birleştirmek için en az iki dosya gerekir.")],
                       "What was already decided keeps its own reason")
        XCTAssertEqual(calls.withLock { $0 }, 1, "Too few files start nothing")
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a birleşik.pdf", "a.pdf", "b.png", "c.pdf"])
    }

    // MARK: The limiter

    func testTwoJobsStartedTogetherNeverHaveMoreThanTwoRequestsInFlight() async throws {
        let gauge = Gauge()
        let converter = Fake { request, context in
            let media = request.formats[0].family == .video
            gauge.enter(media: media)
            defer { gauge.leave(media: media) }
            try await Task.sleep(nanoseconds: 30_000_000)
            return try await Fake.write(request, context)
        }
        // Two engines, as two parts of the app would make them: the limit belongs to the limiter they share.
        let limiter = ConversionLimiter(media: 2, other: 2)
        let first = fixture.engine([converter], limiter: limiter), second = fixture.engine([converter], limiter: limiter)
        let documents = try fixture.job(try (0..<6).map { try fixture.write("a/\($0).txt") }, target: "pdf")
        let more = try fixture.job(try (0..<6).map { try fixture.write("b/\($0).txt") }, target: "pdf")
        async let one = first.run(documents)
        async let two = second.run(more)
        let results = await [one, two]
        XCTAssertEqual(results.map(\.converted), [6, 6])
        XCTAssertEqual(gauge.peakOther, 2, "Never more than two, and the two slots were both used")
        XCTAssertEqual(gauge.peakMedia, 0)

        gauge.reset()
        let videos = try fixture.job(try (0..<5).map { try fixture.write("v/\($0).mov") }, target: "mp4")
        let moreVideos = try fixture.job(try (0..<5).map { try fixture.write("w/\($0).avi") }, target: "mp4")
        async let three = first.run(videos)
        async let four = second.run(moreVideos)
        let media = await [three, four]
        XCTAssertEqual(media.map(\.converted), [5, 5])
        XCTAssertEqual(gauge.peakMedia, 2)
        XCTAssertEqual(gauge.peakOther, 0)

        // A job of both kinds uses both pools at once, and neither beyond its share.
        gauge.reset()
        let mixed = try fixture.job(try (0..<5).map { try fixture.write("m/\($0).txt") } + (0..<5).map { try fixture.write("m/\($0).mov") }, target: "pdf")
        let both = await first.run(mixed)
        XCTAssertEqual(both.converted, 10)
        XCTAssertEqual([gauge.peakMedia, gauge.peakOther], [2, 2])
        XCTAssertGreaterThan(gauge.peak, 2, "The pools do not wait for each other")
        XCTAssertLessThanOrEqual(gauge.peak, 4)
    }

    func testARequestStartsOnlyOnceItHoldsASlotAndACancelledWaitIsCancelled() async throws {
        let sources = try (0..<4).map { try fixture.write("in/\($0).txt") }
        let release = Flag()
        let order = OSAllocatedUnfairLock(initialState: [String]())
        let converter = Fake { request, context in
            order.withLock { $0.append(request.sources[0].lastPathComponent) }
            while !release.isSet { try await Task.sleep(nanoseconds: 2_000_000) }
            return try await Fake.write(request, context)
        }
        let engine = fixture.engine([converter], limiter: ConversionLimiter(media: 1, other: 1))
        let job = try fixture.job(sources, target: "pdf")
        let recorder = recorder!
        let task = Task { await engine.run(job, events: recorder.record) }
        try await wait(for: "the first request") { recorder.started(0) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(starts(), [0], "The second request holds no slot, so it has not started")
        XCTAssertEqual(order.withLock { $0 }, ["0.txt"])
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcomes, [.cancelled, .cancelled, .cancelled, .cancelled])
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(starts(), [0], "A wait that was cancelled never starts")
        XCTAssertEqual(fixture.names(in: fixture.url("in")).count, 4, "Nothing was published")

        // The slot came back: the same engine serves the next job, in the order given.
        release.set()
        let next = await engine.run(job)
        XCTAssertEqual(next.converted, 4)
        XCTAssertEqual(order.withLock { $0 }, ["0.txt", "0.txt", "1.txt", "2.txt", "3.txt"])
    }

    func testTheLimiterGivesEverySlotBackHoweverItsWaitersLeave() async throws {
        let limiter = ConversionLimiter(media: 2, other: 3)
        let held = OSAllocatedUnfairLock(initialState: [0, 0])
        let most = OSAllocatedUnfairLock(initialState: [0, 0])
        // Many waiters; a third of them are cancelled while they wait or just as they are served.
        let tasks = (0..<240).map { number in
            Task {
                let media = number % 2 == 0, pool = media ? 0 : 1
                guard await limiter.acquire(media: media) else { return false }
                let now = held.withLock { $0[pool] += 1; return $0[pool] }
                most.withLock { $0[pool] = max($0[pool], now) }
                try? await Task.sleep(nanoseconds: UInt64(200_000 + number % 7 * 150_000))
                held.withLock { $0[pool] -= 1 }
                limiter.release(media: media)
                return true
            }
        }
        for (number, task) in tasks.enumerated() where number % 3 == 0 {
            if number % 2 == 0 { try await Task.sleep(nanoseconds: 100_000) }
            task.cancel()
        }
        var served = 0
        for task in tasks where await task.value { served += 1 }
        XCTAssertGreaterThanOrEqual(served, 160, "Whoever was not cancelled was served")
        XCTAssertLessThanOrEqual(most.withLock { $0[0] }, 2)
        XCTAssertLessThanOrEqual(most.withLock { $0[1] }, 3)
        XCTAssertEqual(held.withLock { $0 }, [0, 0])

        // Every slot is back: all five can be taken at once without waiting, and a sixth has to wait.
        for media in [true, true, false, false, false] {
            let taken = await limiter.acquire(media: media)
            XCTAssertTrue(taken)
        }
        let waiting = Task { await limiter.acquire(media: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        let late = await waiting.value
        XCTAssertFalse(late, "No sixth slot appeared, and the cancelled wait ended")
        // A slot given back goes to whoever waits first.
        let first = Task { await limiter.acquire(media: false) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task { await limiter.acquire(media: false) }
        try await Task.sleep(nanoseconds: 20_000_000)
        limiter.release(media: false)
        let served1 = await first.value
        XCTAssertTrue(served1)
        second.cancel()
        let served2 = await second.value
        XCTAssertFalse(served2)
    }

    // MARK: Where results go and what they are called

    func testResultsGoBesideTheSourceIntoASubfolderOrIntoAChosenFolder() async throws {
        let source = try fixture.write("in/foto.heic")
        var result = try await run([source], "png")
        XCTAssertEqual(paths(result), [fixture.url("in/foto.png").path])
        let subfolder = ConversionOptions(location: .subfolder("Dönüştürülenler"))
        result = try await run([source], "png", options: subfolder)
        XCTAssertEqual(paths(result), [fixture.url("in/Dönüştürülenler/foto.png").path])
        result = try await run([source], "png", options: subfolder)
        XCTAssertEqual(paths(result), [fixture.url("in/Dönüştürülenler/foto 2.png").path], "The folder that is there is used again")
        // Requests that run side by side make the folder once and share it.
        let many = try (0..<8).map { try fixture.write("in/çok/\($0).heic") }
        result = try await run(many, "png", options: subfolder)
        XCTAssertEqual(result.converted, 8)
        XCTAssertEqual(fixture.names(in: fixture.url("in/çok/Dönüştürülenler")), (0..<8).map { "\($0).png" })
        let chosen = fixture.url("out/derin/klasör")
        result = try await run([source], "png", options: ConversionOptions(location: .folder(chosen.path)))
        XCTAssertEqual(paths(result), [chosen.appendingPathComponent("foto.png").path], "A chosen folder that is gone is made again")
        XCTAssertTrue(result.notices.isEmpty)

        // A job built by hand cannot send a result out of its folder.
        result = try await run([source], "jpg", options: ConversionOptions(location: .subfolder("../../dışarı")))
        XCTAssertEqual(paths(result), [fixture.url("in/foto.jpg").path])
        XCTAssertFalse(fm.fileExists(atPath: fixture.root.deletingLastPathComponent().appendingPathComponent("dışarı").path))
        XCTAssertTrue(fixture.names(in: fixture.fallback).isEmpty)
    }

    func testNamesCarryTheSuffixAndCountUpInsteadOfReplacing() async throws {
        let source = try fixture.write("in/a.jpeg", Data("özgün".utf8))
        try fixture.write("in/a.png", Data("benim".utf8))
        var result = try await run([source], "png")
        XCTAssertEqual(paths(result), [fixture.url("in/a 2.png").path])
        result = try await run([source], "png")
        XCTAssertEqual(paths(result), [fixture.url("in/a 3.png").path])
        XCTAssertEqual(text(fixture.url("in/a.png")), "benim", "What was there is still there")

        // A tool that keeps the format: the source's format, the suffix after a space.
        result = try await run([source], "half", suffix: "küçük")
        XCTAssertEqual(paths(result), [fixture.url("in/a küçük.jpg").path])
        result = try await run([source], "half", suffix: "küçük")
        XCTAssertEqual(paths(result), [fixture.url("in/a küçük 2.jpg").path])
        result = try await run([source], "half", suffix: "  a/b:c ")
        XCTAssertEqual(paths(result), [fixture.url("in/a a-b-c.jpg").path], "A suffix is a word, not a path")

        // Without a suffix the result would have its source's name: a source is never its own output.
        let same = try fixture.write("in/b.jpg", Data("özgün".utf8))
        result = try await run([same], "half")
        XCTAssertEqual(paths(result), [fixture.url("in/b 2.jpg").path])
        XCTAssertEqual(text(same), "özgün")
        XCTAssertEqual(text(source), "özgün")
    }

    func testSeveralFilesGoOutTogetherAsOneFolder() async throws {
        let source = try fixture.write("in/rapor.pdf")
        let pages = Fake { request, _ in
            try (1...3).map { page in
                let url = request.outputURL("\(request.baseName)_p\(page)")
                try Data("sayfa \(page)".utf8).write(to: url)
                return url
            }
        }
        var result = try await run([source], "png", converters: [pages])
        let folder = fixture.url("in/rapor")
        XCTAssertEqual(paths(result), [folder.path])
        XCTAssertEqual(result.converted, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).sorted(), ["rapor_p1.png", "rapor_p2.png", "rapor_p3.png"])
        XCTAssertEqual(text(folder.appendingPathComponent("rapor_p2.png")), "sayfa 2")

        result = try await run([source], "pdf.split", converters: [pages], suffix: "sayfalar")
        XCTAssertEqual(paths(result), [fixture.url("in/rapor sayfalar").path])
        result = try await run([source], "pdf.split", converters: [pages], suffix: "sayfalar")
        XCTAssertEqual(paths(result), [fixture.url("in/rapor sayfalar 2").path])
        XCTAssertEqual(fixture.names(in: fixture.url("in/rapor sayfalar")), ["rapor_p1.pdf", "rapor_p2.pdf", "rapor_p3.pdf"])
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["rapor", "rapor sayfalar", "rapor sayfalar 2", "rapor.pdf"])

        // Two files of one name are both kept.
        let twins = Fake { request, _ in
            try ["bir", "iki"].map { name in
                let folder = request.workFolder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let url = folder.appendingPathComponent("sayfa.png")
                try Data(name.utf8).write(to: url)
                return url
            }
        }
        result = try await run([source], "png", converters: [twins], suffix: "ikiz")
        XCTAssertEqual(fixture.names(in: fixture.url("in/rapor ikiz")), ["sayfa 2.png", "sayfa.png"])
    }

    func testAResultIsPublishedUnderItsOwnExtension() async throws {
        let source = try fixture.write("in/zil.m4a")
        let renaming = Fake { request, _ in
            XCTAssertEqual(request.outputFormat.id, "m4r")
            XCTAssertEqual(request.outputURL().lastPathComponent, "zil.m4r")
            let url = request.workFolder.appendingPathComponent("başka ad.M4R")
            try Data("ton".utf8).write(to: url)
            return [url]
        }
        let result = try await run([source], "m4r", converters: [renaming])
        XCTAssertEqual(paths(result), [fixture.url("in/zil.M4R").path], "The base name is the source's; the extension is the file's own")
        let bare = Fake { request, _ in
            let url = request.workFolder.appendingPathComponent("uzantısız")
            try Data("x".utf8).write(to: url)
            return [url]
        }
        let unnamed = try await run([source], "wav", converters: [bare])
        XCTAssertEqual(paths(unnamed), [fixture.url("in/zil").path])
    }

    func testASourceWithA250ByteNameConverts() async throws {
        let long = String(repeating: "a", count: 246) + ".txt"
        XCTAssertEqual(long.utf8.count, 250)
        let source = try fixture.write("in/\(long)")
        let checking = Fake { request, context in
            XCTAssertLessThanOrEqual(request.outputURL("\(request.baseName)_p12345").lastPathComponent.utf8.count, 240, "Page names fit as well")
            return try await Fake.write(request, context)
        }
        for number in ["", " 2", " 3"] {
            let result = try await run([source], "pdf", converters: [checking], suffix: "sıkıştırılmış")
            XCTAssertEqual(result.converted, 1)
            let name = try XCTUnwrap(result.outputs.first).lastPathComponent
            XCTAssertLessThanOrEqual(name.utf8.count, 240)
            XCTAssertTrue(name.hasPrefix(String(repeating: "a", count: 150)) && name.hasSuffix(" sıkıştırılmış\(number).pdf"), name)
        }

        // Cut between characters. A file URL hands a name back decomposed, as it goes to disk: g and its
        // breve are three bytes together, and no cut may part them.
        let turkish = try fixture.write("in/\(String(repeating: "ğ", count: 123)).md")
        XCTAssertEqual(turkish.lastPathComponent.utf8.count, 123 * 3 + 3)
        let result = try await run([turkish], "docx", converters: [checking])
        let name = try XCTUnwrap(result.outputs.first).lastPathComponent
        XCTAssertLessThanOrEqual(name.utf8.count, 240)
        XCTAssertGreaterThan(name.utf8.count, 200, "As much of the name as fits is kept")
        XCTAssertTrue(name.hasSuffix(".docx") && name.dropLast(5).allSatisfy { $0 == "ğ" }, name)
    }

    func testALocalizedSuffixIsCountedTheWayItReachesTheDisk() async throws {
        // Sixty bytes as Swift holds a word (precomposed); on disk every letter here is three bytes, not two.
        let suffix = String(repeating: "ğ", count: 30)
        XCTAssertEqual(suffix.utf8.count, 60)
        let pages = Fake { request, _ in
            try ["_p12345", "_p12346"].map { page in
                let url = request.outputURL(request.baseName + page)
                try Data("s".utf8).write(to: url)
                return url
            }
        }
        let stems = [String(repeating: "a", count: 250), String(repeating: "ş", count: 80), String(repeating: "日本語", count: 27)]
        for stem in stems {
            let source = try fixture.write("ek/\(UUID().uuidString)/\(stem).heic")
            let folder = source.deletingLastPathComponent()
            for converter in [Fake(), Fake(), pages] {
                let result = try await run([source], "webp", converters: [converter], suffix: suffix)
                XCTAssertEqual(result.converted, 1, "\(result.outcomes)")
            }
            // What the directory lists is what is on disk.
            let listed = try fm.contentsOfDirectory(atPath: folder.path).filter { $0 != source.lastPathComponent }
            XCTAssertEqual(listed.count, 3)
            for name in listed {
                XCTAssertLessThanOrEqual(name.utf8.count, 240, "A published name of \(name.utf8.count) bytes")
                XCTAssertTrue(name.contains(" ğğğğ"), "The suffix is still there: \(name.suffix(40))")
                for page in (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(name).path)) ?? [] {
                    XCTAssertLessThanOrEqual(page.utf8.count, 240, "A page name of \(page.utf8.count) bytes")
                }
            }
        }
        // Within its sixty bytes on disk a suffix is kept whole.
        let short = try fixture.write("ek/kısa/foto.heic")
        let result = try await run([short], "webp", suffix: "sıkıştırılmış")
        XCTAssertEqual(paths(result), [fixture.url("ek/kısa/foto sıkıştırılmış.webp").path])
    }

    func testAResultsFolderTheJobMadeIsNotLeftBehindEmpty() async throws {
        let source = try fixture.write("in/a.heic")
        let folder = fixture.url("in/Dönüştürülenler")
        let options = ConversionOptions(location: .subfolder("Dönüştürülenler"))
        let failing = Fake { _, _ in throw ConversionFailure("Bu görüntü okunamadı.") }
        var result = try await run([source], "png", converters: [failing], options: options)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a.heic"], "A job that produced nothing leaves no empty folder beside the files")
        result = try await run([source], "png", converters: [Fake { _, _ in throw ConversionSkip("Zaten yeterince küçük.") }], options: options)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertFalse(fm.fileExists(atPath: folder.path))

        // A cancelled job leaves nothing either.
        let entered = Flag()
        let waiting = Fake { _, _ in
            entered.set()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return []
        }
        let engine = fixture.engine([waiting])
        let job = try fixture.job([source], target: "png", options: options)
        let task = Task { await engine.run(job) }
        try await wait(for: "the converter") { entered.isSet }
        XCTAssertTrue(fm.fileExists(atPath: folder.path), "The folder is made before the work starts")
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.outcomes, [.cancelled])
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a.heic"])

        // One result among failures keeps the folder, and a folder that holds something is never removed.
        let other = try fixture.write("in/b.heic")
        let picky = Fake { request, context in
            if request.sources[0].lastPathComponent == "a.heic" { throw ConversionFailure("Bu görüntü okunamadı.") }
            return try await Fake.write(request, context)
        }
        result = try await run([source, other], "png", converters: [picky], options: options)
        XCTAssertEqual([result.converted, result.failed], [1, 1])
        XCTAssertEqual(fixture.names(in: folder), ["b.png"])
        result = try await run([source], "png", converters: [failing], options: options)
        XCTAssertEqual(fixture.names(in: folder), ["b.png"])

        // A folder that was there before the job is the user's, empty or not: it stays.
        try fixture.folder("in/Benim")
        result = try await run([source], "png", converters: [failing], options: ConversionOptions(location: .subfolder("Benim")))
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(fm.fileExists(atPath: fixture.url("in/Benim").path))
        // So does a folder the user chose, which is made again when it is gone.
        let chosen = fixture.url("seçilen/klasör")
        result = try await run([source], "png", converters: [failing], options: ConversionOptions(location: .folder(chosen.path)))
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(fm.fileExists(atPath: chosen.path))
    }

    func testAResultStillArrivesAfterAnotherJobRemovedTheResultsFolderTheyShare() async throws {
        let first = try fixture.write("in/a.heic"), second = try fixture.write("in/b.heic")
        let folder = fixture.url("in/Dönüştürülenler")
        let options = ConversionOptions(location: .subfolder("Dönüştürülenler"))
        let inside = OSAllocatedUnfairLock(initialState: Set<String>())
        let failNow = Flag(), finishNow = Flag()
        // The first job made the folder and fails; the second found it there and finishes afterwards.
        let gated = Fake { request, context in
            let name = request.sources[0].lastPathComponent
            inside.withLock { _ = $0.insert(name) }
            let gate = name == "a.heic" ? failNow : finishNow
            while !gate.isSet { try await Task.sleep(nanoseconds: 1_000_000) }
            if name == "a.heic" { throw ConversionFailure("Bu görüntü okunamadı.") }
            return try await Fake.write(request, context)
        }
        let engine = fixture.engine([gated])
        let failing = try fixture.job([first], target: "png", options: options)
        let finishing = try fixture.job([second], target: "png", options: options)
        let early = Task { await engine.run(failing) }
        try await wait(for: "the first job") { inside.withLock { $0.contains("a.heic") } }
        let late = Task { await engine.run(finishing) }
        try await wait(for: "the second job") { inside.withLock { $0.contains("b.heic") } }
        failNow.set()
        let failed = await early.value
        XCTAssertEqual(failed.failed, 1)
        XCTAssertFalse(fm.fileExists(atPath: folder.path), "The job that made the folder found it empty and took it away")
        finishNow.set()
        let finished = await late.value
        XCTAssertEqual(finished.outcomes, [.converted([folder.appendingPathComponent("b.png")])], "The folder is made once more for a result")
        XCTAssertEqual(fixture.names(in: folder), ["b.png"])
        XCTAssertTrue(finished.notices.isEmpty)
    }

    func testAColonInANameBecomesADash() async throws {
        let source = try fixture.write("in/12:30 toplantı.txt")
        let result = try await run([source], "pdf")
        XCTAssertEqual(paths(result), [fixture.url("in/12-30 toplantı.pdf").path])
    }

    func testTheWorkFolderIsEmptyListedWhileInUseAndGoneAfterwards() async throws {
        let source = try fixture.write("in/a.heic")
        let folders = OSAllocatedUnfairLock(initialState: [URL]())
        let recorder = recorder!
        func converter(_ end: @escaping @Sendable (ConversionRequest) throws -> [URL]) -> Fake {
            Fake { request, _ in
                folders.withLock { $0.append(request.workFolder) }
                XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: request.workFolder.path), [], "Empty to begin with")
                XCTAssertTrue(ConversionEngine.liveWorkFolders().contains(request.workFolder))
                XCTAssertTrue(recorder.started(0), "`started` means the work folder is already listed")
                XCTAssertTrue(request.workFolder.lastPathComponent.hasPrefix("NSIRD_") && request.workFolder.path.contains("/TemporaryItems/"),
                              "What the leftover sweep at launch looks for")
                try Data("yarım".utf8).write(to: request.workFolder.appendingPathComponent("kalıntı.tmp"))
                return try end(request)
            }
        }
        let endings: [@Sendable (ConversionRequest) throws -> [URL]] = [
            { request in let url = request.outputURL(); try Data("x".utf8).write(to: url); return [url] },
            { _ in throw ConversionFailure("Bu görüntü okunamadı.") },
            { _ in throw CancellationError() },
            { _ in [] }
        ]
        for end in endings { _ = try await run([source], "png", converters: [converter(end)]) }
        let used = folders.withLock { $0 }
        XCTAssertEqual(Set(used).count, 4, "Every request has a folder of its own")
        for folder in used { XCTAssertFalse(fm.fileExists(atPath: folder.path), "However the request ended, its folder is gone") }
        XCTAssertTrue(ConversionEngine.liveWorkFolders().isEmpty)
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a.heic", "a.png"])
    }

    // MARK: What a converter hands back

    func testWhatAConverterReturnsMustBeANonEmptyFileOfTheWorkFolder() async throws {
        let source = try fixture.write("in/a.heic")
        let outside = try fixture.write("elsewhere/benim.png", Data("benim".utf8))
        let cases: [(String, @Sendable (ConversionRequest) throws -> [URL])] = [
            ("nothing", { _ in [] }),
            ("an empty file", { request in try Data().write(to: request.outputURL()); return [request.outputURL()] }),
            ("a file that was never written", { request in [request.outputURL()] }),
            ("a folder", { request in
                try FileManager.default.createDirectory(at: request.outputURL(), withIntermediateDirectories: false)
                return [request.outputURL()]
            }),
            ("a link", { request in
                try FileManager.default.createSymbolicLink(at: request.outputURL(), withDestinationURL: outside)
                return [request.outputURL()]
            }),
            ("a file outside the work folder", { _ in [outside] }),
            ("a good file and a foreign one", { request in
                try Data("x".utf8).write(to: request.outputURL())
                return [request.outputURL(), outside]
            }),
            ("a file reached through a linked folder", { request in
                let link = request.workFolder.appendingPathComponent("dışarı")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
                return [link.appendingPathComponent("benim.png")]
            })
        ]
        for (name, body) in cases {
            let result = try await run([source], "png", converters: [Fake { request, _ in try body(request) }], options: ConversionOptions(trashOriginals: true))
            XCTAssertEqual(result.outcomes, [.failed(ConversionFailure("Dönüştürme boş bir dosya üretti."))], name)
        }
        XCTAssertEqual(text(outside), "benim")
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a.heic"], "Nothing was published and the original stayed")
        XCTAssertTrue(fixture.trashed.isEmpty)

        // A file in a folder of the work folder is fine, and one file named twice is one result.
        let nested = Fake { request, _ in
            let folder = request.workFolder.appendingPathComponent("iç")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let url = folder.appendingPathComponent("sonuç.png")
            try Data("x".utf8).write(to: url)
            return [url, url]
        }
        let fine = try await run([source], "png", converters: [nested])
        XCTAssertEqual(paths(fine), [fixture.url("in/a.png").path])
    }

    func testCompressingThatDoesNotShrinkIsSkipped() async throws {
        let source = try fixture.write("in/a.jpg", Data(repeating: 7, count: 1000))
        func sized(_ count: Int) -> Fake {
            Fake { request, _ in
                try Data(repeating: 1, count: count).write(to: request.outputURL())
                return [request.outputURL()]
            }
        }
        for count in [1000, 4000] {
            let result = try await run([source], "compress", converters: [sized(count)], suffix: "sıkıştırılmış")
            XCTAssertEqual(result.outcomes, [.skipped("Zaten yeterince küçük.")], "\(count) bytes from 1000")
        }
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a.jpg"], "A result that is not smaller is not kept")
        let smaller = try await run([source], "compress", converters: [sized(999)], suffix: "sıkıştırılmış")
        XCTAssertEqual(paths(smaller), [fixture.url("in/a sıkıştırılmış.jpg").path])
        // The rule is the compress target's: halving may give a bigger file.
        let half = try await run([source], "half", converters: [sized(4000)], suffix: "küçük")
        XCTAssertEqual(half.converted, 1)
    }

    // MARK: Publishing

    func testTwoEnginesPublishingTheSameNameAtTheSameMomentKeepBothResults() async throws {
        let destination = try fixture.folder("out")
        let options = ConversionOptions(location: .folder(destination.path))
        let converter = Fake { request, _ in
            try Data(request.sources[0].path.utf8).write(to: request.outputURL())
            return [request.outputURL()]
        }
        for round in 0..<25 {
            let a = try fixture.write("a\(round)/rapor.txt"), b = try fixture.write("b\(round)/rapor.txt")
            let first = fixture.engine([converter]), second = fixture.engine([converter])
            let jobA = try fixture.job([a], target: "pdf", options: options), jobB = try fixture.job([b], target: "pdf", options: options)
            async let one = first.run(jobA)
            async let two = second.run(jobB)
            let outputs = await [one, two].flatMap(\.outputs)
            XCTAssertEqual(Set(outputs.map(\.lastPathComponent)), ["rapor.pdf", "rapor 2.pdf"], "round \(round)")
            XCTAssertEqual(Set(outputs.compactMap(text)), [a.path, b.path], "Neither result replaced the other")
            for url in outputs { try fm.removeItem(at: url) }
        }
    }

    func testAReadOnlyFolderEndsInTheFallbackFolder() async throws {
        guard getuid() != 0 else { throw XCTSkip("Root may write anywhere") }
        let source = try fixture.write("kilitli/foto.heic"), second = try fixture.write("kilitli/resim.heic")
        let folder = source.deletingLastPathComponent()
        XCTAssertEqual(chmod(folder.path, 0o555), 0)
        defer { _ = chmod(folder.path, 0o755) }
        var result = try await run([source, second], "png")
        XCTAssertEqual(paths(result), [fixture.fallback.appendingPathComponent("foto.png").path, fixture.fallback.appendingPathComponent("resim.png").path])
        XCTAssertEqual(result.notices, [fallbackNotice], "Said once, however many files it happened to")
        XCTAssertEqual(result.converted, 2)
        XCTAssertEqual(fixture.names(in: folder), ["foto.heic", "resim.heic"])

        // A results folder that cannot be made there is known before the work starts.
        result = try await run([source], "png", options: ConversionOptions(location: .subfolder("Dönüştürülenler")))
        XCTAssertEqual(paths(result), [fixture.fallback.appendingPathComponent("foto 2.png").path])
        XCTAssertEqual(result.notices, [fallbackNotice])
        // And the pages of one source arrive there together.
        let pages = Fake { request, _ in
            try (1...2).map { page in
                let url = request.outputURL("\(request.baseName)_p\(page)")
                try Data("s".utf8).write(to: url)
                return url
            }
        }
        result = try await run([source], "jpg", converters: [pages])
        XCTAssertEqual(paths(result), [fixture.fallback.appendingPathComponent("foto").path])
        XCTAssertEqual(fixture.names(in: fixture.fallback.appendingPathComponent("foto")), ["foto_p1.jpg", "foto_p2.jpg"])
    }

    func testAFolderThatTurnsReadOnlyWhileConvertingStillDeliversToTheFallback() async throws {
        guard getuid() != 0 else { throw XCTSkip("Root may write anywhere") }
        let source = try fixture.write("sonradan/foto.heic")
        let folder = source.deletingLastPathComponent()
        defer { _ = chmod(folder.path, 0o755) }
        let locking = Fake { request, context in
            let files = try await Fake.write(request, context)
            XCTAssertEqual(chmod(folder.path, 0o555), 0)
            return files
        }
        let result = try await run([source], "png", converters: [locking])
        XCTAssertEqual(paths(result), [fixture.fallback.appendingPathComponent("foto.png").path], "Finished work is not thrown away with the folder that refused it")
        XCTAssertEqual(text(fixture.fallback.appendingPathComponent("foto.png")), "png <- foto.heic")
        XCTAssertEqual(result.notices, [fallbackNotice])
        XCTAssertEqual(fixture.names(in: folder), ["foto.heic"])
    }

    func testAPrivacyRefusalIsAFailureThatPointsToThePermissions() async throws {
        guard getuid() != 0 else { throw XCTSkip("Root may write anywhere") }
        let source = try fixture.write("korumalı/foto.heic")
        let folder = source.deletingLastPathComponent()
        // A folder that may not be changed refuses a new name with EPERM, the code a privacy refusal has.
        XCTAssertEqual(chflags(folder.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(folder.path, 0) }
        let result = try await run([source], "png")
        XCTAssertEqual(result.outcomes, [.failed(ConversionFailure("BStoeq’in bu klasöre yazma izni yok. Ayarlar → İzinler bölümünden izin verebilirsin."))])
        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertTrue(fixture.names(in: fixture.fallback).isEmpty, "A refusal the user can lift is not worked around")
        XCTAssertTrue(ConversionEngine.liveWorkFolders().isEmpty)
        XCTAssertEqual(starts(), [0], "Only the write itself can tell: the conversion ran")

        // A results folder that may not be made there is refused the same way, before any work.
        let subfolder = try await run([source], "png", options: ConversionOptions(location: .subfolder("Dönüştürülenler")))
        XCTAssertEqual(subfolder.outcomes, result.outcomes)
        XCTAssertEqual(starts(), [0], "Nothing was converted for it")
        XCTAssertEqual(fixture.names(in: folder), ["foto.heic"])
    }

    func testRefusalsAreToldApartByTheirCause() {
        func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        func cocoa(_ code: Int, under: NSError? = nil) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: code, userInfo: under.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        XCTAssertEqual(ConversionEngine.refusal(posix(EROFS)), .readOnly)
        XCTAssertEqual(ConversionEngine.refusal(posix(EACCES)), .readOnly)
        XCTAssertEqual(ConversionEngine.refusal(posix(EPERM)), .privacy)
        for code in [ENOSPC, ENOENT, EEXIST, ENAMETOOLONG, EXDEV] { XCTAssertEqual(ConversionEngine.refusal(posix(code)), .other, "\(code)") }
        XCTAssertEqual(ConversionEngine.refusal(cocoa(NSFileWriteVolumeReadOnlyError)), .readOnly)
        XCTAssertEqual(ConversionEngine.refusal(cocoa(NSFileWriteVolumeReadOnlyError, under: posix(EROFS))), .readOnly)
        XCTAssertEqual(ConversionEngine.refusal(cocoa(NSFileWriteNoPermissionError)), .readOnly)
        XCTAssertEqual(ConversionEngine.refusal(cocoa(NSFileWriteNoPermissionError, under: posix(EACCES))), .readOnly)
        XCTAssertEqual(ConversionEngine.refusal(cocoa(NSFileWriteNoPermissionError, under: posix(EPERM))), .privacy, "What lies underneath decides")
        XCTAssertEqual(ConversionEngine.refusal(cocoa(NSFileNoSuchFileError)), .other)
        XCTAssertEqual(ConversionEngine.refusal(cocoa(NSFileWriteOutOfSpaceError, under: posix(ENOSPC))), .other)
        XCTAssertEqual(ConversionEngine.refusal(ConversionFailure("x")), .other)
    }

    func testAFolderThatDisappearsBeforePublishingIsAFailureThatSaysSo() async throws {
        let source = try fixture.write("in/foto.heic")
        let chosen = try fixture.folder("out")
        let removing = Fake { request, context in
            let files = try await Fake.write(request, context)
            try FileManager.default.removeItem(at: chosen)
            return files
        }
        let result = try await run([source], "png", converters: [removing], options: ConversionOptions(location: .folder(chosen.path), trashOriginals: true))
        guard case .failed(let failure)? = result.outcomes.first else { return XCTFail("\(result.outcomes)") }
        XCTAssertEqual(failure.key, "Dosya kayıt klasörüne taşınamadı: %@")
        XCTAssertFalse(failure.detail?.isEmpty ?? true)
        XCTAssertTrue(fm.fileExists(atPath: source.path), "The original stays when its result did not arrive")
        XCTAssertTrue(fixture.trashed.isEmpty)
        XCTAssertTrue(fixture.names(in: fixture.fallback).isEmpty, "Only a folder that cannot be written is replaced by the fallback")
        XCTAssertTrue(ConversionEngine.liveWorkFolders().isEmpty)
    }

    func testAResultsFolderThatCannotBeUsedIsAFailureNotAGuess() async throws {
        let source = try fixture.write("in/foto.heic")
        try fixture.write("in/Çıktı")
        let elsewhere = try fixture.folder("başka yer")
        try fm.createSymbolicLink(at: fixture.url("in/Bağlantı"), withDestinationURL: elsewhere)
        let locations: [(String, OutputLocation)] = [
            ("a file where the results folder should be", .subfolder("Çıktı")),
            ("a link where the results folder should be", .subfolder("Bağlantı")),
            ("a chosen folder that is a file", .folder(fixture.url("in/Çıktı").path))
        ]
        for (name, location) in locations {
            let result = try await run([source], "png", options: ConversionOptions(location: location))
            guard case .failed(let failure)? = result.outcomes.first else { XCTFail(name); continue }
            XCTAssertEqual(failure.key, "Kayıt klasörü kullanılamıyor: %@", name)
            XCTAssertFalse(failure.detail?.isEmpty ?? true, name)
        }
        XCTAssertTrue(starts().isEmpty, "Nothing was converted for a folder that cannot take the result")
        XCTAssertTrue(fixture.names(in: elsewhere).isEmpty, "A link is not followed")
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["Bağlantı", "foto.heic", "Çıktı"])
        XCTAssertTrue(fixture.names(in: fixture.fallback).isEmpty)
    }

    // MARK: Originals

    func testOriginalsGoToTheTrashOnlyAfterAFormatConversionInsideOneFamily() async throws {
        let on = ConversionOptions(trashOriginals: true)
        func source(_ name: String) throws -> URL { try fixture.write("in/\(name)", Data(repeating: 3, count: 100)) }

        let photo = try source("foto.heic")
        var result = try await run([photo], "png", options: on)
        XCTAssertTrue(result.originalsTrashed)
        XCTAssertEqual(fixture.trashed, [photo])
        XCTAssertFalse(fm.fileExists(atPath: photo.path))
        XCTAssertEqual(paths(result), [fixture.url("in/foto.png").path])

        let clip = try source("klip.mp4")
        result = try await run([clip], "mp4.720p", options: on, suffix: "720p")
        XCTAssertTrue(result.originalsTrashed, "A variant is a format conversion in the same family")
        XCTAssertEqual(fixture.trashed, [photo, clip])
        XCTAssertEqual(paths(result), [fixture.url("in/klip 720p.mp4").path])

        // Never across families, for tools, for merges or for what did not convert.
        let kept = try ["resim.png", "film.mov", "belge.pdf", "a.pdf", "b.pdf"].map(source)
        let failing = Fake { _, _ in throw ConversionFailure("Bu görüntü okunamadı.") }
        let unkept: [(URL, String, [any Converter])] = [
            (kept[0], "pdf", [Fake()]), (kept[1], "m4a", [Fake()]), (kept[1], "gif", [Fake()]), (kept[2], "png", [Fake()]),
            (kept[2], "txt", [Fake()]), (kept[0], "half", [Fake()]), (kept[0], "nobg", [Fake()]), (kept[2], "pdf.split", [Fake()]),
            (kept[0], "jpg", [failing]), (kept[0], "png", [Fake()])
        ]
        for (url, target, converters) in unkept {
            result = try await run([url], target, converters: converters, options: on)
            XCTAssertFalse(result.originalsTrashed, target)
            XCTAssertTrue(fm.fileExists(atPath: url.path), target)
        }
        result = try await run([kept[3], kept[4]], "pdf.merge", options: on, suffix: "birleşik")
        XCTAssertEqual(result.converted, 2)
        XCTAssertFalse(result.originalsTrashed)
        XCTAssertEqual(fixture.trashed, [photo, clip], "Nothing else went")

        // The setting off: the Trash is never asked.
        let other = try source("başka.heic")
        let job = try fixture.job([other], target: "png")
        let untouched = await fixture.engine([Fake()]).run(job, moveToTrash: { _ in XCTFail("The setting is off") })
        XCTAssertEqual(untouched.converted, 1)
        XCTAssertFalse(untouched.originalsTrashed)
    }

    func testAnOriginalThatCannotBeTrashedIsANoticeNotAFailure() async throws {
        let a = try fixture.write("in/a.heic"), b = try fixture.write("in/b.heic"), c = try fixture.write("in/c.heic")
        let trash = fixture.moveToTrash
        let job = try fixture.job([a, b, c], target: "png", options: ConversionOptions(trashOriginals: true))
        let result = await fixture.engine([Fake()], limiter: ConversionLimiter(media: 1, other: 1)).run(job, moveToTrash: { url in
            if url.lastPathComponent != "b.heic" { throw CocoaError(.fileWriteNoPermission) }
            try trash(url)
        })
        XCTAssertEqual(result.converted, 3, "The conversions stand")
        XCTAssertEqual(result.notices, ["Bazı özgün dosyalar Çöp Sepeti’ne taşınamadı."], "Said once")
        XCTAssertTrue(result.originalsTrashed, "One original did go")
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a.heic", "a.png", "b.png", "c.heic", "c.png"])

        let options = ConversionOptions(trashOriginals: true)
        let png = try XCTUnwrap(TargetCatalog.target(id: "png")), heic = try XCTUnwrap(FormatRegistry.format(id: "heic"))
        let mov = try XCTUnwrap(FormatRegistry.format(id: "mov")), pdf = try XCTUnwrap(FormatRegistry.format(id: "pdf"))
        XCTAssertTrue(ConversionEngine.trashesOriginal(png, source: heic, options: options))
        XCTAssertFalse(ConversionEngine.trashesOriginal(png, source: heic, options: ConversionOptions()))
        XCTAssertFalse(ConversionEngine.trashesOriginal(png, source: pdf, options: options))
        XCTAssertTrue(ConversionEngine.trashesOriginal(try fixture.target("mp4.720p"), source: mov, options: options))
        XCTAssertFalse(ConversionEngine.trashesOriginal(try fixture.target("gif"), source: mov, options: options))
        for tool in ["half", "compress", "mute", "nobg", "ocr", "pdf.split", "pdf.merge"] {
            XCTAssertFalse(ConversionEngine.trashesOriginal(try fixture.target(tool), source: heic, options: options), tool)
        }
    }

    // MARK: Cancelling

    func testAConverterLoopingOnCheckCancelledInsideBlockingWorkEndsWithinASecondOfCancel() async throws {
        let sources = [try fixture.write("in/büyük.heic"), try fixture.write("in/sonraki.heic")]
        let looping = Fake { request, context in
            try await ConversionWork.run { () -> [URL] in
                try Data("yarım".utf8).write(to: request.outputURL())
                // What blocking work does between pages: ask, then go on.
                while true {
                    try context.checkCancelled()
                    usleep(2_000)
                }
            }
        }
        let engine = fixture.engine([looping], limiter: ConversionLimiter(media: 1, other: 1))
        let job = try fixture.job(sources, target: "png")
        let recorder = recorder!
        let task = Task { await engine.run(job, events: recorder.record) }
        try await wait(for: "the request") { recorder.started(0) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = DispatchTime.now()
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(seconds(since: start), 1)
        XCTAssertEqual(result.outcomes, [.cancelled, .cancelled])
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(starts(), [0], "The request behind it never started")
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["büyük.heic", "sonraki.heic"], "No partial output")
        XCTAssertTrue(ConversionEngine.liveWorkFolders().isEmpty)
    }

    func testCancellingRunAlsoCancelsWhatTheConverterAwaits() async throws {
        let source = try fixture.write("in/a.mov")
        let sleeping = Fake { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return []
        }
        let engine = fixture.engine([sleeping])
        let job = try fixture.job([source], target: "mp4")
        let recorder = recorder!
        let task = Task { await engine.run(job, events: recorder.record) }
        try await wait(for: "the request") { recorder.started(0) }
        let start = DispatchTime.now()
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(seconds(since: start), 1, "The converter runs in a child task of run")
        XCTAssertEqual(result.outcomes, [.cancelled])
    }

    func testAResultThatIsCompleteWhenTheCancelArrivesIsStillPublished() async throws {
        let source = try fixture.write("in/a.heic")
        let written = Flag()
        let finishing = Fake { request, context in
            let files = try await Fake.write(request, context)
            written.set()
            // The work is done; the cancel arrives now and the converter returns all the same.
            while !context.isCancelled() { try? await Task.sleep(nanoseconds: 1_000_000) }
            return files
        }
        let engine = fixture.engine([finishing])
        let job = try fixture.job([source], target: "png")
        let task = Task { await engine.run(job) }
        try await wait(for: "the file") { written.isSet }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcomes, [.converted([fixture.url("in/a.png")])])
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(text(fixture.url("in/a.png")), "png <- a.heic")

        // A converter that reports whatever its stopped tool said: that is a cancel, not a failure.
        let complaining = Fake { _, context in
            while !context.isCancelled() { try? await Task.sleep(nanoseconds: 1_000_000) }
            throw ConversionFailure("Dönüştürülemedi: %@", detail: "ffmpeg (255)")
        }
        let recorder = recorder!
        let other = fixture.engine([complaining])
        let second = Task { await other.run(job, events: recorder.record) }
        try await wait(for: "the request") { recorder.started(0) }
        second.cancel()
        let stopped = await second.value
        XCTAssertEqual(stopped.outcomes, [.cancelled])
    }

    // MARK: Errors, events, notes

    func testEveryThrownErrorBecomesItsOutcome() async throws {
        let source = try fixture.write("in/a.heic")
        func throwing(_ error: any Error) -> Fake { Fake { _, _ in throw error } }
        let failure = ConversionFailure("Görüntüde metin bulunamadı.")
        var result = try await run([source], "png", converters: [throwing(failure)])
        XCTAssertEqual(result.outcomes, [.failed(failure)], "A failure is passed on as it is")
        result = try await run([source], "png", converters: [throwing(ConversionFailure("Araç başlatılamadı: %@", detail: "ffmpeg: yok"))])
        XCTAssertEqual(result.outcomes, [.failed(ConversionFailure("Araç başlatılamadı: %@", detail: "ffmpeg: yok"))])
        result = try await run([source], "png", converters: [throwing(ConversionSkip("Tek sayfalı PDF bölünemez."))])
        XCTAssertEqual(result.outcomes, [.skipped("Tek sayfalı PDF bölünemez.")])
        XCTAssertEqual([result.converted, result.failed, result.skipped], [0, 0, 1])
        result = try await run([source], "png", converters: [throwing(CancellationError())])
        XCTAssertEqual(result.outcomes, [.cancelled])
        let odd = CocoaError(.fileReadCorruptFile)
        result = try await run([source], "png", converters: [throwing(odd)])
        XCTAssertEqual(result.outcomes, [.failed(ConversionFailure("Dönüştürülemedi: %@", detail: odd.localizedDescription))])
        XCTAssertEqual(fixture.names(in: fixture.url("in")), ["a.heic"])
    }

    func testEventsTellEachRequestsStoryAndNotesBecomeNotices() async throws {
        let a = try fixture.write("in/a.heic"), b = try fixture.write("in/b.heic")
        let converter = Fake { request, context in
            context.note("Yalnızca ilk kare dönüştürüldü.")
            context.note("Yalnızca ilk kare dönüştürüldü.")
            for fraction in [0.25, 2, -1, .nan, .infinity, 1] as [Double] { context.progress(fraction) }
            if request.sources[0].lastPathComponent == "b.heic" {
                context.note("Zil sesi ilk 30 saniyeden oluşturuldu.")
                throw ConversionFailure("Bu görüntü okunamadı.")
            }
            return try await Fake.write(request, context)
        }
        let job = try fixture.job([a, b], target: "png")
        let result = await fixture.engine([converter], limiter: ConversionLimiter(media: 1, other: 1)).run(job, events: recorder.record)
        let progress = [0.25, 1, 0, 1]
        XCTAssertEqual(recorder.events, [.started(index: 0)] + progress.map { .progress(index: 0, fraction: $0) }
                       + [.finished(index: 0, outcome: .converted([fixture.url("in/a.png")])), .started(index: 1)]
                       + progress.map { .progress(index: 1, fraction: $0) }
                       + [.finished(index: 1, outcome: .failed(ConversionFailure("Bu görüntü okunamadı.")))],
                       "Out of range fractions are clamped, what is no number is dropped")
        XCTAssertEqual(result.notices, ["Yalnızca ilk kare dönüştürüldü."], "Each note once, and only for a result that exists")
    }

    func testNothingAConverterSaysAfterItHasReturnedIsPassedOn() async throws {
        let sources = [try fixture.write("in/a.heic"), try fixture.write("in/b.heic")]
        let stop = Flag()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // A progress reporter that outlives the conversion by a moment, as a polling task or a timer does.
        let converter = Fake { request, context in
            let running = Flag()
            Thread.detachNewThread {
                while !stop.isSet {
                    context.progress(0.5)
                    context.note("Yalnızca ilk kare dönüştürüldü.")
                    calls.withLock { $0 += 1 }
                    running.set()
                    usleep(100)
                }
            }
            while !running.isSet { try await Task.sleep(nanoseconds: 200_000) }
            if request.sources[0].lastPathComponent == "b.heic" { throw ConversionFailure("Bu görüntü okunamadı.") }
            return try await Fake.write(request, context)
        }
        let result = await fixture.engine([converter]).run(try fixture.job(sources, target: "png"), events: recorder.record)
        // The reporters go on for a while after `run` itself has returned.
        let returned = calls.withLock { $0 }
        try await wait(for: "the reporters to call again") { calls.withLock { $0 } > returned + 50 }
        stop.set()
        XCTAssertEqual([result.converted, result.failed], [1, 1])
        XCTAssertEqual(result.notices, ["Yalnızca ilk kare dönüştürüldü."], "What was said in time still counts")
        let events = recorder.events
        for index in 0..<2 {
            let own = events.filter { self.index(of: $0) == index }
            XCTAssertEqual(own.first, .started(index: index))
            XCTAssertGreaterThan(own.count, 2, "Progress that was reported in time arrived")
            guard case .finished? = own.last else { return XCTFail("Progress arrived after finished for \(index): \(own.suffix(3))") }
            XCTAssertEqual(own.filter { if case .finished = $0 { true } else { false } }.count, 1)
        }
        XCTAssertEqual(recorder.events.count, events.count, "And nothing arrives once the job is over")
    }

    // MARK: Asking

    func testAnMP4IsOfferedItsVariantsButNotItself() async throws {
        let clip = try fixture.write("in/klip.mp4")
        let engine = fixture.engine([Fake()])
        let offered = engine.offers(for: [clip]).map(\.id)
        XCTAssertTrue(offered.contains("mp4.720p") && offered.contains("mp4.hevc"))
        XCTAssertFalse(offered.contains("mp4"), "A file is not offered its own format")
        XCTAssertEqual(offered, TargetCatalog.all.map(\.id).filter { $0 != "mp4" }, "In catalog order")
        XCTAssertEqual(engine.availability(of: try fixture.target("mp4"), for: clip), .unsupported)
        XCTAssertEqual(engine.availability(of: try fixture.target("mp4.720p"), for: clip), .available)

        let same = try await run([clip], "mp4")
        XCTAssertEqual(same.outcomes, [.skipped(unfit)])
        let small = try await run([clip], "mp4.720p", suffix: "720p")
        XCTAssertEqual(paths(small), [fixture.url("in/klip 720p.mp4").path])
        let hevc = try await run([clip], "mp4.hevc", suffix: "HEVC")
        XCTAssertEqual(paths(hevc), [fixture.url("in/klip HEVC.mp4").path])
    }

    func testOffersCountWhatFitsAndCarryNotesAndMissingTools() throws {
        let converter = Fake(accepts: { target, source, environment in
            switch (source.family, target.id) {
            case (.image, "png"), (.image, "jpg"): target.id == source.id ? .unsupported : .available
            case (.image, "webp"): environment.cwebp == nil ? .needs("cwebp") : .available
            case (.pdf, "png"), (.pdf, "docx"): .available
            case (.audio, "mp3"): .needs("ffmpeg")
            default: .unsupported
            }
        }, caveat: { target, source in
            target.id == "docx" ? "Yalnızca metin aktarılır; düzen ve görseller korunmaz." : source.id == "pdf" ? "pdf notu" : nil
        })
        let photo = try fixture.write("in/a.heic")
        let link = fixture.url("in/kısayol.heic")
        try fm.createSymbolicLink(at: link, withDestinationURL: photo)
        let files = [photo, fixture.url("in/b.png"), fixture.url("in/c.pdf"), fixture.url("in/d.xyz"), link, fixture.url("in/e.PNG")]
        let engine = fixture.engine([converter])
        let offers = engine.offers(for: files)
        XCTAssertEqual(offers.map(\.id), ["jpg", "png", "webp", "docx"], "Catalog order; what fits nothing is left out")
        XCTAssertEqual(offers.map(\.fitting), [3, 2, 0, 1], "A link fits nothing; a PNG is not offered PNG")
        XCTAssertEqual(offers.map(\.total), [6, 6, 6, 6])
        XCTAssertEqual(offers.map(\.availability), [.available, .available, .needs("cwebp"), .available])
        XCTAssertEqual(offers.map(\.noteKey), [nil, "pdf notu", nil, "Yalnızca metin aktarılır; düzen ve görseller korunmaz."],
                       "The first note among the fitting files")
        XCTAssertEqual(offers.map(\.isUsable), [true, true, false, true])
        XCTAssertEqual(offers[0].id, offers[0].target.id)

        let withTool = fixture.engine([converter], environment: ConversionEnvironment(cwebp: URL(fileURLWithPath: "/opt/homebrew/bin/cwebp")))
        XCTAssertEqual(withTool.offers(for: files).first { $0.id == "webp" }?.fitting, 3)
        XCTAssertEqual(engine.offers(for: [fixture.url("in/şarkı.wav")]).map(\.availability), [.needs("ffmpeg")])
        XCTAssertTrue(engine.offers(for: []).isEmpty)
        XCTAssertTrue(engine.offers(for: [fixture.url("in/d.xyz")]).isEmpty)

        // One file is not a merge yet.
        let merge = fixture.engine([Fake()]).offers(for: [fixture.url("in/c.pdf")]).first { $0.id == "pdf.merge" }
        XCTAssertEqual(merge?.fitting, 1)
        XCTAssertEqual(merge?.isUsable, false)
    }

    func testAvailabilityAsksEveryConverterAndEveryFormat() throws {
        let photo = try fixture.write("in/a.heic")
        let link = fixture.url("in/kısayol.heic")
        try fm.createSymbolicLink(at: link, withDestinationURL: photo)
        let engine = fixture.engine([Fake(sources: ["heic"], targets: ["png"]),
                                     Fake(accepts: { target, source, _ in source.family == .audio && target.id == "mp3" ? .needs("ffmpeg") : .unsupported })])
        let png = try fixture.target("png"), mp3 = try fixture.target("mp3"), mkv = try fixture.target("mkv")
        XCTAssertEqual(engine.availability(of: png, for: photo), .available)
        XCTAssertEqual(engine.availability(of: png, for: fixture.url("in/b.jpg")), .unsupported)
        XCTAssertEqual(engine.availability(of: mp3, for: fixture.url("in/c.wav")), .needs("ffmpeg"))
        XCTAssertEqual(engine.availability(of: png, for: link), .unsupported, "run would pass a link over")
        XCTAssertEqual(engine.availability(of: png, for: fixture.url("in/d.xyz")), .unsupported)
        XCTAssertEqual(engine.availability(of: png, for: fixture.url("in/gone.heic")), .available, "A missing file is judged by its name; run reports it")

        XCTAssertEqual(engine.availability(of: png), .available)
        XCTAssertEqual(engine.availability(of: mp3), .needs("ffmpeg"))
        XCTAssertEqual(engine.availability(of: mkv), .unsupported)
        XCTAssertTrue(engine.claims(png, family: .image))
        XCTAssertFalse(engine.claims(png, family: .audio))
        XCTAssertTrue(engine.claims(mp3, family: .audio), "A missing tool is still a claim")
        XCTAssertTrue(engine.claims(mp3, family: nil))
        XCTAssertFalse(engine.claims(mkv, family: nil))
        XCTAssertFalse(engine.claims(png, family: .other))
        XCTAssertEqual(engine.fallbackFolder, fixture.fallback)
        XCTAssertEqual(ConversionEngine.downloadsFolder.lastPathComponent, "Downloads")
    }
}
