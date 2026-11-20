import XCTest
import BStoeqCore
@testable import BStoeq

/// Drives the real process plumbing with a stand-in for yt-dlp. No network is used.
/// The stand-in writes into the folder it is given with `--paths`, which is the
/// manager's private working folder; the manager moves the result to the destination.
final class MediaDownloadManagerTests: XCTestCase {
    private var directory: URL!
    private var destination: URL { directory.appendingPathComponent("hedef", isDirectory: true) }
    private var workingRoot: URL { directory.appendingPathComponent("work", isDirectory: true) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("barlet-download-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func tool(_ name: String, _ script: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @MainActor private func makeManager(_ ytDlp: URL, maxConcurrent: Int = 3) -> MediaDownloadManager {
        MediaDownloadManager(maxConcurrent: maxConcurrent, workingRoot: workingRoot,
                             locateTools: { MediaTools(ytDlp: ytDlp, ffmpeg: nil) })
    }

    @MainActor private func add(_ link: String, to manager: MediaDownloadManager, kind: MediaKind = .audio,
                                wholePlaylist: Bool = false) -> UserMessage? {
        manager.enqueue(link, kind: kind, quality: .best, audioFormat: .mp3, destination: destination, wholePlaylist: wholePlaylist)
    }

    @MainActor private func wait(_ manager: MediaDownloadManager, seconds: Double = 20,
                                 until done: @MainActor (MediaDownloadManager) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(manager) {
            guard Date() < deadline else { XCTFail("Timed out: \(manager.items.map(\.state)) lookups \(manager.lookups.count)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    /// Wait for every job to end, then run the assertions on the main actor.
    @MainActor private func settled(_ manager: MediaDownloadManager,
                                    _ check: @MainActor (MediaDownloadManager) throws -> Void) async throws {
        try await wait(manager) { !$0.items.isEmpty && $0.activeCount == 0 }
        try check(manager)
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Lists a playlist with --flat-playlist; otherwise "downloads" one entry into the
    /// working folder. The file is named from the output template with the title
    /// `title` (a shell expression that may use $id), and holds the video's id.
    private func playlistTool(entries: String = "", title: String = "T-$id", failing: String = "") throws -> URL {
        try tool("yt-dlp", #"""
        flat=0
        for a in "$@"; do [ "$a" = "--flat-playlist" ] && flat=1; done
        while [ $# -gt 0 ]; do
          case "$1" in --paths) shift; work="$1";; --output) shift; out="$1";; --) shift; link="$1";; esac
          shift
        done
        if [ $flat = 1 ]; then
          echo "WARNING: [youtube:tab] YouTube said: INFO - 1 unavailable video is hidden" >&2
        \#(entries)
          exit 0
        fi
        id="${link##*=}"
        echo "$id" >> '\#(directory.path)/order.txt'
        \#(failing)
        name="$(printf '%s' "$out" | sed "s/%(title).150B/\#(title)/; s/%(ext)s/mp3/")"
        echo "BARLET-PROGRESS|finished|1|1|NA|NA|NA"
        printf '%s' "$id" > "$work/$name"
        echo "BARLET-FILE|$work/$name"
        """#)
    }

    // MARK: Single downloads

    func testSuccessfulDownloadIsMovedToTheDestinationAndMarked() async throws {
        // Echo the option terminator and link back so the test proves how they were passed.
        let fake = try tool("yt-dlp", #"""
        while [ $# -gt 0 ]; do
          case "$1" in --paths) shift; work="$1";; --) shift; link="$1";; esac
          shift
        done
        echo "[youtube] noise that must be ignored"
        echo "BARLET-META|137+140|Türkçe Başlık şğü"
        echo "BARLET-PROGRESS|downloading|50|100|NA|2048|4"
        echo "BARLET-PROGRESS|finished|100|100|NA|NA|NA"
        echo "BARLET-PROGRESS|downloading|5|10|NA|1024|1" >&2
        echo "BARLET-PROGRESS|finished|10|10|NA|NA|NA"
        printf '%s' "$link" > "$work/Türkçe Başlık şğü.mp4"
        : > "$work/Türkçe Başlık şğü.f137.mp4.part"
        printf 'BARLET-FILE|%s' "$work/Türkçe Başlık şğü.mp4"
        """#)
        let manager = await MainActor.run {
            let manager = makeManager(fake)
            XCTAssertNil(add("https://youtu.be/vid00000002?si=x", to: manager, kind: .video))
            XCTAssertEqual(manager.activeCount, 1)
            XCTAssertEqual(add("https://www.youtube.com/watch?v=vid00000002", to: manager, kind: .video)?.key, "Bu bağlantı zaten indiriliyor.")
            return manager
        }
        try await settled(manager) { manager in
            let item = try XCTUnwrap(manager.items.first)
            XCTAssertEqual(item.state, .finished)
            XCTAssertFalse(item.alreadyPresent)
            XCTAssertEqual(item.title, "Türkçe Başlık şğü")
            XCTAssertEqual(item.fraction, 1)
            let file = try XCTUnwrap(item.file)
            XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL.path, self.destination.standardizedFileURL.path)
            XCTAssertEqual(file.lastPathComponent, "Türkçe Başlık şğü.mp4")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "https://www.youtube.com/watch?v=vid00000002")
            // Only the finished file reaches the user's folder; it carries its origin.
            XCTAssertEqual(self.names(in: self.destination), ["Türkçe Başlık şğü.mp4"])
            XCTAssertEqual(FileOrigin.key(of: file), "vid00000002|video|best|plain")
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workingDirectory(for: item.id).path))
            XCTAssertEqual(manager.activeCount, 0)
            XCTAssertTrue(manager.hasClearableItems)
            manager.clearFinished()
            XCTAssertTrue(manager.items.isEmpty)
        }
    }

    func testFailureShowsTheDownloaderErrorAndCanBeRetried() async throws {
        let fake = try tool("yt-dlp", #"""
        echo "WARNING: ignored" >&2
        echo "ERROR: [youtube] vid00000002: Video unavailable" >&2
        exit 1
        """#)
        let manager = await MainActor.run {
            let manager = makeManager(fake)
            XCTAssertNil(add("https://youtu.be/vid00000002", to: manager))
            return manager
        }
        try await settled(manager) { manager in
            let item = try XCTUnwrap(manager.items.first)
            XCTAssertEqual(item.state, .failed(UserMessage("İndirme başarısız: %@", detail: "[youtube] vid00000002: Video unavailable")))
            XCTAssertNil(item.file)
            manager.retry(item.id)
            XCTAssertTrue(manager.items[0].isActive)
        }
    }

    func testCancelStopsTheProcessAndQueuedItemsNeverStart() async throws {
        let marker = directory.appendingPathComponent("started")
        // Leave the partial files a real download has on disk when it is stopped.
        let fake = try tool("yt-dlp", #"""
        while [ $# -gt 0 ]; do case "$1" in --paths) shift; work="$1";; esac; shift; done
        echo x >> '\#(marker.path)'
        printf '%s' "$work" > '\#(directory.path)/working-path'
        touch "$work/Uzun video.f137.mp4.part" "$work/Uzun video.f137.mp4.ytdl"
        echo 'BARLET-META|18|Uzun video'
        exec sleep 30
        """#)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let unrelated = ["notlar.part", "Uzun video.mp4.part", "Uzun video.mp4"]
        for name in unrelated { try Data().write(to: destination.appendingPathComponent(name)) }
        let manager = await MainActor.run {
            let manager = makeManager(fake, maxConcurrent: 1)
            XCTAssertNil(add("https://youtu.be/aaaaaaaaaaa", to: manager, kind: .video))
            XCTAssertNil(add("https://youtu.be/bbbbbbbbbbb", to: manager, kind: .video))
            XCTAssertEqual(manager.items.map(\.state), [.queued, .running])
            return manager
        }
        try await wait(manager) { $0.items.last?.title == "Uzun video" }
        await MainActor.run { manager.cancelAll() }
        try await wait(manager) { $0.activeCount == 0 }
        try await MainActor.run {
            XCTAssertEqual(manager.items.map(\.state), [.cancelled, .cancelled])
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "x\n")
            // The working folder with the partial files is gone; the user's folder,
            // including files that merely look like partial downloads, is untouched.
            let working = try String(contentsOf: self.directory.appendingPathComponent("working-path"), encoding: .utf8)
            XCTAssertEqual(working, manager.workingDirectory(for: manager.items[1].id).path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: working))
            XCTAssertEqual(self.names(in: self.destination), unrelated.sorted())
            manager.remove(manager.items[0].id)
            XCTAssertEqual(manager.items.count, 1)
        }
    }

    func testInvalidLinksAndMissingToolsAreReportedWithoutStartingAnything() async throws {
        let fake = try tool("yt-dlp", "exit 0")
        await MainActor.run {
            var tools = MediaTools()
            let manager = MediaDownloadManager(workingRoot: workingRoot, locateTools: { tools })
            XCTAssertEqual(add("https://vimeo.com/123456", to: manager)?.key, "Bu geçerli bir YouTube bağlantısı değil.")
            XCTAssertNotNil(add("https://youtu.be/vid00000002", to: manager))
            XCTAssertTrue(manager.items.isEmpty)
            // Installing the tool later is picked up without restarting the app.
            tools = MediaTools(ytDlp: fake, ffmpeg: nil)
            manager.refreshTools()
            XCTAssertEqual(manager.tools.ytDlp, fake)

            XCTAssertEqual(MediaTools.locate(in: [self.directory.path]), MediaTools(ytDlp: fake, ffmpeg: nil))
            XCTAssertEqual(MediaTools.locate(in: ["/nonexistent-barlet-tools"]), MediaTools())
            XCTAssertEqual(DownloadsView.clock(65), "1:05")
            XCTAssertEqual(DownloadsView.clock(3725), "1:02:05")
        }
    }

    // MARK: Names, existing files and the origin mark

    func testAnExistingFileWithTheSameNameIsNeitherSkippedOverNorTouched() async throws {
        // Every video is called "Ortak" by this stand-in.
        let fake = try playlistTool(title: "Ortak")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let mine = destination.appendingPathComponent("Ortak.mp3")
        try Data("the user's own file".utf8).write(to: mine)
        let before = try FileManager.default.attributesOfItem(atPath: mine.path)[.modificationDate] as? Date
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake, maxConcurrent: 1)
            XCTAssertNil(add("https://youtu.be/aaaaaaaaaaa", to: manager))
            XCTAssertNil(add("https://youtu.be/bbbbbbbbbbb", to: manager))
            return manager
        }
        try await settled(manager) { manager in
            XCTAssertEqual(manager.items.map(\.state), [.finished, .finished])
            // The user's file is byte for byte and date for date what it was, unmarked.
            XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "the user's own file")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: mine.path)[.modificationDate] as? Date, before)
            XCTAssertNil(FileOrigin.key(of: mine))
            // Both videos arrived, each under the next free name, each holding its own content.
            XCTAssertEqual(self.names(in: self.destination), ["Ortak 2.mp3", "Ortak 3.mp3", "Ortak.mp3"])
            XCTAssertEqual(try String(contentsOf: self.destination.appendingPathComponent("Ortak 2.mp3"), encoding: .utf8), "aaaaaaaaaaa")
            XCTAssertEqual(try String(contentsOf: self.destination.appendingPathComponent("Ortak 3.mp3"), encoding: .utf8), "bbbbbbbbbbb")
            XCTAssertEqual(manager.items.map { $0.file?.lastPathComponent }, ["Ortak 3.mp3", "Ortak 2.mp3"])
        }
    }

    func testAVideoAlreadyInTheFolderIsRecognisedByItsMarkEvenAfterRenaming() async throws {
        let fake = try playlistTool()
        let first = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://youtu.be/aaaaaaaaaaa", to: manager))
            return manager
        }
        try await settled(first) { _ in }
        // The user renames the file; the mark travels with it.
        let renamed = destination.appendingPathComponent("Benim adım.mp3")
        try FileManager.default.moveItem(at: destination.appendingPathComponent("T-aaaaaaaaaaa.mp3"), to: renamed)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("order.txt"))

        let second = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://youtu.be/aaaaaaaaaaa", to: manager))
            // Recognised before any process starts.
            XCTAssertEqual(manager.items.map(\.state), [.finished])
            XCTAssertTrue(manager.items[0].alreadyPresent)
            XCTAssertEqual(manager.items[0].file?.lastPathComponent, "Benim adım.mp3")
            // The same video in another form is a different file and is fetched.
            XCTAssertNil(manager.enqueue("https://youtu.be/aaaaaaaaaaa", kind: .audio, quality: .best, audioFormat: .m4a, destination: destination))
            return manager
        }
        try await settled(second) { manager in
            XCTAssertEqual(manager.items.map(\.state), [.finished, .finished])
            XCTAssertFalse(manager.items[0].alreadyPresent)
            XCTAssertEqual(self.names(in: self.destination), ["Benim adım.mp3", "T-aaaaaaaaaaa.mp3"])
            // The stand-in ran once, for the M4A request only.
            XCTAssertEqual(try String(contentsOf: self.directory.appendingPathComponent("order.txt"), encoding: .utf8), "aaaaaaaaaaa\n")
        }
    }

    func testOriginMarkRoundTripsAndUnmarkedFilesHaveNone() throws {
        let file = directory.appendingPathComponent("dosya.mp3")
        try Data().write(to: file)
        XCTAssertNil(FileOrigin.key(of: file))
        FileOrigin.mark(file, key: "abc|audio|mp3")
        XCTAssertEqual(FileOrigin.key(of: file), "abc|audio|mp3")
        XCTAssertEqual(FileOrigin.existingFile(for: "abc|audio|mp3", in: directory)?.lastPathComponent, "dosya.mp3")
        XCTAssertNil(FileOrigin.existingFile(for: "abc|audio|m4a", in: directory))
        XCTAssertNil(FileOrigin.existingFile(for: "abc|audio|mp3", in: directory.appendingPathComponent("yok")))
        XCTAssertNil(FileOrigin.key(of: directory.appendingPathComponent("yok.mp3")))
    }

    func testAReportedPathOutsideTheWorkingFolderIsNotMoved() async throws {
        let outside = directory.appendingPathComponent("dışarıda.mp3")
        try Data("not ours".utf8).write(to: outside)
        // The stand-in claims a file elsewhere; the real result is in the working folder.
        let fake = try tool("yt-dlp", #"""
        while [ $# -gt 0 ]; do case "$1" in --paths) shift; work="$1";; esac; shift; done
        printf 'real' > "$work/Gerçek.mp3"
        echo 'BARLET-FILE|\#(outside.path)'
        """#)
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://youtu.be/aaaaaaaaaaa", to: manager))
            return manager
        }
        try await settled(manager) { manager in
            XCTAssertEqual(manager.items.map(\.state), [.finished])
            XCTAssertEqual(manager.items[0].file?.lastPathComponent, "Gerçek.mp3")
            XCTAssertEqual(self.names(in: self.destination), ["Gerçek.mp3"])
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "not ours")
        }

        // A run that reports success but leaves nothing behind is a failure, not "done".
        let empty = try tool("yt-dlp-empty", "exit 0")
        let second = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(empty)
            XCTAssertNil(add("https://youtu.be/bbbbbbbbbbb", to: manager))
            return manager
        }
        try await settled(second) { manager in
            XCTAssertEqual(manager.items[0].state, .failed(UserMessage("İndirilen dosya bulunamadı.")))
        }
    }

    // MARK: Queue behaviour

    func testCancelPressedAfterTheDownloadSucceededStillDeliversTheFile() async throws {
        let fake = try playlistTool()
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://youtu.be/aaaaaaaaaaa", to: manager))
            // The process has exited successfully; its result is still waiting for the main queue.
            Thread.sleep(forTimeInterval: 2.5)
            manager.cancel(manager.items[0].id)
            return manager
        }
        try await settled(manager) { manager in
            XCTAssertEqual(manager.items.map(\.state), [.finished])
            XCTAssertEqual(self.names(in: self.destination), ["T-aaaaaaaaaaa.mp3"])
        }
    }

    func testRetryFailedLeavesCancelledDownloadsAloneAndClearingKeepsFailures() async throws {
        let fake = try tool("yt-dlp", #"""
        for a in "$@"; do link="$a"; done
        case "$link" in *bbbbbbbbbbb) echo 'ERROR: [youtube] b: Video unavailable' >&2; exit 1;; esac
        exec sleep 30
        """#)
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://youtu.be/aaaaaaaaaaa", to: manager))
            XCTAssertNil(add("https://youtu.be/bbbbbbbbbbb", to: manager))
            return manager
        }
        try await wait(manager) { $0.failedCount == 1 }
        await MainActor.run { manager.cancel(manager.items[1].id) }
        try await wait(manager) { $0.activeCount == 0 }
        await MainActor.run {
            XCTAssertTrue(manager.items[0].isFailed)
            XCTAssertEqual(manager.items[1].state, .cancelled)
            let failedWork = manager.workingDirectory(for: manager.items[0].id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: failedWork.path))

            // What the user stopped on purpose stays stopped.
            manager.retryFailed()
            XCTAssertTrue(manager.items[0].isActive)
            XCTAssertEqual(manager.items[1].state, .cancelled)
        }
        try await wait(manager) { $0.activeCount == 0 }
        await MainActor.run {
            // Tidying up removes what is done or abandoned, not what can still be retried.
            let failed = manager.items[0].id
            manager.clearFinished()
            XCTAssertEqual(manager.items.map(\.id), [failed])
            XCTAssertTrue(FileManager.default.fileExists(atPath: manager.workingDirectory(for: failed).path))
            XCTAssertFalse(manager.hasClearableItems)
            manager.remove(failed)
            XCTAssertTrue(manager.items.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workingDirectory(for: failed).path))
        }
    }

    func testTransientFailuresAreRetriedOnceAndPermanentOnesAreNot() async throws {
        // The first attempt of every video fails with a server error; the second works.
        let flaky = try playlistTool(entries: "echo 'BARLET-ENTRY|vid00000001|a'\necho 'BARLET-ENTRY|vid00000002|b'", failing: #"""
        if [ ! -e '\#(directory.path)'/seen-$id ]; then : > '\#(directory.path)'/seen-$id; echo "ERROR: unable to download video data: HTTP Error 503: Service Unavailable" >&2; exit 1; fi
        """#)
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(flaky)
            XCTAssertNil(add("https://www.youtube.com/playlist?list=PLtestlist0001", to: manager))
            return manager
        }
        try await wait(manager, seconds: 30) { $0.lookups.isEmpty && $0.items.count == 2 && $0.activeCount == 0 }
        await MainActor.run {
            XCTAssertEqual(manager.items.map(\.state), [.finished, .finished])
            for permanent in ["[youtube] x: Video unavailable", "[youtube] x: This video is unavailable",
                              "[youtube] x: Video unavailable. This video is not available",
                              "[youtube] x: Private video. Sign in if you've been granted access",
                              "[youtube:tab] PLx: The playlist does not exist."] {
                XCTAssertTrue(MediaDownloadManager.isPermanentFailure(permanent), permanent)
            }
            // A struggling server or connection is not a missing video.
            for transient in ["unable to download video data: HTTP Error 503: Service Unavailable",
                              "unable to download video data: timed out", "HTTP Error 500: Internal Server Error",
                              "[Errno 28] No space left on device"] {
                XCTAssertFalse(MediaDownloadManager.isPermanentFailure(transient), transient)
            }
            XCTAssertFalse(MediaDownloadManager.isPermanentFailure(nil))
        }

        // A stubborn failure stops after the second attempt and can be retried by hand.
        let always = try tool("yt-dlp-always", "echo x >> '\(directory.path)/attempts'\necho 'ERROR: HTTP Error 503: Service Unavailable' >&2\nexit 1")
        let second = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(always)
            XCTAssertNil(add("https://youtu.be/vid00000002", to: manager))
            return manager
        }
        try await settled(second) { manager in
            XCTAssertTrue(manager.items[0].isFailed)
            XCTAssertEqual(manager.failedCount, 1)
            XCTAssertEqual(try String(contentsOf: self.directory.appendingPathComponent("attempts"), encoding: .utf8), "x\nx\n")
            manager.retryFailed()
            XCTAssertTrue(manager.items[0].isActive)
        }
    }

    func testStaleWorkingFoldersAreSweptButLiveOnesAreKept() async throws {
        let stale = workingRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("leftover".utf8).write(to: stale.appendingPathComponent("eski.mp4.part"))
        let fake = try tool("yt-dlp", "echo 'ERROR: [youtube] a: Video unavailable' >&2\nexit 1")
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://youtu.be/aaaaaaaaaaa", to: manager))
            return manager
        }
        try await settled(manager) { manager in
            let live = manager.workingDirectory(for: manager.items[0].id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
            manager.discardStaleWorkingFiles()
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            // The failed row is still in the list and may be resumed.
            XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        }
        // A manager whose working root does not exist yet has nothing to do.
        await MainActor.run {
            MediaDownloadManager(workingRoot: directory.appendingPathComponent("yok"), locateTools: { MediaTools() }).discardStaleWorkingFiles()
        }
    }

    // MARK: Playlists

    func testPlaylistBecomesOneDownloadPerVideoInItsOwnFolder() async throws {
        var lines = ""
        for index in 1...12 {
            let id = String(format: "vid%08d", index)
            lines += "echo 'BARLET-LIST|12|Yaz: Akşam/Sabah $HOME'\necho 'BARLET-ENTRY|\(id)|Şarkı \(index)'\n"
        }
        // A repeated entry and a malformed one must not create extra downloads.
        lines += "echo 'BARLET-ENTRY|vid00000003|Şarkı 3 yine'\necho 'BARLET-ENTRY|--bad|x'\n"
        let fake = try playlistTool(entries: lines)
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake, maxConcurrent: 1)
            let link = "https://www.youtube.com/watch?v=vid00000005&list=PLtestlist0001"
            XCTAssertNil(add(link, to: manager, wholePlaylist: true))
            XCTAssertEqual(manager.lookups.count, 1)
            XCTAssertEqual(manager.activeCount, 1)
            XCTAssertEqual(add(link, to: manager, wholePlaylist: true)?.key, "Bu bağlantı zaten indiriliyor.")
            // The same list as video is another request and is listed as well.
            XCTAssertNil(add(link, to: manager, kind: .video, wholePlaylist: true))
            XCTAssertEqual(manager.lookups.count, 2)
            manager.cancel(manager.lookups[0].id)
            return manager
        }
        try await wait(manager, seconds: 30) { $0.lookups.isEmpty && $0.items.count == 12 && $0.activeCount == 0 }
        try await MainActor.run {
            XCTAssertEqual(manager.finishedCount, 12)
            XCTAssertEqual(manager.failedCount, 0)
            XCTAssertNil(manager.notice)
            XCTAssertEqual(manager.items.map(\.title), (1...12).map { "Şarkı \($0)" })
            XCTAssertTrue(manager.items.allSatisfy { $0.playlistTitle == "Yaz: Akşam/Sabah $HOME" })
            // The folder is named literally; nothing in the title is expanded or followed.
            XCTAssertEqual(self.names(in: self.destination), ["Yaz- Akşam-Sabah $HOME"])
            let folder = self.destination.appendingPathComponent("Yaz- Akşam-Sabah $HOME")
            // Named after the title alone: no position, no identifier.
            XCTAssertEqual(self.names(in: folder), (1...12).map { String(format: "T-vid%08d.mp3", $0) })
            // With one slot the videos are fetched in playlist order.
            let order = try String(contentsOf: self.directory.appendingPathComponent("order.txt"), encoding: .utf8)
            XCTAssertEqual(order.split(separator: "\n").map(String.init), (1...12).map { String(format: "vid%08d", $0) })
            XCTAssertEqual(manager.items[4].file?.lastPathComponent, "T-vid00000005.mp3")
            XCTAssertEqual(manager.items.map(\.request.position), (1...12).map { PlaylistPosition(index: $0, count: 12) })
            // Finished downloads leave no working folder behind.
            XCTAssertEqual(self.names(in: self.workingRoot), [])
        }

        // Running the same list again fetches nothing: every video is recognised.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("order.txt"))
        let again = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://www.youtube.com/playlist?list=PLtestlist0001", to: manager))
            return manager
        }
        try await wait(again, seconds: 30) { $0.lookups.isEmpty && $0.items.count == 12 && $0.activeCount == 0 }
        await MainActor.run {
            XCTAssertTrue(again.items.allSatisfy { $0.state == .finished && $0.alreadyPresent })
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("order.txt").path))
            XCTAssertEqual(self.names(in: self.destination.appendingPathComponent("Yaz- Akşam-Sabah $HOME")).count, 12)
        }
    }

    func testVideosOfOneListThatShareATitleAreAllKept() async throws {
        let fake = try playlistTool(entries: """
        echo 'BARLET-ENTRY|vid00000001|Aynı Başlık'
        echo 'BARLET-ENTRY|vid00000002|Farklı'
        echo 'BARLET-ENTRY|vid00000003|Aynı Başlık'
        """, title: "Ortak")
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://www.youtube.com/playlist?list=PLtestlist0001", to: manager))
            return manager
        }
        try await wait(manager, seconds: 30) { $0.lookups.isEmpty && $0.items.count == 3 && $0.activeCount == 0 }
        try await MainActor.run {
            XCTAssertEqual(manager.finishedCount, 3)
            let folder = self.destination.appendingPathComponent("PLtestlist0001")
            XCTAssertEqual(self.names(in: folder), ["Ortak 2.mp3", "Ortak 3.mp3", "Ortak.mp3"])
            // Three files, three different videos: none replaced another.
            let contents = try self.names(in: folder).map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
            XCTAssertEqual(Set(contents), ["vid00000001", "vid00000002", "vid00000003"])
        }
    }

    func testSingleVideoIsTakenFromAPlaylistLinkWhenTheWholeListIsNotWanted() async throws {
        let fake = try playlistTool(entries: "echo 'BARLET-ENTRY|vid00000001|x'")
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(fake)
            XCTAssertNil(add("https://www.youtube.com/watch?v=vid00000005&list=PLtestlist0001", to: manager, wholePlaylist: false))
            XCTAssertTrue(manager.lookups.isEmpty)
            XCTAssertEqual(manager.items.count, 1)
            XCTAssertNil(manager.items[0].request.position)
            return manager
        }
        try await settled(manager) { manager in
            XCTAssertEqual(manager.items.map(\.state), [.finished])
            XCTAssertEqual(manager.items[0].file?.lastPathComponent, "T-vid00000005.mp3")
        }
    }

    func testEmptyAndUnreadablePlaylistsAreReported() async throws {
        let empty = try playlistTool()
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(empty)
            XCTAssertNil(add("https://www.youtube.com/playlist?list=PLtestlist0001", to: manager, kind: .video))
            return manager
        }
        try await wait(manager) { $0.lookups.first?.failure != nil }
        await MainActor.run {
            XCTAssertEqual(manager.lookups[0].failure?.key, "Bu oynatma listesinde indirilebilir video bulunamadı.")
            XCTAssertTrue(manager.items.isEmpty)
            XCTAssertEqual(manager.activeCount, 0)
            manager.clearFinished()
            XCTAssertTrue(manager.lookups.isEmpty)
        }

        let broken = try tool("yt-dlp-broken", "echo 'ERROR: [youtube:tab] PLx: The playlist does not exist.' >&2\nexit 1")
        let second = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(broken)
            XCTAssertNil(add("https://www.youtube.com/playlist?list=PLtestlist0001", to: manager, kind: .video))
            return manager
        }
        try await wait(second) { $0.lookups.first?.failure != nil }
        await MainActor.run {
            XCTAssertEqual(second.lookups[0].failure, UserMessage("Oynatma listesi okunamadı: %@", detail: "[youtube:tab] PLx: The playlist does not exist."))
        }
    }

    func testLongListsAndRepeatedListsSayWhatHappened() async throws {
        // The list reports 800 videos but only the first ones are handed over.
        let long = try playlistTool(entries: """
        echo 'BARLET-LIST|800|Uzun liste'
        echo 'BARLET-ENTRY|vid00000001|a'
        echo 'BARLET-LIST|800|Uzun liste'
        echo 'BARLET-ENTRY|vid00000002|b'
        """, failing: "exec sleep 30")
        let manager = await MainActor.run { () -> MediaDownloadManager in
            let manager = makeManager(long)
            XCTAssertNil(add("https://www.youtube.com/playlist?list=PLtestlist0001", to: manager))
            return manager
        }
        try await wait(manager) { $0.lookups.isEmpty && $0.items.count == 2 }
        await MainActor.run {
            XCTAssertEqual(YtDlpCommand.playlistLimit, 500)
            XCTAssertEqual(manager.notice, UserMessage("Bu liste çok uzun; yalnızca ilk 500 video sıraya alındı (toplam %@).", detail: "800"))
            // Pasting the list again while all of it is still running adds nothing, and says so.
            XCTAssertNil(add("https://www.youtube.com/playlist?list=PLtestlist0001", to: manager))
            XCTAssertNil(manager.notice)
        }
        try await wait(manager) { $0.lookups.isEmpty }
        await MainActor.run {
            XCTAssertEqual(manager.items.count, 2)
            XCTAssertEqual(manager.notice, UserMessage("Bu bağlantı zaten indiriliyor."))
            manager.cancelAll()
        }
        try await wait(manager) { $0.activeCount == 0 }
    }
}
