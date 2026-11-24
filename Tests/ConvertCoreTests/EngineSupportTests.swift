import CoreText
import os
import XCTest
@testable import ConvertCore

/// The helpers converters share: blocking work, text decoding and text recognition.
final class EngineSupportTests: XCTestCase {
    // MARK: Blocking work

    func testBlockingWorkRunsOffTheCallersThreadAndResumesOnceWithItsResultOrItsError() async throws {
        let value = try await ConversionWork.run { () -> String in
            XCTAssertFalse(Thread.isMainThread)
            return "tamam"
        }
        XCTAssertEqual(value, "tamam")
        do {
            _ = try await ConversionWork.run { () -> Int in throw ConversionFailure("Bu görüntü okunamadı.") }
            XCTFail("The error of the work is the error of the call")
        } catch {
            XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Bu görüntü okunamadı."))
        }
        // Many at once: each call gets its own answer, exactly once.
        let answers = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for number in 0..<64 {
                group.addTask { try await ConversionWork.run { usleep(2_000); return number * number } }
            }
            var all: [Int] = []
            for try await answer in group { all.append(answer) }
            return all.sorted()
        }
        XCTAssertEqual(answers, (0..<64).map { $0 * $0 })
    }

    func testCancellingTheWaitingTaskDoesNotAbandonBlockingWork() async throws {
        // The work decides when it stops: the call returns only when the work has returned.
        let finished = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await ConversionWork.run {
                usleep(150_000)
                finished.withLock { $0 = true }
                return Task.isCancelled
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let sawCancel = try await task.value
        XCTAssertTrue(finished.withLock { $0 }, "No work is left running behind a call that has returned")
        XCTAssertFalse(sawCancel, "On the work's thread there is no task to ask: that is why the context carries a flag")
    }

    // MARK: Text decoding

    func testTextIsDecodedByMarkThenStrictUTF8ThenUTF16ThenTheTurkishAndWesternCodePages() throws {
        let turkish = "Çağrı ışığı: İĞÜŞÖ ğüşöç"
        XCTAssertEqual(TextEncoding.decode(Data(turkish.utf8)), turkish)
        XCTAssertEqual(TextEncoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data(turkish.utf8)), turkish, "The mark is not part of the text")
        XCTAssertEqual(TextEncoding.decode(Data()), "")
        XCTAssertEqual(TextEncoding.decode(Data("a,b\r\n1,2\r\n".utf8)), "a,b\r\n1,2\r\n", "Line endings are left alone")

        let little = try XCTUnwrap(turkish.data(using: .utf16LittleEndian)), big = try XCTUnwrap(turkish.data(using: .utf16BigEndian))
        XCTAssertEqual(TextEncoding.decode(Data([0xFF, 0xFE]) + little), turkish)
        XCTAssertEqual(TextEncoding.decode(Data([0xFE, 0xFF]) + big), turkish)
        XCTAssertEqual(TextEncoding.decode(little), turkish, "Without a mark, the zero bytes tell the byte order")
        XCTAssertEqual(TextEncoding.decode(big), turkish)
        XCTAssertEqual(TextEncoding.decode(try XCTUnwrap("Āa dünya".data(using: .utf16LittleEndian))), "Āa dünya",
                       "A letter whose low byte is zero does not confuse it")
        let wide = try XCTUnwrap("merhaba 🌍".data(using: .utf32LittleEndian))
        XCTAssertEqual(TextEncoding.decode(Data([0xFF, 0xFE, 0x00, 0x00]) + wide), "merhaba 🌍")
        XCTAssertEqual(TextEncoding.decode(Data([0xFF, 0xFE, 0x61, 0x00, 0x00, 0xD8])), "a\u{FFFD}", "A marked file is read, damaged or not")

        let windows = try XCTUnwrap(turkish.data(using: .windowsCP1254))
        XCTAssertNil(String(data: windows, encoding: .utf8), "The fixture must not be UTF-8")
        XCTAssertEqual(TextEncoding.decode(windows), turkish)
        // Ž exists in Windows-1252 at a place Windows-1254 leaves empty.
        XCTAssertEqual(TextEncoding.decode(Data([0x8E, 0x61, 0x62])), "Žab")
        XCTAssertEqual(TextEncoding.decode(try XCTUnwrap("Größe: 5 µm".data(using: .windowsCP1252))), "Größe: 5 µm",
                       "Western text without such a letter reads the same in both")

        XCTAssertNil(TextEncoding.decode(Data([0x61, 0x81, 0x62])), "A byte neither code page has")
        XCTAssertNil(TextEncoding.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49])), "Not text at all")
        XCTAssertNil(TextEncoding.decode(Data([0x61, 0x00, 0x62])), "A NUL in plain text")
        XCTAssertNil(TextEncoding.decode(Data([0x00, 0x00, 0x00, 0x00])))
    }

    // MARK: Text recognition

    func testRecognitionLanguagesFollowTheUsersOrderAndEndWithEnglish() {
        let supported = ["en-US", "fr-FR", "de-DE", "tr-TR", "pt-BR", "zh-Hans"]
        XCTAssertEqual(TextRecognition.languages(supported: supported, preferred: ["tr-TR", "de-DE"]), ["tr-TR", "de-DE", "en-US"])
        XCTAssertEqual(TextRecognition.languages(supported: supported, preferred: ["tr", "en-GB", "de_AT"]), ["tr-TR", "en-US", "de-DE"],
                       "A language without its region finds the region Vision has")
        XCTAssertEqual(TextRecognition.languages(supported: supported, preferred: ["ja-JP", "pt-PT", "fr-FR", "fr-CA"]), ["pt-BR", "fr-FR", "en-US"])
        XCTAssertEqual(TextRecognition.languages(supported: supported, preferred: []), ["en-US"])
        XCTAssertEqual(TextRecognition.languages(supported: [], preferred: ["tr-TR"]), ["en-US"])
    }

    func testTextIsRecognisedTopToBottomAndCancellingStopsIt() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BSTOEQ_VISION_TESTS"] == "1", "Set BSTOEQ_VISION_TESTS=1 to run the Vision models")
        let lines = ["Merhaba dünya", "İkinci satır burada", "Third line in English"]
        let width = 1200, height = 500
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, 56, nil)
        for (row, text) in lines.enumerated() {
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as [CFString: Any]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
            context.textPosition = CGPoint(x: 60, y: height - 130 - row * 130)
            CTLineDraw(line, context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let text = try TextRecognition.text(in: image, isCancelled: { false })
        // The order is what is tested here; the recogniser may read a dotted capital İ as I.
        func plain(_ line: String) -> String { line.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en")) }
        XCTAssertEqual(text.split(separator: "\n").map { plain(String($0)) }, lines.map(plain))
        XCTAssertTrue(text.contains("dünya") && text.contains("satır"), "Turkish letters come back as letters: \(text)")
        XCTAssertThrowsError(try TextRecognition.text(in: image, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }
}
