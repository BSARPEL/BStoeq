import os
import XCTest
@testable import ConvertCore

/// Real child processes: system tools and stand-in scripts written into the fixture.
final class ToolProcessTests: XCTestCase {
    private var fixture: ConversionFixture!

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "tools") }
    override func tearDownWithError() throws { fixture.remove() }

    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let sleep = URL(fileURLWithPath: "/bin/sleep")
    private let cat = URL(fileURLWithPath: "/bin/cat")

    private func script(_ name: String, _ body: String) throws -> URL { try fixture.tool("bin/\(name)", body) }
    private func isGone(_ process: Int32) -> Bool { kill(process, 0) != 0 && errno == ESRCH }

    /// Waits until the one child of this test is running and answers its process id.
    private func child() async throws -> Int32 {
        for _ in 0..<1000 {
            if let process = ToolProcess.liveProcessIdentifiers.first, process > 0 { return process }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("The child never started")
        throw CancellationError()
    }
    private func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    /// Bytes that are not text: no line break, and sequences UTF-8 does not allow.
    private func binary(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count {
                let byte = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 8)
                buffer[index] = byte == 0x0A || byte == 0x0D ? 0xFF : byte
            }
        }
        return data
    }

    // MARK: Output

    func testExitCodesAndBothStreamsComeBack() async throws {
        let plain = try await ToolProcess.run(shell, arguments: ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(plain.status, 3, "A non-zero exit is an answer, not an error")
        XCTAssertTrue(plain.stdout.isEmpty, "Lines mode keeps no bytes")
        XCTAssertEqual(plain.stderrTail, "err\n")

        let quick = DispatchTime.now()
        let empty = try await ToolProcess.run(cat, arguments: [])
        XCTAssertEqual(empty.status, 0, "Standard input is the null device: cat ends at once")
        XCTAssertLessThan(seconds(since: quick), 0.9, "End of file is seen without waiting for the grace period")

        let folder = try fixture.folder("çalışma klasörü")
        let here = try await ToolProcess.run(URL(fileURLWithPath: "/bin/pwd"), arguments: [], directory: folder, capture: .data(limit: 10_000))
        XCTAssertEqual(String(decoding: here.stdout, as: UTF8.self), folder.path + "\n")
        let variables = try await ToolProcess.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: [], environment: ["BARLET_TEST": "değer"],
                                                  capture: .data(limit: 10_000))
        XCTAssertEqual(String(decoding: variables.stdout, as: UTF8.self), "BARLET_TEST=değer\n", "A given environment replaces the inherited one")
        let literal = try await ToolProcess.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["$HOME", "*", "a b"], capture: .data(limit: 100))
        XCTAssertEqual(String(decoding: literal.stdout, as: UTF8.self), "$HOME * a b\n", "No shell reads the arguments")
    }

    func testLinesAreSplitOnLineFeedsAndCarriageReturns() async throws {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let tool = try script("lines", #"printf 'bir\r\niki\rüç ğış\n\ndört'"#)
        let output = try await ToolProcess.run(tool, arguments: [], capture: .lines { line in lines.withLock { $0.append(line) } })
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(lines.withLock { $0 }, ["bir", "iki", "üç ğış", "dört"], "Empty lines are dropped; the last line needs no line break")
        XCTAssertTrue(output.stdout.isEmpty)

        // Progress lines of an encoder, as they arrive while it runs.
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let progress = try script("progress", "for n in 1 2 3; do printf 'out_time_us=%s000000\\r' $n; done")
        _ = try await ToolProcess.run(progress, arguments: [], capture: .lines { line in seen.withLock { $0.append(line) } })
        XCTAssertEqual(seen.withLock { $0 }, ["out_time_us=1000000", "out_time_us=2000000", "out_time_us=3000000"])
    }

    func testALineOverAMegabyteIsDroppedWholeAndTheLinesAfterItArrive() async throws {
        // 1.5 MB without a break, then two ordinary lines: the tail of the long one is not a line of its own.
        let long = "/usr/bin/head -c 1500000 /dev/zero | /usr/bin/tr '\\0' 'x'"
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let capture = ToolCapture.lines { line in lines.withLock { $0.append(line.count > 20 ? "<\(line.count) bytes>" : line) } }
        let between = try script("long", "printf 'sıfır\\n'\n\(long)\nprintf '\\nbir\\r\\niki\\n'")
        var output = try await ToolProcess.run(between, arguments: [], capture: capture)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(lines.withLock { $0 }, ["sıfır", "bir", "iki"])

        // Twice over the limit in one line, and a long line that is the last thing the tool says.
        lines.withLock { $0 = [] }
        let last = try script("last", "printf 'bir\\n'\n\(long)\n\(long)\nprintf '\\riki\\n'\n\(long)")
        output = try await ToolProcess.run(last, arguments: [], capture: capture)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(lines.withLock { $0 }, ["bir", "iki"], "What is left of a dropped line when the tool ends is not a line either")

        // Just under the limit is a line like any other.
        lines.withLock { $0 = [] }
        let fits = try script("fits", "/usr/bin/head -c 900000 /dev/zero | /usr/bin/tr '\\0' 'x'\nprintf '\\nson\\n'")
        output = try await ToolProcess.run(fits, arguments: [], capture: capture)
        XCTAssertEqual(lines.withLock { $0 }, ["<900000 bytes>", "son"])
    }

    func testFiveMegabytesWithoutALineBreakAndBytesThatAreNotTextSurviveDataCapture() async throws {
        let bytes = binary(5 * 1024 * 1024)
        XCTAssertNil(String(data: bytes, encoding: .utf8), "The fixture must not be text")
        XCTAssertFalse(bytes.contains(0x0A) || bytes.contains(0x0D))
        let file = try fixture.write("blob.bin", bytes)

        let whole = try await ToolProcess.run(cat, arguments: [file.path], capture: .data(limit: 6_000_000))
        XCTAssertEqual(whole.status, 0)
        XCTAssertEqual(whole.stdout, bytes)
        let exact = try await ToolProcess.run(cat, arguments: [file.path], capture: .data(limit: bytes.count))
        XCTAssertEqual(exact.stdout.count, bytes.count, "The limit itself is allowed")

        // The same bytes in pieces, in order.
        let pieces = OSAllocatedUnfairLock(initialState: Data())
        let chunked = try await ToolProcess.run(cat, arguments: [file.path], capture: .chunks { piece in pieces.withLock { $0.append(piece) } })
        XCTAssertEqual(pieces.withLock { $0 }, bytes)
        XCTAssertTrue(chunked.stdout.isEmpty)

        // And through the line splitter nothing blocks or grows without bound.
        let ignored = try await ToolProcess.run(cat, arguments: [file.path], capture: .lines { _ in })
        XCTAssertEqual(ignored.status, 0)
        let dropped = try await ToolProcess.run(cat, arguments: [file.path])
        XCTAssertEqual(dropped.status, 0)
    }

    func testPassingTheLimitEndsTheToolAndThrows() async throws {
        let file = try fixture.write("blob.bin", binary(3_000_000))
        do {
            _ = try await ToolProcess.run(cat, arguments: [file.path], capture: .data(limit: 1_000_000))
            XCTFail("Three megabytes do not fit in one")
        } catch let failure as ConversionFailure {
            XCTAssertEqual(failure, ConversionFailure("Araç çıktısı çok büyük: %@", detail: "cat"))
        }
        // A tool that never stops writing is stopped.
        let start = DispatchTime.now()
        do {
            _ = try await ToolProcess.run(URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], capture: .data(limit: 100_000))
            XCTFail("yes never ends by itself")
        } catch let failure as ConversionFailure {
            XCTAssertEqual(failure.key, "Araç çıktısı çok büyük: %@")
        }
        XCTAssertLessThan(seconds(since: start), 5)
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
    }

    func testAChattyToolCannotDeadlockOnEitherStream() async throws {
        // A megabyte on each stream, stderr first: reading one stream after the other would never finish.
        let tool = try script("chatty", """
        dd if=/dev/zero bs=1024 count=1024 2>/dev/null | tr '\\0' 'e' >&2
        dd if=/dev/zero bs=1024 count=1024 2>/dev/null | tr '\\0' 'o'
        printf 'son satır ğüş' >&2
        """)
        let output = try await ToolProcess.run(tool, arguments: [], capture: .data(limit: 2_000_000))
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.count, 1024 * 1024)
        XCTAssertTrue(output.stdout.allSatisfy { $0 == UInt8(ascii: "o") })
        XCTAssertEqual(output.stderrTail.utf8.count, 4096, "The last 4 KB of stderr")
        XCTAssertTrue(output.stderrTail.hasPrefix("eeee"))
        XCTAssertTrue(output.stderrTail.hasSuffix("eeeeson satır ğüş"), "What the tool said last is what is kept")
    }

    func testAToolThatCannotBeLaunchedThrowsAFailureThatNamesIt() async throws {
        do {
            _ = try await ToolProcess.run(fixture.url("bin/yok-böyle-bir-araç"), arguments: ["x"])
            XCTFail("There is no such tool")
        } catch let failure as ConversionFailure {
            XCTAssertEqual(failure.key, "Araç başlatılamadı: %@")
            XCTAssertTrue(failure.detail?.hasPrefix("yok-böyle-bir-araç: ") == true, failure.detail ?? "")
        }
        let notExecutable = try fixture.write("bin/düz.txt", Data("metin".utf8))
        do {
            _ = try await ToolProcess.run(notExecutable, arguments: [])
            XCTFail("A text file is not a tool")
        } catch let failure as ConversionFailure {
            XCTAssertEqual(failure.key, "Araç başlatılamadı: %@")
        }
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
    }

    func testAHelperThatOutlivesTheToolDoesNotHoldTheCallOpen() async throws {
        // The background sleep inherits both pipes and keeps them open after the script has ended.
        let tool = try script("helper", "/bin/sleep 4 &\necho bitti")
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let start = DispatchTime.now()
        let output = try await ToolProcess.run(tool, arguments: [], capture: .lines { line in lines.withLock { $0.append(line) } })
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(lines.withLock { $0 }, ["bitti"])
        XCTAssertLessThan(seconds(since: start), 3, "The streams are given up one second after the exit")
    }

    func testManyRunsLeaveNoDescriptorsOpen() async throws {
        func descriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        let tool = URL(fileURLWithPath: "/usr/bin/true")
        _ = try await ToolProcess.run(tool, arguments: [])
        let before = descriptors()
        for _ in 0..<150 { _ = try await ToolProcess.run(tool, arguments: [], capture: .data(limit: 10)) }
        // The pipes are closed a moment after a call returns.
        for _ in 0..<400 where descriptors() > before + 4 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertLessThanOrEqual(descriptors(), before + 4, "Every call gives its two pipes back")
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
    }

    // MARK: Stopping

    func testASleepingChildIsGoneAfterCancel() async throws {
        let sleep = sleep
        let task = Task { try await ToolProcess.run(sleep, arguments: ["30"]) }
        let process = try await child()
        XCTAssertFalse(isGone(process))
        let start = DispatchTime.now()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run does not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(seconds(since: start), 1.5, "SIGTERM is sent from the cancellation handler, at once")
        XCTAssertTrue(isGone(process), "The child is gone, not just forgotten")
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
    }

    func testASleepingChildIsGoneAfterTerminateAll() async throws {
        let sleep = sleep
        let task = Task { try await ToolProcess.run(sleep, arguments: ["30"]) }
        let process = try await child()
        let start = DispatchTime.now()
        ToolProcess.terminateAll()
        do {
            _ = try await task.value
            XCTFail("A stopped tool does not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "Quit ends every run as cancelled: \(error)")
        }
        XCTAssertLessThan(seconds(since: start), 1.5)
        XCTAssertTrue(isGone(process))
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
        ToolProcess.terminateAll()  // With nothing running it does nothing.
    }

    func testTerminateAllReachesAToolAtEveryMomentOfItsLaunch() throws {
        // A call is listed from the moment it is made. The pause grows from nothing to two milliseconds, so
        // the quit arrives before the launch, in the middle of it and after it: no tool may run on.
        let rounds = 160
        let ends = OSAllocatedUnfairLock(initialState: [Result<ToolOutput, Error>]())
        let done = DispatchSemaphore(value: 0)
        for round in 0..<rounds {
            ToolProcess.launch(sleep, arguments: ["20"]) { result in
                ends.withLock { $0.append(result) }
                done.signal()
            }
            let pause = UInt64(round % 40) * 50_000, from = DispatchTime.now().uptimeNanoseconds
            while DispatchTime.now().uptimeNanoseconds - from < pause {}
            ToolProcess.terminateAll()
            guard done.wait(timeout: .now() + 4) == .success else {
                XCTFail("Round \(round): terminateAll() passed over a tool whose call had already been made")
                break
            }
        }
        let results = ends.withLock { $0 }
        XCTAssertEqual(results.count, rounds)
        for result in results {
            guard case .failure(let error) = result else { XCTFail("A stopped tool does not return a result"); continue }
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        ToolProcess.terminateAll()
        XCTAssertEqual(ToolProcess.pendingCount, 0, "A call that has ended is not listed any more")
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
    }

    func testACallIsListedBeforeItsToolIsLaunchedAndLeavesTheListHoweverItEnds() async throws {
        let sleep = sleep
        let task = Task { try await ToolProcess.run(sleep, arguments: ["20"]) }
        for _ in 0..<2000 where ToolProcess.pendingCount == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(ToolProcess.pendingCount, 1)
        ToolProcess.terminateAll()
        do {
            _ = try await task.value
            XCTFail("A stopped tool does not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(ToolProcess.pendingCount, 0)
        // A tool that cannot be launched and a call that was never wanted leave the list as well.
        _ = try? await ToolProcess.run(fixture.url("bin/yok"), arguments: [])
        let unwanted = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolProcess.run(sleep, arguments: ["20"])
        }
        _ = try? await unwanted.value
        XCTAssertEqual(ToolProcess.pendingCount, 0)
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
    }

    func testTheFixtureCancelsAConverterThatWaitsForAToolTheWayTheEngineDoes() async throws {
        // The flag is for work that polls it; a converter that awaits a tool is stopped through its task.
        struct Tooled: Converter {
            let tool: URL
            func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability { .available }
            func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
                _ = try await ToolProcess.run(tool, arguments: [request.outputURL().path], capture: .lines { _ in context.progress(0.1) })
                return [request.outputURL()]
            }
        }
        let tool = try script("yavaş", "echo hazır\nprintf x > \"$1\"\nexec /bin/sleep 20")
        let request = try fixture.request([try fixture.write("m/a.wav")], target: "mp3")
        let task = fixture.start(Tooled(tool: tool), request)
        for _ in 0..<2000 where fixture.progress.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(fixture.progress, [0.1])
        let start = DispatchTime.now()
        fixture.cancelAll()
        do {
            _ = try await task.value
            XCTFail("A cancelled converter does not return files")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(seconds(since: start), 1.5)
        XCTAssertTrue(fixture.cancel.isSet)
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
    }

    func testAChildThatIgnoresTheSignalIsKilledTwoSecondsLater() async throws {
        // The script says when its trap is in place: the first run of a new script can take a while to begin.
        let tool = try script("stubborn", "trap '' TERM\necho hazır\nwhile :; do /bin/sleep 0.1; done")
        let ready = ConversionFixture.Flag()
        let task = Task { try await ToolProcess.run(tool, arguments: [], capture: .lines { if $0 == "hazır" { ready.set() } }) }
        let process = try await child()
        for _ in 0..<2000 where !ready.isSet { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(ready.isSet)
        let start = DispatchTime.now()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run does not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let waited = seconds(since: start)
        XCTAssertGreaterThan(waited, 1.5, "It was given its two seconds")
        XCTAssertLessThan(waited, 6)
        XCTAssertTrue(isGone(process))
    }

    func testATaskCancelledBeforehandStartsNothing() async throws {
        let marker = fixture.url("ran")
        let tool = try script("mark", "touch '\(marker.path)'")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolProcess.run(tool, arguments: [])
        }
        do {
            _ = try await task.value
            XCTFail("Nothing may run for a cancelled task")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAToolThatEndedByItselfIsNotReportedAsCancelled() async throws {
        // Cancel arrives when the work is done: the output still counts.
        let output = try await ToolProcess.run(shell, arguments: ["-c", "echo tamam"], capture: .data(limit: 100))
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "tamam\n")
        let killed = try await ToolProcess.run(shell, arguments: ["-c", "kill -9 $$"])
        XCTAssertEqual(killed.status, SIGKILL, "A signal that was not ours comes back as the status")
    }

    func testBlockingCollectionForDetectionReturnsOutputOrNothing() throws {
        let output = try XCTUnwrap(ToolProcess.collect(shell, arguments: ["-c", "echo encoders; exit 2"]))
        XCTAssertEqual(output.status, 2)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "encoders\n")
        XCTAssertNil(ToolProcess.collect(fixture.url("bin/yok"), arguments: []))
        let start = DispatchTime.now()
        XCTAssertNil(ToolProcess.collect(sleep, arguments: ["30"], timeout: 0.3), "A tool that hangs is stopped")
        XCTAssertLessThan(seconds(since: start), 3)
        XCTAssertTrue(ToolProcess.liveProcessIdentifiers.isEmpty)
    }
}
