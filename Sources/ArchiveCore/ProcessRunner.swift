import Foundation
import Darwin

public final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        if let current { stopProcess(current) }
    }
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw ArchiveError.cancelled }
    }
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw ArchiveError.cancelled }
        try process.run(); self.process = process
    }
    func finished(_ completed: Process) {
        lock.lock(); defer { lock.unlock() }
        if process === completed { process = nil }
    }
}

// A stalled engine must not hold the operation (and app shutdown) open forever.
private func stopProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

// Pipe reads can split both a password and a UTF-8 character at any byte.
// Keep the undecidable suffix until the next read instead of logging it early.
struct ProcessOutputFilter {
    private let secret: Data
    private var pending = Data()
    private var utf8 = Data()

    init(password: String) { secret = Data(password.utf8) }

    mutating func consume(_ data: Data) -> String {
        pending.append(data)
        var ready = Data()
        if !secret.isEmpty {
            while let match = pending.range(of: secret) {
                ready.append(pending[..<match.lowerBound])
                ready.append(contentsOf: "••••".utf8)
                pending.removeSubrange(pending.startIndex..<match.upperBound)
            }
        }
        let count = max(0, pending.count - max(0, secret.count - 1))
        ready.append(pending.prefix(count))
        pending.removeFirst(count)
        return decode(ready, final: false)
    }

    mutating func finish() -> String {
        let result = decode(pending, final: true)
        pending.removeAll()
        return result
    }

    private mutating func decode(_ data: Data, final: Bool) -> String {
        utf8.append(data)
        var retained = 0
        if !final {
            let tail = Array(utf8.suffix(4))
            if let lead = tail.lastIndex(where: { $0 & 0xC0 != 0x80 }) {
                let byte = tail[lead]
                let expected = byte >= 0xC2 && byte <= 0xDF ? 2
                    : byte >= 0xE0 && byte <= 0xEF ? 3
                    : byte >= 0xF0 && byte <= 0xF4 ? 4 : 1
                if tail.count - lead < expected { retained = tail.count - lead }
            }
        }
        let count = utf8.count - retained
        let result = String(decoding: utf8.prefix(count), as: UTF8.self)
        utf8.removeFirst(count)
        return result
    }
}

public enum ProcessRunner {
    public static func run(tool: URL, arguments: [String], directory: URL? = nil,
                           password: String = "", control: JobControl,
                           output: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool; process.arguments = arguments; process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                environment["LC_ALL"] = "en_US.UTF-8"; environment["LANG"] = "en_US.UTF-8"
                environment.removeValue(forKey: "RAR")
                process.environment = environment
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                let input = Pipe(); process.standardInput = password.isEmpty ? FileHandle.nullDevice : input
                do {
                    try control.launch(process)
                    if !password.isEmpty {
                        // Interactive stdin avoids exposing the password in the process argument list.
                        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                        // Drain stdout concurrently even if the engine delays reading stdin.
                        DispatchQueue.global(qos: .utility).async {
                            try? input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8))
                            try? input.fileHandleForWriting.close()
                        }
                    }
                    var result = Data()
                    var filter = ProcessOutputFilter(password: password)
                    var exceeded = false
                    while true {
                        let chunk = pipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        if exceeded { continue }
                        if chunk.count > 64 * 1024 * 1024 - result.count {
                            exceeded = true; stopProcess(process); continue
                        }
                        result.append(chunk)
                        let text = filter.consume(chunk)
                        if !text.isEmpty { output(text) }
                    }
                    let tail = filter.finish()
                    if !tail.isEmpty { output(tail) }
                    process.waitUntilExit(); control.finished(process)
                    try control.check()
                    if exceeded { throw ArchiveError.message("LIST_TOO_LARGE") }
                    let raw = String(decoding: result, as: UTF8.self)
                    var text = raw
                    if !password.isEmpty { text = text.replacingOccurrences(of: password, with: "••••") }
                    guard process.terminationStatus == 0 else {
                        let lower = text.lowercased()
                        if lower.contains("wrong password") || lower.contains("enter password") || lower.contains("encrypted archive") {
                            throw ArchiveError.password
                        }
                        throw ArchiveError.engine(process.terminationStatus, String(text.suffix(6000)))
                    }
                    continuation.resume(returning: raw)
                } catch {
                    if process.isRunning { stopProcess(process); process.waitUntilExit() }
                    control.finished(process); continuation.resume(throwing: error)
                }
            }
        }
    }
}
