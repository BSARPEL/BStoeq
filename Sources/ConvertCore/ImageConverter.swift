import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Pictures through ImageIO (SVG through AppKit, WebP through cwebp or ffmpeg): the raster formats,
/// one PDF page per picture (every page of a TIFF), half size, compress, background removal and OCR.
/// Every result is made from upright pixels, so no orientation tag is ever written.
public struct ImageConverter: Converter {
    public init() {}

    private static let unreadable = ConversionFailure("Bu görüntü okunamadı.")

    /// What ImageIO writes for each format target. HEIF files are read but written as HEIC: `public.heif`
    /// is no destination type.
    private static let writers: [String: String] = [
        "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "avif": "public.avif", "tiff": "public.tiff",
        "gif": "com.compuserve.gif", "bmp": "com.microsoft.bmp", "jp2": "public.jpeg-2000", "ico": "com.microsoft.ico",
        "icns": "com.apple.icns"
    ]
    /// The writers this system really has.
    private static let writable: Set<String> = {
        let types = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return Set(writers.filter { types.contains($0.value) }.keys)
    }()
    /// Every extension some ImageIO decoder claims: a camera format can have two types ("orf"), and a
    /// format is readable when any of its spellings is.
    private static let readableExtensions: Set<String> = {
        let types = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return Set(types.flatMap { UTType($0)?.tags[.filenameExtension] ?? [] }.map { $0.lowercased() })
    }()
    /// Sources whose pixels are already lossy: a PDF page gets them as JPEG, not as a page four times the photo.
    private static let lossy: Set<String> = ["jpg", "heic", "avif", "jp2", "webp", "jxl", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]
    private static let compressible: Set<String> = ["jpg", "heic", "avif", "jp2"]
    /// Automatic quality when the user chose none.
    private static let automaticQuality: [String: Double] = ["jpg": 0.9, "heic": 0.8, "avif": 0.6, "jp2": 0.9, "webp": 0.85]
    /// Square sizes ImageIO's ICO writer accepts (24 is one too, but an ICO destination takes at most six
    /// pictures), and the ICNS slots with the DPI that puts a picture into its retina slot (64 and 1024 are
    /// dropped silently without it).
    private static let icoSizes = [16, 32, 48, 64, 128, 256]
    private static let icnsSlots: [(pixels: Int, dpi: Int)] = [(16, 72), (32, 144), (32, 72), (64, 144), (128, 72), (256, 144),
                                                               (256, 72), (512, 144), (512, 72), (1024, 144)]
    /// Vision stalls the Swift concurrency pool; the subject mask gets a queue of its own.
    private static let vision = DispatchQueue(label: "local.barlet.convert.images.vision", qos: .userInitiated)

