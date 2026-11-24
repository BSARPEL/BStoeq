import XCTest
@testable import ConvertCore

/// The data converter on files made by the test, with the system's real zip and unzip. Workbooks are built
/// part by part here, so every cell kind, style and odd name is one the test chose.
final class DataConverterTests: XCTestCase {
    private var fixture: ConversionFixture!
    private let converter = DataConverter()
    private let unreadable = "Bu dosya okunamadı."
    private let notTable = "Bu JSON tablo biçiminde değil."
    private let noNull = "Bu JSON plist’e dönüştürülemez."
    private let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
    private let zip = URL(fileURLWithPath: "/usr/bin/zip")

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "data") }
    override func tearDownWithError() throws { fixture.remove() }

    // MARK: Helpers

    private func convert(_ source: URL, to target: String) async throws -> [URL] {
        try await converter.convert(try fixture.request([source], target: target), context: fixture.context())
    }

    private func convertText(_ name: String, _ text: String, to target: String) async throws -> String {
        let outputs = try await convert(try fixture.write(name, Data(text.utf8)), to: target)
        XCTAssertEqual(outputs.count, 1)
        return try read(outputs[0])
    }

    private func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    private func failure(_ source: URL, to target: String, file: StaticString = #filePath, line: UInt = #line) async -> String? {
        do {
            _ = try await convert(source, to: target)
            XCTFail("The conversion should have failed", file: file, line: line)
            return nil
        } catch let failure as ConversionFailure {
            return failure.key
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    private func sheetXML(_ rows: String, prefix: String = "") -> String {
        let p = prefix.isEmpty ? "" : prefix + ":"
        let namespace = prefix.isEmpty ? "xmlns" : "xmlns:\(prefix)"
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <\(p)worksheet \(namespace)="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><\(p)sheetData>\(rows)</\(p)sheetData></\(p)worksheet>
            """
    }

    /// One row per inner array, inline strings from column A on.
    private func inlineSheet(_ rows: [[String]]) -> String {
        sheetXML(rows.enumerated().map { index, cells in
            "<row r=\"\(index + 1)\">" + cells.map { "<c t=\"inlineStr\"><is><t>\($0)</t></is></c>" }.joined() + "</row>"
        }.joined())
    }

    /// A workbook from its parts, zipped by the system's zip. The sheets are listed in tab order; their
    /// relationship ids run the other way, so that rels order is not tab order. A target starting with "/"
    /// is a member at the package root; nil content leaves the member out.
    @discardableResult
    private func workbook(_ relative: String, sheets: [(name: String, target: String, xml: String?)], strings: String? = nil,
                          styles: String? = nil, date1904: Bool = false, extra: [String: String] = [:],
                          password: String? = nil) async throws -> URL {
        let count = sheets.count
        var parts: [String: String] = extra
        let sheetList = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(sheet.name)\" sheetId=\"\(index + 1)\" r:id=\"rId\(count - index)\"/>"
        }.joined()
        parts["xl/workbook.xml"] = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            \(date1904 ? "<workbookPr date1904=\"1\"/>" : "<workbookPr/>")<sheets>\(sheetList)</sheets></workbook>
            """
        var relations = (0..<count).reversed().map { index in
            "<Relationship Id=\"rId\(count - index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"\(sheets[index].target)\"/>"
        }
        if strings != nil {
            relations.append("<Relationship Id=\"rId90\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>")
            parts["xl/sharedStrings.xml"] = strings
        }
        if styles != nil {
            relations.append("<Relationship Id=\"rId91\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>")
            parts["xl/styles.xml"] = styles
        }
        parts["xl/_rels/workbook.xml.rels"] = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relations.joined())</Relationships>
            """
        parts["[Content_Types].xml"] = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>
            """
        for sheet in sheets {
            guard let xml = sheet.xml else { continue }
            parts[sheet.target.hasPrefix("/") ? String(sheet.target.dropFirst()) : "xl/" + sheet.target] = xml
        }
        let staging = try fixture.folder("parts-\(UUID().uuidString)")
        for (name, text) in parts { try fixture.write("\(staging.lastPathComponent)/\(name)", Data(text.utf8)) }
        let secret = password.map { ["-P", $0] } ?? []
        let output = try await ToolProcess.run(zip, arguments: ["-q", "-X", "-D", "-nw"] + secret + ["../book.zip", "--"] + parts.keys.sorted(),
                                               directory: staging)
        XCTAssertEqual(output.status, 0, output.stderrTail)
        let url = fixture.url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.url("book.zip"), to: url)
        return url
    }

    private func member(_ name: String, of archive: URL) async throws -> String {
        let output = try await ToolProcess.run(unzip, arguments: ["-p", archive.path, name], capture: .data(limit: 10_000_000))
        XCTAssertEqual(output.status, 0, output.stderrTail)
        return String(decoding: output.stdout, as: UTF8.self)
    }

    /// Three sheets with values and one without, every cell kind and the date styles worth telling apart.
    private func richWorkbook(_ relative: String) async throws -> URL {
        let strings = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">\
            <si><t>Ad</t></si>\
            <si><r><rPr><b/></rPr><t>Ay</t></r><r><t>şe</t></r></si>\
            <si><t>漢字</t><rPh sb="0" eb="2"><t>かんじ</t></rPh></si>\
            <si><t>a_x000D_b</t></si></sst>
            """
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <numFmts count="3"><numFmt numFmtId="164" formatCode="dd.mm.yyyy"/><numFmt numFmtId="165" formatCode="0.00&quot; d&quot;"/>\
            <numFmt numFmtId="166" formatCode="[Red]0.00"/></numFmts>\
            <cellStyleXfs count="1"><xf numFmtId="14"/></cellStyleXfs>\
            <cellXfs count="7"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="21"/><xf numFmtId="22"/>\
            <xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="166"/></cellXfs></styleSheet>
            """
        let data = sheetXML("""
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>Şehir</t></is></c></row>\
            <row r="2"><c r="A2" t="s"><v>1</v></c><c r="C2" t="str"><f>LOWER("TOPLAM")</f><v>toplam</v></c></row>\
            <row r="4"><c r="A4" t="b"><v>1</v></c><c r="B4" t="e"><v>#DIV/0!</v></c><c r="D4" s="0"><v>3.14</v></c></row>\
            <row r="5"><c r="A5" t="s"><v>2</v></c><c r="B5" t="s"><v>3</v></c></row>\
            <row r="9"><c r="A9" s="1"/></row>
            """)
        let dates = sheetXML("""
            <row r="1"><c r="A1" s="1"><v>45292</v></c><c r="B1" s="2"><v>0.5</v></c><c r="C1" s="3"><v>45292.75</v></c>\
            <c r="D1" s="4"><v>45000</v></c><c r="E1" s="5"><v>3.5</v></c><c r="F1" s="6"><v>2</v></c><c r="G1" s="1"><v>59</v></c>\
            <c r="H1" s="1"><v>1</v></c><c r="I1" s="1"><v>61</v></c><c r="J1"><v>45292</v></c></row>
            """)
        let summary = sheetXML("""
            <x:row r="1"><x:c r="A1" t="inlineStr"><x:is><x:t>Toplam</x:t></x:is></x:c><x:c r="B1"><x:v>12.5</x:v></x:c></x:row>
            """, prefix: "x")
        return try await workbook(relative, sheets: [("Özet", "worksheets/sheet3.xml", summary), ("Veri Ğ", "worksheets/sheet1.xml", data),
                                                     ("Boş", "worksheets/sheet2.xml", sheetXML("")), ("Tarih", "/xl/worksheets/sheet4.xml", dates)],
                                  strings: strings, styles: styles)
    }

    // MARK: Offers

    func testOnlyTheDataRoutesAreOfferedAndNeverTheSourceFormatItself() {
        let routes: Set<String> = ["csv>tsv", "csv>xlsx", "csv>json", "tsv>csv", "tsv>xlsx", "tsv>json", "xlsx>csv", "xlsx>tsv",
                                   "xlsx>json", "json>csv", "json>tsv", "json>xlsx", "json>plist", "plist>json"]
        var offered: Set<String> = []
        for format in FormatRegistry.all {
            for target in TargetCatalog.all where converter.availability(of: target, for: format, in: ConversionEnvironment()) != .unsupported {
                XCTAssertEqual(converter.availability(of: target, for: format, in: ConversionEnvironment()), .available)
                offered.insert("\(format.id)>\(target.id)")
            }
        }
        XCTAssertEqual(offered, routes, "Exactly the routes of the data family, no tools, no other family")
    }

    // MARK: CSV and TSV

    func testQuotesDelimitersAndLineBreaksInsideFieldsSurviveCSVToTSVAndBack() async throws {
        let csv = "name,note\r\n\"Ali, Veli\",\"dedi ki \"\"merhaba\"\"\"\r\n\"iki\nsatır\",son\r\n\" boşluk\",x\n"
        let tsv = try await convertText("kişiler.csv", csv, to: "tsv")
        XCTAssertEqual(tsv, "\u{FEFF}name\tnote\r\nAli, Veli\t\"dedi ki \"\"merhaba\"\"\"\r\n\"iki\nsatır\"\tson\r\n\" boşluk\"\tx\r\n")
        let back = try await convertText("geri.tsv", tsv, to: "csv")
        XCTAssertEqual(back, "\u{FEFF}name,note\r\n\"Ali, Veli\",\"dedi ki \"\"merhaba\"\"\"\r\n\"iki\nsatır\",son\r\n\" boşluk\",x\r\n",
                       "UTF-8 with a mark, CRLF, and quotes only where a field needs them")
    }

    func testSemicolonSeparatedFilesAreSplitOnSemicolons() async throws {
        let json = try await convertText("fiyat.csv", "ad;tutar\nÇay;12,50\nSimit;\"7,00\"\n", to: "json")
        XCTAssertEqual(json, """
            [
              {
                "ad": "Çay",
                "tutar": "12,50"
              },
              {
                "ad": "Simit",
                "tutar": "7,00"
              }
            ]

            """)
    }

    func testAByteOrderMarkAndWindows1254TextAreReadAsTheirCharacters() async throws {
        let marked = try await convertText("işaretli.csv", "\u{FEFF}şehir,ilçe\r\nİstanbul,Kadıköy\r\n", to: "tsv")
        XCTAssertEqual(marked, "\u{FEFF}şehir\tilçe\r\nİstanbul\tKadıköy\r\n", "The mark is not part of the first cell")
        let legacy = try XCTUnwrap("şehir;ilçe\nİzmir;Karşıyaka\nIğdır;Ağrı\n".data(using: .windowsCP1254))
        let outputs = try await convert(try fixture.write("eski.csv", legacy), to: "tsv")
        XCTAssertEqual(try read(outputs[0]), "\u{FEFF}şehir\tilçe\r\nİzmir\tKarşıyaka\r\nIğdır\tAğrı\r\n")
    }

    func testLeadingZerosAndNumberLikeTextStayTextOnEveryRoute() async throws {
        let csv = "kod,sayı,not\n007,42,1e5\n-01,-12.5,+5\n0.25,1234567890123456,-0\n"
        let source = try fixture.write("kodlar.csv", Data(csv.utf8))
        let rows = "\u{FEFF}kod,sayı,not\r\n007,42,1e5\r\n-01,-12.5,+5\r\n0.25,1234567890123456,-0\r\n"

        let book = try await convert(source, to: "xlsx")[0]
        let sheet = try await member("xl/worksheets/sheet1.xml", of: book)
        XCTAssertTrue(sheet.contains("<c r=\"A2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">007</t></is></c><c r=\"B2\"><v>42</v></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"B3\"><v>-12.5</v></c>") && sheet.contains("<c r=\"A4\"><v>0.25</v></c>"), sheet)
        for text in ["1e5", "-01", "+5", "1234567890123456", "-0"] {
            XCTAssertTrue(sheet.contains("<t xml:space=\"preserve\">\(text)</t>"), "\(text) must be written as text")
        }
        let copy = fixture.url("kopya.xlsx")
        try FileManager.default.copyItem(at: book, to: copy)
        let fromBook = try read(try await convert(copy, to: "csv")[0])
        XCTAssertEqual(fromBook, rows)

        let json = try read(try await convert(source, to: "json")[0])
        XCTAssertTrue(json.contains("\"kod\": \"007\"") && json.contains("\"sayı\": \"42\""), json)
        let fromJSON = try await convertText("geri.json", json, to: "csv")
        XCTAssertEqual(fromJSON, rows)
        let tsv = try await convertText("kodlar2.csv", csv, to: "tsv")
        XCTAssertEqual(tsv, rows.replacingOccurrences(of: ",", with: "\t"))
    }

    func testRaggedRowsKeepTheirLengthAndMissingJSONValuesAreEmpty() async throws {
        let csv = "a,b,c\n1\n1,2,3,4\n\n"
        let tsv = try await convertText("düzensiz.csv", csv, to: "tsv")
        XCTAssertEqual(tsv, "\u{FEFF}a\tb\tc\r\n1\r\n1\t2\t3\t4\r\n",
                       "No padding is invented and the blank line at the end is no row")
        let json = try await convertText("düzensiz2.csv", csv, to: "json")
        XCTAssertEqual(json, """
            [
              {
                "a": "1",
                "b": "",
                "c": "",
                "column4": ""
              },
              {
                "a": "1",
                "b": "2",
                "c": "3",
                "column4": "4"
              }
            ]

            """)
    }

    func testTheRowCapCutsATableAndSaysSo() throws {
        let book = try XCTUnwrap(Spreadsheet.delimited(Data("a\nb\nc\n".utf8), tab: false, limit: 2))
        XCTAssertEqual(book.sheets[0].rows, [["a"], ["b"]])
        XCTAssertTrue(book.truncated)
        let whole = try XCTUnwrap(Spreadsheet.delimited(Data("a\nb\n".utf8), tab: false, limit: 2))
        XCTAssertFalse(whole.truncated, "Exactly as many rows as the cap is not cut")
        XCTAssertEqual(Spreadsheet.rowLimit, 1_000_000)
    }

    // MARK: Workbooks

    func testAWorkbookGivesOneFilePerSheetInTabOrderWithEveryCellKindAndItsDates() async throws {
        let source = try await richWorkbook("tablo.xlsx")
        let outputs = try await convert(source, to: "csv")
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["tablo_Özet.csv", "tablo_Veri Ğ.csv", "tablo_Tarih.csv"],
                       "Tab order, not relationship order; the empty sheet is left out")
        XCTAssertEqual(try read(outputs[0]), "\u{FEFF}Toplam,12.5\r\n", "Prefixed elements are read like plain ones")
        XCTAssertEqual(try read(outputs[1]), "\u{FEFF}Ad,Şehir\r\nAyşe,,toplam\r\n\r\nTRUE,#DIV/0!,,3.14\r\n漢字,\"a\rb\"\r\n",
                       "Shared, rich and inline strings, formula text, a gap column and a gap row, booleans, errors, no phonetic guide")
        XCTAssertEqual(try read(outputs[2]),
                       "\u{FEFF}2024-01-01,12:00:00,2024-01-01 18:00:00,2023-03-15,3.5,2,1900-02-28,1900-01-01,1900-03-01,45292\r\n",
                       "Date, time and both from the styles; quoted and bracketed letters are no date; an unstyled number stays as written")
        XCTAssertEqual(fixture.names(in: outputs[0].deletingLastPathComponent()), outputs.map(\.lastPathComponent).sorted(),
                       "The link unzip read through is gone again")

        let json = try read(try await convert(source, to: "json")[1])
        XCTAssertTrue(json.contains("\"Ad\": \"Ayşe\"") && json.contains("\"Şehir\": \"\"") && json.contains("\"column3\": \"toplam\""), json)
    }

    func testSheetsGoThroughCSVToAWorkbookAndBackUnchanged() async throws {
        let sheets = try await convert(try await richWorkbook("tablo.xlsx"), to: "csv")
        for (index, sheet) in sheets.enumerated() {
            let original = try read(sheet)
            let copy = try fixture.write("tur/sayfa\(index).csv", Data(original.utf8))
            let book = try await convert(copy, to: "xlsx")[0]
            let check = try await ToolProcess.run(unzip, arguments: ["-t", "-q", book.path])
            XCTAssertEqual(check.status, 0, "unzip -t must pass: \(check.stderrTail)")
            let moved = fixture.url("tur/sayfa\(index).xlsx")
            try FileManager.default.moveItem(at: book, to: moved)
            let back = try read(try await convert(moved, to: "csv")[0])
            XCTAssertEqual(back, original, "Sheet \(index) came back changed")
        }
    }

    func testTurkishTextMarkupAndControlCharactersSurviveAWorkbook() async throws {
        let rows = [["şehir", "not"], ["Ağrı <&> \"İğne\"", " kenar boşluğu "], ["satır\nsonu", "zil\u{7}"], ["iki\r\nsatır", "dönüş\r"], ["_x0041_ kalır", "ğüşiöç"]]
        let csv = Spreadsheet.delimitedData(rows, tab: false)
        let book = try await convert(try fixture.write("şehirler.csv", csv), to: "xlsx")[0]
        let check = try await ToolProcess.run(unzip, arguments: ["-t", "-q", book.path])
        XCTAssertEqual(check.status, 0, check.stderrTail)
        let workbookXML = try await member("xl/workbook.xml", of: book)
        XCTAssertTrue(workbookXML.contains("<sheet name=\"şehirler\""), "The sheet is named after the file")
        let moved = fixture.url("geri.xlsx")
        try FileManager.default.moveItem(at: book, to: moved)
        let back = try await convert(moved, to: "csv")[0]
        XCTAssertEqual(Spreadsheet.delimited(try Data(contentsOf: back), tab: false)?.sheets[0].rows, rows)
    }

    func testAWrittenSheetIsNamedTheWayExcelAllows() {
        XCTAssertEqual(Spreadsheet.sheetName("'a/b:c[1]?*\\'"), "a-b-c-1----")
        XCTAssertEqual(Spreadsheet.sheetName("   "), "Sheet1")
        let long = Spreadsheet.sheetName(String(repeating: "😀", count: 20))
        XCTAssertEqual(long.utf16.count, 30, "Fifteen emoji fit in 31 UTF-16 units; half of one does not")
        XCTAssertEqual(Spreadsheet.sheetName(String(repeating: "ş", count: 40)).count, 31)
    }

    func testABracketedWorkbookNameReadsItsOwnFileAndNotItsLookalike() async throws {
        try await workbook("klasör/veri1.xlsx", sheets: [("Bir", "worksheets/sheet1.xml", inlineSheet([["yanlış"]])),
                                                         ("İki", "worksheets/sheet2.xml", inlineSheet([["yanlış 2"]]))])
        let source = try await workbook("klasör/veri[1].xlsx", sheets: [("A", "worksheets/sheet1.xml", inlineSheet([["doğru"]])),
                                                                         ("B", "worksheets/sheet2.xml", inlineSheet([["doğru", "2"]]))])
        let outputs = try await convert(source, to: "csv")
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["veri[1]_A.csv", "veri[1]_B.csv"])
        XCTAssertEqual(try outputs.map(read), ["\u{FEFF}doğru\r\n", "\u{FEFF}doğru,2\r\n"])
    }

    func testMemberNamesFromTheRelsMatchOnlyThemselvesAndStayInsideThePackage() async throws {
        let source = try await workbook("hileli.xlsx", sheets: [
            ("Köşeli", "worksheets/s[1].xml", inlineSheet([["gerçek"]])),
            ("Yıldız", "worksheets/s*.xml", inlineSheet([["yıldız"]])),
            ("Kaçak", "../../dışarı.xml", nil),
            ("Tire", "/-p.xml", inlineSheet([["tire"]])),
            ("Yok", "worksheets/yok.xml", nil)
        ], extra: ["xl/worksheets/s1.xml": inlineSheet([["sahte"]]), "xl/worksheets/s2.xml": inlineSheet([["sahte 2"]]),
                   "xl/dışarı.xml": inlineSheet([["kaçak"]])])
        let outputs = try await convert(source, to: "tsv")
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["hileli_Köşeli.tsv", "hileli_Yıldız.tsv"])
        XCTAssertEqual(try outputs.map(read), ["\u{FEFF}gerçek\r\n", "\u{FEFF}yıldız\r\n"])
    }

    func testA1904WorkbookCountsItsDatesFrom1904() async throws {
        let styles = "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/><xf numFmtId=\"22\"/></cellXfs></styleSheet>"
        let source = try await workbook("mac.xlsx", sheets: [("Sayfa", "worksheets/sheet1.xml",
                                        sheetXML("<row r=\"1\"><c r=\"A1\" s=\"1\"><v>0</v></c><c r=\"B1\" s=\"2\"><v>1.25</v></c></row>"))],
                                        styles: styles, date1904: true)
        let csv = try read(try await convert(source, to: "csv")[0])
        XCTAssertEqual(csv, "\u{FEFF}1904-01-01,1904-01-02 06:00:00\r\n")
    }

    func testAFileThatIsNoWorkbookOrNoTextCannotBeRead() async throws {
        let missing = await failure(try fixture.write("bozuk.xlsx", Data("bir zip değil".utf8)), to: "csv")
        XCTAssertEqual(missing, unreadable)
        let noWorkbook = try await workbook("boş.xlsx", sheets: [], extra: [:])
        let empty = await failure(noWorkbook, to: "json")
        XCTAssertEqual(empty, unreadable, "A workbook without one readable worksheet")
        let binary = await failure(try fixture.write("ikili.csv", Data([0x61, 0x81, 0x62, 0x0A])), to: "json")
        XCTAssertEqual(binary, unreadable)
        let plist = await failure(try fixture.write("bozuk.plist", Data("<plist><dict><key>a".utf8)), to: "json")
        XCTAssertEqual(plist, unreadable)
        // Without a password of its own unzip would ask for one on the terminal and wait.
        let locked = try await workbook("kilitli.xlsx", sheets: [("A", "worksheets/sheet1.xml", inlineSheet([["gizli"]]))], password: "parola")
        let lockedKey = await failure(locked, to: "csv")
        XCTAssertEqual(lockedKey, unreadable)
    }

    func testACancelledRequestStopsAndLeavesNothingBehind() async throws {
        let source = try await richWorkbook("iptal.xlsx")
        let request = try fixture.request([source], target: "csv")
        fixture.cancel.set()
        do {
            _ = try await converter.convert(request, context: fixture.context())
            XCTFail("A cancelled request must not convert")
        } catch is CancellationError {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.workFolder.path), [])
    }

    func testTheEnginePublishesASeveralSheetWorkbookAsOneFolderBesideIt() async throws {
        let source = try await workbook("arşiv/veri.xlsx", sheets: [("A", "worksheets/sheet1.xml", inlineSheet([["1"]])),
                                                                     ("B/C", "worksheets/sheet2.xml", inlineSheet([["2"]]))])
        let result = await fixture.engine([converter]).run(try fixture.job([source], target: "csv"), moveToTrash: fixture.moveToTrash)
        XCTAssertEqual(result.converted, 1, "\(result.outcomes)")
        let folder = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(folder.lastPathComponent, "veri")
        XCTAssertEqual(fixture.names(in: folder), ["veri_A.csv", "veri_B-C.csv"], "A slash in a sheet name cannot make a folder")
        XCTAssertEqual(fixture.names(in: source.deletingLastPathComponent()), ["veri", "veri.xlsx"])
        XCTAssertTrue(fixture.trashed.isEmpty)
    }

    func testAVeryLongSheetNameIsCutSoTheNameStaysWithinTheEngineBudget() async throws {
        let long = String(repeating: "ğ", count: 80)
        let base = String(repeating: "b", count: 200)
        let source = try await workbook("uzun.xlsx", sheets: [(long, "worksheets/sheet1.xml", inlineSheet([["1"]])),
                                                              ("İkinci", "worksheets/sheet2.xml", inlineSheet([["2"]]))])
        let request = try fixture.request([source], target: "csv", baseName: base)
        let outputs = try await converter.convert(request, context: fixture.context())
        XCTAssertEqual(outputs.count, 2)
        for output in outputs {
            XCTAssertLessThanOrEqual(output.lastPathComponent.decomposedStringWithCanonicalMapping.utf8.count, 235, output.lastPathComponent)
            XCTAssertTrue(output.lastPathComponent.hasPrefix(base + "_"))
        }
    }

    // MARK: JSON and property lists

    func testAnArrayOfObjectsKeepsFirstSeenColumnsNumbersAsWrittenAndNestedValuesAsJSON() async throws {
        let json = #"[{"b": 1, "a": {"x": [1, 2]}}, {"c": null, "a": "metin", "b": true}, {"d": 1.50, "e": "tırnak \"İ\""}]"#
        let csv = try await convertText("nesneler.json", json, to: "csv")
        XCTAssertEqual(csv, "\u{FEFF}b,a,c,d,e\r\n1,\"{\"\"x\"\":[1,2]}\",,,\r\ntrue,metin,,,\r\n,,,1.50,\"tırnak \"\"İ\"\"\"\r\n")
    }

    func testAnArrayOfArraysBecomesRowsAsTheyAre() async throws {
        let json = #"[["a", "b"], [1, "x\ty"], [], [false, null, {"k": "v"}]]"#
        let tsv = try await convertText("satırlar.json", json, to: "tsv")
        XCTAssertEqual(tsv, "\u{FEFF}a\tb\r\n1\t\"x\ty\"\r\n\r\nfalse\t\t\"{\"\"k\"\":\"\"v\"\"}\"\r\n")
    }

    func testJSONThatIsNoTableOrNoJSONAtAllFails() async throws {
        for (index, text) in [#"{"a": 1}"#, "[1, 2]", "[]", #"[{"a": 1}, [1]]"#, #""metin""#].enumerated() {
            let key = await failure(try fixture.write("tablo\(index).json", Data(text.utf8)), to: "csv")
            XCTAssertEqual(key, notTable, text)
        }
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        for (index, text) in [#"{"a":"#, "[1,]", "[01]", "[1] [2]", #"["\x"]"#, deep].enumerated() {
            let key = await failure(try fixture.write("bozuk\(index).json", Data(text.utf8)), to: "xlsx")
            XCTAssertEqual(key, unreadable, String(text.prefix(20)))
        }
    }

    func testJSONBecomesAPropertyListAndComesBack() async throws {
        let json = #"{"ad": "Ayşe", "yaş": 30, "oran": 0.25, "etkin": true, "etiketler": ["a", "b"], "iç": {"x": -1}, "emoji": "😀"}"#
        let plist = try await convert(try fixture.write("kişi.json", Data(json.utf8)), to: "plist")[0]
        let data = try Data(contentsOf: plist)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("<?xml"), "An XML property list")
        let value = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(value["ad"] as? String, "Ayşe")
        XCTAssertEqual(value["yaş"] as? Int, 30)
        XCTAssertEqual(value["oran"] as? Double, 0.25)
        XCTAssertEqual(value["etkin"] as? Bool, true)
        XCTAssertEqual(value["etiketler"] as? [String], ["a", "b"])
        XCTAssertEqual((value["iç"] as? [String: Any])?["x"] as? Int, -1)
        XCTAssertEqual(value["emoji"] as? String, "😀")

        let moved = fixture.url("kişi2.plist")
        try FileManager.default.copyItem(at: plist, to: moved)
        let back = try read(try await convert(moved, to: "json")[0])
        XCTAssertEqual(back, """
            {
              "ad": "Ayşe",
              "emoji": "😀",
              "etiketler": [
                "a",
                "b"
              ],
              "etkin": true,
              "iç": {
                "x": -1
              },
              "oran": 0.25,
              "yaş": 30
            }

            """)
    }

    func testANullCannotBecomeAPropertyList() async throws {
        let key = await failure(try fixture.write("boş.json", Data(#"{"a": [1, null]}"#.utf8)), to: "plist")
        XCTAssertEqual(key, noNull)
    }

    func testPropertyListDatesAndDataBecomeTextInJSON() async throws {
        let value: [String: Any] = ["tarih": Date(timeIntervalSince1970: 0), "veri": Data([1, 2, 3]), "liste": [1.5, 2.0, 3] as [Any]]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let json = try read(try await convert(try fixture.write("ayar.plist", data), to: "json")[0])
        XCTAssertEqual(json, """
            {
              "liste": [
                1.5,
                2.0,
                3
              ],
              "tarih": "1970-01-01T00:00:00Z",
              "veri": "AQID"
            }

            """)
    }
}
