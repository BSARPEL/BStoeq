import AppKit
import BStoeqCore

/// BStoeq does not ship a downloader. It drives the user's own yt-dlp (and ffmpeg
/// when present) so those tools keep receiving updates from their package manager.
struct MediaTools: Equatable, Sendable {
    var ytDlp: URL?
    var ffmpeg: URL?

    /// Apps launched from Finder do not inherit the shell's PATH.
    static func defaultDirectories(bundle: Bundle = .main) -> [String] {
        let home = NSHomeDirectory()
        return [bundle.resourceURL?.appendingPathComponent("Tools").path,
                "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                home + "/.local/bin", home + "/bin"].compactMap { $0 }
    }

    static func locate(in directories: [String] = defaultDirectories(), fileManager: FileManager = .default) -> MediaTools {
        func find(_ name: String) -> URL? {
            directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { fileManager.isExecutableFile(atPath: $0.path) }
        }
        return MediaTools(ytDlp: find("yt-dlp"), ffmpeg: find("ffmpeg"))
    }
}

struct PlaylistGroup: Equatable, Sendable {
    let id: UUID
    let title: String
    let count: Int
}

struct DownloadItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued, running, processing, finished, cancelled
        case failed(UserMessage)
    }
    let id = UUID()
    let request: MediaDownloadRequest
    var title: String?
    var group: PlaylistGroup?
    var state = State.queued
    var fraction = 0.0
    var speed: Double?
    var eta: Double?
    var file: URL?
    /// The folder already held this video from an earlier download; nothing was fetched.
    var alreadyPresent = false
    fileprivate var cancelRequested = false
    /// Start order. The list shows the newest request first, a playlist in its own order.
    fileprivate var order = 0
    fileprivate var attempts = 0
    fileprivate var originKey = ""

    var isActive: Bool { state == .queued || state == .running || state == .processing }
    var isRunning: Bool { state == .running || state == .processing }
    var isFailed: Bool { if case .failed = state { return true }; return false }
}

/// A playlist link being turned into one download per video.
struct PlaylistLookup: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// `nil` while yt-dlp is still listing the videos.
    var failure: UserMessage?
}

/// Marks a delivered file with the request it came from. Files are named after the
/// title alone, so the name cannot tell two videos apart; this mark can, and it
/// survives renaming.
enum FileOrigin {
    static let attribute = "local.barlet.source"

    static func mark(_ url: URL, key: String) {
        let bytes = Array(key.utf8)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = setxattr(path, attribute, bytes, bytes.count, 0, 0)
        }
    }

    static func key(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0, size <= 512 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            return getxattr(path, attribute, &buffer, size, 0, 0) == size ? String(decoding: buffer, as: UTF8.self) : nil
        }
    }

    static func existingFile(for key: String, in folder: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().lazy.map { folder.appendingPathComponent($0) }.first { self.key(of: $0) == key }
    }
}

