import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// PDFs to page images, text and Word, splitting, compressing and recognising text; and merging PDFs
/// and images into one PDF. PDFKit, CoreGraphics, Quartz filters and Vision; no tools.
public struct PDFConverter: Converter {
    public init() {}

    private static let pdfTargets: Set<String> = ["png", "jpg", "tiff", "txt", "docx", "rtf", "pdf.split", "pdf.merge", "compress", "ocr"]
    /// Pages beyond this are rendered smaller: a bitmap of 12,000 px a side is already half a gigabyte.
    private static let longestSide = 12_000.0
    /// What a PDF page may measure (200 inches); an image claiming 1 dpi would otherwise make a page of metres.
    private static let longestPage = 14_400.0
    /// The formats whose pixels are kept losslessly on a merged page; other images without alpha become JPEG once.
    private static let losslessImages: Set<String> = ["png", "tiff", "bmp", "gif", "ico", "psd", "svg"]
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
        if target.id == "pdf.merge" { return source.family == .pdf || source.family == .image ? .available : .unsupported }
        return source.family == .pdf && Self.pdfTargets.contains(target.id) ? .available : .unsupported
    }

    public func note(for target: ConversionTarget, source: FileFormat) -> String? {
        source.family == .pdf && (target.id == "docx" || target.id == "rtf") ? "Yalnızca metin aktarılır; düzen ve görseller korunmaz." : nil
    }

    public func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
        // PDFKit, ImageIO, AppKit text and Vision all block: one closure keeps every object on one thread.
        try await ConversionWork.run {
            if request.target.id == "pdf.merge" { return try Self.merge(request, context) }
            guard let source = request.sources.first else { throw ConversionFailure("Bu PDF okunamadı.") }
            let document = try Self.open(source)
            switch request.target.id {
            case "png", "jpg", "tiff": return try Self.pageImages(document, request, context)
            case "txt", "docx", "rtf": return [try Self.writeText(document, request, context)]
            case "pdf.split": return try Self.split(document, request, context)
            case "compress": return [try Self.compress(document, request, context)]
            case "ocr":
                let text = try Self.recognize(document, context)
                guard !text.isEmpty else { throw ConversionFailure("PDF’te metin bulunamadı.") }
                let url = request.outputURL()
                try Data((text + "\n").utf8).write(to: url)
                return [url]
            default: throw ConversionFailure("Bu dosya bu biçime dönüştürülemiyor.")
            }
        }
    }

    // MARK: Reading

    /// An owner password alone does not lock a document; a user password does, and nothing in it can be read.
    private static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionFailure("Bu PDF okunamadı.") }
        if document.isLocked { throw ConversionFailure("Parola korumalı PDF dönüştürülemez.") }
        guard document.pageCount > 0 else { throw ConversionFailure("Bu PDF okunamadı.") }
        return document
    }

    /// The page as it is shown: its crop box, turned by its rotation, on white. Returns the resolution
    /// it was drawn at, which is lower than asked for a page too large for `longestSide`.
    private static func render(_ page: PDFPage, dpi: Double) -> (image: CGImage, dpi: Double)? {
        let box = page.bounds(for: .cropBox)
        let turned = (page.rotation / 90) % 2 != 0
        let width = Double(turned ? box.height : box.width), height = Double(turned ? box.width : box.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(dpi / 72, longestSide / max(width, height))
        let pixelsWide = max(1, Int((width * scale).rounded())), pixelsHigh = max(1, Int((height * scale).rounded()))
        guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // A page is transparent where nothing is drawn; a picture of it is expected to be paper white.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(Double(pixelsWide) / width), y: CGFloat(Double(pixelsHigh) / height))
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        return (image, scale * 72)
    }

    // MARK: Page images

    private static func pageImages(_ document: PDFDocument, _ request: ConversionRequest, _ context: ConversionContext) throws -> [URL] {
        let type: UTType = switch request.outputFormat.id { case "jpg": .jpeg; case "png": .png; default: .tiff }
        let count = document.pageCount
        var urls: [URL] = []
        for index in 0..<count {
            try context.checkCancelled()
            let url = count == 1 ? request.outputURL() : request.outputURL("\(request.baseName)_p\(index + 1)")
            // One page at a time: a long document rendered at once once came to gigabytes.
            try autoreleasepool {
                guard let page = document.page(at: index), let rendered = render(page, dpi: Double(request.options.pdfDPI)),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                    throw ConversionFailure("Bu PDF okunamadı.")
                }
                var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: rendered.dpi, kCGImagePropertyDPIHeight: rendered.dpi]
                if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = request.options.imageQuality ?? 0.9 }
                // LZW: an uncompressed A4 page at 300 dpi would be 35 MB.
                if type == .tiff { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
                CGImageDestinationAddImage(destination, rendered.image, properties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw ConversionFailure("Dönüştürülemedi: %@", detail: request.outputFormat.label)
                }
            }
            urls.append(url)
            context.progress(Double(index + 1) / Double(count))
        }
        return urls
    }

    // MARK: Text

    /// The text layer, pages apart by a blank line; a scan has none, so its pages are read by Vision.
    private static func writeText(_ document: PDFDocument, _ request: ConversionRequest, _ context: ConversionContext) throws -> URL {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try context.checkCancelled()
            pages.append(document.page(at: index)?.string?.trimmingCharacters(in: .newlines) ?? "")
        }
        var text = pages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        if text.isEmpty {
            text = try recognize(document, context)
            guard !text.isEmpty else { throw ConversionFailure("PDF’te metin bulunamadı.") }
            context.note("Metin sayfa görüntülerinden tanındı (OCR); hatalar olabilir.")
        }
        let url = request.outputURL()
        switch request.outputFormat.id {
        case "txt":
            try Data((text + "\n").utf8).write(to: url)
        default:
            let font = NSFont(name: "Helvetica Neue", size: 12) ?? NSFont.systemFont(ofSize: 12)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let type: NSAttributedString.DocumentType = request.outputFormat.id == "docx" ? .officeOpenXML : .rtf
            try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type]).write(to: url)
        }
        context.progress(1)
        return url
    }

    /// Every page drawn at 200 dpi and read by Vision; pages apart by a blank line, empty pages left out.
    private static func recognize(_ document: PDFDocument, _ context: ConversionContext) throws -> String {
        var pages: [String] = []
        let count = document.pageCount
        for index in 0..<count {
            try context.checkCancelled()
            let text = try autoreleasepool { () throws -> String in
                guard let page = document.page(at: index), let rendered = render(page, dpi: 200) else { throw ConversionFailure("Bu PDF okunamadı.") }
                return try TextRecognition.text(in: rendered.image, isCancelled: context.isCancelled)
            }
            pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            context.progress(Double(index + 1) / Double(count))
        }
        return pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: Split and compress

    private static func split(_ document: PDFDocument, _ request: ConversionRequest, _ context: ConversionContext) throws -> [URL] {
        let count = document.pageCount
        guard count > 1 else { throw ConversionSkip("Tek sayfalı PDF bölünemez.") }
        var urls: [URL] = []
        for index in 0..<count {
            try context.checkCancelled()
            let url = request.outputURL("\(request.baseName)_p\(index + 1)")
            try autoreleasepool {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { throw ConversionFailure("Bu PDF okunamadı.") }
                let single = PDFDocument()
                single.documentAttributes = document.documentAttributes
                single.insert(page, at: 0)
                guard single.write(to: url) else { throw ConversionFailure("Dönüştürülemedi: %@", detail: "PDF") }
            }
            urls.append(url)
            context.progress(Double(index + 1) / Double(count))
        }
        return urls
    }

    /// The filter recompresses the pictures as the document is written; pages are not redrawn, so text,
    /// links and the outline stay as they were.
    private static func compress(_ document: PDFDocument, _ request: ConversionRequest, _ context: ConversionContext) throws -> URL {
        let (quality, resolution, largest): (Double, Int, Int) = switch request.options.pdfCompression {
        case .light: (0.85, 220, 4000)
        case .balanced: (0.7, 144, 2400)
        case .strong: (0.45, 96, 1600)
        }
        let properties: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true], "FilterType": 1, "Name": "BStoeq \(request.options.pdfCompression.rawValue)",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": quality, "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": resolution, "ImageScaleInterpolate": true, "ImageSizeMax": largest, "ImageSizeMin": 0]
            ]]]
        ]
        try context.checkCancelled()
        guard let filter = QuartzFilter(properties: properties) else { throw ConversionFailure("Dönüştürülemedi: %@", detail: "Quartz") }
        let url = request.outputURL()
        // "QuartzFilter" is the write option PDFDocument.h documents for this; it has no constant of its own.
        guard document.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
            throw ConversionFailure("Dönüştürülemedi: %@", detail: "PDF")
        }
        context.progress(1)
        return url
    }

    // MARK: Merge

    /// Where a link or an outline item pointed: a page of its own document and a point on it.
    private struct Jump {
        let page: Int
        let point: CGPoint
        let zoom: CGFloat
    }

    /// A link annotation that jumps within its document, found again on the inserted copy by place and bounds.
    private struct Link {
        let page: Int
        let annotation: Int
        let bounds: CGRect
        let isAction: Bool
        let jump: Jump
    }

    /// An outline item read out before the pages move, with its target as a page index.
    private struct Entry {
        let label: String
        let jump: Jump?
        let action: PDFAction?
        let isOpen: Bool
        let children: [Entry]
    }

    /// PDFKit keeps URL links and other annotations of inserted pages, but every jump between pages ends on
    /// page 1 and the outline is gone. So both are read before the pages are inserted and set again after.
    private static func merge(_ request: ConversionRequest, _ context: ConversionContext) throws -> [URL] {
        let merged = PDFDocument()
        let root = PDFOutline()
        // The documents the inserted pages come from stay open until the result is written.
        var opened: [PDFDocument] = []
        let quality = request.options.imageQuality ?? 0.9
        for (number, source) in request.sources.enumerated() {
            try context.checkCancelled()
            let format = number < request.formats.count ? request.formats[number] : FormatRegistry.format(of: source)
            let first = merged.pageCount
            if format?.family == .pdf {
                let document = try open(source)
                opened.append(document)
                var links: [Link] = []
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    for (place, annotation) in page.annotations.enumerated() {
                        let goTo = annotation.action as? PDFActionGoTo
                        guard let jump = jump(annotation.destination ?? goTo?.destination, in: document) else { continue }
                        links.append(Link(page: index, annotation: place, bounds: annotation.bounds,
                                          isAction: annotation.destination == nil, jump: jump))
                    }
                }
                let entries = document.outlineRoot.map { self.entries(of: $0, in: document, depth: 0) } ?? []
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index)?.copy() as? PDFPage else { throw ConversionFailure("Bu PDF okunamadı.") }
                    merged.insert(page, at: merged.pageCount)
                }
                for link in links { restore(link, in: merged, offset: first) }
                if !entries.isEmpty, let start = merged.page(at: first) {
                    let item = PDFOutline()
                    item.label = OutputNaming.baseName(of: source, format: format).precomposedStringWithCanonicalMapping
                    let box = start.bounds(for: .cropBox)
                    item.destination = PDFDestination(page: start, at: CGPoint(x: box.minX, y: box.maxY))
                    root.insertChild(item, at: root.numberOfChildren)
                    build(entries, in: merged, offset: first, under: item)
                }
            } else {
                for document in try imagePages(source, format: format, quality: quality, context) {
                    guard let page = document.page(at: 0) else { throw ConversionFailure("Bu görüntü okunamadı.") }
                    opened.append(document)
                    merged.insert(page, at: merged.pageCount)
                }
            }
            context.progress(0.9 * Double(number + 1) / Double(request.sources.count))
        }
        try context.checkCancelled()
        guard merged.pageCount > 0 else { throw ConversionFailure("Bu PDF okunamadı.") }
        if root.numberOfChildren > 0 { merged.outlineRoot = root }
        let url = request.outputURL()
        guard merged.write(to: url) else { throw ConversionFailure("Dönüştürülemedi: %@", detail: "PDF") }
        withExtendedLifetime(opened) {}
        context.progress(1)
        return [url]
    }

    private static func jump(_ destination: PDFDestination?, in document: PDFDocument) -> Jump? {
        guard let destination, let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard index >= 0, index < document.pageCount else { return nil }
        return Jump(page: index, point: destination.point, zoom: destination.zoom)
    }

    private static func destination(_ jump: Jump, in merged: PDFDocument, offset: Int) -> PDFDestination? {
        guard let page = merged.page(at: offset + jump.page) else { return nil }
        let destination = PDFDestination(page: page, at: jump.point)
        destination.zoom = jump.zoom
        return destination
    }

    private static func restore(_ link: Link, in merged: PDFDocument, offset: Int) {
        guard let page = merged.page(at: offset + link.page), let target = destination(link.jump, in: merged, offset: offset) else { return }
        let annotations = page.annotations
        let annotation = annotations.indices.contains(link.annotation) && annotations[link.annotation].bounds == link.bounds
            ? annotations[link.annotation] : annotations.first { $0.bounds == link.bounds && $0.type == "Link" }
        guard let annotation else { return }
        if link.isAction { annotation.action = PDFActionGoTo(destination: target) } else { annotation.destination = target }
    }

    /// Depth is capped: an outline is a tree only when the file says so.
    private static func entries(of item: PDFOutline, in document: PDFDocument, depth: Int) -> [Entry] {
        guard depth < 64 else { return [] }
        return (0..<item.numberOfChildren).compactMap { item.child(at: $0) }.map { child in
            let target = jump(child.destination ?? (child.action as? PDFActionGoTo)?.destination, in: document)
            return Entry(label: child.label ?? "", jump: target, action: target == nil ? child.action : nil, isOpen: child.isOpen,
                         children: entries(of: child, in: document, depth: depth + 1))
        }
    }

    private static func build(_ entries: [Entry], in merged: PDFDocument, offset: Int, under parent: PDFOutline) {
        for entry in entries {
            let item = PDFOutline()
            item.label = entry.label
            if let jump = entry.jump { item.destination = destination(jump, in: merged, offset: offset) } else { item.action = entry.action }
            parent.insertChild(item, at: parent.numberOfChildren)
            build(entry.children, in: merged, offset: offset, under: item)
            item.isOpen = entry.isOpen
        }
    }

    // MARK: Images as pages

    /// One one-page document per image (every page of a TIFF, the largest picture of an icon, else the main
    /// picture), sized by the image's resolution. A JPEG keeps its own stream, turned by the page; other
    /// photos without transparency are encoded as JPEG once; the rest is kept losslessly.
    private static func imagePages(_ url: URL, format: FileFormat?, quality: Double, _ context: ConversionContext) throws -> [PDFDocument] {
        if format?.id == "svg" { return [try vectorImagePage(url)] }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ConversionFailure("Bu görüntü okunamadı.") }
        let count = CGImageSourceGetCount(source)
        let frames: [Int]
        switch format?.id {
        case "tiff": frames = Array(0..<count)
        case "ico", "icns":
            let area = { (index: Int) -> Int in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
                return ((properties[kCGImagePropertyPixelWidth] as? Int) ?? 0) * ((properties[kCGImagePropertyPixelHeight] as? Int) ?? 0)
            }
            frames = [(0..<count).max { area($0) < area($1) } ?? 0]
        default:
            frames = [CGImageSourceGetPrimaryImageIndex(source)]
            if count > 1 { context.note("Yalnızca ilk kare dönüştürüldü.") }
        }
        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
        return try frames.map { index in
            try context.checkCancelled()
            return try autoreleasepool {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
                // The file's own stream: decoding and encoding it again would only lose quality and gain size.
                let stream = isJPEG ? CGDataProvider(url: url as CFURL).flatMap {
                    CGImage(jpegDataProviderSource: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                } : nil
                guard let decoded = stream ?? CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    throw ConversionFailure("Bu görüntü okunamadı.")
                }
                var image = decoded
                let alpha = (properties[kCGImagePropertyHasAlpha] as? Bool) == true
                    || ![.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo)
                if !isJPEG, !alpha, !losslessImages.contains(format?.id ?? "") { image = try jpegOnce(decoded, quality: quality) }
                let orientation = (properties[kCGImagePropertyOrientation] as? Int).flatMap { (1...8).contains($0) ? $0 : nil } ?? 1
                func dpi(_ key: CFString) -> Double {
                    let value = (properties[key] as? Double) ?? 0
                    return value.isFinite && value > 0 ? value : 72
                }
                let raw = CGSize(width: Double(image.width) * 72 / dpi(kCGImagePropertyDPIWidth),
                                 height: Double(image.height) * 72 / dpi(kCGImagePropertyDPIHeight))
                return try page(image, size: raw, orientation: orientation)
            }
        }
    }

    /// The photo's pixels as one JPEG stream, which the PDF then carries as it is.
    private static func jpegOnce(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionFailure("Bu görüntü okunamadı.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ConversionFailure("Bu görüntü okunamadı.")
        }
        return jpeg
    }

    /// SVG is no ImageIO type: AppKit draws it, at least 2048 px on the long side, on a page of its own size.
    private static func vectorImagePage(_ url: URL) throws -> PDFDocument {
        guard let picture = NSImage(contentsOf: url), picture.size.width > 0, picture.size.height > 0 else {
            throw ConversionFailure("Bu görüntü okunamadı.")
        }
        let size = picture.size
        let long = Double(max(size.width, size.height))
        let scale = min(longestSide, max(2048, long)) / long
        let pixelsWide = max(1, Int((Double(size.width) * scale).rounded())), pixelsHigh = max(1, Int((Double(size.height) * scale).rounded()))
        guard let bitmap = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConversionFailure("Bu görüntü okunamadı.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        picture.draw(in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.makeImage() else { throw ConversionFailure("Bu görüntü okunamadı.") }
        return try page(image, size: size, orientation: 1)
    }

    /// A one-page PDF in memory holding the image, turned upright by the page's transform. `size` is the
    /// image as stored, in points; the page has the turned size, at most `longestPage` on its long side.
    /// The document is returned because its page needs it alive until the merged file is written.
    private static func page(_ image: CGImage, size raw: CGSize, orientation: Int) throws -> PDFDocument {
        let shrink = min(1, longestPage / Double(max(raw.width, raw.height)))
        let drawn = CGSize(width: raw.width * shrink, height: raw.height * shrink)
        let quarter = orientation >= 5
        let width = quarter ? drawn.height : drawn.width, height = quarter ? drawn.width : drawn.height
        // The EXIF orientations as maps from the stored picture to the page, origin at the bottom left.
        let turn: CGAffineTransform = switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: width, ty: height)
        case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: height)
        case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: width, ty: 0)
        default: .identity
        }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ConversionFailure("Bu görüntü okunamadı.")
        }
        pdf.beginPDFPage(nil)
        pdf.concatenate(turn)
        pdf.interpolationQuality = .high
        pdf.draw(image, in: CGRect(origin: .zero, size: drawn))
        pdf.endPDFPage()
        pdf.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount == 1 else { throw ConversionFailure("Bu görüntü okunamadı.") }
        return document
    }
}
