import Foundation

/// Why a conversion did not happen: a localization key with at most one `%@`, and what goes in its place.
public struct ConversionFailure: Error, Equatable, Sendable {
    public let key: String
    public let detail: String?
    public init(_ key: String, detail: String? = nil) { self.key = key; self.detail = detail }
}

/// Thrown when there is nothing to do and that is not an error ("already small enough").
public struct ConversionSkip: Error, Equatable, Sendable {
    public let key: String
    public init(_ key: String) { self.key = key }
}

/// One piece of work for a converter: usually one source, several only for a combining target.
public struct ConversionRequest: Sendable {
    /// One; several only when `target.combines`.
    public let sources: [URL]
    /// Same order as `sources`.
    public let formats: [FileFormat]
    public let target: ConversionTarget
    /// The engine has resolved "*" to the first source's format.
    public let outputFormat: FileFormat
    /// The user's settings with the target's overrides applied.
    public let options: ConversionOptions
    /// Empty and private; results are written here and nowhere else.
    public let workFolder: URL
    /// The result's name without extension and without any suffix.
    public let baseName: String
    public let environment: ConversionEnvironment

    public init(sources: [URL], formats: [FileFormat], target: ConversionTarget, outputFormat: FileFormat,
                options: ConversionOptions = ConversionOptions(), workFolder: URL, baseName: String,
                environment: ConversionEnvironment = ConversionEnvironment()) {
        self.sources = sources; self.formats = formats; self.target = target; self.outputFormat = outputFormat
        self.options = options; self.workFolder = workFolder; self.baseName = baseName; self.environment = environment
    }

    /// `workFolder/<name ?? baseName>.<outputFormat.id>`; no extension for a format that has none (a folder).
    public func outputURL(_ name: String? = nil) -> URL {
        let base = name ?? baseName
        return workFolder.appendingPathComponent(outputFormat.extensions.isEmpty ? base : "\(base).\(outputFormat.id)", isDirectory: false)
    }
}

/// What the engine hands a converter besides the request. Every closure may be called from any thread.
/// Progress and notes count while `convert` runs; the engine drops what is said after it has returned.
public struct ConversionContext: Sendable {
    /// A lock-protected flag the engine sets when the job is cancelled. It is never `Task.isCancelled`,
    /// which is always false on a dispatch thread.
    public let isCancelled: @Sendable () -> Bool
    /// 0...1 for this request.
    public let progress: @Sendable (Double) -> Void
    /// A remark about a result that succeeded with a caveat (a localization key): "only the first 60 s".
    public let note: @Sendable (String) -> Void

    public init(isCancelled: @escaping @Sendable () -> Bool = { false },
                progress: @escaping @Sendable (Double) -> Void = { _ in },
                note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.isCancelled = isCancelled; self.progress = progress; self.note = note
    }

    /// Throws `CancellationError` once the job is cancelled. Call it between pages, frames and files.
    public func checkCancelled() throws {
        if isCancelled() { throw CancellationError() }
    }
}

/// A stateless struct that turns files of some formats into some targets.
public protocol Converter: Sendable {
    /// Whether this converter turns a file of `source` into `target` on this Mac.
    func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability
    /// A caveat the user should see before committing to this pair (a localization key), or nil.
    func note(for target: ConversionTarget, source: FileFormat) -> String?
    /// Writes into `request.workFolder` and returns the files in the order they belong.
    /// One file is published under the base name; several are published together in one folder.
    func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL]
}

/// Most pairs have nothing to warn about.
public extension Converter {
    func note(for target: ConversionTarget, source: FileFormat) -> String? { nil }
}
