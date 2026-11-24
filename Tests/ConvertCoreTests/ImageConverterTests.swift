import CoreGraphics
import CoreText
import ImageIO
import XCTest
@testable import ConvertCore

/// The image converter against pictures drawn here and written with ImageIO, read back the same way.
/// The WebP tools are stand-in scripts (the installed cwebp only where it exists); the Vision tests run
/// only with BSTOEQ_VISION_TESTS=1, because the first recognition of a new executable compiles the models.
final class ImageConverterTests: XCTestCase {
    private let converter = ImageConverter()
    private var fixture: ConversionFixture!

    private let unreadable = "Bu görüntü okunamadı."
    private let firstFrame = "Yalnızca ilk kare dönüştürüldü."
    private let animated = "Hareketli görüntüler bu araçla küçültülemez."

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "images") }
    override func tearDownWithError() throws { fixture.remove() }

    // MARK: Pictures

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func context(_ width: Int, _ height: Int, alpha: Bool = false) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                  bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    }

    /// Gradients with noise, so lossy encoders have something to lose; opaque unless the left half is
    /// to be transparent.
    private func photo(_ width: Int, _ height: Int, transparentLeft: Bool = false) -> CGImage {
        let canvas = context(width, height, alpha: transparentLeft)
        let pixels = canvas.data!.bindMemory(to: UInt8.self, capacity: canvas.bytesPerRow * height)
        var seed: UInt64 = 7
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int((seed >> 59) & 0x1F) - 16
                let offset = y * canvas.bytesPerRow + x * 4
                let clear = transparentLeft && x < width / 2
                pixels[offset] = clear ? 0 : UInt8(clamping: x * 255 / width + noise)
                pixels[offset + 1] = clear ? 0 : UInt8(clamping: y * 255 / height + noise)
                pixels[offset + 2] = clear ? 0 : UInt8(clamping: (x + y) * 128 / (width + height) + noise)
                pixels[offset + 3] = clear ? 0 : 255
            }
        }
        return canvas.makeImage()!
    }

    /// Red in the top left quarter as stored, blue elsewhere; with noise when it is to stand for a photo.
    private func marked(_ width: Int, _ height: Int, noisy: Bool = false) -> CGImage {
        let canvas = context(width, height)
        if noisy { canvas.draw(photo(width, height), in: CGRect(x: 0, y: 0, width: width, height: height)) }
        canvas.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: noisy ? 0.85 : 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: noisy ? 0.85 : 1))
        canvas.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2))
        return canvas.makeImage()!
    }

    @discardableResult
    private func save(_ name: String, _ type: String, _ images: [CGImage], _ properties: [String: Any] = [:]) throws -> URL {
        let url = fixture.url(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination), "writing the fixture \(name)")
        return url
    }

    /// Metadata a phone photo carries, turned the way a phone held upright stores it.
    private func phoneMetadata(orientation: Int = 6, width: Int = 400, height: Int = 300) -> [String: Any] {
        [kCGImagePropertyOrientation as String: orientation,
         kCGImagePropertyDPIWidth as String: 300, kCGImagePropertyDPIHeight as String: 300,
         kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFOrientation as String: orientation, kCGImagePropertyTIFFMake as String: "BStoeqMake"],
         kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifPixelXDimension as String: width, kCGImagePropertyExifPixelYDimension as String: height,
                                                    kCGImagePropertyExifLensModel as String: "BSTOEQLENS"],
         kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 41.0, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                   kCGImagePropertyGPSLongitude as String: 29.0, kCGImagePropertyGPSLongitudeRef as String: "E"]]
    }

    private struct ReadBack {
        let type: String, count: Int, width: Int, height: Int, properties: [String: Any], image: CGImage
        var orientation: Int? { properties[kCGImagePropertyOrientation as String] as? Int }
        var tiffOrientation: Int? { (properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFOrientation as String] as? Int }
        func group(_ key: CFString) -> [String: Any]? { properties[key as String] as? [String: Any] }
    }

    /// The stored pixels, as a viewer that ignores orientation would show them.
    private func readBack(_ url: URL, index: Int = 0) throws -> ReadBack {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.lastPathComponent)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil), url.lastPathComponent)
        return ReadBack(type: CGImageSourceGetType(source) as String? ?? "", count: CGImageSourceGetCount(source),
                        width: image.width, height: image.height,
                        properties: CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:], image: image)
    }

    /// RGBA at a point counted from the top left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let canvas = context(image.width, image.height, alpha: true)
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = canvas.data!.bindMemory(to: UInt8.self, capacity: canvas.bytesPerRow * image.height)
        let offset = y * canvas.bytesPerRow + x * 4
        return (0..<4).map { Int(pixels[offset + $0]) }
    }

    private func isRed(_ rgba: [Int]) -> Bool { rgba[0] > 150 && rgba[2] < 110 }
    private func isBlue(_ rgba: [Int]) -> Bool { rgba[2] > 150 && rgba[0] < 110 }

    private func pdfPages(_ url: URL) throws -> [CGSize] {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        return (0..<document.numberOfPages).compactMap { document.page(at: $0 + 1)?.getBoxRect(.mediaBox).size }
    }

    private func render(_ url: URL) throws -> CGImage {
        let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let canvas = context(Int(box.width.rounded()), Int(box.height.rounded()))
        canvas.drawPDFPage(page)
        return canvas.makeImage()!
    }

    /// JPEG streams in a file: an Exif thumbnail is a second one inside APP1.
    private func pictures(in url: URL) -> Int {
        let bytes = [UInt8]((try? Data(contentsOf: url)) ?? Data())
        return bytes.indices.dropLast(2).filter { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF }.count
    }

    private func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
    private func contains(_ url: URL, _ text: String) -> Bool { (try? Data(contentsOf: url))?.range(of: Data(text.utf8)) != nil }

    private func convert(_ source: URL, _ target: String, options: ConversionOptions = ConversionOptions(),
                         environment: ConversionEnvironment = ConversionEnvironment()) async throws -> URL {
        let request = try fixture.request([source], target: target, options: options, environment: environment)
        let outputs = try await converter.convert(request, context: fixture.context())
        XCTAssertEqual(outputs.count, 1)
        let output = try XCTUnwrap(outputs.first)
        XCTAssertEqual(output.deletingLastPathComponent().path, request.workFolder.path)
        XCTAssertGreaterThan(size(output), 0)
        return output
    }

    private func failure(_ source: URL, _ target: String, options: ConversionOptions = ConversionOptions(),
                         environment: ConversionEnvironment = ConversionEnvironment()) async throws -> Error {
        do {
            _ = try await convert(source, target, options: options, environment: environment)
        } catch {
            return error
        }
        XCTFail("\(source.lastPathComponent) to \(target) did not fail")
        throw CancellationError()
    }

    private func availability(_ target: String, _ source: String, _ environment: ConversionEnvironment = ConversionEnvironment()) throws -> TargetAvailability {
        converter.availability(of: try fixture.target(target), for: try XCTUnwrap(FormatRegistry.format(id: source)), in: environment)
    }

    // MARK: Availability

    func testEveryRegisteredImageFormatIsReadAndTheWritersAreTheOnesTheSpecNames() throws {
        for format in FormatRegistry.all where format.family == .image {
            XCTAssertEqual(try availability(format.id == "png" ? "jpg" : "png", format.id), .available, format.id)
            XCTAssertEqual(try availability("pdf", format.id), .available, format.id)
            XCTAssertEqual(try availability("ocr", format.id), .available, format.id)
            XCTAssertEqual(try availability("nobg", format.id), .available, format.id)
            if TargetCatalog.target(id: format.id) != nil { XCTAssertEqual(try availability(format.id, format.id), .unsupported, "\(format.id) to itself") }
        }
        for target in ["jpg", "png", "heic", "avif", "tiff", "gif", "bmp", "jp2", "ico", "icns"] {
            XCTAssertEqual(try availability(target, "tga"), .available, target)
        }
        for target in ["txt", "docx", "mp4", "mp3", "csv", "srt", "pdf.merge", "pdf.split", "mute", "mp4.720p"] {
            XCTAssertEqual(try availability(target, "jpg"), .unsupported, target)
        }
        for source in ["pdf", "mp4", "txt", "zip"] {
            XCTAssertEqual(try availability("png", source), .unsupported, source)
        }
    }

    func testHalfAndCompressOnlyTakeSourcesTheyCanWriteBack() throws {
        for source in ["jpg", "png", "heic", "avif", "tiff", "gif", "bmp", "jp2", "ico", "icns"] {
            XCTAssertEqual(try availability("half", source), .available, source)
        }
        for source in ["svg", "dng", "cr2", "nef", "psd", "tga", "exr", "jxl"] {
            XCTAssertEqual(try availability("half", source), .unsupported, source)
        }
        XCTAssertEqual(try availability("half", "webp"), .needs("cwebp"))
        for source in ["jpg", "heic", "avif", "jp2"] { XCTAssertEqual(try availability("compress", source), .available, source) }
        for source in ["png", "tiff", "gif", "bmp", "webp", "svg", "dng"] { XCTAssertEqual(try availability("compress", source), .unsupported, source) }
    }

    func testWebPNeedsCwebpOrAnFfmpegThatListsLibwebp() async throws {
        let ffmpeg = URL(fileURLWithPath: "/nonexistent/ffmpeg"), cwebp = URL(fileURLWithPath: "/nonexistent/cwebp")
        XCTAssertEqual(try availability("webp", "png"), .needs("cwebp"))
        XCTAssertEqual(try availability("webp", "png", ConversionEnvironment(ffmpeg: ffmpeg, encoders: ["libx264", "png"])), .needs("cwebp"))
        XCTAssertEqual(try availability("webp", "png", ConversionEnvironment(ffmpeg: ffmpeg, encoders: ["libwebp"])), .available)
        XCTAssertEqual(try availability("webp", "png", ConversionEnvironment(cwebp: cwebp)), .available)
        XCTAssertEqual(try availability("half", "webp", ConversionEnvironment(cwebp: cwebp)), .available)
        XCTAssertEqual(try availability("png", "webp"), .available, "reading WebP needs no tool")

        let source = try save("photo.png", "public.png", [photo(64, 48)])
        let error = try await failure(source, "webp")
        XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Bu dönüştürme için %@ gerekli.", detail: "cwebp"))
    }

    // MARK: Targets

    func testEveryTargetIsWrittenInItsTypeAndReadsBackAtItsSize() async throws {
        let png = try save("photo.png", "public.png", [photo(320, 240)])
        let types = ["jpg": "public.jpeg", "heic": "public.heic", "avif": "public.avif", "tiff": "public.tiff", "gif": "com.compuserve.gif",
                     "bmp": "com.microsoft.bmp", "jp2": "public.jpeg-2000"]
        for (target, type) in types {
            let output = try await convert(png, target)
            XCTAssertEqual(output.pathExtension, target)
            let back = try readBack(output)
            XCTAssertEqual(back.type, type, target)
            XCTAssertEqual([back.width, back.height], [320, 240], target)
        }
        let jpg = try save("photo.jpg", "public.jpeg", [photo(320, 240)])
        let back = try readBack(try await convert(jpg, "png"))
        XCTAssertEqual(back.type, "public.png")
        XCTAssertEqual([back.width, back.height], [320, 240])
        let ico = try await convert(png, "ico"), icns = try await convert(png, "icns"), pdf = try await convert(png, "pdf")
        XCTAssertEqual(try readBack(ico).type, "com.microsoft.ico")
        XCTAssertEqual(try readBack(icns).type, "com.apple.icns")
        XCTAssertEqual(try pdfPages(pdf), [CGSize(width: 320, height: 240)])
        XCTAssertEqual(fixture.notes, [])
    }

    func testAnOrientationSixPictureComesOutUprightAndUntaggedForEveryTarget() async throws {
        let jpg = try save("turned.jpg", "public.jpeg", [marked(400, 300)], phoneMetadata())
        XCTAssertEqual(try readBack(jpg).orientation, 6)
        let tiff = try save("turned.tiff", "public.tiff", [marked(400, 300)], phoneMetadata())
        var outputs = [("half", try await convert(jpg, "half", options: ConversionOptions(keepMetadata: true)), 150, 200),
                       ("jpg", try await convert(tiff, "jpg", options: ConversionOptions(keepMetadata: true)), 300, 400)]
        for target in ["png", "heic", "avif", "tiff", "gif", "bmp", "jp2", "ico", "icns"] {
            let square = target == "ico" || target == "icns"
            outputs.append((target, try await convert(jpg, target, options: ConversionOptions(keepMetadata: true)), square ? 256 : 300, square ? 256 : 400))
        }
        for (target, output, width, height) in outputs {
            let back = try readBack(output)
            XCTAssertEqual([back.width, back.height], [width, height], target)
            XCTAssertTrue(back.orientation == nil || back.orientation == 1, "\(target) reads back orientation \(back.orientation ?? 0)")
            XCTAssertTrue(back.tiffOrientation == nil || back.tiffOrientation == 1, "\(target) keeps {TIFF} orientation \(back.tiffOrientation ?? 0)")
            if target == "ico" || target == "icns" { continue }
            // Turned 90° clockwise: the stored top left quarter is now the top right one.
            XCTAssertTrue(isRed(pixel(back.image, width * 3 / 4, height / 4)), "\(target) top right \(pixel(back.image, width * 3 / 4, height / 4))")
            XCTAssertTrue(isBlue(pixel(back.image, width / 4, height / 4)), "\(target) top left \(pixel(back.image, width / 4, height / 4))")
            XCTAssertTrue(isBlue(pixel(back.image, width / 4, height * 3 / 4)), "\(target) bottom left")
        }
    }

    func testAPictureIsResizedAsChosenAndNeverEnlarged() async throws {
        let png = try save("photo.png", "public.png", [photo(320, 240)])
        let sizes: [(ImageResize, [Int])] = [(.long1920, [320, 240]), (.half, [160, 120]), (.quarter, [80, 60]),
                                             (ImageResize(mode: .longEdge, value: 100), [100, 75]), (ImageResize(mode: .percent, value: 100), [320, 240])]
        for (resize, expected) in sizes {
            let back = try readBack(try await convert(png, "jpg", options: ConversionOptions(imageResize: resize)))
            XCTAssertEqual([back.width, back.height], expected, "\(resize)")
        }
        let half = try readBack(try await convert(try save("photo.heic", "public.heic", [photo(320, 240)]), "half"))
        XCTAssertEqual([half.type, "\(half.width)x\(half.height)"], ["public.heic", "160x120"])
        let tiny = try readBack(try await convert(try save("dot.png", "public.png", [photo(1, 1)]), "half"))
        XCTAssertEqual([tiny.width, tiny.height], [1, 1])
    }

    func testAlphaIsFlattenedOnWhiteForJPGAndKeptForPNGAndHEIC() async throws {
        let tiff = try save("cutout.tiff", "public.tiff", [photo(200, 100, transparentLeft: true)])
        let jpg = try readBack(try await convert(tiff, "jpg"))
        XCTAssertTrue(pixel(jpg.image, 20, 50).prefix(3).allSatisfy { $0 > 245 }, "JPG \(pixel(jpg.image, 20, 50))")
        for target in ["png", "heic"] {
            let back = try readBack(try await convert(tiff, target))
            XCTAssertLessThan(pixel(back.image, 20, 50)[3], 10, target)
            XCTAssertGreaterThan(pixel(back.image, 180, 50)[3], 245, target)
        }
    }

    func testTheQualityChoiceChangesTheSize() async throws {
        let png = try save("photo.png", "public.png", [photo(400, 300)])
        for target in ["jpg", "heic", "avif", "jp2"] {
            let low = size(try await convert(png, target, options: ConversionOptions(imageQuality: 0.3)))
            let high = size(try await convert(png, target, options: ConversionOptions(imageQuality: 0.95)))
            XCTAssertLessThan(low, high * 7 / 10, target)
        }
        // AVIF at 1.0 does not finalize: it is capped and still written.
        let lossless = try await convert(png, "avif", options: ConversionOptions(imageQuality: 1))
        XCTAssertGreaterThan(size(lossless), 0)
        let jpg = try save("photo.jpg", "public.jpeg", [photo(400, 300)], [kCGImageDestinationLossyCompressionQuality as String: 1.0])
        let compressed = try await convert(jpg, "compress")
        XCTAssertLessThan(size(compressed), size(jpg))
    }

    func testMetadataIsKeptWithoutOrientationOrStrippedAndNoThumbnailIsCarried() async throws {
        var metadata = phoneMetadata(orientation: 1)
        metadata[kCGImageDestinationEmbedThumbnail as String] = true
        let jpg = try save("phone.jpg", "public.jpeg", [photo(400, 300)], metadata)
        XCTAssertGreaterThan(pictures(in: jpg), 1, "the fixture carries a thumbnail")

        for target in ["half", "heic", "tiff", "png"] {
            let kept = try readBack(try await convert(jpg, target, options: ConversionOptions(keepMetadata: true)))
            XCTAssertEqual(kept.group(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFMake as String] as? String, "BStoeqMake", target)
            XCTAssertNotNil(kept.group(kCGImagePropertyGPSDictionary)?[kCGImagePropertyGPSLatitude as String], target)
            XCTAssertEqual(kept.group(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifLensModel as String] as? String, "BSTOEQLENS", target)
            XCTAssertEqual(kept.properties[kCGImagePropertyDPIWidth as String] as? Double, 300, target)
            if target == "half" {
                XCTAssertEqual(kept.group(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifPixelXDimension as String] as? Int ?? 200, 200)
            }

            let stripped = try readBack(try await convert(jpg, target, options: ConversionOptions(keepMetadata: false)))
            XCTAssertNil(stripped.group(kCGImagePropertyGPSDictionary), target)
            XCTAssertNil(stripped.group(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFMake as String], target)
            XCTAssertNil(stripped.group(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifLensModel as String], target)
        }
        let half = try await convert(jpg, "half", options: ConversionOptions(keepMetadata: true))
        XCTAssertEqual(pictures(in: half), 1, "no embedded thumbnail")
    }

    func testAnIconHoldsEverySquareSizeThePictureFillsOnATransparentCanvas() async throws {
        func sizes(_ url: URL) throws -> [Int] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try (0..<CGImageSourceGetCount(source)).map { index in
                let back = try readBack(url, index: index)
                XCTAssertEqual(back.width, back.height)
                return back.width
            }.sorted()
        }
        let wide = try save("wide.png", "public.png", [photo(300, 200)])
        let ico = try await convert(wide, "ico")
        XCTAssertEqual(try sizes(ico), [16, 32, 48, 64, 128, 256])
        let largest = try readBack(ico, index: try XCTUnwrap((0..<6).first { try readBack(ico, index: $0).width == 256 }))
        XCTAssertLessThan(pixel(largest.image, 128, 2)[3], 10, "padding above a wide picture is transparent")
        XCTAssertGreaterThan(pixel(largest.image, 128, 128)[3], 245)

        let small = try await convert(try save("small.png", "public.png", [photo(40, 30)]), "ico")
        let dot = try await convert(try save("dot.png", "public.png", [photo(10, 8)]), "ico")
        XCTAssertEqual(try sizes(small), [16, 32])
        XCTAssertEqual(try sizes(dot), [16])

        let icns = try await convert(wide, "icns"), big = try await convert(try save("big.png", "public.png", [photo(1100, 1000)]), "icns")
        XCTAssertEqual(Set(try sizes(icns)), [16, 32, 64, 128, 256])
        XCTAssertEqual(try sizes(big).max(), 1024)
    }

    // MARK: PDF

    func testAPDFPageIsThePictureSizeAtItsDPIAndALosslessSourceStaysLossless() async throws {
        let dense = try save("dense.png", "public.png", [photo(600, 400)], [kCGImagePropertyDPIWidth as String: 144, kCGImagePropertyDPIHeight as String: 144])
        let output = try await convert(dense, "pdf")
        XCTAssertEqual(try pdfPages(output), [CGSize(width: 300, height: 200)])
        XCTAssertFalse(contains(output, "/DCTDecode"))
        let plain = try await convert(try save("plain.png", "public.png", [photo(600, 400)]), "pdf")
        XCTAssertEqual(try pdfPages(plain), [CGSize(width: 600, height: 400)])
        let cutout = try await convert(try save("cutout.heic", "public.heic", [photo(200, 100, transparentLeft: true)]), "pdf")
        XCTAssertFalse(contains(cutout, "/DCTDecode"), "a picture with alpha keeps it")
    }

    func testARotatedJPEGGoesIntoThePDFUntouchedAndThePageTurnsIt() async throws {
        let jpg = try save("phone.jpg", "public.jpeg", [marked(1200, 900, noisy: true)],
                           phoneMetadata(width: 1200, height: 900).merging([kCGImageDestinationLossyCompressionQuality as String: 0.9]) { $1 })
        let output = try await convert(jpg, "pdf", options: ConversionOptions(keepMetadata: true))
        XCTAssertLessThanOrEqual(Double(size(output)), Double(size(jpg)) * 1.1, "\(size(output)) against \(size(jpg))")
        XCTAssertTrue(contains(output, "/DCTDecode"))
        // 300 dpi: 1200 × 900 pixels are 288 × 216 points, upright 216 × 288.
        XCTAssertEqual(try pdfPages(output), [CGSize(width: 216, height: 288)])
        let page = try render(output)
        XCTAssertTrue(isRed(pixel(page, 162, 72)), "top right \(pixel(page, 162, 72))")
        XCTAssertTrue(isBlue(pixel(page, 54, 72)), "top left \(pixel(page, 54, 72))")
        XCTAssertTrue(isBlue(pixel(page, 162, 216)), "bottom right \(pixel(page, 162, 216))")
        XCTAssertTrue(contains(output, "BSTOEQLENS"), "metadata kept travels in the stream")

        let stripped = try await convert(jpg, "pdf", options: ConversionOptions(keepMetadata: false))
        XCTAssertFalse(contains(stripped, "BSTOEQLENS"))
        XCTAssertTrue(contains(stripped, "/DCTDecode"))
        XCTAssertTrue(isRed(pixel(try render(stripped), 162, 72)))
        XCTAssertLessThanOrEqual(Double(size(stripped)), Double(size(jpg)) * 1.1)
    }

    func testEveryOtherOrientationOfAJPEGIsTurnedUprightOnThePage() async throws {
        // Where the stored top left quarter is seen after each turn (as fractions of the upright page).
        let seen: [Int: (Double, Double)] = [1: (0.25, 0.25), 2: (0.75, 0.25), 3: (0.75, 0.75), 4: (0.25, 0.75),
                                             5: (0.25, 0.25), 6: (0.75, 0.25), 7: (0.75, 0.75), 8: (0.25, 0.75)]
        for (orientation, spot) in seen {
            let jpg = try save("o\(orientation).jpg", "public.jpeg", [marked(200, 100)], [kCGImagePropertyOrientation as String: orientation])
            let page = try render(try await convert(jpg, "pdf"))
            XCTAssertEqual([page.width, page.height], orientation >= 5 ? [100, 200] : [200, 100], "\(orientation)")
            XCTAssertTrue(isRed(pixel(page, Int(Double(page.width) * spot.0), Int(Double(page.height) * spot.1))), "orientation \(orientation)")
            XCTAssertTrue(isBlue(pixel(page, Int(Double(page.width) * (1 - spot.0)), Int(Double(page.height) * (1 - spot.1)))), "orientation \(orientation)")
        }
    }

    func testALossyPictureOrAResizedPhotoGoesIntoThePDFAsOneJPEG() async throws {
        let heic = try save("photo.heic", "public.heic", [photo(800, 600)])
        let fromHEIC = try await convert(heic, "pdf")
        XCTAssertTrue(contains(fromHEIC, "/DCTDecode"))
        let resized = try await convert(try save("photo.jpg", "public.jpeg", [photo(800, 600)]), "pdf", options: ConversionOptions(imageResize: .half))
        XCTAssertTrue(contains(resized, "/DCTDecode"))
        XCTAssertEqual(try pdfPages(resized), [CGSize(width: 400, height: 300)])
        let png = try await convert(try save("photo.png", "public.png", [photo(800, 600)]), "pdf", options: ConversionOptions(imageResize: .half))
        XCTAssertFalse(contains(png, "/DCTDecode"), "a resized PNG stays lossless")
    }

    func testAMultiPageTIFFGivesAMultiPagePDFAndElsewhereOnlyItsFirstPage() async throws {
        let url = fixture.url("pages.tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 3, nil))
        for (width, height) in [(100, 50), (80, 80), (60, 120)] { CGImageDestinationAddImage(destination, photo(width, height), nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pdf = try await convert(url, "pdf")
        XCTAssertEqual(try pdfPages(pdf), [CGSize(width: 100, height: 50), CGSize(width: 80, height: 80), CGSize(width: 60, height: 120)])
        XCTAssertEqual(fixture.notes, [])
        let png = try readBack(try await convert(url, "png"))
        XCTAssertEqual([png.width, png.height], [100, 50])
        XCTAssertEqual(fixture.notes, [firstFrame])
        let error = try await failure(url, "half")
        XCTAssertEqual(error as? ConversionSkip, ConversionSkip(animated))
    }

    // MARK: Frames, damage, SVG

    func testAnAnimatedGIFIsSkippedByHalfAndGivesItsFirstFrameWithANoteOtherwise() async throws {
        let gif = try save("moving.gif", "com.compuserve.gif", [marked(120, 80), photo(120, 80), marked(120, 80)],
                           [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.1]])
        XCTAssertEqual(try readBack(gif).count, 3)
        let error = try await failure(gif, "half")
        XCTAssertEqual(error as? ConversionSkip, ConversionSkip(animated))
        XCTAssertEqual(fixture.notes, [])

        let png = try readBack(try await convert(gif, "png"))
        XCTAssertEqual([png.count, png.width, png.height], [1, 120, 80])
        XCTAssertTrue(isRed(pixel(png.image, 20, 20)), "the first frame")
        let pdf = try await convert(gif, "pdf")
        XCTAssertEqual(try pdfPages(pdf).count, 1)
        XCTAssertEqual(fixture.notes, [firstFrame, firstFrame])

        let still = try save("still.gif", "com.compuserve.gif", [photo(120, 80)])
        let half = try await convert(still, "half")
        XCTAssertEqual(try readBack(half).width, 60)
    }

    func testDataThatIsNoPictureFailsAsUnreadable() async throws {
        for name in ["broken.png", "broken.jpg", "broken.svg", "broken.tiff"] {
            let url = try fixture.write(name, Data("this is not a picture at all".utf8))
            for target in name == "broken.png" ? ["jpg", "pdf", "ocr", "nobg"] : ["png", "pdf"] {
                let error = try await failure(url, target)
                XCTAssertEqual(error as? ConversionFailure, ConversionFailure(unreadable), "\(name) to \(target)")
            }
        }
    }

    func testAnSVGIsDrawnWithALongSideOfAtLeast2048PixelsAndKeepsItsSizeAsAPage() async throws {
        let svg = try fixture.write("drawing.svg", Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
            <rect width="100" height="100" fill="#ff0000"/><rect x="100" width="100" height="100" fill="#0000ff"/></svg>
            """.utf8))
        let png = try readBack(try await convert(svg, "png"))
        XCTAssertEqual([png.width, png.height], [2048, 1024])
        XCTAssertTrue(isRed(pixel(png.image, 400, 500)))
        XCTAssertTrue(isBlue(pixel(png.image, 1600, 500)))
        let pages = try pdfPages(try await convert(svg, "pdf"))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].width, 200, accuracy: 0.5)
        XCTAssertEqual(pages[0].height, 100, accuracy: 0.5)
    }

    // MARK: Cancellation

    func testACancelledRequestWritesNothing() async throws {
        let png = try save("photo.png", "public.png", [photo(320, 240)])
        fixture.cancel.set()
        for target in ["jpg", "pdf", "half", "ico", "ocr", "nobg"] {
            let request = try fixture.request([png], target: target)
            do {
                _ = try await converter.convert(request, context: fixture.context())
                XCTFail("\(target) ran on")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(target): \(error)")
            }
            XCTAssertEqual(fixture.names(in: request.workFolder), [], target)
        }
    }

    func testCancellingBetweenPagesStopsThePDFAndRemovesIt() async throws {
        let url = fixture.url("pages.tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 4, nil))
        for _ in 0..<4 { CGImageDestinationAddImage(destination, photo(200, 150), nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let flag = ConversionFixture.Flag()
        let request = try fixture.request([url], target: "pdf")
        // The first page reports progress, and that is when the user cancels.
        let context = ConversionContext(isCancelled: { flag.isSet }, progress: { _ in flag.set() })
        do {
            _ = try await converter.convert(request, context: context)
            XCTFail("the PDF was finished")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(fixture.names(in: request.workFolder), [])
    }

    // MARK: WebP tools

    /// A stand-in encoder: it records its arguments and writes a small file where `-o` (or, as ffmpeg, the
    /// last argument) says.
    private func standIn(_ name: String) throws -> URL {
        try fixture.tool("tools/\(name)", """
            out=""; prev=""; last=""
            for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; last="$a"; done
            [ -z "$out" ] && out="$last"
            for a in "$@"; do printf '%s\\n' "$a"; done > "\(fixture.url("\(name).args").path)"
            printf 'RIFF0000WEBPVP8 ' > "$out"
            """)
    }

    private func arguments(_ name: String) throws -> [String] {
        try String(contentsOf: fixture.url("\(name).args"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func follows(_ arguments: [String], _ pair: [String]) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { [$0, $1] == pair }
    }

    func testWebPGoesThroughCwebpWithTheQualityAndMetadataChoiceAndLeavesNoStagedPicture() async throws {
        let cwebp = try standIn("cwebp")
        let png = try save("photo.png", "public.png", [photo(64, 48)])
        let request = try fixture.request([png], target: "webp", environment: ConversionEnvironment(cwebp: cwebp))
        let outputs = try await converter.convert(request, context: fixture.context())
        XCTAssertEqual(outputs, [request.outputURL()])
        XCTAssertEqual(fixture.names(in: request.workFolder), ["photo.webp"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.workFolder.path), ["photo.webp"], "the staged PNG is gone")
        var said = try arguments("cwebp")
        XCTAssertTrue(follows(said, ["-q", "85"]), "\(said)")
        XCTAssertTrue(follows(said, ["-metadata", "all"]), "\(said)")
        XCTAssertTrue(follows(said, ["-o", request.outputURL().path]), "\(said)")
        XCTAssertTrue(said.contains { $0.hasSuffix(".png") && $0.hasPrefix(request.workFolder.path) }, "\(said)")

        _ = try await convert(png, "webp", options: ConversionOptions(imageQuality: 0.5, keepMetadata: false), environment: ConversionEnvironment(cwebp: cwebp))
        said = try arguments("cwebp")
        XCTAssertTrue(follows(said, ["-q", "50"]), "\(said)")
        XCTAssertTrue(follows(said, ["-metadata", "icc"]), "\(said)")

        let ffmpeg = try standIn("ffmpeg")
        _ = try await convert(png, "webp", environment: ConversionEnvironment(ffmpeg: ffmpeg, encoders: ["libwebp"]))
        said = try arguments("ffmpeg")
        XCTAssertTrue(follows(said, ["-c:v", "libwebp"]), "\(said)")
        XCTAssertTrue(follows(said, ["-quality", "85"]), "\(said)")
    }

    func testAFailingWebPToolFailsWithWhatItSaidAndACancelStopsIt() async throws {
        let png = try save("photo.png", "public.png", [photo(64, 48)])
        let broken = try fixture.tool("tools/broken", "echo 'Error! Could not process file' >&2\nexit 2")
        let error = try await failure(png, "webp", environment: ConversionEnvironment(cwebp: broken))
        XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Dönüştürülemedi: %@", detail: "Error! Could not process file"))

        let started = fixture.url("started")
        let slow = try fixture.tool("tools/slow", "touch '\(started.path)'\nexec sleep 30")
        let request = try fixture.request([png], target: "webp", environment: ConversionEnvironment(cwebp: slow))
        let task = fixture.start(converter, request)
        let begin = Date()
        while !FileManager.default.fileExists(atPath: started.path) {
            XCTAssertLessThan(Date().timeIntervalSince(begin), 20, "the tool never started")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancelled = Date()
        fixture.cancelAll()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
    }

    func testTheInstalledCwebpWritesAWebPThatKeepsAlpha() async throws {
        let environment = ConversionEnvironment.detect(in: ["/opt/homebrew/bin", "/usr/local/bin"])
        guard environment.cwebp != nil else { throw XCTSkip("cwebp is not installed") }
        let tiff = try save("cutout.tiff", "public.tiff", [photo(200, 100, transparentLeft: true)])
        let back = try readBack(try await convert(tiff, "webp", environment: ConversionEnvironment(cwebp: environment.cwebp)))
        XCTAssertEqual(back.type, "org.webmproject.webp")
        XCTAssertEqual([back.width, back.height], [200, 100])
        XCTAssertLessThan(pixel(back.image, 20, 50)[3], 10)
        XCTAssertGreaterThan(pixel(back.image, 180, 50)[3], 245)
    }

    // MARK: Through the engine

    func testTheEnginePublishesBesideTheSourceAndSkipsACompressThatWouldGrow() async throws {
        let engine = fixture.engine([converter])
        let png = try save("photo.png", "public.png", [photo(320, 240)])
        let converted = await engine.run(try fixture.job([png], target: "jpg"), moveToTrash: fixture.moveToTrash)
        XCTAssertEqual(converted.outcomes, [.converted([fixture.url("photo.jpg")])])

        let half = await engine.run(try fixture.job([fixture.url("photo.jpg")], target: "half", suffix: "küçük"), moveToTrash: fixture.moveToTrash)
        XCTAssertEqual(half.converted, 1)
        let published = try XCTUnwrap(half.outputs.first)
        XCTAssertEqual(published.lastPathComponent, "photo küçük.jpg")
        XCTAssertEqual(try readBack(published).width, 160)

        let rough = try save("rough.jpg", "public.jpeg", [photo(320, 240)], [kCGImageDestinationLossyCompressionQuality as String: 0.2])
        let compressed = await engine.run(try fixture.job([rough], target: "compress"), moveToTrash: fixture.moveToTrash)
        XCTAssertEqual(compressed.outcomes, [.skipped("Zaten yeterince küçük.")])
        XCTAssertFalse(fixture.names(in: fixture.root).contains { $0.hasPrefix("rough ") }, "\(fixture.names(in: fixture.root))")
    }

    // MARK: Vision (opt-in)

    private func requireVision() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BSTOEQ_VISION_TESTS"] == "1", "Vision tests run with BSTOEQ_VISION_TESTS=1")
    }

    private func gradient(_ width: Int, _ height: Int) -> CGContext {
        let canvas = context(width, height)
        let colours = [CGColor(srgbRed: 0.55, green: 0.75, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.3, green: 0.6, blue: 0.3, alpha: 1)] as CFArray
        canvas.drawLinearGradient(CGGradient(colorsSpace: srgb, colors: colours, locations: [0, 1])!, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        return canvas
    }

    private func draw(_ text: String, font: String, size: CGFloat, at point: CGPoint, in canvas: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
                          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)]
        canvas.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), canvas)
    }

    func testRemovingTheBackgroundKeepsTheSubjectOnTransparency() async throws {
        try requireVision()
        let canvas = gradient(1024, 768)
        draw("🐕", font: "Apple Color Emoji", size: 420, at: CGPoint(x: 280, y: 190), in: canvas)
        let jpg = try save("dog.jpg", "public.jpeg", [canvas.makeImage()!])
        let output = try await convert(jpg, "nobg")
        XCTAssertEqual(output.pathExtension, "png")
        let back = try readBack(output)
        XCTAssertEqual([back.width, back.height], [1024, 768])
        XCTAssertLessThan(pixel(back.image, 5, 5)[3], 10, "the background is gone")
        // Sampled every 8 pixels: the dog covers about a tenth of the picture, opaque, and nothing else stays.
        var opaque = 0, clear = 0
        for y in stride(from: 0, to: 768, by: 8) {
            for x in stride(from: 0, to: 1024, by: 8) {
                let alpha = pixel(back.image, x, y)[3]
                if alpha > 224 { opaque += 1 } else if alpha < 8 { clear += 1 }
            }
        }
        XCTAssertGreaterThan(opaque, 600, "the subject stays")
        XCTAssertGreaterThan(clear, 10_000, "the background is gone")
        XCTAssertGreaterThan(pixel(back.image, 500, 430)[3], 224, "the body")
    }

    func testRemovingTheBackgroundOfAPictureWithoutASubjectFails() async throws {
        try requireVision()
        let png = try save("sky.png", "public.png", [gradient(640, 480).makeImage()!])
        let error = try await failure(png, "nobg")
        XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Görüntüde öne çıkan bir nesne bulunamadı."))
    }

    func testRecognizingTextReadsTheLinesAndAPictureWithoutTextFails() async throws {
        try requireVision()
        let canvas = context(1500, 300)
        canvas.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 1500, height: 300))
        draw("Merhaba dünya, güneşli bir gün.", font: "Helvetica", size: 48, at: CGPoint(x: 40, y: 190), in: canvas)
        draw("The quick brown fox jumps over the lazy dog.", font: "Helvetica", size: 48, at: CGPoint(x: 40, y: 80), in: canvas)
        let png = try save("text.png", "public.png", [canvas.makeImage()!])
        let output = try await convert(png, "ocr")
        XCTAssertEqual(output.pathExtension, "txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("Merhaba"), text)
        XCTAssertTrue(text.contains("quick brown fox"), text)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Merhaba")).lowerBound, try XCTUnwrap(text.range(of: "quick")).lowerBound, "top line first")

        let blank = context(400, 300)
        blank.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        blank.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let error = try await failure(try save("blank.png", "public.png", [blank.makeImage()!]), "ocr")
        XCTAssertEqual(error as? ConversionFailure, ConversionFailure("Görüntüde metin bulunamadı."))
    }
}
