import XCTest
@testable import ConvertCore

/// SRT and WebVTT files written by hand into the fixture's folder, converted and compared byte for byte.
final class SubtitleConverterTests: XCTestCase {
    private var fixture: ConversionFixture!
    private let converter = SubtitleConverter()

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "subtitles") }
    override func tearDownWithError() throws { fixture.remove() }

    func testOnlySRTAndWebVTTAreOfferedToEachOther() throws {
        let srt = try XCTUnwrap(FormatRegistry.format(id: "srt")), vtt = try XCTUnwrap(FormatRegistry.format(id: "vtt"))
        let environment = ConversionEnvironment()
        XCTAssertEqual(converter.availability(of: try fixture.target("vtt"), for: srt, in: environment), .available)
        XCTAssertEqual(converter.availability(of: try fixture.target("srt"), for: vtt, in: environment), .available)
        XCTAssertEqual(converter.availability(of: try fixture.target("srt"), for: srt, in: environment), .unsupported)
        XCTAssertEqual(converter.availability(of: try fixture.target("vtt"), for: vtt, in: environment), .unsupported)
        for id in ["txt", "pdf", "mp4", "compress", "ocr"] {
            XCTAssertEqual(converter.availability(of: try fixture.target(id), for: srt, in: environment), .unsupported, id)
        }
        for source in ["txt", "mp4", "docx"] {
            XCTAssertEqual(converter.availability(of: try fixture.target("vtt"), for: try XCTUnwrap(FormatRegistry.format(id: source)), in: environment), .unsupported, source)
        }
        XCTAssertNil(converter.note(for: try fixture.target("vtt"), source: srt))
    }

    func testSRTBecomesWebVTTAndBackWithTurkishTextAndTheBasicTags() async throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\nMerhaba, nasılsın?\r\n<i>Çok iyiyim</i>, ya sen?\r\n\r\n"
            + "2\r\n00:00:04,250 --> 00:01:02,005\r\nŞu ağaç <b>İstanbul</b>’da, <u>öğle</u> güneşinde & “gölgede” > 3 < 5\r\n\r\n"
            + "3\r\n01:02:03,004 --> 101:00:00,000\r\nGöz ışığı ÜĞİŞÇÖ ß\r\n\r\n"
        let source = try fixture.write("film.srt", Data(srt.utf8))
        let vtt = try await converted(source, to: "vtt")
        XCTAssertEqual(vtt, "WEBVTT\n\n"
            + "00:00:01.000 --> 00:00:03.500\nMerhaba, nasılsın?\n<i>Çok iyiyim</i>, ya sen?\n\n"
            + "00:00:04.250 --> 00:01:02.005\nŞu ağaç <b>İstanbul</b>’da, <u>öğle</u> güneşinde &amp; “gölgede” &gt; 3 &lt; 5\n\n"
            + "01:02:03.004 --> 101:00:00.000\nGöz ışığı ÜĞİŞÇÖ ß\n\n")
        let back = try await converted(try fixture.write("geri.vtt", Data(vtt.utf8)), to: "srt")
        XCTAssertEqual(back, srt, "SRT → WebVTT → SRT gives the file back")
    }

    func testTheWrittenFilesAreUTF8WithoutAMarkAndUseTheirOwnLineEnds() async throws {
        let source = try fixture.write("a.srt", Data("1\n00:00:01,000 --> 00:00:02,000\nbir\niki\n\n2\n00:00:03,000 --> 00:00:04,000\nüç\n".utf8))
        let request = try fixture.request([source], target: "vtt")
        let vtt = try Data(contentsOf: try await converter.convert(request, context: fixture.context())[0])
        XCTAssertFalse(vtt.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertFalse(vtt.contains(0x0D), "WebVTT uses LF only")
        let srtRequest = try fixture.request([try fixture.write("b.vtt", vtt)], target: "srt")
        let srt = try Data(contentsOf: try await converter.convert(srtRequest, context: fixture.context())[0])
        XCTAssertFalse(srt.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = String(decoding: srt, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\r\n").joined().contains("\n"), false, "SRT uses CRLF only")
        XCTAssertTrue(text.hasSuffix("üç\r\n\r\n"))
    }

    func testASloppySRTIsReadAsItsAuthorMeantIt() async throws {
        // Windows-1254 with CR, LF and CRLF mixed; a missing counter; full stops in the times; a blank
        // line inside a cue; a counter stuck to the cue before; one-digit hours and short fractions;
        // an unclosed <i>; a <font> tag and an ASS position block; cues out of order; an empty cue.
        let sloppy = "\r\n\r\n00:00:01.5 --> 00:00:02,25\r\n  Bir  iki   üç  \r\n\r\n"
            + "2\n0:00:03,000 --> 0:00:04,000 X1:10\nşığ\n\n<i>İkinci satır\n3\n"
            + "00:00:05,000 -> 00:00:06,000\r<font color=\"#ff0000\">{\\an8}Kırmızı</font> ğ\r\r"
            + "4\n00:00:10,000 --> 00:00:11,000\nonuncu saniye\n\n"
            + "5\n00:00:07:250 --> 00:00:08:000\nSonradan gelen\n\n"
            + "6\n00:00:09,000 --> 00:00:09,000\nsıfır süre\n\n"
            + "7\n00:00:11,500 --> 00:00:11,900\n\n"
            + "8\n00:00:12,000 --> 00:00:13,000\n1999\n"
        let data = try XCTUnwrap(sloppy.data(using: .windowsCP1254))
        let vtt = try await converted(try fixture.write("özensiz.srt", data), to: "vtt")
        XCTAssertEqual(vtt, "WEBVTT\n\n"
            + "00:00:01.500 --> 00:00:02.250\nBir iki üç\n\n"
            + "00:00:03.000 --> 00:00:04.000\nşığ\n<i>İkinci satır</i>\n\n"
            + "00:00:05.000 --> 00:00:06.000\nKırmızı ğ\n\n"
            + "00:00:07.250 --> 00:00:08.000\nSonradan gelen\n\n"
            + "00:00:10.000 --> 00:00:11.000\nonuncu saniye\n\n"
            + "00:00:12.000 --> 00:00:13.000\n1999\n\n")
    }

    func testWebVTTSettingsNotesStylesVoicesAndEntitiesDoNotReachTheSRT() async throws {
        let vtt = """
        WEBVTT - Türkçe altyazı
        Kind: captions
        Language: tr

        STYLE
        ::cue { color: yellow }

        NOTE Bu bir not
        ve devamı

        giriş
        00:01.000 --> 00:02.500 align:start position:10% line:0
        <v Ayşe>Merhaba</v> &amp; hoş geldin&nbsp;&#304;pek &lt;3

        00:00:03.000 --> 00:00:04.000
        <c.yellow>Sarı</c> <i.loud>bağır</i> <00:00:03.500>ve <ruby>kanji<rt>k</rt></ruby>

        NOTE
        son not
        """
        let srt = try await converted(try fixture.write("dizi.vtt", Data(vtt.utf8)), to: "srt")
        XCTAssertEqual(srt, "1\r\n00:00:01,000 --> 00:00:02,500\r\nMerhaba & hoş geldin İpek <3\r\n\r\n"
            + "2\r\n00:00:03,000 --> 00:00:04,000\r\nSarı <i>bağır</i> ve kanjik\r\n\r\n")
    }

    func testAWebVTTFileWithAnSRTNameIsStillReadAsWebVTT() async throws {
        let source = try fixture.write("yanlış.srt", Data("\u{FEFF}WEBVTT\n\nNOTE not\n\n00:00:01.000 --> 00:00:02.000\nDoğru\n".utf8))
        let vtt = try await converted(source, to: "vtt")
        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nDoğru\n\n")
    }

    func testAFileWithoutCuesOrWithoutTextFails() async throws {
        for (name, data) in [("boş.srt", Data("Merhaba\n\nhiç zaman yok\n".utf8)), ("ikili.vtt", Data([0x00, 0x01, 0x02])),
                             ("sadece.vtt", Data("WEBVTT\n\nNOTE yalnızca not\n".utf8))] {
            do {
                _ = try await converter.convert(try fixture.request([try fixture.write(name, data)], target: name.hasSuffix(".srt") ? "vtt" : "srt"), context: fixture.context())
                XCTFail("\(name) has no cue")
            } catch {
                XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Bu altyazı okunamadı."), name)
            }
        }
    }

    func testACancelledConversionWritesNothing() async throws {
        let source = try fixture.write("film.srt", Data("1\n00:00:01,000 --> 00:00:02,000\nbir\n".utf8))
        let request = try fixture.request([source], target: "vtt")
        fixture.cancel.set()
        do {
            _ = try await converter.convert(request, context: fixture.context())
            XCTFail("Cancelled")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(fixture.names(in: request.workFolder), [])
    }

    private func converted(_ source: URL, to target: String) async throws -> String {
        let request = try fixture.request([source], target: target)
        let outputs = try await converter.convert(request, context: fixture.context())
        XCTAssertEqual(outputs, [request.outputURL()])
        return try XCTUnwrap(String(data: try Data(contentsOf: outputs[0]), encoding: .utf8))
    }
}
