import XCTest
@testable import ConvertCore

/// The engine picks the first converter that answers; two answering the same pair would make
/// the result depend on the order of a list.
final class StandardConvertersTests: XCTestCase {
    func testAtMostOneConverterClaimsEachSourceAndTarget() {
        let full = ConversionEnvironment(ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                                         ffprobe: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
                                         encoders: ["libmp3lame", "libvorbis", "libopus", "libvpx-vp9", "libx264", "libx265", "aac", "libwebp"],
                                         cwebp: URL(fileURLWithPath: "/opt/homebrew/bin/cwebp"))
        let converters = ConversionEngine.standardConverters()
        for environment in [ConversionEnvironment(), full] {
            for format in FormatRegistry.all {
                for target in TargetCatalog.all {
                    let claimants = converters.filter { $0.availability(of: target, for: format, in: environment) == .available }
                    XCTAssertLessThanOrEqual(claimants.count, 1, "\(format.id) → \(target.id): \(claimants.map { String(describing: type(of: $0)) })")
                }
            }
        }
    }

    func testEveryToolbarTargetIsClaimedForSomeFormatOfItsFamily() {
        let environment = ConversionEnvironment()
        let engine = ConversionEngine(converters: ConversionEngine.standardConverters(), environment: environment,
                                      limiter: ConversionLimiter())
        let claimedSomewhere = TargetCatalog.all.filter { target in
            FormatRegistry.all.contains { format in
                engine.converters.contains { $0.availability(of: target, for: format, in: environment) != .unsupported }
            }
        }
        // Each everyday target must work on a Mac with nothing extra installed, or say which tool it needs.
        for id in ["jpg", "png", "heic", "pdf", "pdf.merge", "pdf.split", "half", "compress", "txt", "docx", "csv", "xlsx",
                   "mp4", "mp4.720p", "mov", "gif", "m4a", "mp3", "wav", "flac", "srt", "vtt", "ocr", "nobg"] {
            XCTAssertTrue(claimedSomewhere.contains { $0.id == id }, id)
        }
    }
}
