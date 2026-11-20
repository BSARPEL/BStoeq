import XCTest
@testable import BStoeqCore

final class MediaDownloadTests: XCTestCase {
    func testYouTubeLinksAreReducedToTheVideoIdentifier() {
        let expected = "https://www.youtube.com/watch?v=vid00000002"
        for link in [
            "https://www.youtube.com/watch?v=vid00000002",
            "  http://youtube.com/watch?v=vid00000002&list=PL123&t=42s\n",
            "youtu.be/vid00000002?si=tracking",
            "https://m.youtube.com/watch?feature=share&v=vid00000002#fragment",
            "https://www.youtube.com/shorts/vid00000002",
            "https://www.youtube.com/live/vid00000002?feature=share",
            "https://www.youtube-nocookie.com/embed/vid00000002"
        ] {
            XCTAssertEqual(MediaLink.youtubeURL(from: link)?.absoluteString, expected, link)
        }
        XCTAssertEqual(MediaLink.youtubeURL(from: "https://music.youtube.com/watch?v=vid00000002")?.absoluteString,
                       "https://music.youtube.com/watch?v=vid00000002")
    }

    func testOtherSitesPlaylistsAndOptionLikeTextAreRejected() {
        for link in [
            "", "   ", "vid00000002", "--exec rm", "-o /tmp/x https://youtu.be/vid00000002",
            "https://example.com/watch?v=vid00000002",
            "https://youtube.com.example.com/watch?v=vid00000002",
            "https://user:secret@www.youtube.com/watch?v=vid00000002",
            "https://www.youtube.com:8443/watch?v=vid00000002",
            "ftp://www.youtube.com/watch?v=vid00000002",
            "file:///etc/passwd",
            "https://www.youtube.com/playlist?list=PL123456789",
            "https://www.youtube.com/@channel",
            "https://www.youtube.com/watch",
            "https://www.youtube.com/watch?v=",
            "https://www.youtube.com/watch?v=abc$(id)xyz",
            "https://youtu.be/",
            "https://youtu.be/vid00000002/extra"
        ] {
            XCTAssertNil(MediaLink.youtubeURL(from: link), link)
        }
    }

    func testVideoArgumentsMergeToMP4AndKeepTheLinkBehindTheOptionTerminator() throws {
        let url = try XCTUnwrap(MediaLink.youtubeURL(from: "https://youtu.be/vid00000002"))
        let request = MediaDownloadRequest(url: url, kind: .video, quality: .p720, audioFormat: .mp3,
                                           destination: URL(fileURLWithPath: "/tmp/BStoeq İndirme"))
        let arguments = YtDlpCommand.arguments(for: request, ffmpegDirectory: "/opt/homebrew/bin", outputDirectory: "/tmp/çalışma")
        XCTAssertEqual(Array(arguments.suffix(2)), ["--", "https://www.youtube.com/watch?v=vid00000002"])
        // yt-dlp is pointed at the working folder only; the user's folder never reaches it.
        XCTAssertEqual(value(after: "--paths", in: arguments), "/tmp/çalışma")
        XCTAssertFalse(arguments.contains { $0.contains("BStoeq İndirme") })
        XCTAssertEqual(value(after: "--ffmpeg-location", in: arguments), "/opt/homebrew/bin")
        XCTAssertEqual(value(after: "--merge-output-format", in: arguments), "mp4/mkv")
        XCTAssertTrue(try XCTUnwrap(value(after: "--format", in: arguments)).contains("height<=720"))
        for flag in ["--ignore-config", "--no-playlist", "--no-simulate", "--progress", "--newline"] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        XCTAssertFalse(arguments.contains("--extract-audio"))
    }

    func testAudioArgumentsConvertOnlyWhenFFmpegIsAvailable() throws {
        let url = try XCTUnwrap(MediaLink.youtubeURL(from: "https://youtu.be/vid00000002"))
        let request = MediaDownloadRequest(url: url, kind: .audio, quality: .best, audioFormat: .mp3,
                                           destination: URL(fileURLWithPath: "/tmp"))
        let converted = YtDlpCommand.arguments(for: request, ffmpegDirectory: "/usr/local/bin", outputDirectory: "/tmp/w")
        XCTAssertTrue(converted.contains("--extract-audio"))
        XCTAssertEqual(value(after: "--audio-format", in: converted), "mp3")

        let plain = YtDlpCommand.arguments(for: request, ffmpegDirectory: nil, outputDirectory: "/tmp/w")
        XCTAssertFalse(plain.contains("--extract-audio"))
        XCTAssertFalse(plain.contains("--ffmpeg-location"))
        XCTAssertEqual(value(after: "--format", in: plain), "ba[ext=m4a]/ba")
        // A single ready-made file is the only video that needs no merge.
        XCTAssertFalse(YtDlpCommand.formatSelector(kind: .video, quality: .best, audioFormat: .mp3, hasFFmpeg: false).contains("+"))
        XCTAssertEqual(YtDlpCommand.formatSelector(kind: .video, quality: .best, audioFormat: .mp3, hasFFmpeg: true), "bv*+ba/b")
    }

