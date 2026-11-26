import XCTest
import AppKit
import PDFKit
import ImageIO
import AVFoundation
@testable import ConvertCore

/// Defects found after release, each with the input that showed it.
final class ConvertRegressionTests: XCTestCase {
    private var fixture: ConversionFixture!
    override func setUpWithError() throws { fixture = try ConversionFixture(area: "regression") }
    override func tearDownWithError() throws { fixture.remove() }

    /// An animated GIF to PNG keeps only the first frame: the original must not go to the Trash.
    func testAPartialResultNeverTrashesTheOriginal() async throws {
        let url = fixture.url("in/hareketli.gif")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 2, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for shade in [0.2, 0.8] {
            context.setFillColor(gray: shade, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var options = ConversionOptions(); options.trashOriginals = true
        let result = await fixture.engine([ImageConverter()]).run(try fixture.job([url], target: "png", options: options), moveToTrash: fixture.moveToTrash)
        XCTAssertEqual(result.converted, 1)
        XCTAssertEqual(result.notices, ["Yalnızca ilk kare dönüştürüldü."])
        XCTAssertTrue(fixture.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// A table cell longer than a page used to be cut at the page's edge, its text lost.
    func testATableCellLongerThanAPageKeepsAllItsText() async throws {
        let words = (1...1200).map { "w\($0)" }.joined(separator: " ")
        let source = try fixture.write("in/tablo.md", Data("| A | B |\n|---|---|\n| \(words) | x |\n\nSONSATIR\n".utf8))
        let out = try await DocumentConverter().convert(try fixture.request([source], target: "pdf"), context: fixture.context())[0]
        let text = try XCTUnwrap(PDFDocument(url: out)?.string)
        for word in ["w1 ", "w600 ", "w1200", "SONSATIR"] { XCTAssertTrue(text.contains(word), word) }
    }

    /// A short table stays a table.
    func testAShortTableKeepsItsTableLayout() async throws {
        let source = try fixture.write("in/kisa.md", Data("| A | B |\n|---|---|\n| bir | iki |\n".utf8))
        let out = try await DocumentConverter().convert(try fixture.request([source], target: "rtf"), context: fixture.context())[0]
        let rtf = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(rtf.contains("\\trowd") || rtf.contains("\\itap"), "The table survives as a table")
    }

    /// A page that declares its own charset is read in it, not in the Turkish fallback.
    func testAnHTMLPageIsReadInTheCharsetItDeclares() async throws {
        let html = "<html><head><meta charset=\"windows-1251\"></head><body><p>Привет мир</p></body></html>"
        let data = try XCTUnwrap(html.data(using: .windowsCP1251))
        let source = try fixture.write("in/ru.html", data)
        let out = try await DocumentConverter().convert(try fixture.request([source], target: "txt"), context: fixture.context())[0]
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "Привет мир")
    }

    /// A stray NUL after UTF-8 text is padding, not a sign of UTF-16.
    func testUTF8WithAStrayNULIsStillUTF8() {
        XCTAssertEqual(TextEncoding.decode(Data("ad,şehir\r\nAyşe,İzmir\r\n\0\0".utf8)), "ad,şehir\r\nAyşe,İzmir\r\n")
        XCTAssertEqual(TextEncoding.decode(Data("xSatır bir\nSatır iki\n\0".utf8)), "xSatır bir\nSatır iki\n")
        // Real UTF-16 without a mark still reads as UTF-16.
        XCTAssertEqual(TextEncoding.decode(try XCTUnwrap("Merhaba dünya".data(using: .utf16LittleEndian))), "Merhaba dünya")
    }

    /// Sheet names cut to fit a long workbook name can come out the same; both sheets still arrive.
    func testSheetsWhoseCutNamesCollideAreBothKept() async throws {
        let long = String(repeating: "Yıllık rapor ", count: 16)
        let rows = [["a", "b"], ["1", "2"]]
        let workbook = fixture.url("in/\(long).xlsx")
        try FileManager.default.createDirectory(at: workbook.deletingLastPathComponent(), withIntermediateDirectories: true)
        let work = try fixture.workFolder()
        // Two sheets whose names share a long beginning.
        let sheets = [Spreadsheet.Sheet(name: "Satış Raporu Ocak", rows: rows), Spreadsheet.Sheet(name: "Satış Raporu Şubat", rows: rows)]
        try await Self.writeTwoSheets(sheets, to: workbook, work: work, fixture: fixture)
        let result = await fixture.engine([DataConverter()]).run(try fixture.job([workbook], target: "csv"))
        guard case .converted(let urls)? = result.outcomes.first, let folder = urls.first else { return XCTFail("\(result.outcomes)") }
        XCTAssertEqual(fixture.names(in: folder).count, 2)
    }

    private static func writeTwoSheets(_ sheets: [Spreadsheet.Sheet], to url: URL, work: URL, fixture: ConversionFixture) async throws {
        let parts = work.appendingPathComponent("parts", isDirectory: true)
        let fm = FileManager.default
        for path in ["_rels", "xl/_rels", "xl/worksheets"] { try fm.createDirectory(at: parts.appendingPathComponent(path), withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: parts.appendingPathComponent(path)) }
        try write("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """)
        try write("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        try write("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(sheets[0].name)" sheetId="1" r:id="rId1"/><sheet name="\(sheets[1].name)" sheetId="2" r:id="rId2"/></sheets></workbook>
        """)
        try write("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>
        """)
        for number in 1...2 {
            try write("xl/worksheets/sheet\(number).xml", """
            <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>a</t></is></c></row></sheetData></worksheet>
            """)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = parts
        zip.arguments = ["-q", "-r", "-X", work.appendingPathComponent("book.xlsx").path, "."]
        try zip.run(); zip.waitUntilExit()
        try fm.moveItem(at: work.appendingPathComponent("book.xlsx"), to: url)
    }

    /// A 24-bit surround recording used to come out of the lossless targets as 16-bit stereo.
    func testLosslessTargetsKeepBitDepthAndChannels() async throws {
        let source = fixture.url("in/kayıt.wav")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | 6
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 6,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)]
        do {
            let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for channel in 0..<6 { for frame in 0..<48_000 { buffer.floatChannelData![channel][frame] = sinf(Float(frame) * 0.05 * Float(channel + 1)) * 0.3 } }
            try file.write(from: buffer)
        }
        for target in ["aiff", "alac"] {
            let out = try await MediaConverter().convert(try fixture.request([source], target: target), context: fixture.context())[0]
            let format = try AVAudioFile(forReading: out).fileFormat
            XCTAssertEqual(format.channelCount, 6, target)
            let description = format.streamDescription.pointee
            let bits = description.mBitsPerChannel > 0 ? Int(description.mBitsPerChannel) : [1: 16, 2: 20, 3: 24, 4: 32][Int(description.mFormatFlags)] ?? 0
            XCTAssertEqual(bits, 24, target)
        }
    }
}
