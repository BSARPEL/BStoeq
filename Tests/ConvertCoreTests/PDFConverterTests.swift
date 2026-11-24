import AppKit
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ConvertCore

/// PDFs to page images, text and Word; split, merge, compress and OCR. Every PDF is drawn here with
/// CoreGraphics or written out by hand, so the outline and the links are really in the file.
final class PDFConverterTests: XCTestCase {
    private var fixture: ConversionFixture!
    private let converter = PDFConverter()

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "pdf") }
    override func tearDownWithError() throws { fixture.remove() }

    // MARK: What is offered

    func testAPDFIsOfferedPageImagesTextWordAndThePDFToolsAndNothingElse() throws {
        let pdf = try XCTUnwrap(FormatRegistry.format(id: "pdf"))
        for id in ["png", "jpg", "tiff", "txt", "docx", "rtf", "pdf.split", "pdf.merge", "compress", "ocr"] {
            XCTAssertEqual(converter.availability(of: try fixture.target(id), for: pdf, in: ConversionEnvironment()), .available, id)
        }
        for id in ["pdf", "half", "nobg", "mute", "webp", "heic", "html", "odt", "mp4", "csv"] {
            XCTAssertEqual(converter.availability(of: try fixture.target(id), for: pdf, in: ConversionEnvironment()), .unsupported, id)
        }
    }

    func testImagesMayJoinAMergeButAreLeftToTheImageConverterOtherwise() throws {
        for id in ["jpg", "png", "heic", "tiff", "gif", "svg", "webp", "dng"] {
            let format = try XCTUnwrap(FormatRegistry.format(id: id))
            XCTAssertEqual(converter.availability(of: try fixture.target("pdf.merge"), for: format, in: ConversionEnvironment()), .available, id)
            for target in ["pdf", "png", "compress", "ocr", "half"] {
                XCTAssertEqual(converter.availability(of: try fixture.target(target), for: format, in: ConversionEnvironment()), .unsupported, "\(id) \(target)")
            }
        }
        for id in ["txt", "docx", "mp4", "zip", "csv", "folder"] {
            let format = try XCTUnwrap(FormatRegistry.format(id: id))
            XCTAssertEqual(converter.availability(of: try fixture.target("pdf.merge"), for: format, in: ConversionEnvironment()), .unsupported, id)
        }
    }

    func testWordAndRTFWarnThatOnlyTheTextIsCarried() throws {
        let pdf = try XCTUnwrap(FormatRegistry.format(id: "pdf"))
        XCTAssertEqual(converter.note(for: try fixture.target("docx"), source: pdf), "Yalnızca metin aktarılır; düzen ve görseller korunmaz.")
        XCTAssertEqual(converter.note(for: try fixture.target("rtf"), source: pdf), "Yalnızca metin aktarılır; düzen ve görseller korunmaz.")
        for id in ["txt", "png", "pdf.merge", "compress"] { XCTAssertNil(converter.note(for: try fixture.target(id), source: pdf), id) }
    }

    // MARK: Page images

    func testEveryPageBecomesAnImageAtTheChosenResolutionNamedByItsNumber() async throws {
        let pdf = try textPDF("Rapor.pdf", ["Birinci sayfa", "İkinci sayfa"])
        for (dpi, size) in [(72, (595, 842)), (150, (1240, 1754))] {
            let urls = try await run([pdf], "png", options: ConversionOptions(pdfDPI: dpi))
            XCTAssertEqual(urls.map(\.lastPathComponent), ["Rapor_p1.png", "Rapor_p2.png"])
            for url in urls {
                let image = try decoded(url)
                XCTAssertEqual(image.width, size.0, "\(dpi) dpi")
                XCTAssertEqual(image.height, size.1, "\(dpi) dpi")
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil) as? [CFString: Any])
                XCTAssertEqual((properties[kCGImagePropertyDPIWidth] as? Double) ?? 0, Double(dpi), accuracy: 0.5)
            }
            let (_, _, bytes) = rgba(try decoded(urls[0]))
            XCTAssertEqual(Array(bytes[0..<3]), [255, 255, 255], "Paper is white, not transparent")
        }
        XCTAssertEqual(fixture.progress.last, 1)
    }

    func testOnePageGivesOneImageUnderTheBaseNameInEachFormat() async throws {
        let pdf = try textPDF("Tek.pdf", ["Yalnız bir sayfa"])
        for (id, type) in [("png", UTType.png), ("jpg", .jpeg), ("tiff", .tiff)] {
            let urls = try await run([pdf], id, options: ConversionOptions(pdfDPI: 100))
            XCTAssertEqual(urls.map(\.lastPathComponent), ["Tek.\(id)"])
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, type.identifier)
            let image = try decoded(urls[0])
            XCTAssertEqual(image.width, 826)
            XCTAssertEqual(image.height, 1169)
            let (_, _, bytes) = rgba(image)
            XCTAssertGreaterThan(Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2]), 3 * 245, "\(id): white paper")
        }
    }

    func testARotatedPageIsDrawnUprightWithinItsCropBox() async throws {
        // Unturned, the crop box shows red at its bottom left and blue at its top right; green lies outside it.
        let drawing = "0 1 0 rg 0 0 200 100 re f 1 1 1 rg 20 10 160 80 re f 1 0 0 rg 20 10 20 20 re f 0 0 1 rg 160 70 20 20 re f"
        let pdf = try handWritten("Döndürülmüş.pdf", [Sketch(size: CGSize(width: 200, height: 100), rotate: 90,
                                                             crop: CGRect(x: 20, y: 10, width: 160, height: 80), drawing: drawing)])
        for (dpi, size) in [(72, (80, 160)), (144, (160, 320))] {
            let url = try await run([pdf], "png", options: ConversionOptions(pdfDPI: dpi))[0]
            let image = try decoded(url)
            XCTAssertEqual(image.width, size.0)
            XCTAssertEqual(image.height, size.1)
            let (width, height, bytes) = rgba(image)
            func color(_ x: Int, _ y: Int) -> [Int] { let at = (y * width + x) * 4; return bytes[at..<at + 3].map(Int.init) }
            let step = dpi / 72
            // Turned a quarter clockwise: bottom left goes to top left, top right to bottom right.
            XCTAssertTrue(near(color(5 * step, 5 * step), [255, 0, 0]), "\(dpi) dpi: \(color(5 * step, 5 * step))")
            XCTAssertTrue(near(color(width - 5 * step, height - 5 * step), [0, 0, 255]), "\(dpi) dpi")
            for (x, y) in [(width - 3, 2), (2, height - 3), (width / 2, height / 2), (width - 3, height / 2)] {
                XCTAssertTrue(near(color(x, y), [255, 255, 255]), "Nothing outside the crop box at \(x),\(y): \(color(x, y))")
            }
        }
    }

    func testAHugePageIsCappedAtTwelveThousandPixels() async throws {
        let pdf = try handWritten("Afiş.pdf", [Sketch(size: CGSize(width: 1500, height: 100))])
        let image = try decoded(try await run([pdf], "png", options: ConversionOptions(pdfDPI: 600))[0])
        XCTAssertEqual(image.width, 12_000)
        XCTAssertEqual(image.height, 800)
    }

    // MARK: Text

    func testTextComesOutInPageOrderWithTurkishLettersIntact() async throws {
        let pdf = try textPDF("Metin.pdf", ["Birinci sayfa: çğıöşü ÇĞİÖŞÜ", "İkinci sayfa: Şişli ılık"])
        let url = try await run([pdf], "txt")[0]
        XCTAssertEqual(url.lastPathComponent, "Metin.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let first = try XCTUnwrap(text.range(of: "Birinci sayfa: çğıöşü ÇĞİÖŞÜ")), second = try XCTUnwrap(text.range(of: "İkinci sayfa: Şişli ılık"))
        XCTAssertLessThan(first.upperBound, second.lowerBound)
        XCTAssertTrue(text[first.upperBound..<second.lowerBound].contains("\n\n"), "Pages are apart by a blank line")
        XCTAssertTrue(fixture.notes.isEmpty, "A text layer needs no OCR")
    }

    func testWordAndRTFHoldTheTextOfEveryPage() async throws {
        let pdf = try textPDF("Belge.pdf", ["Birinci sayfa: çğıöşü", "İkinci sayfa: ÇĞİÖŞÜ"])
        for (id, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("rtf", .rtf)] {
            let url = try await run([pdf], id)[0]
            XCTAssertEqual(url.lastPathComponent, "Belge.\(id)")
            let read = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
            XCTAssertTrue(read.contains("Birinci sayfa: çğıöşü"), id)
            XCTAssertTrue(read.contains("İkinci sayfa: ÇĞİÖŞÜ"), id)
        }
    }

    // MARK: Split

    func testSplittingGivesOneDocumentPerPageInOrder() async throws {
        let pdf = try textPDF("Kitap.pdf", ["Sayfa bir", "Sayfa iki", "Sayfa üç"])
        let urls = try await run([pdf], "pdf.split")
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Kitap_p1.pdf", "Kitap_p2.pdf", "Kitap_p3.pdf"])
        for (url, text) in zip(urls, ["Sayfa bir", "Sayfa iki", "Sayfa üç"]) {
            let document = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertEqual(document.pageCount, 1)
            XCTAssertTrue(document.string?.contains(text) == true, text)
        }
        XCTAssertEqual(fixture.progress.last, 1)
    }

    func testASinglePagePDFIsNotSplit() async throws {
        let pdf = try textPDF("Tek.pdf", ["Tek sayfa"])
        let error = await failure([pdf], "pdf.split")
        XCTAssertEqual(error as? ConversionSkip, ConversionSkip("Tek sayfalı PDF bölünemez."))
    }

    // MARK: Merge

    func testMergeKeepsTheOrderOfPDFsAndImagesAndEveryTIFFPage() async throws {
        let first = try textPDF("Bir.pdf", ["Bir-1", "Bir-2", "Bir-3"])
        let png = try save([picture(300, 200)], "Resim.png", type: .png)
        let second = try textPDF("İki.pdf", ["İki-1", "İki-2"], size: CGSize(width: 842, height: 595))
        let tiff = try save([picture(100, 100), picture(50, 80)], "Tarama.tiff", type: .tiff)
        let urls = try await run([first, png, second, tiff], "pdf.merge")
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Bir.pdf"], "Named after the first source; the engine adds the suffix")
        let merged = try XCTUnwrap(PDFDocument(url: urls[0]))
        XCTAssertEqual(merged.pageCount, 8)
        let texts = (0..<8).map { merged.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        XCTAssertEqual(texts, ["Bir-1", "Bir-2", "Bir-3", "", "İki-1", "İki-2", "", ""])
        let sizes = (0..<8).map { merged.page(at: $0)!.bounds(for: .mediaBox).size }
        XCTAssertEqual(sizes[3], CGSize(width: 300, height: 200), "An image without a resolution is 72 dpi")
        XCTAssertEqual(sizes[4], CGSize(width: 842, height: 595))
        XCTAssertEqual(sizes[6], CGSize(width: 100, height: 100))
        XCTAssertEqual(sizes[7], CGSize(width: 50, height: 80))
        XCTAssertTrue(fixture.notes.isEmpty)
        XCTAssertEqual(fixture.progress.last, 1)
    }

    func testMergeRebuildsTheOutlineAndEveryInternalLinkOnTheRightPage() async throws {
        let first = try handWritten("Kılavuz.pdf", [
            Sketch(text: "A sayfa 1", links: [.dest(2)]), Sketch(text: "A sayfa 2", links: [.uri("https://example.com/a")]), Sketch(text: "A sayfa 3")
        ], outline: [("A bölüm 1", 0), ("A bölüm 2", 2)])
        let between = try save([picture(120, 80)], "Ara.png", type: .png)
        let second = try handWritten("Ek.pdf", [Sketch(text: "B sayfa 1", links: [.goTo(1)]), Sketch(text: "B sayfa 2")],
                                     outline: [("B bölüm 1", 0), ("B bölüm 2", 1)])
        let plain = try textPDF("Düz.pdf", ["Anahat yok"])
        // What PDFKit loses on its own: without the rebuild the outline is empty and both jumps land on page 1.
        let sourceA = try XCTUnwrap(PDFDocument(url: first))
        XCTAssertEqual(jumps(in: sourceA), ["p1->p3"])
        XCTAssertEqual(outline(of: sourceA), ["A bölüm 1 p1", "A bölüm 2 p3"])

        let output = try await run([first, between, second, plain], "pdf.merge")[0]
        let merged = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(merged.pageCount, 7)
        XCTAssertEqual(jumps(in: merged), ["p1->p3", "p5->p6"])
        XCTAssertEqual(outline(of: merged), ["Kılavuz p1", "  A bölüm 1 p1", "  A bölüm 2 p3", "Ek p5", "  B bölüm 1 p5", "  B bölüm 2 p6"],
                       "One entry per source that had an outline, holding its own")
        let link = try XCTUnwrap(merged.page(at: 0)?.annotations.first { $0.type == "Link" })
        XCTAssertEqual(try XCTUnwrap(link.destination ?? (link.action as? PDFActionGoTo)?.destination).point.y, 500, accuracy: 0.5,
                       "The point on the page is kept")
        let web = merged.page(at: 1)?.annotations.compactMap { $0.url ?? ($0.action as? PDFActionURL)?.url }
        XCTAssertEqual(web, [URL(string: "https://example.com/a")!], "A URL link survives as it is")
    }

    func testAMergedPhotoKeepsItsJPEGStreamAndIsTurnedByThePage() async throws {
        // Stored 300 × 200 with a red block top left; orientation 6 shows it turned a quarter clockwise.
        let photo = try save([picture(300, 200, noise: true, marker: true)], "Foto.jpg", type: .jpeg,
                             properties: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.9])
        let other = try save([picture(300, 200, noise: true)], "Foto2.jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
        let url = try await run([photo, other], "pdf.merge")[0]
        let merged = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(merged.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 200, height: 300), "Upright, so portrait")
        let (width, _, bytes) = rgba(try draw(try XCTUnwrap(merged.page(at: 0))))
        let at = (10 * width + (width - 10)) * 4
        XCTAssertGreaterThan(bytes[at], 200, "The marker is top right")
        XCTAssertLessThan(bytes[at + 1], 80)
        XCTAssertLessThan(bytes[at + 2], 80)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(occurrences(of: "/DCTDecode", in: data), 2)
        let photos = try size(photo) + size(other)
        XCTAssertLessThanOrEqual(data.count, photos + photos / 10, "Embedded, not decoded and encoded again")
    }

    func testOtherPhotosBecomeJPEGOnceWhileLosslessFormatsAndTransparencyStayLossless() async throws {
        let heic = try save([picture(200, 100, noise: true)], "Telefon.heic", type: .heic)
        let png = try save([picture(200, 100, noise: true)], "Ekran.png", type: .png)
        let clear = try save([picture(200, 100, noise: true, alpha: true)], "Saydam.heic", type: .heic)
        let data = try Data(contentsOf: try await run([heic, png, clear], "pdf.merge")[0])
        XCTAssertEqual(occurrences(of: "/DCTDecode", in: data), 1, "Only the opaque HEIC is a JPEG stream")
        XCTAssertGreaterThanOrEqual(occurrences(of: "/SMask", in: data), 1, "Transparency is kept")
    }

    func testAMergedImageTakesItsPageSizeFromItsResolution() async throws {
        let sharp = try save([picture(300, 150)], "Keskin.png", type: .png, properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let icon = try save([picture(16, 16), picture(64, 64), picture(32, 32)], "Simge.ico", type: UTType("com.microsoft.ico")!)
        let svg = try fixture.write("Çizim.svg", Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="#e33"/></svg>
            """.utf8))
        let output = try await run([sharp, icon, svg], "pdf.merge")[0]
        let merged = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(merged.pageCount, 3, "An icon gives one page: its largest picture")
        XCTAssertEqual(merged.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 150, height: 75))
        XCTAssertEqual(merged.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 64, height: 64))
        XCTAssertEqual(merged.page(at: 2)?.bounds(for: .mediaBox).size, CGSize(width: 200, height: 100))
        let (width, height, bytes) = rgba(try draw(try XCTUnwrap(merged.page(at: 2))))
        let at = (height / 2 * width + width / 2) * 4
        XCTAssertTrue(near(bytes[at..<at + 3].map(Int.init), [0xEE, 0x33, 0x33]), "The drawing is there")
    }

    func testAnAnimatedImageInAMergeGivesItsFirstFrameWithANote() async throws {
        let gif = try save([picture(40, 30), picture(40, 30, marker: true)], "Hareket.gif", type: .gif)
        let pdf = try textPDF("Kapak.pdf", ["Kapak"])
        let output = try await run([pdf, gif], "pdf.merge")[0]
        let merged = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(merged.pageCount, 2)
        XCTAssertEqual(merged.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 40, height: 30))
        XCTAssertEqual(fixture.notes, ["Yalnızca ilk kare dönüştürüldü."])
    }

    func testAnUnreadableImageFailsTheMerge() async throws {
        let pdf = try textPDF("Kapak.pdf", ["Kapak"])
        let broken = try fixture.write("Bozuk.png", Data("bu bir resim değil".utf8))
        let error = await failure([pdf, broken], "pdf.merge")
        XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Bu görüntü okunamadı."))
    }

    func testTheEngineMergesBesideTheFirstSourceUnderTheSuffix() async throws {
        let first = try textPDF("Bir.pdf", ["Bir"])
        let second = try textPDF("İki.pdf", ["İki"])
        let result = await fixture.engine([converter]).run(try fixture.job([first, second], target: "pdf.merge", suffix: "birleşik"),
                                                           moveToTrash: fixture.moveToTrash)
        XCTAssertEqual(result.converted, 2)
        XCTAssertEqual(result.outputs.map(\.lastPathComponent), ["Bir birleşik.pdf"])
        XCTAssertEqual(PDFDocument(url: try XCTUnwrap(result.outputs.first))?.pageCount, 2)
    }

    // MARK: Compress

    func testCompressShrinksAnImageHeavyPDFAndKeepsItsOutlineAndLinks() async throws {
        let heavy = try handWritten("Katalog.pdf", [
            Sketch(text: "Katalog 1", size: CGSize(width: 300, height: 225), noise: (1200, 900), links: [.dest(1)]),
            Sketch(text: "Katalog 2", size: CGSize(width: 300, height: 225), noise: (1200, 900))
        ], outline: [("Giriş", 0), ("Ürünler", 1)])
        var sizes: [CompressionLevel: Int] = [:]
        for level in CompressionLevel.allCases {
            let url = try await run([heavy], "compress", options: ConversionOptions(pdfCompression: level))[0]
            XCTAssertEqual(url.lastPathComponent, "Katalog.pdf")
            let document = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertEqual(document.pageCount, 2)
            XCTAssertEqual(outline(of: document), ["Giriş p1", "Ürünler p2"], "\(level)")
            XCTAssertEqual(jumps(in: document), ["p1->p2"], "\(level)")
            XCTAssertTrue(document.string?.contains("Katalog 2") == true, "Text stays text")
            sizes[level] = try size(url)
        }
        let original = try size(heavy)
        XCTAssertLessThan(try XCTUnwrap(sizes[.light]), original / 2)
        XCTAssertLessThan(try XCTUnwrap(sizes[.strong]), try XCTUnwrap(sizes[.balanced]))
        XCTAssertLessThan(try XCTUnwrap(sizes[.balanced]), try XCTUnwrap(sizes[.light]))
    }

    // MARK: Refusals and cancellation

    func testALockedPDFIsRefusedForEveryTargetAndAnUnreadableOneSaysSo() async throws {
        let plain = try textPDF("Açık.pdf", ["Gizli değil", "İkinci"])
        let locked = fixture.url("Kilitli.pdf")
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: plain)).write(to: locked, withOptions: [.userPasswordOption: "okur", .ownerPasswordOption: "sahip"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: locked)).isLocked, "The fixture must be locked")
        for id in ["png", "txt", "docx", "pdf.split", "compress", "ocr"] {
            let error = await failure([locked], id)
            XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Parola korumalı PDF dönüştürülemez."), id)
        }
        let error = await failure([plain, locked], "pdf.merge")
        XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Parola korumalı PDF dönüştürülemez."))

        let broken = try fixture.write("Bozuk.pdf", Data("%PDF-1.4 bu bir belge değil".utf8))
        for id in ["png", "txt", "pdf.split", "compress", "pdf.merge"] {
            let error = await failure([broken], id)
            XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Bu PDF okunamadı."), id)
        }
    }

    func testAnOwnerPasswordAloneDoesNotStopAConversion() async throws {
        let plain = try textPDF("Açık.pdf", ["Kısıtlı ama açık"])
        let restricted = fixture.url("Kısıtlı.pdf")
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: plain)).write(to: restricted, withOptions: [.ownerPasswordOption: "sahip"]))
        let text = try String(contentsOf: try await run([restricted], "txt")[0], encoding: .utf8)
        XCTAssertTrue(text.contains("Kısıtlı ama açık"))
    }

    func testWorkStopsBetweenPagesOnceCancelled() async throws {
        let pdf = try textPDF("Uzun.pdf", (1...6).map { "Sayfa \($0)" })
        for id in ["png", "pdf.split"] {
            let request = try fixture.request([pdf], target: id)
            let cancelled = ConversionFixture.Flag()
            // The flag goes up while the first page is reported: no page after it may be started.
            let context = ConversionContext(isCancelled: { cancelled.isSet }, progress: { _ in cancelled.set() })
            do {
                _ = try await converter.convert(request, context: context)
                XCTFail("\(id) ran on after the cancel")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(id): \(error)")
            }
            XCTAssertEqual(fixture.names(in: request.workFolder), ["Uzun_p1.\(request.outputFormat.id)"], id)
        }
        // Already cancelled: nothing is read, recognised or written.
        fixture.cancel.set()
        for id in ["txt", "ocr", "pdf.merge", "compress"] {
            let request = try fixture.request([pdf], target: id)
            let error = await failure(request)
            XCTAssertTrue(error is CancellationError, "\(id): \(String(describing: error))")
            XCTAssertEqual(fixture.names(in: request.workFolder), [], id)
        }
    }

    // MARK: Vision (opt-in: the first recognition of a new program name takes about half a minute)

    func testAScanWithoutATextLayerIsReadByOCRWithANote() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BSTOEQ_VISION_TESTS"] == "1")
        let scan = try scanned("Tarama.pdf", ["Merhaba Dünya"])
        XCTAssertEqual(PDFDocument(url: scan)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "", "A scan has no text layer")
        let text = try String(contentsOf: try await run([scan], "txt")[0], encoding: .utf8)
        XCTAssertTrue(text.contains("Merhaba"), text)
        XCTAssertEqual(fixture.notes, ["Metin sayfa görüntülerinden tanındı (OCR); hatalar olabilir."])
    }

    func testOCRReadsEveryPageApartByABlankLine() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BSTOEQ_VISION_TESTS"] == "1")
        let scan = try scanned("Tarama.pdf", ["Birinci Sayfa", "İkinci Sayfa"])
        let url = try await run([scan], "ocr")[0]
        XCTAssertEqual(url.lastPathComponent, "Tarama.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let first = try XCTUnwrap(text.range(of: "Birinci")), second = try XCTUnwrap(text.range(of: "kinci Sayfa", options: [], range: first.upperBound..<text.endIndex))
        XCTAssertTrue(text[first.upperBound..<second.lowerBound].contains("\n\n"), text)
        let blank = try handWritten("Boş.pdf", [Sketch()])
        let error = await failure([blank], "ocr")
        XCTAssertEqual(error as? ConversionFailure, ConversionFailure("PDF’te metin bulunamadı."))
    }

    // MARK: Helpers

    private func run(_ sources: [URL], _ target: String, options: ConversionOptions = ConversionOptions()) async throws -> [URL] {
        try await converter.convert(try fixture.request(sources, target: target, options: options), context: fixture.context())
    }

    private func failure(_ sources: [URL], _ target: String) async -> Error? {
        do { return await failure(try fixture.request(sources, target: target)) } catch { return error }
    }

    private func failure(_ request: ConversionRequest) async -> Error? {
        do { _ = try await converter.convert(request, context: fixture.context()); return nil } catch { return error }
    }

    /// Text drawn with CoreText, so the font is embedded and every Turkish letter is in the text layer.
    private func textPDF(_ name: String, _ pages: [String], size: CGSize = CGSize(width: 595, height: 842)) throws -> URL {
        let url = fixture.url(name)
        var box = CGRect(origin: .zero, size: size)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 54, y: size.height - 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Pages that hold only a picture of their text, as a scanner makes them.
    private func scanned(_ name: String, _ pages: [String]) throws -> URL {
        let url = fixture.url(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1240, height: 1754, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 1240, height: 1754))
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, 64, nil)
            bitmap.textPosition = CGPoint(x: 120, y: 1400)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), bitmap)
            pdf.beginPDFPage(nil)
            pdf.draw(try XCTUnwrap(bitmap.makeImage()), in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }

    /// A page of a PDF written out by hand: what CoreGraphics cannot be told to write (an outline whose
    /// entries point at pages, link annotations with destinations, a rotation, a crop box, raw pictures).
    private struct Sketch {
        enum Link { case dest(Int), goTo(Int), uri(String) }
        var text = ""
        var size = CGSize(width: 595, height: 842)
        var rotate = 0
        var crop: CGRect?
        var drawing = ""
        /// An uncompressed picture of noise filling the page, in pixels.
        var noise: (width: Int, height: Int)?
        var links: [Link] = []
    }

    private func handWritten(_ name: String, _ pages: [Sketch], outline: [(String, Int)] = []) throws -> URL {
        var next = 5 + outline.count
        var numbers: [(page: Int, content: Int, image: Int?, links: [Int])] = []
        for sketch in pages {
            let page = next, content = next + 1
            next += 2
            var image: Int?
            if sketch.noise != nil { image = next; next += 1 }
            let links = sketch.links.indices.map { next + $0 }
            next += links.count
            numbers.append((page, content, image, links))
        }
        func reference(_ page: Int) -> String { "\(numbers[page].page) 0 R" }
        func utf16(_ text: String) -> String { "<FEFF" + text.utf16.map { String(format: "%04X", $0) }.joined() + ">" }
        func number(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }
        var objects: [Int: Data] = [:]
        objects[1] = Data("<< /Type /Catalog /Pages 2 0 R\(outline.isEmpty ? "" : " /Outlines 4 0 R") >>".utf8)
        objects[2] = Data("<< /Type /Pages /Count \(pages.count) /Kids [\(pages.indices.map(reference).joined(separator: " "))] >>".utf8)
        objects[3] = Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8)
        if !outline.isEmpty {
            objects[4] = Data("<< /Type /Outlines /First 5 0 R /Last \(4 + outline.count) 0 R /Count \(outline.count) >>".utf8)
            for (offset, (title, page)) in outline.enumerated() {
                let links = (offset > 0 ? " /Prev \(4 + offset) 0 R" : "") + (offset < outline.count - 1 ? " /Next \(6 + offset) 0 R" : "")
                objects[5 + offset] = Data("<< /Title \(utf16(title)) /Parent 4 0 R\(links) /Dest [\(reference(page)) /XYZ 0 \(number(pages[page].size.height)) null] >>".utf8)
            }
        }
        for (index, sketch) in pages.enumerated() {
            let slot = numbers[index]
            var content = sketch.text.isEmpty ? "" : "BT /F1 24 Tf 40 \(number(sketch.size.height - 60)) Td (\(sketch.text)) Tj ET\n"
            content += sketch.drawing
            if let noise = sketch.noise {
                content += "\nq \(number(sketch.size.width)) 0 0 \(number(sketch.size.height)) 0 0 cm /Im1 Do Q"
                var state: UInt32 = 0x2545_F491
                var pixels = Data(count: noise.width * noise.height * 3)
                pixels.withUnsafeMutableBytes { raw in
                    for at in raw.indices { state = state &* 1_664_525 &+ 1_013_904_223; raw[at] = UInt8(truncatingIfNeeded: state >> 24) }
                }
                objects[slot.image!] = Data("<< /Type /XObject /Subtype /Image /Width \(noise.width) /Height \(noise.height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length \(pixels.count) >>\nstream\n".utf8)
                    + pixels + Data("\nendstream".utf8)
            }
            objects[slot.content] = Data("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream".utf8)
            for (place, link) in sketch.links.enumerated() {
                let rect = "/Rect [40 \(number(sketch.size.height - 120 - CGFloat(place) * 40)) 240 \(number(sketch.size.height - 100 - CGFloat(place) * 40))]"
                let target = switch link {
                case .dest(let page): "/Dest [\(reference(page)) /XYZ 0 500 null]"
                case .goTo(let page): "/A << /S /GoTo /D [\(reference(page)) /XYZ 0 500 null] >>"
                case .uri(let address): "/A << /S /URI /URI (\(address)) >>"
                }
                objects[slot.links[place]] = Data("<< /Type /Annot /Subtype /Link \(rect) /Border [0 0 0] \(target) >>".utf8)
            }
            var page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(number(sketch.size.width)) \(number(sketch.size.height))]"
            if let crop = sketch.crop { page += " /CropBox [\(number(crop.minX)) \(number(crop.minY)) \(number(crop.maxX)) \(number(crop.maxY))]" }
            if sketch.rotate != 0 { page += " /Rotate \(sketch.rotate)" }
            page += " /Resources << /Font << /F1 3 0 R >>\(slot.image.map { " /XObject << /Im1 \($0) 0 R >>" } ?? "") >>"
            page += " /Contents \(slot.content) 0 R"
            if !slot.links.isEmpty { page += " /Annots [\(slot.links.map { "\($0) 0 R" }.joined(separator: " "))]" }
            objects[slot.page] = Data((page + " >>").utf8)
        }
        var file = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]
        for key in objects.keys.sorted() {
            offsets[key] = file.count
            file += Data("\(key) 0 obj\n".utf8) + objects[key]! + Data("\nendobj\n".utf8)
        }
        let table = file.count
        var xref = "xref\n0 \(next)\n0000000000 65535 f \n"
        for key in 1..<next { xref += offsets[key].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 65535 f \n" }
        file += Data((xref + "trailer\n<< /Size \(next) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n").utf8)
        return try fixture.write(name, file)
    }

    /// Grey, or noise; a red block in the top-left corner as stored; half transparent with `alpha`.
    private func picture(_ width: Int, _ height: Int, noise: Bool = false, alpha: Bool = false, marker: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt32 = 0x9E37_79B9
        for y in 0..<height {
            for x in 0..<width {
                let at = (y * width + x) * 4
                let opacity: UInt8 = alpha && x < width / 2 ? 128 : 255
                if marker, x < 30, y < 30 {
                    bytes[at] = 255; bytes[at + 1] = 0; bytes[at + 2] = 0
                } else if noise {
                    for channel in 0..<3 { state = state &* 1_664_525 &+ 1_013_904_223; bytes[at + channel] = UInt8(truncatingIfNeeded: state >> 24) }
                } else {
                    bytes[at] = 128; bytes[at + 1] = 128; bytes[at + 2] = 128
                }
                // Premultiplied.
                for channel in 0..<3 { bytes[at + channel] = UInt8(Int(bytes[at + channel]) * Int(opacity) / 255) }
                bytes[at + 3] = opacity
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func save(_ images: [CGImage], _ name: String, type: UTType, properties: [CFString: Any] = [:]) throws -> URL {
        let url = fixture.url(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination), name)
        return url
    }

    private func decoded(_ url: URL) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil))
    }

    /// RGBA bytes, the first row at the top.
    private func rgba(_ image: CGImage) -> (width: Int, height: Int, bytes: [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, bytes)
    }

    /// The page at 72 dpi on white, drawn by CoreGraphics rather than by the converter under test.
    private func draw(_ page: PDFPage) throws -> CGImage {
        let cgPage = try XCTUnwrap(page.pageRef)
        let box = cgPage.getBoxRect(.mediaBox)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: box.size))
        context.concatenate(cgPage.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: box.size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(cgPage)
        return try XCTUnwrap(context.makeImage())
    }

    /// "p1->p3" for a link on page 1 that jumps to page 3.
    private func jumps(in document: PDFDocument) -> [String] {
        (0..<document.pageCount).flatMap { index in
            (document.page(at: index)?.annotations ?? []).compactMap { annotation -> String? in
                guard let page = (annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination)?.page else { return nil }
                return "p\(index + 1)->p\(document.index(for: page) + 1)"
            }
        }
    }

    /// Each entry as "label pN", children indented by two spaces.
    private func outline(of document: PDFDocument) -> [String] {
        func lines(_ item: PDFOutline, _ depth: Int) -> [String] {
            (0..<item.numberOfChildren).compactMap { item.child(at: $0) }.flatMap { child -> [String] in
                let page = (child.destination ?? (child.action as? PDFActionGoTo)?.destination)?.page.map { "p\(document.index(for: $0) + 1)" } ?? "-"
                return ["\(String(repeating: "  ", count: depth))\(child.label ?? "") \(page)"] + lines(child, depth + 1)
            }
        }
        return document.outlineRoot.map { lines($0, 0) } ?? []
    }

    /// Colour management may move a channel by a few steps.
    private func near(_ color: [Int], _ wanted: [Int]) -> Bool { zip(color, wanted).allSatisfy { abs($0 - $1) <= 12 } }

    private func occurrences(of marker: String, in data: Data) -> Int {
        var count = 0, from = data.startIndex
        while let found = data.range(of: Data(marker.utf8), in: from..<data.endIndex) { count += 1; from = found.upperBound }
        return count
    }

    private func size(_ url: URL) throws -> Int { try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) }
}
