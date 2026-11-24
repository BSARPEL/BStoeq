import Foundation

/// Rows of text read from and written to CSV, TSV and XLSX. A value stays the text it was: nothing is
/// turned into a number on the way, so "007" is still "007" at the other end.
struct Spreadsheet: Sendable {
    struct Sheet: Equatable, Sendable {
        var name: String
        var rows: [[String]]
    }

    var sheets: [Sheet]
    /// A sheet had more than `rowLimit` rows and was cut there.
    var truncated = false

    static let rowLimit = 1_000_000
    /// Excel's last column, XFD.
    private static let columnLimit = 16_384
    /// What one workbook part may unpack to: a small file that claims gigabytes is refused, not read.
    private static let partLimit = 512 * 1024 * 1024
    private static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
    private static let zip = URL(fileURLWithPath: "/usr/bin/zip")

    /// Both are part of macOS; a system without them cannot read or write workbooks.
    static var hasZipTools: Bool {
        FileManager.default.isExecutableFile(atPath: unzip.path) && FileManager.default.isExecutableFile(atPath: zip.path)
    }

    // MARK: CSV and TSV

    /// RFC 4180 with CRLF, LF or CR line ends. The delimiter is the most frequent of comma, semicolon and tab
    /// outside quotes in the first 4096 characters (a comma on a tie); `tab` fixes it, as a TSV file does.
    /// Nil when the data is no text.
    static func delimited(_ data: Data, tab: Bool, limit: Int = rowLimit) -> Spreadsheet? {
        guard let text = TextEncoding.decode(data) else { return nil }
        let delimiter = tab ? UInt8(ascii: "\t") : detectDelimiter(text)
        let bytes = Array(text.utf8)
        let quote = UInt8(ascii: "\""), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        enum State { case fieldStart, plain, quoted, afterQuote }
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var state = State.fieldStart, truncated = false, index = 0
        func endField() { row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true) }
        func endRow() -> Bool {
            endField()
            guard rows.count < limit else { truncated = true; return false }
            rows.append(row); row = []
            return true
        }
        scan: while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch state {
            case .quoted:
                if byte == quote {
                    if index < bytes.count, bytes[index] == quote { field.append(quote); index += 1 } else { state = .afterQuote }
                } else {
                    field.append(byte)
                }
            case .fieldStart, .plain, .afterQuote:
                if byte == quote, state == .fieldStart {
                    state = .quoted
                } else if byte == delimiter {
                    endField(); state = .fieldStart
                } else if byte == cr || byte == lf {
                    if byte == cr, index < bytes.count, bytes[index] == lf { index += 1 }
                    guard endRow() else { break scan }
                    state = .fieldStart
                } else {
                    // Text after a closing quote is kept rather than refused: such files exist.
                    field.append(byte); state = .plain
                }
            }
        }
        if !truncated, state != .fieldStart || !row.isEmpty || !field.isEmpty { _ = endRow() }
        // Blank lines at the end are not rows of the table.
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        return Spreadsheet(sheets: [Sheet(name: "", rows: rows)], truncated: truncated)
    }

    /// UTF-8 with a byte order mark and CRLF, which is what spreadsheet apps read without asking. A field is
    /// quoted when it holds the delimiter, a quote or a line break, or begins or ends with a space.
    static func delimitedData(_ rows: [[String]], tab: Bool) -> Data {
        let delimiter = tab ? "\t" : ","
        let special: Set<UInt8> = [delimiter.utf8.first ?? 0, UInt8(ascii: "\""), UInt8(ascii: "\n"), UInt8(ascii: "\r")]
        var text = "\u{FEFF}"
        for row in rows {
            text += row.map { field -> String in
                // Bytes, not characters: "\r\n" is one Character and equals neither of its halves.
                let needsQuotes = field.utf8.contains(where: special.contains) || field.utf8.first == 0x20 || field.utf8.last == 0x20
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: delimiter)
            text += "\r\n"
        }
        return Data(text.utf8)
    }

    private static func detectDelimiter(_ text: String) -> UInt8 {
        var counts: [UInt8: Int] = [UInt8(ascii: ","): 0, UInt8(ascii: ";"): 0, UInt8(ascii: "\t"): 0]
        var quoted = false
        for scalar in text.unicodeScalars.prefix(4096) {
            if scalar == "\"" { quoted.toggle(); continue }
            guard !quoted, scalar.isASCII, let count = counts[UInt8(scalar.value)] else { continue }
            counts[UInt8(scalar.value)] = count + 1
        }
        let comma = UInt8(ascii: ",")
        return [UInt8(ascii: ";"), UInt8(ascii: "\t")].reduce(comma) { best, candidate in
            counts[candidate, default: 0] > counts[best, default: 0] ? candidate : best
        }
    }

    // MARK: Reading XLSX

    /// Reads every worksheet in tab order without unpacking the workbook to disk: each part comes out of
    /// `unzip -p`. unzip takes the archive's name and every member name as a wildcard pattern (a workbook
    /// named "data[1].xlsx" reads the members of "data1.xlsx"), so it is never given the user's path: it
    /// reads an own link `in.zip` in the work folder, and member names are escaped.
    static func readWorkbook(_ source: URL, workFolder: URL, context: ConversionContext) async throws -> Spreadsheet {
        let link = workFolder.appendingPathComponent("in.zip", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: source.absoluteURL.path)
        defer { unlink(link.path) }
        let unreadable = ConversionFailure("Bu dosya okunamadı.")
        func part(_ member: String) async throws -> Data? {
            try context.checkCancelled()
            let output = try await ToolProcess.run(unzip, arguments: ["-P", "", "-p", "in.zip", escaped(member)], directory: workFolder,
                                                   capture: .data(limit: partLimit))
            switch output.status {
            case 0, 1: return output.stdout   // 1: a warning about the archive, the part is complete
            case 11: return nil               // no such member
            default: throw unreadable
            }
        }

        guard let workbookData = try await part("xl/workbook.xml"), let relsData = try await part("xl/_rels/workbook.xml.rels") else { throw unreadable }
        let isCancelled = context.isCancelled
        let (workbook, rels) = try await ConversionWork.run { () throws -> (Workbook, [Relationship]) in
            guard let workbook = Workbook.parse(workbookData, isCancelled: isCancelled),
                  let rels = Relationship.parse(relsData, isCancelled: isCancelled) else {
                if isCancelled() { throw CancellationError() }
                throw unreadable
            }
            return (workbook, rels)
        }
        func member(ofType suffix: String) -> String? { rels.first { $0.type.hasSuffix(suffix) }.flatMap { resolve($0.target) } }
        let stringsData = try await part(member(ofType: "/sharedStrings") ?? "xl/sharedStrings.xml")
        let stylesData = try await part(member(ofType: "/styles") ?? "xl/styles.xml")
        let (strings, styles) = try await ConversionWork.run { () throws -> ([String], Styles) in
            var strings: [String] = []
            if let stringsData {
                guard let parsed = SharedStrings.parse(stringsData, isCancelled: isCancelled) else {
                    if isCancelled() { throw CancellationError() }
                    throw unreadable
                }
                strings = parsed
            }
            // Without readable styles a date is its serial number, which is still the cell's value.
            let styles = stylesData.flatMap { Styles.parse($0, isCancelled: isCancelled) } ?? Styles()
            return (strings, styles)
        }
        context.progress(0.1)

        var book = Spreadsheet(sheets: [])
        let worksheets = workbook.sheets.compactMap { sheet -> (name: String, member: String)? in
            guard let relation = rels.first(where: { $0.id == sheet.relation }), relation.type.hasSuffix("/worksheet"),
                  let member = resolve(relation.target) else { return nil }
            return (sheet.name, member)
        }
        for (offset, sheet) in worksheets.enumerated() {
            guard let data = try await part(sheet.member) else { continue }
            let date1904 = workbook.date1904
            let parsed = try await ConversionWork.run { () throws -> Worksheet in
                guard let parsed = Worksheet.parse(data, strings: strings, styles: styles, date1904: date1904, limit: rowLimit,
                                                   isCancelled: isCancelled) else {
                    if isCancelled() { throw CancellationError() }
                    throw unreadable
                }
                return parsed
            }
            book.sheets.append(Sheet(name: sheet.name, rows: parsed.rows))
            book.truncated = book.truncated || parsed.truncated
            context.progress(0.1 + 0.8 * Double(offset + 1) / Double(worksheets.count))
        }
        guard !book.sheets.isEmpty else { throw unreadable }
        return book
    }

    /// A target from the workbook's rels as a member name: relative to `xl/` unless it starts with a slash.
    /// Nil for anything that could leave the package or be read as an option.
    private static func resolve(_ target: String) -> String? {
        let target = target.removingPercentEncoding ?? target
        let member = target.hasPrefix("/") ? String(target.drop(while: { $0 == "/" })) : "xl/" + target
        guard !member.isEmpty, !member.hasPrefix("-"), !member.contains(".."), !member.contains("\0") else { return nil }
        return member
    }

    /// unzip's pattern characters, each behind a backslash so that the name matches only itself.
    private static func escaped(_ member: String) -> String {
        var result = ""
        for character in member {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: Writing XLSX

    /// A minimal workbook of one sheet with inline strings, packed by `/usr/bin/zip` inside the work folder.
    /// A cell is a number only when its text is a plain decimal number of at most 15 digits, so that Excel
    /// shows exactly what was written; everything else, "007" and "1e5" among it, is text.
    static func writeWorkbook(_ rows: [[String]], sheetName: String, to url: URL, workFolder: URL, context: ConversionContext) async throws {
        let staging = workFolder.appendingPathComponent(".xlsx-\(UUID().uuidString)", isDirectory: true)
        let parts = staging.appendingPathComponent("parts", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let isCancelled = context.isCancelled
        let members = try await ConversionWork.run { () throws -> [String] in
            let files = [("[Content_Types].xml", contentTypes), ("_rels/.rels", packageRels), ("xl/workbook.xml", workbook(sheetName)),
                         ("xl/_rels/workbook.xml.rels", workbookRels), ("xl/worksheets/sheet1.xml", try worksheet(rows, isCancelled: isCancelled))]
            for (name, text) in files {
                let file = parts.appendingPathComponent(name, isDirectory: false)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file, options: .withoutOverwriting)
            }
            return files.map(\.0)
        }
        try context.checkCancelled()
        // Fixed names only: the user's file name never reaches zip, which reads patterns in its arguments.
        let output = try await ToolProcess.run(zip, arguments: ["-q", "-X", "-D", "-nw", "../book.xlsx", "--"] + members, directory: parts)
        guard output.status == 0 else {
            throw ConversionFailure("Dönüştürülemedi: %@", detail: output.stderrTail.isEmpty ? "zip: \(output.status)" : output.stderrTail)
        }
        try FileManager.default.moveItem(at: staging.appendingPathComponent("book.xlsx", isDirectory: false), to: url)
    }

    /// Excel's rules for a sheet name: at most 31 UTF-16 units, none of `: \ / ? * [ ]`, no apostrophe at either end.
    static func sheetName(_ name: String) -> String {
        var cleaned = ""
        for character in name.map({ ":\\/?*[]".contains($0) ? "-" : $0 }) {
            guard cleaned.utf16.count + character.utf16.count <= 31 else { break }
            cleaned.append(character)
        }
        while cleaned.hasPrefix("'") { cleaned.removeFirst() }
        while cleaned.hasSuffix("'") { cleaned.removeLast() }
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "Sheet1" : cleaned
    }

    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        </Types>
        """
    private static let packageRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
    private static let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        </Relationships>
        """

    private static func workbook(_ sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="\(xml(sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
    }

    private static func worksheet(_ rows: [[String]], isCancelled: () -> Bool) throws -> String {
        var text = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            """
        for (index, row) in rows.enumerated() where !row.allSatisfy(\.isEmpty) {
            if index % 4096 == 0, isCancelled() { throw CancellationError() }
            text += "<row r=\"\(index + 1)\">"
            for (column, value) in row.enumerated() where !value.isEmpty && column < columnLimit {
                let reference = columnName(column) + String(index + 1)
                if isPlainNumber(value) {
                    text += "<c r=\"\(reference)\"><v>\(value)</v></c>"
                } else {
                    text += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
                }
            }
            text += "</row>"
        }
        return text + "</sheetData></worksheet>"
    }

    /// "-12.5" and "0.25" are numbers; "007", "+5", "1e5", " 5", "-0" and sixteen digits are not.
    private static func isPlainNumber(_ text: String) -> Bool {
        var digits = text.utf8[...]
        if digits.first == UInt8(ascii: "-") { digits = digits.dropFirst() }
        let parts = digits.split(separator: UInt8(ascii: "."), maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, !whole.isEmpty, parts.count == 1 || !parts[1].isEmpty,
              parts.allSatisfy({ $0.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") } }),
              whole.count == 1 || whole.first != UInt8(ascii: "0"),
              parts.reduce(0, { $0 + $1.count }) <= 15 else { return false }
        // Negative zero is not something anyone typed as a number.
        return !(text.hasPrefix("-") && digits.allSatisfy { $0 == UInt8(ascii: "0") || $0 == UInt8(ascii: ".") })
    }

    /// A, B, … Z, AA, AB: bijective base 26.
    private static func columnName(_ index: Int) -> String {
        var number = index + 1, letters: [Character] = []
        while number > 0 {
            number -= 1
            letters.append(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(number % 26))))
            number /= 26
        }
        return String(letters.reversed())
    }

    /// Escapes markup, and writes the characters XML 1.0 cannot hold as `_xHHHH_`, the way Office does;
    /// a literal `_x` that would read as such a code is protected as `_x005F_`.
    private static func xml(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            // A parser turns a carriage return into a line feed, so it travels as a code like the control characters.
            case "\t", "\n": result.unicodeScalars.append(scalar)
            case "_" where isEscapeCode(scalars, at: index): result += "_x005F_"
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF {
                    result += String(format: "_x%04X_", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// `_xHHHH_` starting at `index`.
    private static func isEscapeCode(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + 6 < scalars.count, scalars[index] == "_", scalars[index + 1] == "x", scalars[index + 6] == "_" else { return false }
        return scalars[index + 2...index + 5].allSatisfy { $0.properties.isASCIIHexDigit }
    }

    /// Reads Office's `_xHHHH_` codes back into the characters they stand for.
    private static func unescapedCodes(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView(), index = 0
        while index < scalars.count {
            if isEscapeCode(scalars, at: index), let value = UInt32(String(String.UnicodeScalarView(scalars[index + 2...index + 5])), radix: 16),
               let scalar = Unicode.Scalar(value) {
                result.append(scalar); index += 7
            } else {
                result.append(scalars[index]); index += 1
            }
        }
        return String(result)
    }

    // MARK: Workbook parts

    /// Element and attribute names without their namespace prefix: some writers prefix everything (`x:row`).
    private final class Events: NSObject, XMLParserDelegate {
        var start: (String, [String: String]) -> Void = { _, _ in }
        var end: (String) -> Void = { _ in }
        var text: (String) -> Void = { _ in }
        private let isCancelled: () -> Bool
        private var count = 0

        init(isCancelled: @escaping () -> Bool) { self.isCancelled = isCancelled }

        /// False when the part is no XML, or the work was cancelled.
        func run(_ data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            return parser.parse() && !isCancelled()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            count += 1
            if count % 4096 == 0, isCancelled() { parser.abortParsing(); return }
            if attributes.keys.contains(where: { $0.contains(":") }) {
                var plain: [String: String] = [:]
                for (key, value) in attributes { plain[Events.local(key)] = value }
                start(Events.local(elementName), plain)
            } else {
                start(Events.local(elementName), attributes)
            }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            end(Events.local(elementName))
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text(String(decoding: CDATABlock, as: UTF8.self)) }
        /// Stops at the first error instead of reporting more of a broken part.
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { parser.abortParsing() }

        static func local(_ name: String) -> String {
            guard let colon = name.lastIndex(of: ":") else { return name }
            return String(name[name.index(after: colon)...])
        }
    }

    private struct Relationship {
        var id: String, type: String, target: String
        static func parse(_ data: Data, isCancelled: @escaping () -> Bool) -> [Relationship]? {
            var found: [Relationship] = []
            let events = Events(isCancelled: isCancelled)
            events.start = { name, attributes in
                guard name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
                found.append(Relationship(id: id, type: attributes["Type"] ?? "", target: target))
            }
            return events.run(data) ? found : nil
        }
    }

    /// The sheets in tab order, which is not the order of their relationships.
    private struct Workbook {
        var sheets: [(name: String, relation: String)] = []
        var date1904 = false
        static func parse(_ data: Data, isCancelled: @escaping () -> Bool) -> Workbook? {
            var workbook = Workbook()
            let events = Events(isCancelled: isCancelled)
            events.start = { name, attributes in
                switch name {
                case "sheet":
                    // The relationship is `r:id`; without its prefix it is plain `id`, unlike `sheetId`.
                    if let relation = attributes["id"] { workbook.sheets.append((attributes["name"] ?? "", relation)) }
                case "workbookPr":
                    workbook.date1904 = ["1", "true"].contains(attributes["date1904"]?.lowercased() ?? "")
                default: break
                }
            }
            return events.run(data) ? workbook : nil
        }
    }

    /// One string per `si`: its own `t`, or the `t` of its runs; phonetic guides (`rPh`) are left out.
    private enum SharedStrings {
        static func parse(_ data: Data, isCancelled: @escaping () -> Bool) -> [String]? {
            var strings: [String] = [], path: [String] = [], current = "", inItem = false
            let events = Events(isCancelled: isCancelled)
            events.start = { name, _ in
                path.append(name)
                if name == "si" { inItem = true; current = "" }
            }
            events.text = { text in
                guard inItem, path.last == "t", path.dropLast().last == "si" || (path.dropLast().last == "r" && path.dropLast(2).last == "si") else { return }
                current += text
            }
            events.end = { name in
                if name == "si" { strings.append(unescapedCodes(current)); inItem = false }
                path.removeLast()
            }
            return events.run(data) ? strings : nil
        }
    }

    /// Which cell styles show a date or a time: `cellXfs` points each style at a number format.
    private struct Styles: Sendable {
        enum Kind: Sendable { case date, time, dateTime }
        var formats: [Int] = []
        var codes: [Int: String] = [:]

        func kind(ofStyle index: Int) -> Kind? {
            guard formats.indices.contains(index) else { return nil }
            let format = formats[index]
            if let code = codes[format] { return Styles.kind(ofCode: code) }
            switch format {
            case 14...17: return .date
            case 18...21, 45...47: return .time
            case 22: return .dateTime
            default: return nil
            }
        }

        /// A custom code shows a date or time when it has d, m, y, h or s outside quotes, brackets (colours,
        /// locales, elapsed hours) and escaped characters. An m beside h or s is minutes.
        static func kind(ofCode code: String) -> Kind? {
            var date = false, month = false, time = false, quoted = false, bracketed = false, skipNext = false
            for character in code.lowercased() {
                if skipNext { skipNext = false; continue }
                if quoted { if character == "\"" { quoted = false }; continue }
                if bracketed { if character == "]" { bracketed = false }; continue }
                switch character {
                case "\"": quoted = true
                case "[": bracketed = true
                case "\\", "_", "*": skipNext = true
                case "d", "y": date = true
                case "m": month = true
                case "h", "s": time = true
                default: break
                }
            }
            date = date || (month && !time)
            switch (date, time) {
            case (true, true): return .dateTime
            case (true, false): return .date
            case (false, true): return .time
            default: return nil
            }
        }

        static func parse(_ data: Data, isCancelled: @escaping () -> Bool) -> Styles? {
            var styles = Styles(), inCellFormats = false
            let events = Events(isCancelled: isCancelled)
            events.start = { name, attributes in
                switch name {
                case "numFmt":
                    if let id = attributes["numFmtId"].flatMap({ Int($0) }), let code = attributes["formatCode"] { styles.codes[id] = code }
                case "cellXfs": inCellFormats = true
                case "xf" where inCellFormats: styles.formats.append(attributes["numFmtId"].flatMap { Int($0) } ?? 0)
                default: break
                }
            }
            events.end = { name in if name == "cellXfs" { inCellFormats = false } }
            return events.run(data) ? styles : nil
        }
    }

    /// The rows of one worksheet. Columns come from the cell references, so a gap stays a gap; rows from
    /// the row numbers, so blank rows between values stay too.
    private struct Worksheet: Sendable {
        var rows: [[String]] = []
        var truncated = false

        static func parse(_ data: Data, strings: [String], styles: Styles, date1904: Bool, limit: Int,
                          isCancelled: @escaping () -> Bool) -> Worksheet? {
            var sheet = Worksheet(), path: [String] = []
            var rowIndex = -1, cells: [String] = [], column = -1
            var kind = "", style: Int?, value = "", inline = ""
            var kinds: [Int: Styles.Kind?] = [:]
            let events = Events(isCancelled: isCancelled)
            events.start = { name, attributes in
                path.append(name)
                switch name {
                case "row":
                    rowIndex = attributes["r"].flatMap { Int($0) }.map { $0 - 1 } ?? rowIndex + 1
                    cells = []; column = -1
                case "c":
                    column = attributes["r"].flatMap(Worksheet.column(of:)) ?? column + 1
                    kind = attributes["t"] ?? "n"; style = attributes["s"].flatMap { Int($0) }; value = ""; inline = ""
                default: break
                }
            }
            events.text = { text in
                guard let last = path.last else { return }
                let parent = path.dropLast().last
                if last == "v", parent == "c" { value += text }
                if last == "t", parent == "is" || (parent == "r" && path.dropLast(2).last == "is") { inline += text }
            }
            events.end = { name in
                path.removeLast()
                switch name {
                case "c":
                    guard column >= 0, column < columnLimit else { return }
                    let text: String
                    switch kind {
                    case "s": text = Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? value
                    case "inlineStr": text = unescapedCodes(inline)
                    case "b": text = value == "1" ? "TRUE" : value == "0" ? "FALSE" : value
                    case "n":
                        let styleKind = style.flatMap { index in
                            if let known = kinds[index] { return known }
                            let found = styles.kind(ofStyle: index)
                            kinds[index] = found
                            return found
                        }
                        text = styleKind.flatMap { Worksheet.date(value, kind: $0, date1904: date1904) } ?? value
                    default: text = value   // str (a formula's text), e (an error such as #DIV/0!), d (ISO text)
                    }
                    guard !text.isEmpty else { return }
                    if cells.count <= column { cells += Array(repeating: "", count: column - cells.count + 1) }
                    cells[column] = text
                case "row":
                    guard !cells.isEmpty, rowIndex >= 0 else { return }
                    guard rowIndex < limit else { sheet.truncated = true; return }
                    // Rows arrive in order; one that does not is added at the end rather than lost.
                    if rowIndex > sheet.rows.count { sheet.rows += Array(repeating: [], count: rowIndex - sheet.rows.count) }
                    sheet.rows.append(cells)
                default: break
                }
            }
            return events.run(data) ? sheet : nil
        }

        /// "C7" gives 2. Nil without letters.
        static func column(of reference: String) -> Int? {
            var number = 0, letters = 0
            for scalar in reference.uppercased().unicodeScalars {
                guard scalar.value >= 65, scalar.value <= 90 else { break }
                number = number * 26 + Int(scalar.value - 64)
                letters += 1
                if letters > 3 { return nil }
            }
            return letters == 0 ? nil : number - 1
        }

        /// A serial day number as `yyyy-MM-dd`, `HH:mm:ss` or both, computed without time zones: the cell
        /// shows wall-clock time. The 1900 system counts a 29 February 1900 that never was, so serials below
        /// 60 are a day later than the arithmetic says.
        static func date(_ value: String, kind: Styles.Kind, date1904: Bool) -> String? {
            guard let serial = Double(value), serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
            let seconds = Int((serial * 86_400).rounded())
            var days = seconds / 86_400
            let time = seconds % 86_400
            days += date1904 ? -24_107 : serial < 60 ? -25_568 : -25_569   // to days since 1970-01-01
            let (year, month, day) = civil(days)
            let datePart = String(format: "%04d-%02d-%02d", year, month, day)
            let timePart = String(format: "%02d:%02d:%02d", time / 3600, time % 3600 / 60, time % 60)
            switch kind {
            case .date: return datePart
            case .time: return timePart
            case .dateTime: return "\(datePart) \(timePart)"
            }
        }

        /// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
        private static func civil(_ days: Int) -> (Int, Int, Int) {
            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let dayOfEra = z - era * 146_097
            let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            let shifted = (5 * dayOfYear + 2) / 153
            let day = dayOfYear - (153 * shifted + 2) / 5 + 1
            let month = shifted < 10 ? shifted + 3 : shifted - 9
            return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
        }
    }
}
