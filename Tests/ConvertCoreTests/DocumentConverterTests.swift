import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ConvertCore

/// Real AppKit reading, layout and writing on documents made for the test (through `NSAttributedString`
/// or as Markdown and plain text), in the fixture's folders. Nothing needs a window or the main thread.
final class DocumentConverterTests: XCTestCase {
    private var fixture: ConversionFixture!
    private let converter = DocumentConverter()
    /// The letters a Turkish or German document must not lose.
    private static let sample = "Çiğdem şığ öğütü İSTANBUL ığüşöç ÄÖÜ Straße"

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "documents") }
    override func tearDownWithError() throws { fixture.remove() }

    // MARK: Offers

    func testDocumentsAreOfferedTheWritableFormatsButNeverTheirOwnOrATool() throws {
        let environment = ConversionEnvironment()
        for source in ["docx", "doc", "rtf", "rtfd", "odt", "html", "webarchive", "txt", "md"] {
            let format = try XCTUnwrap(FormatRegistry.format(id: source))
            for id in ["pdf", "docx", "rtf", "odt", "html", "txt"] {
                let expected: TargetAvailability = id == source ? .unsupported : .available
                XCTAssertEqual(converter.availability(of: try fixture.target(id), for: format, in: environment), expected, "\(source) → \(id)")
            }
            for id in ["png", "jpg", "csv", "srt", "compress", "ocr", "pdf.merge", "half"] {
                XCTAssertEqual(converter.availability(of: try fixture.target(id), for: format, in: environment), .unsupported, "\(source) → \(id)")
            }
        }
        for source in ["pdf", "png", "csv", "srt", "mp4"] {
            let format = try XCTUnwrap(FormatRegistry.format(id: source))
            XCTAssertEqual(converter.availability(of: try fixture.target("docx"), for: format, in: environment), .unsupported, "\(source) is not a document")
        }
        let caveat = "Görseller aktarılmaz; yazı biçimleri sadeleşebilir."
        for source in ["doc", "docx", "odt"] {
            XCTAssertEqual(converter.note(for: try fixture.target("pdf"), source: try XCTUnwrap(FormatRegistry.format(id: source))), caveat)
        }
        XCTAssertEqual(converter.note(for: try fixture.target("pdf"), source: try XCTUnwrap(FormatRegistry.format(id: "md"))),
                       "Görseller aktarılmaz.", "Markdown pictures keep only their alt text")
        for source in ["rtf", "rtfd", "html", "txt"] {
            XCTAssertNil(converter.note(for: try fixture.target("pdf"), source: try XCTUnwrap(FormatRegistry.format(id: source))))
        }
        XCTAssertNil(converter.note(for: try fixture.target("png"), source: try XCTUnwrap(FormatRegistry.format(id: "docx"))), "No caveat for a pair that is not offered")
    }

    // MARK: Every pair

    func testEveryDocumentBecomesEveryTargetAndKeepsTheTurkishAndGermanLetters() async throws {
        let sources = [try writeRich("kaynak.rtf", .rtf), try writeRich("kaynak.docx", .officeOpenXML), try writeRich("kaynak.odt", .openDocument),
                       try writeRich("kaynak.doc", .docFormat), try writeRich("kaynak.html", .html), try writeRich("kaynak.rtfd", .rtfd),
                       try fixture.write("kaynak.txt", Data("Başlık\n\n\(Self.sample)\n".utf8)),
                       try fixture.write("kaynak.md", Data("# Başlık\n\n**\(Self.sample)**\n".utf8))]
        for source in sources {
            let format = try XCTUnwrap(FormatRegistry.format(of: source))
            for target in ["pdf", "docx", "rtf", "odt", "html", "txt"] where target != format.id {
                let request = try fixture.request([source], target: target)
                let outputs = try await converter.convert(request, context: fixture.context())
                XCTAssertEqual(outputs, [request.outputURL()], "\(format.id) → \(target)")
                let text = try readBack(outputs[0], as: target)
                XCTAssertTrue(text.contains(Self.sample), "\(format.id) → \(target) lost letters: \(text.debugDescription)")
                XCTAssertTrue(text.contains("Başlık"), "\(format.id) → \(target)")
            }
        }
    }

    func testPlainTextInUTF16AndWindows1254IsDecodedAndSetInHelveticaNeue() async throws {
        let text = "\(Self.sample)\nİkinci satır: ğĞıİşŞ"
        let files = [try fixture.write("utf16-bom.txt", try XCTUnwrap(text.data(using: .utf16))),
                     try fixture.write("utf16-le.txt", try XCTUnwrap(text.data(using: .utf16LittleEndian))),
                     try fixture.write("utf16-be.txt", try XCTUnwrap(text.data(using: .utf16BigEndian))),
                     try fixture.write("windows-1254.txt", try XCTUnwrap(text.replacingOccurrences(of: "ß", with: "ss").data(using: .windowsCP1254)))]
        for file in files {
            let request = try fixture.request([file], target: "rtf")
            let outputs = try await converter.convert(request, context: fixture.context())
            let back = try NSAttributedString(url: outputs[0], options: [:], documentAttributes: nil)
            let expected = file.lastPathComponent == "windows-1254.txt" ? text.replacingOccurrences(of: "ß", with: "ss") : text
            XCTAssertEqual(back.string.trimmingCharacters(in: .newlines), expected, file.lastPathComponent)
            let font = try XCTUnwrap(back.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.fontName, "HelveticaNeue", file.lastPathComponent)
            XCTAssertEqual(font.pointSize, 12, file.lastPathComponent)
        }
    }

    // MARK: PDF

    func testALongTextPaginatesOnThePaperOfTheSettingsAndItsTextCanBeSearched() async throws {
        let paragraphs = (1...240).map { "Paragraf \($0): \(Self.sample) " + String(repeating: "lorem ipsum dolor sit amet ", count: 6) }
        let source = try fixture.write("uzun.txt", Data(paragraphs.joined(separator: "\n").utf8))
        for (paper, size) in [(PaperSize.a4, CGSize(width: 595, height: 842)), (.letter, CGSize(width: 612, height: 792))] {
            let request = try fixture.request([source], target: "pdf", options: ConversionOptions(paper: paper))
            let outputs = try await converter.convert(request, context: fixture.context())
            let document = try XCTUnwrap(PDFDocument(url: outputs[0]))
            XCTAssertGreaterThan(document.pageCount, 4, "\(paper)")
            for index in 0..<document.pageCount {
                let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
                XCTAssertEqual(bounds.size, size, "page \(index + 1) on \(paper)")
            }
            let text = try XCTUnwrap(document.string).precomposedStringWithCanonicalMapping
            XCTAssertTrue(text.contains("Paragraf 1: \(Self.sample)"))
            XCTAssertTrue(text.contains("Paragraf 240: \(Self.sample)"), "The last paragraph is on the last page")
            XCTAssertTrue(try XCTUnwrap(document.page(at: document.pageCount - 1)?.string).contains("Paragraf 240"))
        }
        XCTAssertTrue(fixture.progress.contains { $0 > 0.1 && $0 < 1 }, "Progress is reported page by page")
        let steps = fixture.progress
        XCTAssertTrue(zip(steps, steps.dropFirst()).allSatisfy { $1 >= $0 || $1 == 0.1 }, "Progress goes back only where the next conversion starts: \(steps)")
    }

    func testAPictureLargerThanThePageIsScaledToFitAndStaysInThePDF() async throws {
        // Blue above, red below: a picture clipped to its page would show only blue.
        let picture = NSTextAttachment(fileWrapper: FileWrapper(regularFileWithContents: try png(width: 1200, height: 1800, lowerHalf: CGColor(red: 1, green: 0, blue: 0, alpha: 1))))
        picture.fileWrapper?.preferredFilename = "resim.png"
        let text = NSMutableAttributedString(string: "Önce\n", attributes: [.font: try XCTUnwrap(NSFont(name: "HelveticaNeue", size: 12))])
        text.append(NSAttributedString(attachment: picture))
        text.append(NSAttributedString(string: "\nSonra\n", attributes: [.font: try XCTUnwrap(NSFont(name: "HelveticaNeue", size: 12))]))
        let wrapper = try text.fileWrapper(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let source = fixture.url("resimli.rtfd")
        try wrapper.write(to: source, options: [], originalContentsURL: nil)
        let outputs = try await converter.convert(try fixture.request([source], target: "pdf"), context: fixture.context())
        let document = try XCTUnwrap(PDFDocument(url: outputs[0]))
        XCTAssertTrue(try XCTUnwrap(document.string).contains("Önce"))
        XCTAssertTrue(try XCTUnwrap(document.string).contains("Sonra"))
        let colours = try (0..<document.pageCount).map { try self.colours(on: try XCTUnwrap(document.page(at: $0))) }
        XCTAssertTrue(colours.contains { $0.red && $0.blue }, "The whole picture is on one page: \(colours)")
    }

    func testHTMLIsReadWithItsOwnFolderAsTheBaseAndInUTF8WithoutACharset() async throws {
        try fixture.write("sayfa/nokta.png", try png(width: 40, height: 30))
        let page = "<html><body><h1>Başlık</h1><p>\(Self.sample)</p><img src=\"nokta.png\"></body></html>"
        let source = try fixture.write("sayfa/sayfa.html", Data(page.utf8))
        let pdf = try await converter.convert(try fixture.request([source], target: "pdf"), context: fixture.context())
        XCTAssertTrue(String(decoding: try Data(contentsOf: pdf[0]), as: Unicode.ASCII.self).contains("/Subtype /Image"), "The relative picture was found")
        let text = try await converter.convert(try fixture.request([source], target: "txt"), context: fixture.context())
        XCTAssertEqual(try String(contentsOf: text[0], encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }, ["Başlık", Self.sample])
        let legacy = try fixture.write("eski.html", try XCTUnwrap("<html><body><p>\(Self.sample.replacingOccurrences(of: "ß", with: "ss"))</p></body></html>".data(using: .windowsCP1254)))
        let decoded = try await converter.convert(try fixture.request([legacy], target: "txt"), context: fixture.context())
        XCTAssertEqual(try String(contentsOf: decoded[0], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), Self.sample.replacingOccurrences(of: "ß", with: "ss"))
    }

    func testAWebArchiveIsRead() async throws {
        let page = "<html><head><meta charset=\"utf-8\"></head><body><p>\(Self.sample)</p></body></html>"
        let archive: [String: Any] = ["WebMainResource": ["WebResourceData": Data(page.utf8), "WebResourceMIMEType": "text/html",
                                                          "WebResourceTextEncodingName": "UTF-8", "WebResourceURL": "file:///sayfa.html",
                                                          "WebResourceFrameName": ""]]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        let source = try fixture.write("arşiv.webarchive", data)
        let outputs = try await converter.convert(try fixture.request([source], target: "txt"), context: fixture.context())
        XCTAssertEqual(try String(contentsOf: outputs[0], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), Self.sample)
    }

    // MARK: Markdown

    func testMarkdownKeepsHeadingSizesListsCodeAndTables() async throws {
        let markdown = """
        # Bir
        ## İki
        ### Üç

        Düz *eğik* **kalın** ~~çizik~~ `kod` [bağlantı](https://example.com/a) [betik](javascript:alert(1))

        - elma
        - armut
          - iç madde
        3. üçüncü
        4. dördüncü

        > alıntı

        ```swift
        let x = 1
        print(x)
        ```

        | Sütun A | Sütun B |
        |---|:---:|
        | hücre 1 | |
        | | hücre 4 |

        ---
        Son.
        """
        let rendered = MarkdownRenderer.render(markdown)
        let string = rendered.string as NSString
        func font(of text: String) throws -> NSFont {
            let range = string.range(of: text)
            XCTAssertNotEqual(range.location, NSNotFound, text)
            return try XCTUnwrap(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont, text)
        }
        func paragraph(of text: String) throws -> NSParagraphStyle {
            try XCTUnwrap(rendered.attribute(.paragraphStyle, at: string.range(of: text).location, effectiveRange: nil) as? NSParagraphStyle, text)
        }
        XCTAssertEqual(try font(of: "Bir").fontName, "HelveticaNeue-Bold"); XCTAssertEqual(try font(of: "Bir").pointSize, 24)
        XCTAssertEqual(try font(of: "İki").pointSize, 20); XCTAssertEqual(try font(of: "Üç").pointSize, 16)
        XCTAssertEqual(try paragraph(of: "Bir").headerLevel, 1)
        XCTAssertEqual(try font(of: "Düz").fontName, "HelveticaNeue"); XCTAssertEqual(try font(of: "Düz").pointSize, 12)
        XCTAssertEqual(try font(of: "eğik").fontName, "HelveticaNeue-Italic")
        XCTAssertEqual(try font(of: "kalın").fontName, "HelveticaNeue-Bold")
        XCTAssertEqual(try font(of: "kod").fontName, "Menlo-Regular"); XCTAssertEqual(try font(of: "kod").pointSize, 11)
        XCTAssertEqual(try font(of: "let x = 1").fontName, "Menlo-Regular")
        XCTAssertTrue(string.contains("let x = 1\nprint(x)\n"), "Code keeps its lines")
        XCTAssertNotNil(rendered.attribute(.strikethroughStyle, at: string.range(of: "çizik").location, effectiveRange: nil))
        XCTAssertEqual(rendered.attribute(.link, at: string.range(of: "bağlantı").location, effectiveRange: nil) as? URL, URL(string: "https://example.com/a"))
        XCTAssertNil(rendered.attribute(.link, at: string.range(of: "betik").location, effectiveRange: nil), "A script link keeps its text only")
        XCTAssertTrue(string.contains("\t•\telma\n\t•\tarmut\n\t◦\tiç madde\n"), "Bullets by depth: \(string)")
        XCTAssertTrue(string.contains("\t3.\tüçüncü\n\t4.\tdördüncü\n"), "Numbers as written")
        XCTAssertEqual(try paragraph(of: "iç madde").textLists.count, 2, "A nested item sits in both lists")
        XCTAssertEqual(try paragraph(of: "üçüncü").textLists.first?.startingItemNumber, 3)
        XCTAssertGreaterThan(try paragraph(of: "alıntı").headIndent, 0)
        XCTAssertTrue(string.contains("Sütun A\nSütun B\nhücre 1\n\n\nhücre 4\n"), "Cells in order, the empty ones kept: \(string)")
        let cell = try XCTUnwrap(try paragraph(of: "hücre 4").textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(cell.startingRow, 2); XCTAssertEqual(cell.startingColumn, 1); XCTAssertEqual(cell.table.numberOfColumns, 2)
        XCTAssertEqual(try paragraph(of: "hücre 4").alignment, .center)
        XCTAssertEqual(try font(of: "Sütun A").fontName, "HelveticaNeue-Bold", "The header row is bold")
        XCTAssertTrue(string.contains("Son."))
        XCTAssertTrue(string.hasPrefix("Bir\n\n"), "Top-level blocks are kept apart")

        // Written to RTF and read back, the structure survives.
        let source = try fixture.write("notlar.md", Data(markdown.utf8))
        let rtf = try await converter.convert(try fixture.request([source], target: "rtf"), context: fixture.context())
        let back = try NSAttributedString(url: rtf[0], options: [.textKit1ListMarkerFormatDocumentOption: true], documentAttributes: nil)
        let backString = back.string as NSString
        XCTAssertTrue(backString.contains("\t•\telma"), back.string)
        XCTAssertTrue(backString.contains("\t3.\tüçüncü"), back.string)
        let heading = try XCTUnwrap(back.attribute(.font, at: backString.range(of: "Bir").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(heading.fontName, "HelveticaNeue-Bold"); XCTAssertEqual(heading.pointSize, 24)
        let code = try XCTUnwrap(back.attribute(.font, at: backString.range(of: "print(x)").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(code.fontName, "Menlo-Regular")
        let style = try XCTUnwrap(back.attribute(.paragraphStyle, at: backString.range(of: "hücre 4").location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertTrue(style.textBlocks.first is NSTextTableBlock, "The table is still a table")

        let html = try await converter.convert(try fixture.request([source], target: "html"), context: fixture.context())
        let markup = try String(contentsOf: html[0], encoding: .utf8)
        for element in ["<h1", "<ul", "<ol", "<li", "<table", "<a href=\"https://example.com/a\""] { XCTAssertTrue(markup.contains(element), element) }
        XCTAssertFalse(markup.contains("javascript:"))

        let plain = try await converter.convert(try fixture.request([source], target: "txt"), context: fixture.context())
        let lines = try String(contentsOf: plain[0], encoding: .utf8)
        XCTAssertTrue(lines.hasPrefix("Bir\n\nİki\n\nÜç\n\nDüz eğik kalın çizik kod bağlantı betik\n\n\t•\telma\n"), lines)
    }

    func testNoFontNameInAWrittenDocumentStartsWithAFullStop() async throws {
        // A document made with the system fonts, the case that would leak their private names.
        let text = NSMutableAttributedString(string: "Sistem yazısı \(Self.sample)\n", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        text.append(NSAttributedString(string: "kalın\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
        text.append(NSAttributedString(string: "let kod = 1\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]))
        let rich = try fixture.write("sistem.rtf", try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let markdown = try fixture.write("not.md", Data("# Başlık\n\n**kalın** `kod`\n\n```\nblok\n```\n".utf8))
        for source in [rich, markdown] {
            for target in ["rtf", "docx", "odt", "html"] where target != FormatRegistry.format(of: source)?.id {
                let outputs = try await converter.convert(try fixture.request([source], target: target), context: fixture.context())
                let back = try NSAttributedString(url: outputs[0], options: [:], documentAttributes: nil)
                var names = Set<String>()
                back.enumerateAttribute(.font, in: NSRange(location: 0, length: back.length)) { value, _, _ in
                    if let font = value as? NSFont { names.insert(font.fontName) }
                }
                XCTAssertFalse(names.isEmpty)
                XCTAssertFalse(names.contains { $0.hasPrefix(".") }, "\(source.lastPathComponent) → \(target): \(names.sorted())")
                if target == "rtf" || target == "html" {
                    let raw = String(decoding: try Data(contentsOf: outputs[0]), as: UTF8.self)
                    XCTAssertFalse(raw.contains(".AppleSystemUI") || raw.contains(".SFNS"), "\(source.lastPathComponent) → \(target)")
                }
            }
        }
        let code = try await converter.convert(try fixture.request([rich], target: "docx"), context: fixture.context())
        let back = try NSAttributedString(url: code[0], options: [:], documentAttributes: nil)
        let font = try XCTUnwrap(back.attribute(.font, at: (back.string as NSString).range(of: "let kod").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.fontName, "Menlo-Regular", "The fixed-pitch system font stays fixed-pitch")
    }

    // MARK: Threads

    /// Runs on the main thread and blocks it while the conversions run: nothing may wait for the main
    /// thread or a running application, as the probe showed for `NSPrintOperation`.
    func testConversionToPDFRunsWhileTheMainThreadIsBlocked() throws {
        XCTAssertTrue(Thread.isMainThread)
        let sources = [try writeRich("ana.docx", .officeOpenXML), try writeRich("ana.html", .html),
                       try fixture.write("ana.md", Data("# Başlık\n\n- \(Self.sample)\n".utf8)), try fixture.write("ana.txt", Data(Self.sample.utf8))]
        let requests = try sources.map { try fixture.request([$0], target: "pdf") }
        let converter = converter, context = fixture.context()
        let finished = DispatchSemaphore(value: 0)
        let results = Results()
        for request in requests {
            Task.detached {
                do { results.add(try await converter.convert(request, context: context)) } catch { results.add(error) }
                finished.signal()
            }
        }
        for _ in requests { XCTAssertEqual(finished.wait(timeout: .now() + 60), .success, "A conversion waited for the main thread") }
        XCTAssertEqual(results.errors.count, 0, "\(results.errors)")
        for url in results.outputs {
            XCTAssertTrue(try XCTUnwrap(PDFDocument(url: url)?.string).precomposedStringWithCanonicalMapping.contains(Self.sample), url.lastPathComponent)
        }
        XCTAssertEqual(results.outputs.count, requests.count)
    }

    // MARK: Failures

    func testEmptyAndUnreadableDocumentsFailWithTheirOwnMessages() async throws {
        let empty = try fixture.write("boş.txt", Data(" \n\n\t\n".utf8))
        await assertFailure(try fixture.request([empty], target: "pdf"), "Belge boş.")
        let emptyMarkdown = try fixture.write("boş.md", Data("\n\n".utf8))
        await assertFailure(try fixture.request([emptyMarkdown], target: "docx"), "Belge boş.")
        let broken = try fixture.write("bozuk.docx", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
        await assertFailure(try fixture.request([broken], target: "pdf"), "Bu belge okunamadı.")
        let binary = try fixture.write("ikili.txt", Data([0x41, 0x00, 0x42]))
        await assertFailure(try fixture.request([binary], target: "rtf"), "Bu belge okunamadı.")
        let missing = fixture.url("yok.rtf")
        await assertFailure(try fixture.request([missing], target: "txt"), "Bu belge okunamadı.")
    }

    func testCancellationStopsBeforeReadingAndBetweenPages() async throws {
        let source = try fixture.write("uzun.txt", Data((1...3000).map { "Satır \($0) \(Self.sample)" }.joined(separator: "\n").utf8))
        fixture.cancel.set()
        do {
            _ = try await converter.convert(try fixture.request([source], target: "pdf"), context: fixture.context())
            XCTFail("A cancelled conversion does not run")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }

        // Cancelled once the first page is out.
        let flag = ConversionFixture.Flag()
        let pages = Counter()
        let context = ConversionContext(isCancelled: { flag.isSet }, progress: { fraction in if fraction > 0.1 { pages.increment(); flag.set() } })
        do {
            _ = try await converter.convert(try fixture.request([source], target: "pdf"), context: context)
            XCTFail("The conversion stops between pages")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(pages.value, 1, "No page is laid out after the cancel")
    }

    // MARK: Helpers

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = [], failures: [Error] = []
        func add(_ value: [URL]) { lock.withLock { urls += value } }
        func add(_ error: Error) { lock.withLock { failures.append(error) } }
        var outputs: [URL] { lock.withLock { urls } }
        var errors: [Error] { lock.withLock { failures } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func assertFailure(_ request: ConversionRequest, _ key: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await converter.convert(request, context: fixture.context())
            XCTFail("Expected \(key)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? ConversionFailure)?.key, key, "\(error)", file: file, line: line)
        }
    }

    /// A heading, the sample in bold, italic and plain, and a bulleted list, as a word processor writes it.
    private func writeRich(_ name: String, _ type: NSAttributedString.DocumentType) throws -> URL {
        let body = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        let text = NSMutableAttributedString(string: "Başlık\n", attributes: [.font: try XCTUnwrap(NSFont(name: "Helvetica-Bold", size: 20))])
        text.append(NSAttributedString(string: "\(Self.sample)\n", attributes: [.font: body]))
        text.append(NSAttributedString(string: "kalın ", attributes: [.font: try XCTUnwrap(NSFont(name: "Helvetica-Bold", size: 12))]))
        text.append(NSAttributedString(string: "eğik\n", attributes: [.font: try XCTUnwrap(NSFont(name: "Helvetica-Oblique", size: 12))]))
        let list = NSMutableParagraphStyle()
        list.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        text.append(NSAttributedString(string: "\t•\tmadde\n", attributes: [.font: body, .paragraphStyle: list]))
        let range = NSRange(location: 0, length: text.length)
        let url = fixture.url(name)
        if type == .rtfd {
            try text.fileWrapper(from: range, documentAttributes: [.documentType: type]).write(to: url, options: [], originalContentsURL: nil)
        } else {
            try text.data(from: range, documentAttributes: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue]).write(to: url)
        }
        return url
    }

    private func readBack(_ url: URL, as format: String) throws -> String {
        let text: String
        switch format {
        case "pdf": text = try XCTUnwrap(PDFDocument(url: url)?.string)
        case "txt": text = try String(contentsOf: url, encoding: .utf8)
        default: text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        return text.precomposedStringWithCanonicalMapping
    }

    private func png(width: Int, height: Int, lowerHalf: CGColor? = nil) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let lowerHalf {
            context.setFillColor(lowerHalf)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Whether a page, drawn at 72 dpi, shows clearly red and clearly blue pixels.
    private func colours(on page: PDFPage) throws -> (red: Bool, blue: Bool) {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width), height = Int(bounds.height)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: context)
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        var red = false, blue = false
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let (r, g, b) = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
            if r > 200, g < 60, b < 60 { red = true }
            if b > 200, r < 60, g < 60 { blue = true }
        }
        return (red, blue)
    }
}
