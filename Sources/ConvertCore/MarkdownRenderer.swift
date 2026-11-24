import AppKit
import Foundation

/// Markdown and plain text as styled text for the document targets. `AttributedString(markdown:)` reads the
/// full syntax but keeps the structure only in presentation intents: it drops every block separator and sets
/// no fonts. This walks the parsed runs block by block and rebuilds both: one paragraph per block, a small
/// empty paragraph between top-level blocks (a blank line in plain text), lists as TextKit 1 lists with
/// their markers in the text (what RTF, ODT and HTML writers turn into real lists), tables as `NSTextTable`.
///
/// Fonts are requested by name. The system fonts would write a private name (".AppleSystemUIFont…") into
/// RTF, DOCX, ODT and HTML that no other reader has, and a PDF made with them reads back as Times.
enum MarkdownRenderer {
    static let bodySize: CGFloat = 12
    static let codeSize: CGFloat = 11
    static let headingSizes: [CGFloat] = [24, 20, 16, 14, 13, 12]

    /// Helvetica Neue, or Menlo for code, in the four styles; nil only on a Mac without them.
    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false, code: Bool = false) -> NSFont? {
        let style = bold && italic ? "BoldItalic" : bold ? "Bold" : italic ? "Italic" : nil
        let name = code ? "Menlo-\(style ?? "Regular")" : style.map { "HelveticaNeue-\($0)" } ?? "HelveticaNeue"
        return NSFont(name: name, size: size) ?? NSFont(name: "Helvetica", size: size)
    }

    /// Plain text in Helvetica Neue 12 pt, black, line endings made uniform.
    static func plainText(_ text: String) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]
        attributes[.font] = font(size: bodySize)
        return NSAttributedString(string: uniformLineEndings(text), attributes: attributes)
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: uniformLineEndings(markdown), options: options) else { return plainText(markdown) }
        let builder = Builder()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            builder.add(String(parsed[run.range].characters), style: run.inlinePresentationIntent ?? [], link: run.link,
                        block: components.first?.identity ?? -1, components: components)
        }
        return builder.finish()
    }

    private static func uniformLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Collects the inline runs of one block, then writes the block with the paragraph style its intents ask for.
    private final class Builder {
        private struct Inline { let text: String; let style: InlinePresentationIntent; let link: URL? }
        private struct Block { let identity: Int; let components: [PresentationIntent.IntentType]; var runs: [Inline] = [] }
        /// The table being written: missing cells (an empty cell has no run at all) are filled in so that the
        /// columns stay where they belong.
        private struct OpenTable { let identity: Int; let table: NSTextTable; let alignments: [NSTextAlignment]; var row = 0; var column = 0 }

        private let output = NSMutableAttributedString()
        private var block: Block?
        private var table: OpenTable?
        private var lastOuter: Int?
        private var lists: [Int: NSTextList] = [:]
        private var markedItems = Set<Int>()

        func add(_ text: String, style: InlinePresentationIntent, link: URL?, block identity: Int, components: [PresentationIntent.IntentType]) {
            if block?.identity != identity {
                flush()
                block = Block(identity: identity, components: components)
            }
            block?.runs.append(Inline(text: text, style: style, link: link))
        }

        func finish() -> NSAttributedString {
            flush()
            closeTable()
            return output
        }

        // MARK: Blocks

        private func flush() {
            guard let block else { return }
            self.block = nil
            let kinds = block.components.map(\.kind)
            let cell = kinds.first.flatMap { kind -> Int? in if case .tableCell(let column) = kind { column } else { nil } }
            if cell == nil || table?.identity != tableIdentity(block.components) { closeTable() }
            // A blank line between top-level blocks; a list, a quote or a table is one such block.
            let outer = block.components.last?.identity ?? block.identity
            if outer != lastOuter, output.length > 0 { output.append(spacer()) }
            lastOuter = outer

            if let cell { writeCell(block, column: cell); return }
            var level = 0, code = false, rule = false
            switch kinds.first {
            case .header(let depth)?: level = min(max(depth, 1), 6)
            case .codeBlock?: code = true
            case .thematicBreak?: rule = true
            default: break
            }
            let size = level > 0 ? MarkdownRenderer.headingSizes[level - 1] : code ? MarkdownRenderer.codeSize : MarkdownRenderer.bodySize
            let paragraph = NSMutableParagraphStyle()
            var marker = ""
            let listDepth = kinds.filter(isList).count
            let quoteDepth = kinds.filter { if case .blockQuote = $0 { true } else { false } }.count
            let quoteIndent = CGFloat(quoteDepth) * 18
            if listDepth > 0, let item = block.components.first(where: { if case .listItem = $0.kind { true } else { false } }) {
                let textIndent = quoteIndent + CGFloat(listDepth) * 36
                paragraph.headIndent = textIndent
                // Only the item's first paragraph carries the marker and the list; the rest are indented to its text.
                if markedItems.insert(item.identity).inserted, !code {
                    marker = "\t\(markerText(block.components, item: item.kind, depth: listDepth))\t"
                    paragraph.textLists = textLists(block.components)
                    paragraph.firstLineHeadIndent = textIndent - 36
                    paragraph.tabStops = [NSTextTab(textAlignment: .natural, location: textIndent - 25), NSTextTab(textAlignment: .natural, location: textIndent)]
                } else {
                    paragraph.firstLineHeadIndent = textIndent
                }
            } else {
                paragraph.headIndent = quoteIndent; paragraph.firstLineHeadIndent = quoteIndent
            }
            if code { paragraph.headIndent += 12; paragraph.firstLineHeadIndent += 12 }
            if level > 0 { paragraph.headerLevel = level }
            if rule { paragraph.alignment = .center }

            let color = quoteDepth > 0 || rule ? NSColor(white: 0.35, alpha: 1) : NSColor.black
            let start = output.length
            if !marker.isEmpty { output.append(styled(marker, size: size, bold: level > 0, color: color)) }
            if rule {
                output.append(styled("———", size: size, bold: false, color: color))
            } else if code {
                var text = block.runs.map(\.text).joined()
                if text.hasSuffix("\n") { text.removeLast() }
                output.append(styled(text, size: size, bold: false, code: true, color: color))
            } else {
                for run in block.runs { output.append(inline(run, size: size, bold: level > 0, color: color)) }
            }
            output.append(styled("\n", size: size, bold: level > 0, color: color))
            output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: output.length - start))
        }

        private func isList(_ kind: PresentationIntent.Kind) -> Bool {
            switch kind {
            case .orderedList, .unorderedList: true
            default: false
            }
        }

        private func markerText(_ components: [PresentationIntent.IntentType], item: PresentationIntent.Kind, depth: Int) -> String {
            let ordered = components.first(where: { isList($0.kind) }).map { if case .orderedList = $0.kind { true } else { false } } ?? false
            guard ordered else { return ["•", "◦", "▪"][(depth - 1) % 3] }
            if case .listItem(let ordinal) = item { return "\(ordinal)." }
            return "1."
        }

        /// The lists around a paragraph, outermost first, one `NSTextList` per Markdown list.
        private func textLists(_ components: [PresentationIntent.IntentType]) -> [NSTextList] {
            let enclosing = components.filter { isList($0.kind) }
            return enclosing.reversed().enumerated().map { depth, component in
                if let list = lists[component.identity] { return list }
                let ordered = if case .orderedList = component.kind { true } else { false }
                let format: NSTextList.MarkerFormat = ordered ? .decimal : [NSTextList.MarkerFormat.disc, .circle, .square][depth % 3]
                let list = NSTextList(markerFormat: format, options: 0)
                // A list that starts at "3." keeps its number in writers that number lists themselves.
                if ordered, let item = components.first(where: { if case .listItem = $0.kind { true } else { false } }),
                   case .listItem(let ordinal) = item.kind, component.identity == enclosing.first?.identity {
                    list.startingItemNumber = ordinal
                }
                lists[component.identity] = list
                return list
            }
        }

        // MARK: Tables

        private func tableIdentity(_ components: [PresentationIntent.IntentType]) -> Int? {
            components.first(where: { if case .table = $0.kind { true } else { false } })?.identity
        }

        private func writeCell(_ block: Block, column: Int) {
            guard let tableComponent = block.components.first(where: { if case .table = $0.kind { true } else { false } }),
                  case .table(let columns) = tableComponent.kind else { return }
            var row = 0
            for component in block.components {
                if case .tableRow(let index) = component.kind { row = index }
            }
            if table == nil {
                let made = NSTextTable()
                made.numberOfColumns = max(columns.count, column + 1)
                made.layoutAlgorithm = .automatic
                made.collapsesBorders = true
                made.hidesEmptyCells = false
                made.setValue(100, type: .percentageValueType, for: .width)
                let alignments = columns.map { column -> NSTextAlignment in
                    switch column.alignment {
                    case .center: .center
                    case .right: .right
                    default: .left
                    }
                }
                table = OpenTable(identity: tableComponent.identity, table: made, alignments: alignments)
            }
            guard var open = table else { return }
            // Rows and cells the parser left out because they were empty.
            while open.row < row { fill(&open, upTo: open.table.numberOfColumns); open.row += 1; open.column = 0 }
            fill(&open, upTo: column)
            let start = output.length
            for run in block.runs { output.append(inline(run, size: MarkdownRenderer.bodySize, bold: row == 0, color: .black)) }
            output.append(styled("\n", size: MarkdownRenderer.bodySize, bold: row == 0, color: .black))
            output.addAttribute(.paragraphStyle, value: cellStyle(open, row: row, column: column), range: NSRange(location: start, length: output.length - start))
            open.column = column + 1
            table = open
        }

        private func closeTable() {
            guard var open = table else { return }
            fill(&open, upTo: open.table.numberOfColumns)
            table = nil
        }

        private func fill(_ open: inout OpenTable, upTo column: Int) {
            while open.column < min(column, open.table.numberOfColumns) {
                let start = output.length
                output.append(styled("\n", size: MarkdownRenderer.bodySize, bold: false, color: .black))
                output.addAttribute(.paragraphStyle, value: cellStyle(open, row: open.row, column: open.column), range: NSRange(location: start, length: 1))
                open.column += 1
            }
        }

        private func cellStyle(_ open: OpenTable, row: Int, column: Int) -> NSParagraphStyle {
            let cell = NSTextTableBlock(table: open.table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            cell.setBorderColor(NSColor(white: 0.6, alpha: 1))
            cell.setWidth(0.5, type: .absoluteValueType, for: .border)
            cell.setWidth(4, type: .absoluteValueType, for: .padding)
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [cell]
            paragraph.alignment = column < open.alignments.count ? open.alignments[column] : .left
            return paragraph
        }

        // MARK: Runs

        private func inline(_ run: Inline, size: CGFloat, bold: Bool, color: NSColor) -> NSAttributedString {
            let code = run.style.contains(.code)
            // A hard line break stays inside its paragraph; any other line break here is a soft one.
            let text = run.style.contains(.lineBreak) ? "\u{2028}" : run.text.replacingOccurrences(of: "\n", with: " ")
            var attributes = attributes(size: code && size == MarkdownRenderer.bodySize ? MarkdownRenderer.codeSize : size,
                                        bold: bold || run.style.contains(.stronglyEmphasized), italic: run.style.contains(.emphasized),
                                        code: code, color: color)
            if run.style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Only links a reader can follow safely; the text of any other stays.
            if let link = run.link, let scheme = link.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor(srgbRed: 0.0, green: 0.33, blue: 0.8, alpha: 1)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return NSAttributedString(string: text, attributes: attributes)
        }

        private func styled(_ text: String, size: CGFloat, bold: Bool, code: Bool = false, color: NSColor) -> NSAttributedString {
            NSAttributedString(string: text, attributes: attributes(size: size, bold: bold, italic: false, code: code, color: color))
        }

        private func attributes(size: CGFloat, bold: Bool, italic: Bool, code: Bool, color: NSColor) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            attributes[.font] = MarkdownRenderer.font(size: size, bold: bold, italic: italic, code: code)
            return attributes
        }

        /// A small empty paragraph: some air in a PDF or a word processor, a blank line in plain text.
        private func spacer() -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]
            attributes[.font] = MarkdownRenderer.font(size: 6)
            return NSAttributedString(string: "\n", attributes: attributes)
        }
    }
}
