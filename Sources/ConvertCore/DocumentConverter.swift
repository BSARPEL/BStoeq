import AppKit
import Foundation

/// Word, OpenDocument, RTF, HTML, web archives, plain text and Markdown into PDF, DOCX, RTF, ODT, HTML and
/// plain text, with AppKit's text system alone. A document is read, laid out and written inside one
/// blocking call: AppKit text objects cannot leave it. Nothing here needs the main thread or a running
/// `NSApplication` (printing through `NSPrintOperation` would: its text view crashes off the main thread).
public struct DocumentConverter: Converter {
    public init() {}

    private static let readable: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "html", "webarchive", "txt", "md"]
    private static let writable: Set<String> = ["pdf", "docx", "rtf", "odt", "html", "txt"]
    /// AppKit's Word and OpenDocument readers drop every picture and ignore the style sheet.
    private static let simplified: Set<String> = ["doc", "docx", "odt"]
    private static let margin: CGFloat = 56

    public func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
        Self.claims(target, source) ? .available : .unsupported
    }

    public func note(for target: ConversionTarget, source: FileFormat) -> String? {
        Self.claims(target, source) && Self.simplified.contains(source.id) ? "Görseller aktarılmaz; yazı biçimleri sadeleşebilir." : nil
    }

    public func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
        guard let source = request.sources.first, let format = request.formats.first else { throw ConversionFailure("Bu belge okunamadı.") }
        let output = request.outputURL(), target = request.outputFormat.id, paper = request.options.paper.size
        try await ConversionWork.run {
            try context.checkCancelled()
            let text = try Self.read(source, format: format.id)
            try context.checkCancelled()
            let visible = text.string.unicodeScalars.contains { $0 != "\u{FFFC}" && !CharacterSet.whitespacesAndNewlines.contains($0) }
            guard visible else { throw ConversionFailure("Belge boş.") }
            Self.replacePrivateFonts(in: text)
            context.progress(0.1)
            if target == "pdf" {
                try Self.layOut(text, paper: paper, to: output, context: context)
            } else {
                try Self.write(text, as: target, to: output)
            }
        }
        return [output]
    }

    private static func claims(_ target: ConversionTarget, _ source: FileFormat) -> Bool {
        target.kind == .convert && target.format == target.id && writable.contains(target.id) && readable.contains(source.id) && target.id != source.id
    }

    // MARK: Reading

    private static func read(_ url: URL, format: String) throws -> NSMutableAttributedString {
        let unreadable = ConversionFailure("Bu belge okunamadı.")
        typealias Option = NSAttributedString.DocumentReadingOptionKey
        // Lists come with their markers in the text, the form TextKit 1 draws and every writer keeps.
        var options: [Option: Any] = [.textKit1ListMarkerFormatDocumentOption: true]
        switch format {
        case "txt", "md":
            guard let data = try? Data(contentsOf: url), let text = TextEncoding.decode(data) else { throw unreadable }
            return NSMutableAttributedString(attributedString: format == "md" ? MarkdownRenderer.render(text) : MarkdownRenderer.plainText(text))
        case "html":
            guard let data = try? Data(contentsOf: url) else { throw unreadable }
            options[.documentType] = NSAttributedString.DocumentType.html
            // Relative pictures and style sheets resolve next to the file; WebKit's importer fetches nothing remote.
            options[.baseURL] = url.deletingLastPathComponent()
            if let encoding = htmlEncoding(of: data) { options[.textEncodingName] = encoding }
            guard let text = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else { throw unreadable }
            return text
        case "webarchive": options[.documentType] = NSAttributedString.DocumentType.webArchive
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        default: options[.documentType] = NSAttributedString.DocumentType.openDocument
        }
        if let text = try? NSMutableAttributedString(url: url, options: options, documentAttributes: nil) { return text }
        // Many ".doc" files are RTF that Word saved under its own extension.
        if format == "doc" {
            options[.documentType] = NSAttributedString.DocumentType.rtf
            if let text = try? NSMutableAttributedString(url: url, options: options, documentAttributes: nil) { return text }
        }
        throw unreadable
    }

    /// The encoding for a page that does not name its own: WebKit would guess Latin-1. A byte order mark
    /// speaks for itself; a `<meta charset>` in the page still wins.
    private static func htmlEncoding(of data: Data) -> String? {
        let head = [UInt8](data.prefix(3))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return nil }
        return String(data: data, encoding: .utf8) != nil ? "utf-8" : "windows-1254"
    }

    /// A document made on a Mac can carry the system font, whose private name (".AppleSystemUIFont…") no
    /// other reader has. It becomes Helvetica Neue, or Menlo when it was the fixed-pitch one.
    private static func replacePrivateFonts(in text: NSMutableAttributedString) {
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont, font.fontName.hasPrefix(".") else { return }
            let traits = font.fontDescriptor.symbolicTraits
            guard let replacement = MarkdownRenderer.font(size: font.pointSize, bold: traits.contains(.bold), italic: traits.contains(.italic),
                                                          code: traits.contains(.monoSpace)) else { return }
            text.addAttribute(.font, value: replacement, range: range)
        }
    }

    // MARK: Writing

    private static func write(_ text: NSMutableAttributedString, as target: String, to url: URL) throws {
        // Every writer here either drops pictures or links them as "file:///name" that leads nowhere.
        removeAttachments(from: text)
        let range = NSRange(location: 0, length: text.length)
        let data: Data
        switch target {
        case "txt":
            data = Data(text.string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n").utf8)
        case "html":
            data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                                   .characterEncoding: String.Encoding.utf8.rawValue])
        case "rtf": data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case "docx": data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        default: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument])
        }
        try data.write(to: url, options: .withoutOverwriting)
    }

    private static func removeAttachments(from text: NSMutableAttributedString) {
        let string = text.string as NSString
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: .reverse) { value, range, _ in
            guard value != nil else { return }
            for location in (range.location..<NSMaxRange(range)).reversed() where string.character(at: location) == 0xFFFC {
                text.deleteCharacters(in: NSRange(location: location, length: 1))
            }
        }
    }

    // MARK: PDF

    /// TextKit 1 off screen: one text container per page, each drawn into its own page of a PDF context.
    /// It runs on any thread (also several at once), keeps tables, pictures and links, and the PDF's text
    /// stays searchable. A form feed in the text (a page break from Word) starts a new page by itself.
    private static func layOut(_ text: NSMutableAttributedString, paper: CGSize, to url: URL, context: ConversionContext) throws {
        let area = CGSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin)
        fitAttachments(in: text, to: area)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        // Background layout would schedule work on the main run loop.
        layout.backgroundLayoutEnabled = false
        storage.addLayoutManager(layout)
        var box = CGRect(origin: .zero, size: paper)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
        defer { pdf.closePDF() }
        let glyphs = layout.numberOfGlyphs
        var laidOut = 0, pages = 0
        // A line taller than a page is clipped to its page rather than holding up the rest, so every page
        // takes glyphs; the page limit only guards against a layout that would not end.
        while laidOut < glyphs, pages < 100_000 {
            try context.checkCancelled()
            let container = NSTextContainer(size: area)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0, pages > 0 { break }
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
            pdf.saveGState()
            pdf.translateBy(x: margin, y: paper.height - margin)
            pdf.scaleBy(x: 1, y: -1)
            layout.drawBackground(forGlyphRange: range, at: .zero)
            layout.drawGlyphs(forGlyphRange: range, at: .zero)
            pdf.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
            pages += 1
            laidOut = max(laidOut, NSMaxRange(range))
            context.progress(0.1 + 0.9 * Double(laidOut) / Double(max(glyphs, 1)))
        }
    }

    /// A picture larger than the text area is shown whole, scaled down to fit it.
    private static func fitAttachments(in text: NSMutableAttributedString, to area: CGSize) {
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, let cell = attachment.attachmentCell else { return }
            let size = cell.cellSize()
            guard size.width > area.width || size.height > area.height, size.width > 0, size.height > 0,
                  let image = (cell as? NSCell)?.image?.copy() as? NSImage else { return }
            let scale = min(area.width / size.width, area.height / size.height)
            image.size = NSSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        }
    }
}