    func testOutputLinesAreParsed() {
        XCTAssertEqual(YtDlpOutput.parse("BARLET-META|137+140|Şarkı | Canlı"), .meta(title: "Şarkı | Canlı", parts: 2))
        XCTAssertEqual(YtDlpOutput.parse("BARLET-META|18|Tek dosya"), .meta(title: "Tek dosya", parts: 1))
        XCTAssertEqual(YtDlpOutput.parse("BARLET-PROGRESS|downloading|512|NA|2048.0|1024.5|3\r"),
                       .progress(downloaded: 512, total: 2048, speed: 1024.5, eta: 3, finished: false))
        XCTAssertEqual(YtDlpOutput.parse("BARLET-PROGRESS|finished|2048|2048|NA|NA|NA"),
                       .progress(downloaded: 2048, total: 2048, speed: nil, eta: nil, finished: true))
        XCTAssertEqual(YtDlpOutput.parse("BARLET-FILE|/Users/a/İndirilenler/Şarkı [id].mp3"), .file("/Users/a/İndirilenler/Şarkı [id].mp3"))
        XCTAssertEqual(YtDlpOutput.parse("ERROR: [youtube] abc: Video unavailable"), .error("[youtube] abc: Video unavailable"))
        for line in ["", "[download] 12.0% of 3.00MiB", "BARLET-PROGRESS|downloading|1", "BARLET-FILE|relative.mp4", "WARNING: something"] {
            XCTAssertNil(YtDlpOutput.parse(line), line)
        }
    }

    func testProgressCoversBothPartsAndNeverMovesBackwards() {
        var tracker = DownloadProgressTracker()
        tracker.setParts(2)
        tracker.update(downloaded: 50, total: 100, finished: false)
        XCTAssertEqual(tracker.fraction, 0.25, accuracy: 0.001)
        tracker.update(downloaded: 100, total: 100, finished: true)
        XCTAssertEqual(tracker.fraction, 0.5, accuracy: 0.001)
        XCTAssertFalse(tracker.processing)
        tracker.update(downloaded: 1, total: 10, finished: false)
        XCTAssertEqual(tracker.fraction, 0.55, accuracy: 0.001)
        tracker.update(downloaded: nil, total: nil, finished: false)
        XCTAssertEqual(tracker.fraction, 0.55, accuracy: 0.001)
        tracker.update(downloaded: 10, total: 10, finished: true)
        XCTAssertEqual(tracker.fraction, 1, accuracy: 0.001)
        XCTAssertTrue(tracker.processing)

        // An unexpected extra part must not push the bar backwards or past the end.
        var single = DownloadProgressTracker()
        single.update(downloaded: 10, total: 10, finished: true)
        XCTAssertTrue(single.processing)
        single.update(downloaded: 1, total: 10, finished: false)
        XCTAssertEqual(single.fraction, 1, accuracy: 0.001)
        XCTAssertFalse(single.processing)
    }

