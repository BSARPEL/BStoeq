import Foundation

/// Tables and structured data: CSV and TSV into each other, XLSX and JSON; XLSX into CSV, TSV and JSON;
/// JSON into CSV, TSV, XLSX and a property list; a property list into JSON. Foundation, plus the system's
/// zip and unzip for workbooks. Cell values travel as text, so "007" arrives as "007" on every route.
public struct DataConverter: Converter {
    public init() {}

    private static let routes: [String: Set<String>] = [
        "csv": ["tsv", "xlsx", "json"], "tsv": ["csv", "xlsx", "json"], "xlsx": ["csv", "tsv", "json"],
        "json": ["csv", "tsv", "xlsx", "plist"], "plist": ["json"]
    ]

    public func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
        guard target.kind == .convert, target.format == target.id, Self.routes[source.id]?.contains(target.id) == true else { return .unsupported }
        if source.id == "xlsx" || target.id == "xlsx", !Spreadsheet.hasZipTools { return .unsupported }
        return .available
    }

    public func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
        guard let source = request.sources.first, let format = request.formats.first,
              Self.routes[format.id]?.contains(request.outputFormat.id) == true else { throw Self.unreadable }
        try context.checkCancelled()
        let output = request.outputFormat.id
        switch (format.id, output) {
        case ("plist", "json"):
            let url = request.outputURL()
            try await ConversionWork.run { try Self.write(Self.json(Self.plistValue(try Self.read(source))), to: url) }
            return [url]
        case ("json", "plist"):
            let url = request.outputURL()
            try await ConversionWork.run {
                let value = try Self.foundationValue(try Self.parseJSON(try Self.read(source)))
                let data: Data
                do { data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) } catch {
                    throw ConversionFailure("Bu JSON plist’e dönüştürülemez.")
                }
                try data.write(to: url, options: .withoutOverwriting)
            }
            return [url]
        default:
            break
        }

        let book: Spreadsheet
        if format.id == "xlsx" {
            book = try await Spreadsheet.readWorkbook(source, workFolder: request.workFolder, context: context)
        } else {
            book = try await ConversionWork.run { try Self.table(source, format: format) }
        }
        try context.checkCancelled()
        // A workbook's empty sheets are left out; one that is empty throughout still gives its one (empty) table.
        var sheets = book.sheets.filter { !$0.rows.isEmpty }
        if sheets.isEmpty { sheets = Array(book.sheets.prefix(1)) }

        var results: [URL] = []
        if output == "xlsx" {
            let url = request.outputURL()
            try await Spreadsheet.writeWorkbook(sheets.first?.rows ?? [], sheetName: Spreadsheet.sheetName(request.baseName.precomposedStringWithCanonicalMapping),
                                                to: url, workFolder: request.workFolder, context: context)
            results = [url]
        } else {
            for (index, sheet) in sheets.enumerated() {
                let url = sheets.count == 1 ? request.outputURL()
                    : request.outputURL(Self.sheetFileName(sheet.name, index: index, base: request.baseName, extension: output))
                let isCancelled = context.isCancelled
                try await ConversionWork.run {
                    let data = output == "json" ? Data(Self.json(try Self.objects(sheet.rows, isCancelled: isCancelled)).utf8)
                        : Spreadsheet.delimitedData(sheet.rows, tab: output == "tsv")
                    try data.write(to: url, options: .withoutOverwriting)
                }
                results.append(url)
                try context.checkCancelled()
            }
        }
        if book.truncated { context.note("Yalnızca ilk 1.000.000 satır dönüştürüldü.") }
        context.progress(1)
        return results
    }

    private static let unreadable = ConversionFailure("Bu dosya okunamadı.")

    private static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw unreadable }
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }

    // MARK: Tables

    /// A CSV, TSV or JSON source as one table.
    private static func table(_ source: URL, format: FileFormat) throws -> Spreadsheet {
        let data = try read(source)
        guard format.id == "json" else {
            guard let book = Spreadsheet.delimited(data, tab: format.id == "tsv") else { throw unreadable }
            return book
        }
        let notTable = ConversionFailure("Bu JSON tablo biçiminde değil.")
        guard case .array(let items) = try parseJSON(data), !items.isEmpty else { throw notTable }
        var rows: [[String]] = []
        if items.allSatisfy({ if case .object = $0 { true } else { false } }) {
            // Columns in the order their keys are first seen, the first object's keys first.
            var columns: [String] = [], known: [String: Int] = [:]
            for case .object(let pairs) in items {
                for (key, _) in pairs where known[key] == nil { known[key] = columns.count; columns.append(key) }
            }
            rows.append(columns)
            for case .object(let pairs) in items {
                var row = Array(repeating: "", count: columns.count)
                for (key, value) in pairs { if let column = known[key] { row[column] = cell(value) } }
                rows.append(row)
            }
        } else if items.allSatisfy({ if case .array = $0 { true } else { false } }) {
            for case .array(let values) in items { rows.append(values.map(cell)) }
        } else {
            throw notTable
        }
        let truncated = rows.count > Spreadsheet.rowLimit
        return Spreadsheet(sheets: [Spreadsheet.Sheet(name: "", rows: Array(rows.prefix(Spreadsheet.rowLimit)))], truncated: truncated)
    }

    /// Text for one cell: strings as they are, numbers as written, nested values as compact JSON.
    private static func cell(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .null: ""
        case .array, .object: json(value, indent: nil)
        }
    }

    /// The rows below the header as objects keyed by it, every value a string. A blank header is
    /// `column<n>`, a repeated one gets `_2`, `_3`, so no column is lost; blank rows are left out.
    private static func objects(_ rows: [[String]], isCancelled: () -> Bool) throws -> JSONValue {
        guard let header = rows.first else { return .array([]) }
        let width = rows.map(\.count).max() ?? 0
        var keys: [String] = [], taken: Set<String> = []
        for column in 0..<width {
            let name = column < header.count && !header[column].isEmpty ? header[column] : "column\(column + 1)"
            var key = name, number = 2
            while taken.contains(key) { key = "\(name)_\(number)"; number += 1 }
            taken.insert(key); keys.append(key)
        }
        var objects: [JSONValue] = []
        for (index, row) in rows.dropFirst().enumerated() where !row.allSatisfy(\.isEmpty) {
            if index % 4096 == 0, isCancelled() { throw CancellationError() }
            objects.append(.object(keys.enumerated().map { column, key in (key, .string(column < row.count ? row[column] : "")) }))
        }
        return .array(objects)
    }

    /// A sheet's own file among several: `<base>_<sheet name>`, the name cleaned and cut so the whole stays
    /// within the engine's 240 bytes, its position when nothing usable is left of it.
    private static func sheetFileName(_ name: String, index: Int, base: String, extension ext: String) -> String {
        // One byte for "_", one for the dot and five for a number the engine may add (" 9999").
        let room = 240 - base.utf8.count - ext.utf8.count - 7
        let cleaned = OutputNaming.cleaned(name).decomposedStringWithCanonicalMapping
        let part = OutputNaming.shortened(cleaned, toBytes: max(0, min(60, room)))
        return base + "_" + (part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(index + 1) : part)
    }

    // MARK: JSON

    /// A parsed JSON value that keeps what Foundation's parser loses: the order of keys and numbers as written.
    private indirect enum JSONValue {
        case object([(String, JSONValue)])
        case array([JSONValue])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    private static func parseJSON(_ data: Data) throws -> JSONValue {
        guard let text = TextEncoding.decode(data) else { throw unreadable }
        var parser = JSONParser(bytes: Array(text.utf8))
        guard let value = parser.document() else { throw unreadable }
        return value
    }

    /// RFC 8259, strict apart from accepting control characters inside strings. Nil for anything else.
    private struct JSONParser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0
        /// Far beyond any real document, and well before the stack ends.
        static let maximumDepth = 512

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func document() -> JSONValue? {
            skipSpace()
            guard let value = value() else { return nil }
            skipSpace()
            return index == bytes.count ? value : nil
        }

        private mutating func value() -> JSONValue? {
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return nested { $0.object() }
            case UInt8(ascii: "["): return nested { $0.array() }
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        private mutating func nested(_ body: (inout JSONParser) -> JSONValue?) -> JSONValue? {
            guard depth < Self.maximumDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            return body(&self)
        }

        private mutating func object() -> JSONValue? {
            index += 1
            var pairs: [(String, JSONValue)] = []
            skipSpace()
            if take(UInt8(ascii: "}")) { return .object(pairs) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard take(UInt8(ascii: ":")) else { return nil }
                skipSpace()
                guard let value = value() else { return nil }
                pairs.append((key, value))
                skipSpace()
                if take(UInt8(ascii: ",")) { continue }
                return take(UInt8(ascii: "}")) ? .object(pairs) : nil
            }
        }

        private mutating func array() -> JSONValue? {
            index += 1
            var items: [JSONValue] = []
            skipSpace()
            if take(UInt8(ascii: "]")) { return .array(items) }
            while true {
                skipSpace()
                guard let value = value() else { return nil }
                items.append(value)
                skipSpace()
                if take(UInt8(ascii: ",")) { continue }
                return take(UInt8(ascii: "]")) ? .array(items) : nil
            }
        }

        private mutating func string() -> String? {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { return nil }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var code = hex() else { return nil }
                        // A surrogate pair is one character; half of one is replaced, not refused.
                        if (0xD800...0xDBFF).contains(code), bytes.count >= index + 6, bytes[index] == UInt8(ascii: "\\"),
                           bytes[index + 1] == UInt8(ascii: "u") {
                            let saved = index
                            index += 2
                            if let low = hex(), (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + (code - 0xD800) << 10 + (low - 0xDC00)
                            } else {
                                index = saved
                            }
                        }
                        out.append(contentsOf: String(Unicode.Scalar(code).map(Character.init) ?? "\u{FFFD}").utf8)
                    default: return nil
                    }
                default: out.append(byte)
                }
            }
            return nil
        }

        private mutating func hex() -> UInt32? {
            guard bytes.count >= index + 4, bytes[index..<index + 4].allSatisfy({ Unicode.Scalar($0).properties.isASCIIHexDigit }),
                  let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { return nil }
            index += 4
            return code
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, kept as written.
        private mutating func number() -> JSONValue? {
            let start = index
            func digits() -> Int {
                let first = index
                while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") { index += 1 }
                return index - first
            }
            _ = take(UInt8(ascii: "-"))
            let wholeStart = index
            let whole = digits()
            guard whole > 0, whole == 1 || bytes[wholeStart] != UInt8(ascii: "0") else { return nil }
            if take(UInt8(ascii: ".")), digits() == 0 { return nil }
            if take(UInt8(ascii: "e")) || take(UInt8(ascii: "E")) {
                if !take(UInt8(ascii: "+")) { _ = take(UInt8(ascii: "-")) }
                if digits() == 0 { return nil }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private mutating func literal(_ word: String, _ value: JSONValue) -> JSONValue? {
            let spelled = Array(word.utf8)
            guard bytes.count >= index + spelled.count, Array(bytes[index..<index + spelled.count]) == spelled else { return nil }
            index += spelled.count
            return value
        }

        private mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private mutating func skipSpace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
        }
    }

    /// Two-space indentation and a final line break; nil `indent` writes it compactly on one line.
    private static func json(_ value: JSONValue, indent: Int? = 0) -> String {
        var text = ""
        append(value, indent: indent, to: &text)
        return indent == nil ? text : text + "\n"
    }

    private static func append(_ value: JSONValue, indent: Int?, to text: inout String) {
        let inner = indent.map { $0 + 2 }
        let breakBefore = { (level: Int?) -> String in level.map { "\n" + String(repeating: " ", count: $0) } ?? "" }
        switch value {
        case .string(let string): text += quoted(string)
        case .number(let number): text += number
        case .bool(let flag): text += flag ? "true" : "false"
        case .null: text += "null"
        case .array(let items):
            guard !items.isEmpty else { text += "[]"; return }
            text += "["
            for (offset, item) in items.enumerated() {
                text += (offset == 0 ? "" : ",") + breakBefore(inner)
                append(item, indent: inner, to: &text)
            }
            text += breakBefore(indent) + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { text += "{}"; return }
            text += "{"
            for (offset, (key, item)) in pairs.enumerated() {
                text += (offset == 0 ? "" : ",") + breakBefore(inner) + quoted(key) + (indent == nil ? ":" : ": ")
                append(item, indent: inner, to: &text)
            }
            text += breakBefore(indent) + "}"
        }
    }

    /// Only what JSON requires is escaped; other characters, Turkish letters among them, are written as they are.
    private static func quoted(_ string: String) -> String {
        var text = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            default:
                if scalar.value < 0x20 { text += String(format: "\\u%04x", scalar.value) } else { text.unicodeScalars.append(scalar) }
            }
        }
        return text + "\""
    }

    // MARK: Property lists

    /// A property list as JSON: dates as ISO 8601 text, data as Base64, keys sorted (a property list keeps no order).
    private static func plistValue(_ data: Data) throws -> JSONValue {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { throw unreadable }
        return try jsonValue(value)
    }

    private static func jsonValue(_ value: Any) throws -> JSONValue {
        switch value {
        case let string as String: return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            guard CFNumberIsFloatType(number as CFNumber) else { return .number(number.stringValue) }
            let double = number.doubleValue
            // JSON has no infinity and no NaN; as text they survive instead of failing the file.
            return double.isFinite ? .number("\(double)") : .string("\(double)")
        case let date as Date: return .string(date.formatted(.iso8601))
        case let data as Data: return .string(data.base64EncodedString())
        case let array as [Any]: return .array(try array.map(jsonValue))
        case let dictionary as [String: Any]:
            return .object(try dictionary.sorted { $0.key < $1.key }.map { key, item in (key, try jsonValue(item)) })
        default: throw unreadable
        }
    }

    /// JSON as property list objects. A property list has no null.
    private static func foundationValue(_ value: JSONValue) throws -> Any {
        switch value {
        case .object(let pairs):
            var dictionary: [String: Any] = [:]
            for (key, item) in pairs { dictionary[key] = try foundationValue(item) }
            return dictionary
        case .array(let items): return try items.map(foundationValue)
        case .string(let text): return text
        case .number(let text):
            if let integer = Int64(text) { return NSNumber(value: integer) }
            guard let double = Double(text) else { throw unreadable }
            return NSNumber(value: double)
        case .bool(let flag): return NSNumber(value: flag)
        case .null: throw ConversionFailure("Bu JSON plist’e dönüştürülemez.")
        }
    }
}
