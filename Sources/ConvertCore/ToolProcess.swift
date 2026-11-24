import Foundation
import os

/// How a tool ended and what it said.
public struct ToolOutput: Sendable {
    /// The exit code, or the signal number when a signal ended the tool.
    public let status: Int32
    /// Filled by `ToolCapture.data` only.
    public let stdout: Data
    /// The last 4 KB the tool wrote to stderr.
    public let stderrTail: String

    public init(status: Int32, stdout: Data = Data(), stderrTail: String = "") {
        self.status = status; self.stdout = stdout; self.stderrTail = stderrTail
    }
}

/// What happens to a tool's stdout. The closures run on a private queue, in output order.
public enum ToolCapture: Sendable {
    /// Decoded as UTF-8 and split on LF and CR (ffmpeg separates progress with CR); `stdout` stays empty.
    /// Empty lines are dropped, and so is a line of more than 1 MB, whole.
    case lines((@Sendable (String) -> Void)?)
    /// Collected into `stdout`; passing the limit ends the tool and throws.
    case data(limit: Int)
    /// Bytes as they arrive.
    case chunks(@Sendable (Data) -> Void)
}

/// Runs the user's command-line tools. No shell is involved: the arguments reach the tool as they are.
public enum ToolProcess {
    /// A non-zero exit is returned in `status`, never thrown. Three things throw: a tool that could not be
    /// launched and a passed limit, each as a `ConversionFailure` that names the tool, and a tool that was
    /// stopped, as `CancellationError`. Null stdin; stderr's last 4 KB kept.
    /// Cancelling the calling task sends SIGTERM at once (from the cancellation handler, not from a
    /// poll) and SIGKILL 2 s later. A tool that had already ended by itself still returns its output.
    public static func run(_ tool: URL, arguments: [String], directory: URL? = nil,
                           environment: [String: String]? = nil, capture: ToolCapture = .lines(nil)) async throws -> ToolOutput {
        let child = Child(tool: tool, arguments: arguments, directory: directory, environment: environment, capture: capture)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.start { continuation.resume(with: $0) }
            }
        } onCancel: {
            child.stop()
        }
    }

    /// Quit: every child this process started gets SIGTERM now, and a call that has not launched its tool
    /// yet never launches it. Their `run` calls end with `CancellationError`.
    public static func terminateAll() {
        for child in registry.withLock({ Array($0.values) }) { child.stop() }
    }

    /// Starts a tool without waiting for it and answers how to stop it. `completion` is called exactly
    /// once, on a private queue. From the moment this returns, `terminateAll()` reaches the tool.
    @discardableResult
    static func launch(_ tool: URL, arguments: [String], capture: ToolCapture = .lines(nil),
                       completion: @escaping @Sendable (Result<ToolOutput, Error>) -> Void) -> @Sendable () -> Void {
        let child = Child(tool: tool, arguments: arguments, directory: nil, environment: nil, capture: capture)
        child.start(completion)
        return { child.stop() }
    }

    /// Tool detection is blocking by contract; everything else awaits `run`.
    static func collect(_ tool: URL, arguments: [String], limit: Int = 4_000_000, timeout: TimeInterval = 10) -> ToolOutput? {
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<ToolOutput?>(initialState: nil)
        let stop = launch(tool, arguments: arguments, capture: .data(limit: limit)) { outcome in
            result.withLock { $0 = try? outcome.get() }
            done.signal()
        }
        // A tool that hangs must not hold detection open forever.
        if done.wait(timeout: .now() + timeout) == .timedOut { stop(); done.wait() }
        return result.withLock { $0 }
    }

    /// The children that are running right now.
    static var liveProcessIdentifiers: [Int32] { registry.withLock { Array($0.values) }.compactMap(\.identifier) }

    /// Calls that have not ended yet, whether their tool has been launched or not.
    static var pendingCount: Int { registry.withLock { $0.count } }

    private static let registry = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Child]())

    /// One child process, listed in the registry from `start` until its completion has been called, so
    /// that `terminateAll()` cannot pass over one that is about to launch. The buffers are touched on
    /// `queue` only, the three flags under `lock`.
    private final class Child: @unchecked Sendable {
        /// More than this without a line break is not a line.
        private static let longestLine = 1_000_000

        private let process = Process()
        private let name: String
        private let capture: ToolCapture
        private let queue = DispatchQueue(label: "local.barlet.convert.tool", qos: .userInitiated)
        private let lock = NSLock()
        private var wanted = true
        private var launched = false
        /// A live child was ended on purpose: its caller hears of a cancellation, whatever it exits with.
        private var stopped = false

        private var completion: (@Sendable (Result<ToolOutput, Error>) -> Void)?
        private var channels: [DispatchIO] = []
        private var open = 0
        private var status: Int32?
        private var collected = Data()
        private var line = Data()
        /// Inside a line that passed the limit: what follows, up to its line break, belongs to it.
        private var skipping = false
        private var errors = Data()
        private var exceeded = false

        /// Nil until the tool has been launched.
        var identifier: Int32? { lock.withLock { launched ? process.processIdentifier : nil } }

        init(tool: URL, arguments: [String], directory: URL?, environment: [String: String]?, capture: ToolCapture) {
            name = tool.lastPathComponent
            self.capture = capture
            process.executableURL = tool
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }
            if let environment { process.environment = environment }
            process.standardInput = FileHandle.nullDevice
        }

        /// `completion` is called exactly once, on the private queue.
        func start(_ completion: @escaping @Sendable (Result<ToolOutput, Error>) -> Void) {
            // Listed before the launch is even queued: a quit in this moment must still find the child.
            ToolProcess.registry.withLock { $0[ObjectIdentifier(self)] = self }
            // Launching on the queue keeps the exit, which is reported on it too, behind this set-up.
            queue.async { [self] in
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.terminationHandler = { [self] process in
                    let status = process.terminationStatus
                    queue.async { self.exited(status) }
                }
                let failure: Error? = lock.withLock {
                    guard wanted else { return CancellationError() }
                    do { try process.run() } catch {
                        return ConversionFailure("Araç başlatılamadı: %@", detail: "\(name): \(error.localizedDescription)")
                    }
                    launched = true
                    return nil
                }
                if let failure {
                    process.terminationHandler = nil
                    ToolProcess.registry.withLock { $0[ObjectIdentifier(self)] = nil }
                    completion(.failure(failure))
                    return
                }
                self.completion = completion
                // Both streams are drained at the same time: a tool that fills one pipe while
                // the other is being waited for would never finish.
                read(output.fileHandleForReading, stream: 0)
                read(errors.fileHandleForReading, stream: 1)
            }
        }

        /// SIGTERM now, SIGKILL two seconds later. Before the launch it prevents the launch.
        func stop(cancelling: Bool = true) {
            let live: Bool = lock.withLock {
                if cancelling { wanted = false }
                guard launched, process.isRunning else { return false }
                if cancelling { stopped = true }
                process.terminate()
                return true
            }
            guard live else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        private func read(_ handle: FileHandle, stream: Int) {
            // The channel borrows the descriptor; the handle closes it when the channel is done with it.
            let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in try? handle.close() }
            channel.setLimit(lowWater: 1)
            channels.append(channel)
            open += 1
            channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, _ in
                if let data, !data.isEmpty {
                    var bytes = Data(count: data.count)
                    bytes.withUnsafeMutableBytes { data.copyBytes(to: $0, count: data.count) }
                    consume(bytes, stream: stream)
                }
                if done { open -= 1; finishIfDone() }
            }
        }

        private func consume(_ data: Data, stream: Int) {
            guard stream == 0 else {
                errors.append(data)
                if errors.count > 4096 { errors = Data(errors.suffix(4096)) }
                return
            }
            switch capture {
            case .lines(let handler):
                guard let handler else { return }
                line.append(data)
                var start = line.startIndex
                while let end = line[start...].firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    if skipping {
                        skipping = false
                    } else if end > start, end - start <= Self.longestLine {
                        handler(String(decoding: line[start..<end], as: UTF8.self))
                    }
                    start = line.index(after: end)
                }
                line.removeSubrange(line.startIndex..<start)
                // A line this long is not text for us; keep memory bounded. Its rest is dropped with it.
                if skipping || line.count > Self.longestLine {
                    line.removeAll()
                    skipping = true
                }
            case .data(let limit):
                guard !exceeded else { return }
                if data.count > limit - collected.count {
                    exceeded = true
                    collected = Data()
                    stop(cancelling: false)
                } else {
                    collected.append(data)
                }
            case .chunks(let handler):
                handler(data)
            }
        }

        private func exited(_ status: Int32) {
            self.status = status
            finishIfDone()
            guard open > 0 else { return }
            // A helper the tool started can hold the pipes open after it. Do not wait for it.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                for channel in channels { channel.close(flags: .stop) }
            }
        }

        private func finishIfDone() {
            guard let status, open == 0, let completion else { return }
            self.completion = nil
            channels = []
            process.terminationHandler = nil
            ToolProcess.registry.withLock { $0[ObjectIdentifier(self)] = nil }
            if case .lines(let handler) = capture, let handler, !line.isEmpty, !skipping {
                handler(String(decoding: line, as: UTF8.self))
            }
            if lock.withLock({ stopped }) {
                completion(.failure(CancellationError()))
            } else if exceeded {
                completion(.failure(ConversionFailure("Araç çıktısı çok büyük: %@", detail: name)))
            } else {
                // The cut to 4 KB may have landed inside a character.
                let tail = String(decoding: errors.drop { $0 & 0xC0 == 0x80 }, as: UTF8.self)
                completion(.success(ToolOutput(status: status, stdout: collected, stderrTail: tail)))
            }
        }
    }
}