    func testDownloadPreferencesRoundTripAndTolerateOlderOrInvalidFiles() throws {
        var preferences = Preferences()
        preferences.downloadKind = .audio; preferences.videoQuality = .p480
        preferences.audioFormat = .m4a; preferences.downloadFolder = "/Users/Shared/Müzik"
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)

        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"assignments":{"example.app":"hidden"}}"#.utf8))
        XCTAssertEqual(old.downloadKind, .video)
        XCTAssertEqual(old.videoQuality, .p1080)
        XCTAssertEqual(old.audioFormat, .mp3)
        XCTAssertEqual(old.downloadFolder, "")

        let invalid = try JSONDecoder().decode(Preferences.self, from:
            Data(#"{"downloadKind":"gif","videoQuality":"8k","audioFormat":"wav","downloadFolder":"relative/path"}"#.utf8))
        XCTAssertEqual(invalid.downloadKind, .video)
        XCTAssertEqual(invalid.videoQuality, .p1080)
        XCTAssertEqual(invalid.audioFormat, .mp3)
        XCTAssertEqual(invalid.downloadFolder, "")
        XCTAssertTrue(invalid.downloadWholePlaylist)
        var single = Preferences(); single.downloadWholePlaylist = false
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(single)).downloadWholePlaylist)
    }

    func testPlaylistLinksAreRecognisedAlongsideTheVideo() {
        let both = MediaLink.target(from: "https://www.youtube.com/watch?v=vid00000001&list=PLtestlist0001&index=4")
        XCTAssertEqual(both?.video?.absoluteString, "https://www.youtube.com/watch?v=vid00000001")
        XCTAssertEqual(both?.playlist?.absoluteString, "https://www.youtube.com/playlist?list=PLtestlist0001")

        let listOnly = MediaLink.target(from: "youtube.com/playlist?list=PLtestlist0001&si=tracking")
        XCTAssertNil(listOnly?.video)
        XCTAssertEqual(listOnly?.playlist?.absoluteString, "https://www.youtube.com/playlist?list=PLtestlist0001")

        XCTAssertEqual(MediaLink.target(from: "https://youtu.be/vid00000001?list=PLtestlist0001")?.playlist?.absoluteString,
                       "https://www.youtube.com/playlist?list=PLtestlist0001")
        XCTAssertEqual(MediaLink.target(from: "https://music.youtube.com/playlist?list=OLAK5uy_abcDEF123")?.playlist?.absoluteString,
                       "https://music.youtube.com/playlist?list=OLAK5uy_abcDEF123")

        // Mixes, Watch Later and Liked are not downloadable lists: only the video remains.
        for list in ["RDvid00000001", "RDMMvid00000001", "RDAMVMvid00000001", "WL", "LL"] {
            let target = MediaLink.target(from: "https://www.youtube.com/watch?v=vid00000001&list=\(list)")
            XCTAssertNotNil(target?.video, list)
            XCTAssertNil(target?.playlist, list)
        }
        // YouTube Music's editorial lists share the "RD" prefix but are ordinary finite playlists.
        let editorial = "RDCLAK5uy_ExampleEditorialPlaylist000000001"
        XCTAssertEqual(MediaLink.target(from: "https://music.youtube.com/playlist?list=\(editorial)")?.playlist?.absoluteString,
                       "https://music.youtube.com/playlist?list=\(editorial)")
        XCTAssertNotNil(MediaLink.target(from: "https://music.youtube.com/watch?v=vid00000001&list=\(editorial)")?.playlist)
        // The embed form of a playlist names no video.
        let series = MediaLink.target(from: "https://www.youtube.com/embed/videoseries?list=PLtestlist0001")
        XCTAssertNil(series?.video)
        XCTAssertEqual(series?.playlist?.absoluteString, "https://www.youtube.com/playlist?list=PLtestlist0001")
        XCTAssertNil(MediaLink.target(from: "https://www.youtube.com/embed/videoseries"))
        for link in [
            "https://www.youtube.com/playlist", "https://www.youtube.com/playlist?list=", "https://www.youtube.com/playlist?list=WL",
            "https://www.youtube.com/playlist?list=PL$(id)", "https://www.youtube.com/@channel?list=PLtestlist0001",
            // A broken video identifier is an error, not a silent switch to the playlist.
            "https://www.youtube.com/watch?v=bad!id&list=PLtestlist0001",
            "https://example.com/playlist?list=PLtestlist0001"
        ] {
            XCTAssertNil(MediaLink.target(from: link), link)
        }
    }

    func testPlaylistListingCommandAndItsOutput() throws {
        let playlist = try XCTUnwrap(MediaLink.target(from: "https://www.youtube.com/playlist?list=PLtestlist0001")?.playlist)
        let arguments = YtDlpCommand.playlistArguments(for: playlist)
        XCTAssertEqual(Array(arguments.suffix(2)), ["--", "https://www.youtube.com/playlist?list=PLtestlist0001"])
        for flag in ["--ignore-config", "--flat-playlist", "--yes-playlist"] { XCTAssertTrue(arguments.contains(flag), flag) }
        XCTAssertEqual(value(after: "--playlist-end", in: arguments), "500")
        XCTAssertFalse(arguments.contains("--no-playlist"))

        XCTAssertTrue(arguments.contains("BARLET-LIST|%(playlist_count)s|%(playlist_title)s"))
        XCTAssertEqual(YtDlpOutput.parse("BARLET-LIST|90|Yaz | Akşamları"), .playlist(title: "Yaz | Akşamları", count: 90))
        XCTAssertEqual(YtDlpOutput.parse("BARLET-LIST|NA|Adı var"), .playlist(title: "Adı var", count: nil))
        XCTAssertEqual(YtDlpOutput.parse("BARLET-LIST|800|NA"), .playlist(title: nil, count: 800))
        for line in ["BARLET-LIST|NA|NA", "BARLET-LIST|NA", "BARLET-LIST|0|"] { XCTAssertNil(YtDlpOutput.parse(line), line) }
        XCTAssertEqual(YtDlpOutput.parse("BARLET-ENTRY|vid00000001|Şarkı | Canlı"), .playlistEntry(id: "vid00000001", title: "Şarkı | Canlı"))
        // Identifiers may start with a hyphen; they only ever travel inside a link after "--".
        XCTAssertEqual(YtDlpOutput.parse("BARLET-ENTRY|-abcDEF_123|x"), .playlistEntry(id: "-abcDEF_123", title: "x"))
        for line in ["BARLET-ENTRY|vid00000001", "BARLET-ENTRY|a$(id)b|x", "BARLET-ENTRY|a b c d e|x", "BARLET-ENTRY|abc&list=PLx|x", "BARLET-ENTRY||x"] {
            XCTAssertNil(YtDlpOutput.parse(line), line)
        }
    }

    func testFilesAreNamedAfterTheTitleAndFolderNamesAreSafe() throws {
        XCTAssertEqual(PlaylistPosition(index: 7, count: 90).label, "07")
        XCTAssertEqual(PlaylistPosition(index: 7, count: 5).label, "07")
        XCTAssertEqual(PlaylistPosition(index: 7, count: 250).label, "007")
        XCTAssertEqual(PlaylistPosition(index: 120, count: 90).label, "120")

        let url = try XCTUnwrap(MediaLink.youtubeURL(from: "https://youtu.be/vid00000001"))
        var request = MediaDownloadRequest(url: url, kind: .audio, quality: .best, audioFormat: .mp3,
                                           destination: URL(fileURLWithPath: "/tmp/Liste"))
        // The position in a playlist is shown in the list, never written into the file name.
        request.position = PlaylistPosition(index: 3, count: 90)
        let arguments = YtDlpCommand.arguments(for: request, ffmpegDirectory: nil, outputDirectory: "/tmp/w")
        XCTAssertEqual(value(after: "--output", in: arguments), "%(title).150B.%(ext)s")
        XCTAssertEqual(arguments.filter { $0 == "--paths" }.count, 1)
        // Each entry is still one video: the list itself is never handed to the downloader.
        XCTAssertTrue(arguments.contains("--no-playlist"))

        // A name that is taken is never reused: the newcomer gets a number.
        let taken: Set<String> = ["Şarkı.mp3", "Şarkı 2.mp3", "Dosya"]
        XCTAssertEqual(MediaLink.availableName(for: "Yeni.mp3") { taken.contains($0) }, "Yeni.mp3")
        XCTAssertEqual(MediaLink.availableName(for: "Şarkı.mp3") { taken.contains($0) }, "Şarkı 3.mp3")
        XCTAssertEqual(MediaLink.availableName(for: "Dosya") { taken.contains($0) }, "Dosya 2")
        XCTAssertEqual(MediaLink.availableName(for: "a.b.mp4") { $0 == "a.b.mp4" }, "a.b 2.mp4")

        // What a file is marked with: the video and the form it was saved in.
        XCTAssertEqual(request.originKey(hasFFmpeg: true), "vid00000001|audio|mp3")
        XCTAssertEqual(request.originKey(hasFFmpeg: false), "vid00000001|audio|mp3|plain")
        var other = request; other.audioFormat = .m4a
        XCTAssertNotEqual(other.originKey(hasFFmpeg: true), request.originKey(hasFFmpeg: true))
        other = request; other.kind = .video; other.quality = .p720
        XCTAssertEqual(other.originKey(hasFFmpeg: true), "vid00000001|video|p720")
        // Where it is saved and its place in a list do not change what it is.
        other = request; other.position = nil; other.destination = URL(fileURLWithPath: "/tmp/Başka")
        XCTAssertEqual(other.originKey(hasFFmpeg: true), request.originKey(hasFFmpeg: true))

        XCTAssertEqual(MediaLink.folderName(for: "Exactly", fallback: "x"), "Exactly")
        XCTAssertEqual(MediaLink.folderName(for: "  ../Rock/Pop: 90’lar\n ", fallback: "x"), "-Rock-Pop- 90’lar-")
        XCTAssertEqual(MediaLink.folderName(for: " ... ", fallback: "PL123"), "PL123")
        XCTAssertEqual(MediaLink.folderName(for: String(repeating: "a", count: 300), fallback: "x").count, 100)
        XCTAssertFalse(MediaLink.folderName(for: "a/b\\c", fallback: "x").contains("/"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