@MainActor final class MediaDownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var lookups: [PlaylistLookup] = []
    @Published private(set) var tools: MediaTools
    /// Something the user should know about the last request that is not an error.
    @Published private(set) var notice: UserMessage?
    /// Kept here so the link survives switching settings pages.
    @Published var draftURL = ""
    private var jobs: [UUID: DownloadJob] = [:]
    private var trackers: [UUID: DownloadProgressTracker] = [:]
    private var lookupJobs: [UUID: DownloadJob] = [:]
    private var lookupPlans: [UUID: LookupPlan] = [:]
    private var nextOrder = 0
    private let locateTools: () -> MediaTools
    private let maxConcurrent: Int
    private let workingRoot: URL

    private struct LookupPlan {
        let kind: MediaKind, quality: VideoQuality, audioFormat: AudioFormat, destination: URL
        var title: String?
        var total: Int?
        var entries: [(id: String, title: String)] = []
        var cancelled = false
        func asksTheSame(as other: LookupPlan) -> Bool {
            kind == other.kind && quality == other.quality && audioFormat == other.audioFormat && destination == other.destination
        }
    }

    nonisolated static var defaultWorkingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("local.barlet.downloads", isDirectory: true)
    }

    init(maxConcurrent: Int = 3, workingRoot: URL = MediaDownloadManager.defaultWorkingRoot,
         locateTools: @escaping () -> MediaTools = { MediaTools.locate() }) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.workingRoot = workingRoot
        self.locateTools = locateTools
        tools = locateTools()
    }

    var activeCount: Int { items.filter(\.isActive).count + lookups.filter { $0.failure == nil }.count }
    var finishedCount: Int { items.filter { $0.state == .finished }.count }
    var failedCount: Int { items.filter(\.isFailed).count }
    /// Failed downloads stay in the list: they can still be retried and resumed.
    var hasClearableItems: Bool {
        items.contains { $0.state == .finished || $0.state == .cancelled } || lookups.contains { $0.failure != nil }
    }

    static func destination(for folder: String) -> URL {
        if folder.hasPrefix("/") { return URL(fileURLWithPath: folder, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads", isDirectory: true)
    }

    func refreshTools() {
        let found = locateTools()
        if found != tools { tools = found }
    }

    /// Returns a message when the link was not accepted. A playlist link, or a video
    /// link from a playlist with `wholePlaylist`, queues every video of that list.
    @discardableResult
    func enqueue(_ text: String, kind: MediaKind, quality: VideoQuality, audioFormat: AudioFormat,
                 destination: URL, wholePlaylist: Bool = false) -> UserMessage? {
        notice = nil
        guard let target = MediaLink.target(from: text) else {
            return UserMessage("Bu geçerli bir YouTube bağlantısı değil.")
        }
        refreshTools()
        guard let ytDlp = tools.ytDlp else {
            return UserMessage("İndirme için yt-dlp gerekli. Terminal’de aşağıdaki komutu çalıştır, ardından Yeniden denetle’ye bas.")
        }
        if let playlist = target.playlist, wholePlaylist || target.video == nil {
            return lookUp(playlist, with: ytDlp, plan: LookupPlan(kind: kind, quality: quality, audioFormat: audioFormat, destination: destination))
        }
        guard let url = target.video else { return UserMessage("Bu geçerli bir YouTube bağlantısı değil.") }
        let request = MediaDownloadRequest(url: url, kind: kind, quality: quality, audioFormat: audioFormat, destination: destination)
        guard !items.contains(where: { $0.isActive && $0.request == request }) else {
            return UserMessage("Bu bağlantı zaten indiriliyor.")
        }
        var item = DownloadItem(request: request)
        item.order = nextOrder; nextOrder += 1
        items.insert(item, at: 0)
        pump()
        return nil
    }

    func cancel(_ id: UUID) {
        if let job = lookupJobs[id] { lookupPlans[id]?.cancelled = true; job.cancel(); return }
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else { return }
        if let job = jobs[id] {
            items[index].cancelRequested = true
            job.cancel()
        } else {
            items[index].state = .cancelled
        }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        requeue(index)
        pump()
    }

    /// Only failures. A download the user cancelled was stopped on purpose.
    func retryFailed() {
        for index in items.indices where items[index].isFailed { requeue(index) }
        pump()
    }

    private func requeue(_ index: Int) {
        guard !items[index].isActive, items[index].state != .finished else { return }
        items[index].state = .queued; items[index].fraction = 0; items[index].attempts = 0
        items[index].speed = nil; items[index].eta = nil; items[index].cancelRequested = false
        items[index].file = nil
    }

    func remove(_ id: UUID) {
        if items.contains(where: { $0.id == id && !$0.isActive }) { discardWorkingFiles(of: id) }
        items.removeAll { $0.id == id && !$0.isActive }
        lookups.removeAll { $0.id == id && $0.failure != nil }
    }

    /// Finished and cancelled rows. Failed ones stay until retried or removed one by one.
    func clearFinished() {
        for item in items where item.state == .finished || item.state == .cancelled { discardWorkingFiles(of: item.id) }
        items.removeAll { $0.state == .finished || $0.state == .cancelled }
        lookups.removeAll { $0.failure != nil }
    }

    /// yt-dlp works only in here, never in the user's folder. The folder is kept
    /// while a failed download can still be resumed.
    func workingDirectory(for id: UUID) -> URL {
        workingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func discardWorkingFiles(of id: UUID) {
        try? FileManager.default.removeItem(at: workingDirectory(for: id))
    }

    /// Folders left by a previous run (a quit during a download, a failed row that was
    /// never cleared) belong to items that no longer exist. Call once at launch.
    func discardStaleWorkingFiles() {
        guard jobs.isEmpty else { return }
        let known = Set(items.map(\.id.uuidString))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: workingRoot.path)) ?? [] where !known.contains(name) {
            try? FileManager.default.removeItem(at: workingRoot.appendingPathComponent(name))
        }
    }

    /// Quit must not leave a downloader running without a visible owner.
    func cancelAll() {
        for id in Array(lookupJobs.keys) { cancel(id) }
        for index in items.indices where items[index].isActive {
            if let job = jobs[items[index].id] { items[index].cancelRequested = true; job.cancel() }
            else { items[index].state = .cancelled }
        }
    }

    private func environment(for ytDlp: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // yt-dlp looks up its helpers (ffmpeg, a JavaScript runtime) through PATH.
        let toolDirectories = [ytDlp, tools.ffmpeg].compactMap { $0?.deletingLastPathComponent().path }
        var path: [String] = []
        for directory in toolDirectories + ["/opt/homebrew/bin", "/usr/local/bin"] +
            (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        where !path.contains(directory) { path.append(directory) }
        environment["PATH"] = path.joined(separator: ":")
        // Without a locale a Finder-launched Python cannot print non-ASCII titles.
        environment["PYTHONUTF8"] = "1"; environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUNBUFFERED"] = "1"; environment["LC_ALL"] = "en_US.UTF-8"
        return environment
    }

    // MARK: Playlists

    private func lookUp(_ playlist: URL, with ytDlp: URL, plan: LookupPlan) -> UserMessage? {
        // The same list as video and as music are two different requests.
        guard !lookups.contains(where: { $0.url == playlist && $0.failure == nil && lookupPlans[$0.id]?.asksTheSame(as: plan) == true }) else {
            return UserMessage("Bu bağlantı zaten indiriliyor.")
        }
        let lookup = PlaylistLookup(url: playlist), id = lookup.id
        let job = DownloadJob(executable: ytDlp, arguments: YtDlpCommand.playlistArguments(for: playlist),
            environment: environment(for: ytDlp), directory: FileManager.default.temporaryDirectory,
            onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.collect(event, for: id) } }
            },
            onExit: { [weak self] status, message in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishLookup(id, status: status, message: message) } }
            })
        do { try job.start() } catch {
            return UserMessage("İndirme başlatılamadı: %@", detail: error.localizedDescription)
        }
        lookupJobs[id] = job; lookupPlans[id] = plan
        lookups.insert(lookup, at: 0)
        return nil
    }

    private func collect(_ event: YtDlpEvent, for id: UUID) {
        switch event {
        case .playlist(let title, let count):
            if lookupPlans[id]?.title == nil { lookupPlans[id]?.title = title }
            if let count {
                let known = lookupPlans[id]?.total ?? 0
                lookupPlans[id]?.total = max(known, count)
            }
        case .playlistEntry(let entry, let title):
            // A video can appear twice in one playlist; one file is enough.
            if lookupPlans[id]?.entries.contains(where: { $0.id == entry }) == false {
                lookupPlans[id]?.entries.append((entry, title))
            }
        default: break
        }
    }

    private func finishLookup(_ id: UUID, status: Int32, message: String?) {
        guard lookupJobs.removeValue(forKey: id) != nil, let plan = lookupPlans.removeValue(forKey: id),
              let index = lookups.firstIndex(where: { $0.id == id }) else { return }
        if plan.cancelled { lookups.remove(at: index); return }
        guard !plan.entries.isEmpty else {
            lookups[index].failure = status == 0
                ? UserMessage("Bu oynatma listesinde indirilebilir video bulunamadı.")
                : UserMessage("Oynatma listesi okunamadı: %@", detail: message ?? "yt-dlp (\(status))")
            return
        }
        let playlist = lookups.remove(at: index).url
        let listID = URLComponents(url: playlist, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "list" })?.value
        let title = plan.title ?? listID ?? "Playlist"
        let folder = plan.destination.appendingPathComponent(
            MediaLink.folderName(for: title, fallback: listID ?? "Playlist"), isDirectory: true)
        let group = PlaylistGroup(id: UUID(), title: title, count: plan.entries.count)
        let site = playlist.host ?? "www.youtube.com"
        var batch: [DownloadItem] = []
        for (offset, entry) in plan.entries.enumerated() {
            guard let url = URL(string: "https://\(site)/watch?v=\(entry.id)") else { continue }
            let request = MediaDownloadRequest(url: url, kind: plan.kind, quality: plan.quality, audioFormat: plan.audioFormat,
                destination: folder, position: PlaylistPosition(index: offset + 1, count: plan.entries.count))
            guard !items.contains(where: { $0.isActive && $0.request == request }) else { continue }
            var item = DownloadItem(request: request)
            item.title = entry.title; item.group = group
            item.order = nextOrder; nextOrder += 1
            batch.append(item)
        }
        if batch.isEmpty {
            // Every video of this list is already on its way; say so instead of doing nothing.
            notice = UserMessage("Bu bağlantı zaten indiriliyor.")
        } else if let total = plan.total, total > plan.entries.count, total > YtDlpCommand.playlistLimit {
            notice = UserMessage("Bu liste çok uzun; yalnızca ilk 500 video sıraya alındı (toplam %@).", detail: String(total))
        }
        items.insert(contentsOf: batch, at: 0)
        pump()
    }

    // MARK: Downloads

    private func pump() {
        while jobs.count < maxConcurrent,
              let index = items.indices.filter({ items[$0].state == .queued }).min(by: { items[$0].order < items[$1].order }) {
            start(index)
        }
    }

    private func start(_ index: Int) {
        let item = items[index], id = item.id
        guard let ytDlp = tools.ytDlp else {
            items[index].state = .failed(UserMessage("İndirme için yt-dlp gerekli. Terminal’de aşağıdaki komutu çalıştır, ardından Yeniden denetle’ye bas."))
            return
        }
        let key = item.request.originKey(hasFFmpeg: tools.ffmpeg != nil)
        items[index].originKey = key
        // Recognised by its mark, not by its name: a different video that happens to
        // share the title is not mistaken for this one.
        if let existing = FileOrigin.existingFile(for: key, in: item.request.destination) {
            items[index].state = .finished; items[index].fraction = 1
            items[index].file = existing; items[index].alreadyPresent = true
            discardWorkingFiles(of: id)
            return
        }
        let working = workingDirectory(for: id)
        do {
            try FileManager.default.createDirectory(at: item.request.destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        } catch {
            items[index].state = .failed(UserMessage("Kayıt klasörü kullanılamıyor: %@", detail: error.localizedDescription))
            return
        }
        let job = DownloadJob(executable: ytDlp,
            arguments: YtDlpCommand.arguments(for: item.request, ffmpegDirectory: tools.ffmpeg?.deletingLastPathComponent().path,
                                              outputDirectory: working.path),
            environment: environment(for: ytDlp), directory: working,
            onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, for: id) } }
            },
            onExit: { [weak self] status, message in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(id, status: status, message: message) } }
            })
        do {
            try job.start()
            jobs[id] = job; trackers[id] = DownloadProgressTracker()
            items[index].state = .running; items[index].attempts += 1
            items[index].file = nil; items[index].alreadyPresent = false
        } catch {
            items[index].state = .failed(UserMessage("İndirme başlatılamadı: %@", detail: error.localizedDescription))
        }
    }

    private func handle(_ event: YtDlpEvent, for id: UUID) {
        guard jobs[id] != nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .meta(let title, let parts):
            items[index].title = title
            trackers[id]?.setParts(parts)
        case .progress(let downloaded, let total, let speed, let eta, let finished):
            var tracker = trackers[id] ?? DownloadProgressTracker()
            tracker.update(downloaded: downloaded, total: total, finished: finished)
            trackers[id] = tracker
            items[index].fraction = tracker.fraction
            items[index].speed = finished ? nil : speed
            items[index].eta = finished ? nil : eta
            items[index].state = tracker.processing ? .processing : .running
        case .file(let path):
            items[index].file = URL(fileURLWithPath: path)
        case .error, .playlist, .playlistEntry:
            break
        }
    }

    /// Videos that are gone or locked stay that way; anything else (a dropped
    /// connection, a throttled request, a server error) deserves one more try.
    static func isPermanentFailure(_ message: String?) -> Bool {
        guard let text = message?.lowercased() else { return false }
        // "HTTP Error 503: Service Unavailable" is the server's trouble, not the video's.
        if text.contains("http error 5") || text.contains("timed out") { return false }
        return ["video unavailable", "video is unavailable", "video is not available", "content is not available",
                "not available in your country", "private video", "video is private", "been removed", "terminated",
                "copyright", "members-only", "members only", "sign in", "age-restricted", "confirm your age",
                "does not exist"].contains { text.contains($0) }
    }

    private func finish(_ id: UUID, status: Int32, message: String?) {
        guard jobs.removeValue(forKey: id) != nil else { return }
        trackers[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].speed = nil; items[index].eta = nil
            if status == 0 {
                // Even if cancel was pressed in the last instant: the file is complete.
                deliver(index)
            } else if items[index].cancelRequested {
                // A cancelled download is abandoned; a failed one keeps its partial
                // files so that a retry resumes instead of starting over.
                items[index].state = .cancelled; items[index].file = nil
                discardWorkingFiles(of: id)
            } else if items[index].attempts < 2 && !Self.isPermanentFailure(message) {
                // Back to the queue: yt-dlp resumes from the partial file.
                items[index].state = .queued; items[index].fraction = 0; items[index].file = nil
            } else {
                items[index].file = nil
                items[index].state = .failed(UserMessage("İndirme başarısız: %@", detail: message ?? "yt-dlp (\(status))"))
            }
        }
        pump()
    }

    /// Move the finished file from the working folder into the user's folder under a
    /// name that is free. Existing files are never replaced, renamed or modified.
    private func deliver(_ index: Int) {
        let item = items[index]
        let working = workingDirectory(for: item.id).resolvingSymlinksInPath()
        var produced: URL?
        // Trust the reported path only inside the working folder.
        if let reported = item.file?.resolvingSymlinksInPath(), reported.path.hasPrefix(working.path + "/"),
           FileManager.default.fileExists(atPath: reported.path) {
            produced = reported
        } else {
            let leftovers = (try? FileManager.default.contentsOfDirectory(at: working, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            produced = leftovers.filter { url in
                let name = url.lastPathComponent
                return !name.hasPrefix(".") && !name.hasSuffix(".part") && !name.hasSuffix(".ytdl") && !name.contains(".part-Frag")
            }.max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        guard let produced else {
            items[index].file = nil
            items[index].state = .failed(UserMessage("İndirilen dosya bulunamadı."))
            return
        }
        let folder = item.request.destination
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = MediaLink.availableName(for: produced.lastPathComponent) {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            let final = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: produced, to: final)
            FileOrigin.mark(final, key: item.originKey)
            items[index].file = final
            items[index].state = .finished; items[index].fraction = 1
            discardWorkingFiles(of: item.id)
        } catch {
            // The finished file stays in the working folder; a retry delivers it again.
            items[index].file = nil
            items[index].state = .failed(UserMessage("Dosya kayıt klasörüne taşınamadı: %@", detail: error.localizedDescription))
        }
    }
}

/// One yt-dlp process. Output arrives on background queues; every mutation of the
/// buffers happens on `queue`, and the callbacks are delivered in output order.
private final class DownloadJob: @unchecked Sendable {
    private let process = Process()
    private let queue = DispatchQueue(label: "local.barlet.download")
    private let pipes = [Pipe(), Pipe()]
    private var buffers = [Data(), Data()]
    private var open = [true, true]
    private var status: Int32?
    private var finished = false
    private var lastError: String?
    private let onEvent: @Sendable (YtDlpEvent) -> Void
    private let onExit: @Sendable (Int32, String?) -> Void

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
         onEvent: @escaping @Sendable (YtDlpEvent) -> Void, onExit: @escaping @Sendable (Int32, String?) -> Void) {
        self.onEvent = onEvent; self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]
    }

    func start() throws {
        for (index, pipe) in pipes.enumerated() {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                // An empty read is end-of-file; a handler left installed would spin.
                if data.isEmpty { handle.readabilityHandler = nil }
                self?.queue.async { self?.consume(data, stream: index) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.queue.async {
                self?.status = status
                self?.completeIfDone()
            }
            // A helper that outlives yt-dlp can hold the pipes open. Do not wait for it.
            self?.queue.asyncAfter(deadline: .now() + 1.5) { self?.closeStreams() }
        }
        do { try process.run() } catch {
            for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
            throw error
        }
    }

    /// SIGINT lets yt-dlp stop its own ffmpeg child; SIGTERM is the fallback.
    func cancel() {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    private func consume(_ data: Data, stream: Int) {
        guard open[stream] else { return }
        if data.isEmpty {
            open[stream] = false
            emit(buffers[stream]); buffers[stream].removeAll()
            completeIfDone(); return
        }
        buffers[stream].append(data)
        // Progress may be separated by carriage returns when --newline is ignored.
        while let end = buffers[stream].firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            emit(buffers[stream][buffers[stream].startIndex..<end])
            buffers[stream].removeSubrange(buffers[stream].startIndex...end)
        }
        // A line this long is not ours; keep memory bounded.
        if buffers[stream].count > 1_000_000 { buffers[stream].removeAll() }
    }

    private func emit(_ line: Data) {
        guard !line.isEmpty, let event = YtDlpOutput.parse(String(decoding: line, as: UTF8.self)) else { return }
        if case .error(let message) = event { lastError = message } else { onEvent(event) }
    }

    private func closeStreams() {
        for index in open.indices where open[index] {
            pipes[index].fileHandleForReading.readabilityHandler = nil
            open[index] = false
            emit(buffers[index]); buffers[index].removeAll()
        }
        completeIfDone()
    }

    private func completeIfDone() {
        guard !finished, let status, !open.contains(true) else { return }
        finished = true
        onExit(status, lastError)
    }
}