    public func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
        guard source.family == .image, Self.readable(source) else { return .unsupported }
        switch target.id {
        case "nobg", "ocr", "pdf":
            return .available
        case "half":
            return Self.writes(source.id, in: environment)
        case "compress":
            return Self.compressible.contains(source.id) ? Self.writes(source.id, in: environment) : .unsupported
        default:
            guard target.kind == .convert, target.format == target.id, target.id != source.id else { return .unsupported }
            return Self.writes(target.id, in: environment)
        }
    }

    public func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
        try context.checkCancelled()
        switch request.target.id {
        case "pdf": return try await ConversionWork.run { [try Self.pdf(request, context)] }
        case "ocr": return try await ConversionWork.run { [try Self.recognize(request, context)] }
        case "nobg": return try await ConversionWork.run { [try Self.cutOut(request, context)] }
        default: break
        }
        guard request.outputFormat.id == "webp" else { return try await ConversionWork.run { [try Self.raster(request, context)] } }
        return [try await Self.webp(request, context)]
    }

    // MARK: Formats

    private static func readable(_ format: FileFormat) -> Bool {
        format.id == "svg" || format.extensions.contains { readableExtensions.contains($0) }
    }

    private static func writes(_ format: String, in environment: ConversionEnvironment) -> TargetAvailability {
        if format == "webp" { return webpTool(environment) == nil ? .needs("cwebp") : .available }
        return writable.contains(format) ? .available : .unsupported
    }

    /// cwebp when it is there; otherwise an ffmpeg that was built with libwebp (Homebrew's is not).
    private static func webpTool(_ environment: ConversionEnvironment) -> (url: URL, ffmpeg: Bool)? {
        if let cwebp = environment.cwebp { return (cwebp, false) }
        if let ffmpeg = environment.ffmpeg, environment.encoders.contains("libwebp") { return (ffmpeg, true) }
        return nil
    }

    private static func quality(of format: String, _ options: ConversionOptions) -> Double? {
        guard let automatic = automaticQuality[format] else { return nil }
        let chosen = options.imageQuality ?? automatic
        // AVIF at 1.0 fails to finalize.
        return format == "avif" ? min(chosen, 0.95) : chosen
    }

    // MARK: Reading

    /// The frame a conversion starts from, its pixels upright.
    private struct Picture {
        var image: CGImage
        /// As the file stored them; the orientation is already applied to `image`.
        var properties: [String: Any]
        /// More than one: an animation or a document with pages.
        var frames: Int
        /// Pixels per inch along the upright picture's width and height; 72 when the file says nothing.
        var dpi: (x: Double, y: Double)
    }

    /// The first frame, or for icons the largest picture in the file; SVG rendered so its long side is at
    /// least 2048 pixels. `refuseFrames` throws the skip of `half` and `compress` for animations.
    private static func read(_ request: ConversionRequest, refuseFrames: Bool = false) throws -> Picture {
        let url = request.sources[0], format = request.formats[0].id
        if format == "svg" {
            let (image, scale) = try svg(url)
            return Picture(image: image, properties: [:], frames: 1, dpi: (72 * scale, 72 * scale))
        }
        let source = try open(url)
        let frames = frameCount(source, format: format)
        if refuseFrames, frames > 1 { throw ConversionSkip("Hareketli görüntüler bu araçla küçültülemez.") }
        return try picture(source, at: mainIndex(source, format: format), frames: frames)
    }

    private static func open(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache as String: false] as CFDictionary),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 else { throw unreadable }
        return source
    }

    /// Only these formats animate or have pages. A JPEG can carry a second picture (MPO, a depth map), a
    /// camera file a preview, and an icon holds sizes of one picture: none of them is an animation.
    private static let framed: Set<String> = ["gif", "png", "webp", "heic", "avif", "tiff", "jxl"]

    private static func frameCount(_ source: CGImageSource, format: String) -> Int {
        framed.contains(format) ? CGImageSourceGetCount(source) : 1
    }

    private static func mainIndex(_ source: CGImageSource, format: String) -> Int {
        guard format == "ico" || format == "icns" else { return CGImageSourceGetPrimaryImageIndex(source) }
        let areas = (0..<CGImageSourceGetCount(source)).map { index -> Int in
            let properties = self.properties(source, index)
            return (properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0) * (properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
        }
        return areas.indices.max { areas[$0] < areas[$1] } ?? 0
    }

    private static func properties(_ source: CGImageSource, _ index: Int) -> [String: Any] {
        CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
    }

    private static func orientation(_ properties: [String: Any]) -> Int {
        let value = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        return (1...8).contains(value) ? value : 1
    }

    /// Pixels per inch along the stored width and height; orientations 5 to 8 swap the two.
    private static func dpi(_ properties: [String: Any], orientation: Int) -> (x: Double, y: Double) {
        func value(_ key: CFString) -> Double {
            let number = properties[key as String] as? Double ?? 0
            return number.isFinite && number > 0 ? number : 72
        }
        let stored = (x: value(kCGImagePropertyDPIWidth), y: value(kCGImagePropertyDPIHeight))
        return orientation >= 5 ? (stored.y, stored.x) : stored
    }

    private static func picture(_ source: CGImageSource, at index: Int, frames: Int) throws -> Picture {
        let properties = self.properties(source, index), orientation = self.orientation(properties)
        let image = try decode(source, at: index, properties: properties, orientation: orientation)
        return Picture(image: image, properties: properties, frames: frames, dpi: dpi(properties, orientation: orientation))
    }

    /// A turned picture is decoded through the thumbnail call at full size, which bakes the orientation into
    /// the pixels and never enlarges; an upright one is decoded as it is, its depth untouched.
    private static func decode(_ source: CGImageSource, at index: Int, properties: [String: Any], orientation: Int) throws -> CGImage {
        let plain = [kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary
        if orientation == 1, let image = CGImageSourceCreateImageAtIndex(source, index, plain) { return image }
        var side = max(properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0, properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
        if side <= 0, let image = CGImageSourceCreateImageAtIndex(source, index, plain) { side = max(image.width, image.height) }
        let options: [String: Any] = [kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                                      kCGImageSourceCreateThumbnailWithTransform as String: true,
                                      kCGImageSourceThumbnailMaxPixelSize as String: side,
                                      kCGImageSourceShouldCacheImmediately as String: true]
        guard side > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw unreadable }
        return image
    }

    /// SVG is no ImageIO type. AppKit draws it into a context of a known pixel size (its own
    /// `cgImage(forProposedRect:)` answers differently off the main thread). Returns the scale over the
    /// drawing's own size, which becomes the picture's DPI so a PDF page keeps the drawing's size.
    private static func svg(_ url: URL) throws -> (CGImage, CGFloat) {
        guard let drawing = NSImage(contentsOf: url) else { throw unreadable }
        let size = drawing.size, long = max(size.width, size.height)
        guard long.isFinite, long > 0, min(size.width, size.height) > 0 else { throw unreadable }
        let scale = long < 2048 ? 2048 / long : min(1, 16384 / long)
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = canvas(width: width, height: height, like: nil, alpha: true) else { throw unreadable }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        drawing.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw unreadable }
        return (image, scale)
    }

    // MARK: Pixels

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        default: false
        }
    }

    /// A bitmap in the picture's own colour space where a bitmap context can have it (RGB, or grey without
    /// alpha), else sRGB; 16 bits when the picture has more than 8.
    private static func canvas(width: Int, height: Int, like image: CGImage?, alpha: Bool) -> CGContext? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var space = image?.colorSpace ?? srgb
        if !(space.model == .rgb || (space.model == .monochrome && !alpha)) || !space.supportsOutput { space = srgb }
        let info: CGImageAlphaInfo = alpha ? .premultipliedLast : space.model == .monochrome ? .none : .noneSkipLast
        let depth = (image?.bitsPerComponent ?? 8) > 8 ? 16 : 8
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: depth, bytesPerRow: 0, space: space, bitmapInfo: info.rawValue)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                         bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)
    }

    /// `kCGImageDestinationImageMaxPixelSize` enlarges, so the size is made here and only ever shrinks.
    private static func resized(_ image: CGImage, _ resize: ImageResize) throws -> CGImage {
        let size = resize.pixelSize(width: image.width, height: image.height)
        guard size.width != image.width || size.height != image.height else { return image }
        guard let context = canvas(width: size.width, height: size.height, like: image, alpha: hasAlpha(image)) else { throw unreadable }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let result = context.makeImage() else { throw unreadable }
        return result
    }

    /// For formats without alpha, and for Vision, which reads transparent pixels as black.
    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard hasAlpha(image) else { return image }
        guard let context = canvas(width: image.width, height: image.height, like: image, alpha: false) else { throw unreadable }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw unreadable }
        return result
    }

    // MARK: Writing

    /// The source's metadata without what no longer holds for upright, re-encoded pixels: the orientation
    /// at the top level and inside {TIFF} (a leftover one made JPG and PNG read back rotated and JP2 fail to
    /// finalize), the EXIF pixel dimensions, and the encoding of the old file. The embedded thumbnail and
    /// XMP are not carried over at all. The colour profile travels with the pixels, whatever this says.
    private static func metadata(of picture: Picture) -> [String: Any] {
        var kept: [String: Any] = [:]
        for key in [kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let group = picture.properties[key as String] { kept[key as String] = group }
        }
        if var exif = picture.properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = nil
            exif[kCGImagePropertyExifPixelYDimension as String] = nil
            kept[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = picture.properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            for key in [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
                        kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength, kCGImagePropertyTIFFTransferFunction,
                        kCGImagePropertyTIFFWhitePoint, kCGImagePropertyTIFFPrimaryChromaticities] {
                tiff[key as String] = nil
            }
            kept[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if picture.properties[kCGImagePropertyDPIWidth as String] != nil || picture.properties[kCGImagePropertyDPIHeight as String] != nil {
            kept[kCGImagePropertyDPIWidth as String] = picture.dpi.x
            kept[kCGImagePropertyDPIHeight as String] = picture.dpi.y
        }
        return kept
    }

    private static func properties(for format: String, of picture: Picture, _ options: ConversionOptions) -> [String: Any] {
        var properties = options.keepMetadata ? metadata(of: picture) : [:]
        if let quality = quality(of: format, options) { properties[kCGImageDestinationLossyCompressionQuality as String] = quality }
        if format == "tiff" {
            // LZW: lossless and about 40 % smaller than ImageIO's uncompressed default.
            var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = 5
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return properties
    }

    private static func failed(_ format: String) -> ConversionFailure {
        ConversionFailure("Dönüştürülemedi: %@", detail: FormatRegistry.format(id: format)?.label ?? format.uppercased())
    }

    /// One picture into one file; a half-written file is removed.
    private static func write(_ images: [(CGImage, [String: Any])], as format: String, to url: URL) throws {
        guard let type = writers[format],
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil) else { throw failed(format) }
        for (image, properties) in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw failed(format)
        }
    }

    /// ICO and ICNS hold square pictures of fixed sizes: the picture is centred on a transparent square and
    /// drawn at every size that is not larger than its long side (16 at least).
    private static func writeIcon(_ image: CGImage, as format: String, to url: URL, context: ConversionContext) throws {
        let side = max(image.width, image.height)
        let slots = format == "ico" ? icoSizes.map { (pixels: $0, dpi: 72) } : icnsSlots
        let chosen = slots.filter { $0.pixels <= side }
        var entries: [(CGImage, [String: Any])] = []
        for slot in chosen.isEmpty ? [slots[0]] : chosen {
            try context.checkCancelled()
            guard let canvas = canvas(width: slot.pixels, height: slot.pixels, like: image, alpha: true) else { throw failed(format) }
            let scale = CGFloat(slot.pixels) / CGFloat(side)
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            canvas.interpolationQuality = .high
            canvas.draw(image, in: CGRect(x: (CGFloat(slot.pixels) - width) / 2, y: (CGFloat(slot.pixels) - height) / 2, width: width, height: height))
            guard let square = canvas.makeImage() else { throw failed(format) }
            entries.append((square, [kCGImagePropertyDPIWidth as String: slot.dpi, kCGImagePropertyDPIHeight as String: slot.dpi]))
        }
        try write(entries, as: format, to: url)
    }

    // MARK: Raster targets

    /// The one pipeline: first frame upright, resized, flattened for JPG, written at the format's quality
    /// with the metadata the options keep.
    private static func raster(_ request: ConversionRequest, _ context: ConversionContext) throws -> URL {
        let tool = request.target.id == "half" || request.target.id == "compress"
        let url = request.outputURL()
        let frames = try encode(request, context, refuseFrames: tool, as: request.outputFormat.id, to: url)
        if frames > 1 { context.note("Yalnızca ilk kare dönüştürüldü.") }
        context.progress(1)
        return url
    }

    /// Writes the pipeline's picture as `format` (PNG for the WebP tools) and returns the source's frame count.
    private static func encode(_ request: ConversionRequest, _ context: ConversionContext, refuseFrames: Bool, as format: String, to url: URL) throws -> Int {
        let picture = try read(request, refuseFrames: refuseFrames)
        try context.checkCancelled()
        context.progress(0.4)
        var image = try resized(picture.image, request.options.imageResize)
        if format == "jpg" { image = try flattened(image) }
        try context.checkCancelled()
        context.progress(0.6)
        if format == "ico" || format == "icns" {
            try writeIcon(image, as: format, to: url, context: context)
        } else {
            try write([(image, properties(for: format, of: picture, request.options))], as: format, to: url)
        }
        return picture.frames
    }

    /// ImageIO cannot write WebP: the pipeline writes a PNG beside the result and the tool encodes it.
    private static func webp(_ request: ConversionRequest, _ context: ConversionContext) async throws -> URL {
        guard let tool = webpTool(request.environment) else { throw ConversionFailure("Bu dönüştürme için %@ gerekli.", detail: "cwebp") }
        let staged = request.workFolder.appendingPathComponent(".stage-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: staged) }
        let refuse = request.target.id == "half" || request.target.id == "compress"
        let frames = try await ConversionWork.run { try encode(request, context, refuseFrames: refuse, as: "png", to: staged) }
        try context.checkCancelled()
        let output = request.outputURL()
        let quality = String(Int(((quality(of: "webp", request.options) ?? 0.85) * 100).rounded()))
        let arguments = tool.ffmpeg
            ? ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", staged.path, "-frames:v", "1", "-c:v", "libwebp",
               "-quality", quality, "-f", "webp", output.path]
            : ["-quiet", "-mt", "-q", quality, "-metadata", request.options.keepMetadata ? "all" : "icc", staged.path, "-o", output.path]
        let result = try await ToolProcess.run(tool.url, arguments: arguments)
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard result.status == 0, size > 0 else {
            try? FileManager.default.removeItem(at: output)
            let said = result.stderrTail.split(whereSeparator: \.isNewline).last.map(String.init)
            throw ConversionFailure("Dönüştürülemedi: %@", detail: said ?? tool.url.lastPathComponent)
        }
        if frames > 1 { context.note("Yalnızca ilk kare dönüştürüldü.") }
        context.progress(1)
        return output
    }

    // MARK: PDF

    /// One page per picture, every page of a TIFF. A JPEG that keeps its size goes in untouched and the page
    /// turns it; other lossy pictures without alpha, a resized JPEG among them, go in as one JPEG; the rest
    /// (PNG, TIFF, BMP, GIF, icons, PSD, SVG and anything with alpha) losslessly.
    /// Page size = pixels × 72 / the picture's DPI.
    private static func pdf(_ request: ConversionRequest, _ context: ConversionContext) throws -> URL {
        let url = request.outputURL(), format = request.formats[0].id, options = request.options
        guard let document = CGContext(url as CFURL, mediaBox: nil, nil) else { throw failed("pdf") }
        var unfinished = true
        defer { if unfinished { document.closePDF(); try? FileManager.default.removeItem(at: url) } }
        func page(_ size: CGSize, _ draw: () -> Void) {
            var box = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            document.beginPDFPage(info)
            draw()
            document.endPDFPage()
        }
        func place(_ picture: Picture, lossy: Bool) throws {
            let image = try resized(picture.image, options.imageResize)
            let embedded = lossy && !hasAlpha(image) ? try jpeg(image, quality: options.imageQuality ?? 0.9) : image
            let size = CGSize(width: Double(image.width) * 72 / picture.dpi.x, height: Double(image.height) * 72 / picture.dpi.y)
            page(size) { document.draw(embedded, in: CGRect(origin: .zero, size: size)) }
        }

        if format == "svg" {
            try place(try read(request), lossy: false)
        } else {
            let source = try open(request.sources[0])
            let frames = frameCount(source, format: format)
            if format == "tiff" {
                for index in 0..<frames {
                    try context.checkCancelled()
                    try place(try picture(source, at: index, frames: frames), lossy: false)
                    context.progress(Double(index + 1) / Double(frames))
                }
            } else {
                let index = mainIndex(source, format: format), properties = self.properties(source, index)
                let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                let target = options.imageResize.pixelSize(width: width, height: height)
                if CGImageSourceGetType(source) as String? == "public.jpeg", width > 0, height > 0, target.width == width, target.height == height,
                   let stream = try? Data(contentsOf: request.sources[0]),
                   let embedded = options.keepMetadata ? stream : withoutMetadata(stream),
                   let provider = CGDataProvider(data: embedded as CFData),
                   let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                    try context.checkCancelled()
                    let orientation = self.orientation(properties), dpi = self.dpi(properties, orientation: orientation)
                    // The stored picture in points, before it is turned.
                    let stored = orientation >= 5
                        ? CGSize(width: Double(image.width) * 72 / dpi.y, height: Double(image.height) * 72 / dpi.x)
                        : CGSize(width: Double(image.width) * 72 / dpi.x, height: Double(image.height) * 72 / dpi.y)
                    let size = orientation >= 5 ? CGSize(width: stored.height, height: stored.width) : stored
                    page(size) {
                        document.concatenate(upright(orientation, stored))
                        document.draw(image, in: CGRect(origin: .zero, size: stored))
                    }
                } else {
                    let picture = try self.picture(source, at: index, frames: frames)
                    try context.checkCancelled()
                    try place(picture, lossy: lossy.contains(format))
                }
                if frames > 1 { context.note("Yalnızca ilk kare dönüştürüldü.") }
            }
        }
        unfinished = false
        document.closePDF()
        context.progress(1)
        return url
    }

    /// Maps the stored picture, drawn at the origin in `stored` points, onto the upright page for an EXIF
    /// orientation (y up; 6 means the stored picture is turned 90° clockwise to be seen upright).
    private static func upright(_ orientation: Int, _ stored: CGSize) -> CGAffineTransform {
        let w = stored.width, h = stored.height
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return .identity
        }
    }

    /// A picture encoded once as JPEG, as a picture backed by that stream, so the PDF embeds the stream.
    private static func jpeg(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { throw failed("pdf") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data as CFData),
              let result = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw failed("pdf") }
        return result
    }

    /// The JPEG stream without its APP1 (Exif, XMP) and APP13 (IPTC) segments; the profile (APP2) and
    /// Adobe's colour transform (APP14) stay. Nil for a stream it cannot follow.
    private static func withoutMetadata(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var kept: [UInt8] = [0xFF, 0xD8]
        var offset = 2
        while offset + 1 < bytes.count {
            guard bytes[offset] == 0xFF else { return nil }
            let marker = bytes[offset + 1]
            switch marker {
            case 0xFF:
                offset += 1
            case 0xDA:
                // Start of scan: the picture itself, copied as it is.
                kept += bytes[offset...]
                return Data(kept)
            case 0x01, 0xD0...0xD7:
                kept += [0xFF, marker]
                offset += 2
            default:
                guard offset + 3 < bytes.count else { return nil }
                let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                guard length >= 2, offset + 2 + length <= bytes.count else { return nil }
                if marker != 0xE1, marker != 0xED { kept += bytes[offset ..< offset + 2 + length] }
                offset += 2 + length
            }
        }
        return nil
    }

    // MARK: Vision

    private static func recognize(_ request: ConversionRequest, _ context: ConversionContext) throws -> URL {
        let picture = try read(request)
        try context.checkCancelled()
        context.progress(0.2)
        let text = try TextRecognition.text(in: try flattened(picture.image), isCancelled: context.isCancelled)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionFailure("Görüntüde metin bulunamadı.") }
        let url = request.outputURL()
        try Data((text + "\n").utf8).write(to: url)
        if picture.frames > 1 { context.note("Yalnızca ilk kare dönüştürüldü.") }
        context.progress(1)
        return url
    }

    /// The subject Vision finds, on transparency, as PNG. The mask is applied to the picture's own pixels, so
    /// its colour space and profile stay.
    private static func cutOut(_ request: ConversionRequest, _ context: ConversionContext) throws -> URL {
        let picture = try read(request)
        try context.checkCancelled()
        context.progress(0.2)
        let image = try resized(picture.image, request.options.imageResize)
        let mask = try subjectMask(image, context)
        try context.checkCancelled()
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let canvas = canvas(width: image.width, height: image.height, like: image, alpha: true) else { throw unreadable }
        canvas.clip(to: rect, mask: mask)
        canvas.draw(image, in: rect)
        guard let result = canvas.makeImage() else { throw unreadable }
        let url = request.outputURL()
        try write([(result, properties(for: "png", of: picture, request.options))], as: "png", to: url)
        if picture.frames > 1 { context.note("Yalnızca ilk kare dönüştürüldü.") }
        context.progress(1)
        return url
    }

    /// A grey mask of the picture's size: white where the subject is.
    private static func subjectMask(_ image: CGImage, _ context: ConversionContext) throws -> CGImage {
        let noSubject = ConversionFailure("Görüntüde öne çıkan bir nesne bulunamadı.")
        let buffer: CVPixelBuffer = try vision.sync {
            try context.checkCancelled()
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            try context.checkCancelled()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw noSubject }
            return try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { throw noSubject }
        var levels = [UInt8](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for row in 0..<height {
                let line = (base + row * rowBytes).assumingMemoryBound(to: Float.self)
                for column in 0..<width { levels[row * width + column] = UInt8((min(max(line[column], 0), 1) * 255).rounded()) }
            }
        case kCVPixelFormatType_OneComponent8:
            for row in 0..<height {
                let line = (base + row * rowBytes).assumingMemoryBound(to: UInt8.self)
                for column in 0..<width { levels[row * width + column] = line[column] }
            }
        default:
            throw noSubject
        }
        guard levels.contains(where: { $0 > 0 }), let provider = CGDataProvider(data: Data(levels) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw noSubject }
        return mask
    }
}
