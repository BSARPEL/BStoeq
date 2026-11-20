import XCTest
@testable import ArchiveCore

final class ProcessRegressionTests: XCTestCase {
    func testPasswordsStayRedactedAcrossEveryPipeSplit() {
        for password in ["secret", "türkçe-🔑", "a", "abab"] {
            let original = "İstanbul 🗂️ \(password) / \(password) beendet ✓"
            let bytes = Data(original.utf8)
            let expected = original.replacingOccurrences(of: password, with: "••••")
            for boundary in 0...bytes.count {
                var filter = ProcessOutputFilter(password: password)
                let actual = filter.consume(bytes.prefix(boundary))
                    + filter.consume(bytes.suffix(bytes.count - boundary)) + filter.finish()
                XCTAssertEqual(actual, expected, "Password \(password), boundary \(boundary)")
            }
        }
    }

    func testUnicodeOutputSurvivesOneByteReads() {
        let original = "Türkçe / Deutsch / 日本語 / 🗂️ / 👨‍👩‍👦"
        for password in ["", "unused-password"] {
            var filter = ProcessOutputFilter(password: password)
            var result = ""
            for byte in original.utf8 { result += filter.consume(Data([byte])) }
            result += filter.finish()
            XCTAssertEqual(result, original)
        }
    }

    func testRunningEngineThatIgnoresTerminateCanStillBeCancelled() async throws {
        let token = JobControl()
        let ready = expectation(description: "Engine started")
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(tool: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: ["-c", "trap '' TERM; printf ready; exec /bin/sleep 8"],
                                        control: token) { chunk in
                if chunk.contains("ready") { ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 3)
        token.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled engine should not report success")
        } catch ArchiveError.cancelled { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "Cancellation must escalate when the engine ignores SIGTERM")
    }

    func testRawOutputRemainsIntactWhileLogIsRedacted() async throws {
        let log = LogCapture()
        let raw = try await ProcessRunner.run(tool: URL(fileURLWithPath: "/bin/cat"),
                                              arguments: [], password: "türkçe-🔑", control: JobControl()) {
            log.append($0)
        }
        XCTAssertEqual(raw, "türkçe-🔑\ntürkçe-🔑\n")
        XCTAssertEqual(log.value, "••••\n••••\n")
    }

    func testLongPasswordDoesNotDeadlockOutputBeforeInput() async throws {
        let password = String(repeating: "x", count: 300_000)
        // Write beyond pipe capacity before reading the password. A synchronous
        // stdin write and stdout read wait on each other in this situation.
        let token = JobControl()
        let task = Task {
            try await ProcessRunner.run(tool: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: ["-c", "/usr/bin/head -c 300000 /dev/zero; /bin/cat >/dev/null"],
                                        password: password, control: token)
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(8))
            token.cancel()
        }
        defer { watchdog.cancel() }
        let output = try await task.value
        XCTAssertEqual(output.utf8.count, 300_000)
    }
}

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) { lock.lock(); defer { lock.unlock() }; text += chunk }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
