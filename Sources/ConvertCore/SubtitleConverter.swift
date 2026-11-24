import Foundation

/// SRT to WebVTT and back. The SRT reader takes files as people and old tools write them: counters
/// missing or stuck to the cue before, a full stop instead of a comma in the times, blank lines inside a
/// cue, any of the encodings `TextEncoding` knows. What both formats share is kept: the timing, the
/// lines of text and `<i> <b> <u>`. Cue settings, styles, notes, voices and colours are not.
/// Output is UTF-8 without a byte order mark; SRT with CRLF line ends, WebVTT with LF.
public struct SubtitleConverter: Converter {
    public init() {}

    private static let formats: Set<String> = ["srt", "vtt"]
    private static let keptTags: Set<String> = ["i", "b", "u"]

    /// A cue as read: its times in milliseconds and its lines as they stand in the file.
    private struct Cue { var start: Int; var end: Int; var lines: [String] }
    /// Cue text as plain characters and the tags both formats understand.
    private enum Piece { case text(String), open(String), close(String) }
    /// A cue ready to write: each line in pieces.
    private struct Timed { let start: Int; let end: Int; let lines: [[Piece]] }

    public func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
        target.kind == .convert && target.format == target.id && Self.formats.contains(target.id) && Self.formats.contains(source.id)
            && target.id != source.id ? .available : .unsupported
    }

    public func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
        guard let source = request.sources.first else { throw ConversionFailure("Bu altyazı okunamadı.") }
        let output = request.outputURL(), target = request.outputFormat.id
        try await ConversionWork.run {
            try context.checkCancelled()
            guard let data = try? Data(contentsOf: source), let text = TextEncoding.decode(data) else { throw ConversionFailure("Bu altyazı okunamadı.") }
            let cues = Self.cues(in: text)
            guard !cues.isEmpty else { throw ConversionFailure("Bu altyazı okunamadı.") }
            try context.checkCancelled()
            try Data(Self.written(cues, vtt: target == "vtt").utf8).write(to: output, options: .withoutOverwriting)
        }
        return [output]
    }

    // MARK: Reading

    private static func cues(in text: String) -> [Timed] {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The header decides, not the name: a WebVTT file saved as .srt is still read as WebVTT.
        let vtt = lines.first(where: { !isBlank($0) })?.trimmingCharacters(in: .whitespaces).hasPrefix("WEBVTT") ?? false
        let raw = vtt ? vttCues(lines) : srtCues(lines)
        let cues = raw.compactMap { cue -> Timed? in
            let cleaned = clean(cue.lines, vtt: vtt)
            return cleaned.isEmpty || cue.end <= cue.start ? nil : Timed(start: cue.start, end: cue.end, lines: cleaned)
        }
        // In time order; cues that start together keep the order of the file.
        return cues.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    /// A cue starts at every timing line and runs to the next one, so neither a missing blank line nor a
    /// blank line inside a cue loses text. The next cue's counter is what its last line then is.
    private static func srtCues(_ lines: [String]) -> [Cue] {
        var cues: [Cue] = []
        var current: Cue?
        for line in lines {
            if let timing = timing(line) {
                if var cue = current { cue.lines = withoutCounter(cue.lines); cues.append(cue) }
                current = Cue(start: timing.start, end: timing.end, lines: [])
            } else {
                current?.lines.append(line)
            }
        }
        if let current { cues.append(current) }
        return cues
    }

    private static func withoutCounter(_ lines: [String]) -> [String] {
        var lines = lines
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        // A cue whose only line is a number keeps it: then it is the text, not a counter.
        if lines.count > 1, let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty, last.allSatisfy(\.isASCII), last.allSatisfy(\.isNumber) {
            lines.removeLast()
        }
        return lines
    }

    /// WebVTT blocks are separated by blank lines; a cue is a block with a timing line (after an optional
    /// identifier), and NOTE, STYLE and REGION blocks are not cues.
    private static func vttCues(_ lines: [String]) -> [Cue] {
        var blocks: [[String]] = [[]]
        for line in lines {
            if isBlank(line) { if !(blocks.last?.isEmpty ?? true) { blocks.append([]) } } else { blocks[blocks.count - 1].append(line) }
        }
        return blocks.compactMap { block in
            guard let first = block.first?.trimmingCharacters(in: .whitespaces),
                  !["NOTE", "STYLE", "REGION"].contains(where: { first == $0 || first.hasPrefix($0 + " ") || first.hasPrefix($0 + "\t") }),
                  let index = block.firstIndex(where: { timing($0) != nil }), let timing = timing(block[index]) else { return nil }
            return Cue(start: timing.start, end: timing.end, lines: Array(block[(index + 1)...]))
        }
    }

    /// "00:01:02,345 --> 00:01:04,000" and every looser spelling: hours optional or of any length, a comma,
    /// full stop or colon before one to three fraction digits, any number of dashes in the arrow, cue
    /// settings after the end time (dropped). Milliseconds.
    private static func timing(_ line: String) -> (start: Int, end: Int)? {
        guard let arrow = line.range(of: "->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "-").union(.whitespaces))
        let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let endText = right.split(whereSeparator: \.isWhitespace).first,
              let start = milliseconds(left), let end = milliseconds(String(endText)) else { return nil }
        return (start, end)
    }

    private static func milliseconds(_ text: String) -> Int? {
        var parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        var clock = parts[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var fraction = parts.count == 2 ? parts[1] : ""
        // "00:00:01:500": the fourth field is the fraction.
        if parts.count == 1, clock.count == 4 { fraction = clock.removeLast() }
        parts = clock + [fraction]
        guard (2...3).contains(clock.count), fraction.count <= 3,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }), clock.allSatisfy({ !$0.isEmpty }) else { return nil }
        let numbers = clock.compactMap { Int($0) }
        guard numbers.count == clock.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let (hours, minutes, seconds) = numbers.count == 3 ? (numbers[0], numbers[1], numbers[2]) : (0, numbers[0], numbers[1])
        // "5" is half a second, "05" fifty milliseconds, "005" five.
        let millis = fraction.isEmpty ? 0 : (Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0)
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    // MARK: Cue text

    /// The lines with only `<i> <b> <u>` left, nested properly, entities of WebVTT decoded, ASS override
    /// blocks ("{\an8}") removed, empty lines dropped; each line as text with those tags in it.
    private static func clean(_ lines: [String], vtt: Bool) -> [[Piece]] {
        var open: [String] = []
        var result: [[Piece]] = []
        for line in lines {
            var pieces: [Piece] = []
            for piece in parse(line, vtt: vtt) {
                switch piece {
                case .text: pieces.append(piece)
                case .open(let name):
                    guard !open.contains(name) else { continue }
                    open.append(name); pieces.append(piece)
                case .close(let name):
                    // A closer without its opener is dropped; one that crosses others closes them too.
                    guard let index = open.lastIndex(of: name) else { continue }
                    for inner in open[index...].reversed() { pieces.append(.close(inner)) }
                    open.removeSubrange(index...)
                }
            }
            result.append(pieces)
        }
        if !open.isEmpty, !result.isEmpty { result[result.count - 1] += open.reversed().map { .close($0) } }
        return result.compactMap { pieces in
            let trimmed = trim(pieces)
            let visible = trimmed.contains { if case .text(let text) = $0 { !text.allSatisfy(\.isWhitespace) } else { false } }
            return visible ? trimmed : nil
        }.map(merged)
    }

    private static func parse(_ line: String, vtt: Bool) -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        var rest = Substring(line)
        while let character = rest.first {
            if character == "<", let close = rest.firstIndex(of: ">") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                let closing = inner.hasPrefix("/")
                let name = inner.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
                // "<3" or "a < b > c" is text, not a tag.
                if let first = inner.drop(while: { $0 == "/" }).first, first.isLetter || first.isNumber {
                    if keptTags.contains(name) {
                        if !text.isEmpty { pieces.append(.text(text)); text = "" }
                        pieces.append(closing ? .close(name) : .open(name))
                    }
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            }
            if character == "{", rest.dropFirst().first == "\\", let close = rest.firstIndex(of: "}") {
                rest = rest[rest.index(after: close)...]
                continue
            }
            if vtt, character == "&", let (decoded, length) = entity(rest) {
                text += decoded
                rest = rest.dropFirst(length)
                continue
            }
            text.append(character == "\t" || character == "\u{00A0}" ? " " : character)
            rest = rest.dropFirst()
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    private static func entity(_ text: Substring) -> (String, Int)? {
        guard let end = text.prefix(12).firstIndex(of: ";") else { return nil }
        let name = text[text.index(after: text.startIndex)..<end]
        let length = text.distance(from: text.startIndex, to: end) + 1
        switch name {
        case "amp": return ("&", length)
        case "lt": return ("<", length)
        case "gt": return (">", length)
        case "quot": return ("\"", length)
        case "apos": return ("'", length)
        case "nbsp": return (" ", length)
        case "lrm", "rlm": return ("", length)
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (String(Character(scalar)), length)
        }
    }

    /// Spaces at both ends of the line go, across the tags at its ends.
    private static func trim(_ pieces: [Piece]) -> [Piece] {
        var pieces = pieces
        if let index = pieces.firstIndex(where: { if case .text = $0 { true } else { false } }), case .text(let text) = pieces[index] {
            pieces[index] = .text(String(text.drop(while: \.isWhitespace)))
        }
        if let index = pieces.lastIndex(where: { if case .text = $0 { true } else { false } }), case .text(let text) = pieces[index] {
            pieces[index] = .text(String(text.reversed().drop(while: \.isWhitespace).reversed()))
        }
        return pieces
    }

    /// Runs of spaces become one.
    private static func merged(_ pieces: [Piece]) -> [Piece] {
        pieces.map { piece in
            guard case .text(let text) = piece else { return piece }
            var single = ""
            for character in text where !(character == " " && single.last == " ") { single.append(character) }
            return .text(single)
        }
    }

    // MARK: Writing

    private static func written(_ cues: [Timed], vtt: Bool) -> String {
        func line(_ pieces: [Piece]) -> String {
            pieces.map { piece in
                switch piece {
                // WebVTT reads "&" and "<" as markup, and "-->" in a cue would end it.
                case .text(let text): vtt ? text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;") : text
                case .open(let name): "<\(name)>"
                case .close(let name): "</\(name)>"
                }
            }.joined()
        }
        if vtt {
            return "WEBVTT\n\n" + cues.map { cue in
                "\(stamp(cue.start, ".")) --> \(stamp(cue.end, "."))\n" + cue.lines.map(line).joined(separator: "\n") + "\n\n"
            }.joined()
        }
        return cues.enumerated().map { index, cue in
            "\(index + 1)\r\n\(stamp(cue.start, ",")) --> \(stamp(cue.end, ","))\r\n" + cue.lines.map(line).joined(separator: "\r\n") + "\r\n\r\n"
        }.joined()
    }

    private static func stamp(_ milliseconds: Int, _ separator: String) -> String {
        func padded(_ value: Int, _ width: Int) -> String { String(repeating: "0", count: max(0, width - String(value).count)) + String(value) }
        let seconds = milliseconds / 1000
        return "\(padded(seconds / 3600, 2)):\(padded(seconds / 60 % 60, 2)):\(padded(seconds % 60, 2))\(separator)\(padded(milliseconds % 1000, 3))"
    }
}
