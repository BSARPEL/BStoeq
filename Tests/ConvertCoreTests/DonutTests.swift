import CoreGraphics
import XCTest
@testable import ConvertCore

/// The ring's model: which slices a set of files gets and where a point lands. Files are judged by
/// their names; the few that must exist are made in the fixture.
final class DonutTests: XCTestCase {
    private var fixture: ConversionFixture!

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "donut") }
    override func tearDownWithError() throws { fixture.remove() }

    private func urls(_ names: String...) -> [URL] { names.map { fixture.url($0) } }

    /// The faces as an engine with one accommodating converter would give them.
    private func faces(_ urls: [URL], converter: ConversionFixture.Fake = ConversionFixture.Fake(),
                       environment: ConversionEnvironment = ConversionEnvironment()) -> DonutFaces {
        fixture.engine([converter], environment: environment).faces(for: urls)
    }
    private func ids(_ slices: [DonutSlice]) -> [String] { slices.map(\.id) }
    private func slice(_ faces: DonutFaces, _ id: String) throws -> DonutSlice {
        try XCTUnwrap((faces.front + faces.back).first { $0.id == id }, id)
    }

    // MARK: Toolbars

    func testEveryFamilyHasItsToolbarInTheContractsOrder() {
        let expected: [(String, [String], [String])] = [
            ("foto.heic", ["jpg", "png", "pdf", "pdf.merge", "half", "compress", "heic"],
             ["nobg", "ocr", "webp", "avif", "tiff", "action.zip"]),
            ("rapor.pdf", ["jpg", "png", "txt", "pdf.split", "pdf.merge", "compress"],
             ["ocr", "docx", "tiff", "action.zip", "action.copyPath", "action.airDrop", "action.openConverter"]),
            ("mektup.docx", ["pdf", "docx", "rtf", "txt", "html", "odt"], ["action.zip", "action.copyPath", "action.airDrop", "action.openConverter"]),
            ("tablo.csv", ["csv", "xlsx", "json", "tsv", "plist"], ["action.zip", "action.copyPath", "action.openConverter"]),
            ("film.mov", ["mp4", "mp4.720p", "mov", "gif", "m4a", "mp3"], ["mp4.hevc", "mute", "compress", "webm", "mkv", "wav", "action.zip"]),
            ("şarkı.flac", ["mp3", "m4a", "wav", "flac", "aiff"], ["mp3.128k", "alac", "opus", "m4r", "action.zip"]),
            ("altyazı.srt", ["srt", "vtt"], ["action.zip", "action.copyPath"])
        ]
        for (name, front, back) in expected {
            let faces = faces(urls(name))
            XCTAssertEqual(ids(faces.front), front + ["flip"], name)
            XCTAssertEqual(ids(faces.back), back + ["flip"], name)
            XCTAssertLessThanOrEqual(faces.front.count, DonutToolbar.faceLimit + 1)
            XCTAssertLessThanOrEqual(faces.back.count, DonutToolbar.faceLimit + 1)
        }
        XCTAssertEqual(DonutToolbar.faceLimit, 7)
    }

    func testArchivesFoldersUnknownAndMixedFilesGetTheirOwnToolbars() throws {
        let archive = faces(urls("yedek.zip", "eski.tar.gz"))
        XCTAssertEqual(ids(archive.front), ["action.extract", "action.openArchive", "action.copyPath", "action.airDrop"])
        XCTAssertTrue(archive.back.isEmpty, "Nothing on the back: no slice to turn the ring over")
        XCTAssertEqual(archive.front.map(\.fitting), [2, 2, 2, 2])
        XCTAssertTrue(archive.front.allSatisfy(\.enabled))

        let folder = faces([try fixture.folder("Belgeler")])
        XCTAssertEqual(ids(folder.front), ["action.zip", "action.sevenZip", "action.copyPath"])
        XCTAssertTrue(folder.back.isEmpty)

        let unknown = faces(urls("veri.xyz", "adsız"))
        XCTAssertEqual(ids(unknown.front), ["action.zip", "action.copyPath", "action.airDrop"])
        XCTAssertTrue(unknown.back.isEmpty)

        let mixed = faces(urls("foto.png", "rapor.pdf", "not.txt"))
        XCTAssertEqual(ids(mixed.front), ["pdf", "pdf.merge", "png", "jpg", "txt", "action.zip", "flip"])
        XCTAssertEqual(ids(mixed.back), ["action.copyPath", "action.airDrop", "action.openConverter", "flip"])
        XCTAssertEqual(ids(faces(urls("foto.png", "bilinmeyen.xyz")).front), ids(mixed.front), "Recognised and unrecognised together are mixed")

        XCTAssertEqual(DonutToolbar.family(of: urls("a.png", "b.heic")), .image)
        XCTAssertNil(DonutToolbar.family(of: urls("a.png", "b.pdf")))
        XCTAssertEqual(DonutToolbar.family(of: urls("a.xyz")), .other)
        XCTAssertEqual(DonutToolbar.family(of: []), .other)
        XCTAssertEqual(faces([]), DonutFaces(front: [], back: []))
    }

    // MARK: Slice rules

    func testASliceKeepsItsSlotWhateverTheFilesAre() throws {
        let one = faces(urls("a.png"))
        let three = faces(urls("a.png", "b.png", "c.png"))
        let two = faces(urls("a.jpg", "b.png"))
        XCTAssertEqual(ids(one.front), ids(three.front))
        XCTAssertEqual(ids(one.front), ids(two.front))
        XCTAssertEqual(ids(one.back), ids(two.back))

        // One PNG: PNG is greyed in place, and a merge needs a second file.
        let png = try slice(one, "png")
        XCTAssertFalse(png.enabled)
        XCTAssertEqual(png.reasonKey, "Dosya zaten bu biçimde.")
        XCTAssertEqual(png.fitting, 0)
        let merge = try slice(one, "pdf.merge")
        XCTAssertFalse(merge.enabled)
        XCTAssertEqual(merge.reasonKey, "Birleştirmek için en az iki dosya gerekir.")
        XCTAssertEqual(merge.fitting, 1)
        let jpg = try slice(one, "jpg")
        XCTAssertTrue(jpg.enabled)
        XCTAssertNil(jpg.reasonKey)
        XCTAssertEqual(jpg.fitting, 1)
        XCTAssertEqual(jpg.content, .target(try fixture.target("jpg")))
        XCTAssertEqual([jpg.title, jpg.shortTitle, jpg.symbol], ["JPG", "JPG", "photo"])
        XCTAssertFalse(jpg.titleIsKey)

        // A JPG and a PNG: both format slices work for one file each, the merge for both.
        XCTAssertEqual(try slice(two, "png").fitting, 1)
        XCTAssertTrue(try slice(two, "png").enabled)
        XCTAssertEqual(try slice(two, "jpg").fitting, 1)
        XCTAssertEqual(try slice(two, "pdf.merge").fitting, 2)
        XCTAssertTrue(try slice(two, "pdf.merge").enabled)
        let half = try slice(two, "half")
        XCTAssertTrue(half.titleIsKey)
        XCTAssertEqual([half.title, half.shortTitle], ["Yarı boyuta küçült", "Yarı boyut"])
    }

    func testOnlyATargetNobodyClaimsIsLeftOutAndAGreySliceSaysWhy() throws {
        // A converter for images that needs cwebp for WebP, does no AVIF at all and cannot read PSD.
        let converter = ConversionFixture.Fake(accepts: { target, source, environment in
            guard source.family == .image, source.id != "psd", target.id != source.id, target.id != "avif" else { return .unsupported }
            if target.id == "webp" { return environment.cwebp == nil ? .needs("cwebp") : .available }
            return .available
        }, caveat: { target, _ in target.id == "ocr" ? "Metin sayfa görüntülerinden tanındı (OCR); hatalar olabilir." : nil })

        let without = faces(urls("a.png"), converter: converter)
        XCTAssertEqual(ids(without.back), ["nobg", "ocr", "webp", "tiff", "action.zip", "flip"], "AVIF is claimed by nobody and gone")
        let webp = try slice(without, "webp")
        XCTAssertFalse(webp.enabled)
        XCTAssertEqual(webp.reasonKey, "Bu dönüştürme için %@ gerekli. Kurulum adımı Ayarlar → Dönüştürücü’de.")
        XCTAssertEqual(webp.reasonDetail, "cwebp")
        XCTAssertNil(webp.noteKey)
        let ocr = try slice(without, "ocr")
        XCTAssertTrue(ocr.enabled)
        XCTAssertEqual(ocr.noteKey, "Metin sayfa görüntülerinden tanındı (OCR); hatalar olabilir.", "An enabled slice carries the offer's note")
        XCTAssertNil(ocr.reasonDetail)

        let with = faces(urls("a.png"), converter: converter, environment: ConversionEnvironment(cwebp: URL(fileURLWithPath: "/opt/homebrew/bin/cwebp")))
        XCTAssertTrue(try slice(with, "webp").enabled)

        // A file the converter cannot read keeps every slot, greyed.
        let unreadable = faces(urls("katmanlar.psd"), converter: converter)
        XCTAssertEqual(ids(unreadable.front), ["jpg", "png", "pdf", "pdf.merge", "half", "compress", "heic", "flip"])
        for id in ["jpg", "png", "pdf", "pdf.merge", "half", "compress", "heic", "nobg", "tiff"] {
            let slice = try slice(unreadable, id)
            XCTAssertFalse(slice.enabled, id)
            XCTAssertEqual(slice.reasonKey, "Bu dosya bu biçime dönüştürülemiyor.", id)
            XCTAssertEqual(slice.fitting, 0)
        }
        XCTAssertEqual(try slice(unreadable, "webp").reasonKey, "Bu dosya bu biçime dönüştürülemiyor.",
                       "A missing tool is the reason only for files it would help")

        // Nothing at all claimed: the targets go, the actions stay and move to the front.
        let none = fixture.engine([]).faces(for: urls("a.png"))
        XCTAssertEqual(ids(none.front), ["action.zip"], "A face with nothing on it is not the front")
        XCTAssertTrue(none.back.isEmpty)
        let documents = fixture.engine([]).faces(for: urls("a.docx"))
        XCTAssertEqual(ids(documents.front), ["action.zip", "action.copyPath", "action.airDrop", "action.openConverter"])
        XCTAssertTrue(documents.back.isEmpty)
    }

    func testFacesArePureGivenOffersAndClaims() throws {
        let files = urls("a.mp4", "b.mov")
        let mp4 = try fixture.target("mp4"), small = try fixture.target("mp4.720p"), mp3 = try fixture.target("mp3")
        let offers = [TargetOffer(target: mp4, availability: .available, fitting: 1, total: 2, noteKey: "not"),
                      TargetOffer(target: small, availability: .available, fitting: 2, total: 2),
                      TargetOffer(target: mp3, availability: .needs("ffmpeg"), fitting: 0, total: 2)]
        let faces = DonutToolbar.faces(for: files, offers: offers, claimed: { ["mp4", "mp4.720p", "mp3", "mov"].contains($0.id) })
        XCTAssertEqual(ids(faces.front), ["mp4", "mp4.720p", "mov", "mp3", "flip"], "gif and m4a are unclaimed")
        XCTAssertEqual(ids(faces.back), ["action.zip", "flip"])
        XCTAssertEqual(try slice(faces, "mp4").fitting, 1)
        XCTAssertEqual(try slice(faces, "mp4").noteKey, "not")
        XCTAssertEqual(try slice(faces, "mp4.720p").fitting, 2)
        XCTAssertEqual(try slice(faces, "mov").reasonKey, "Bu dosya bu biçime dönüştürülemiyor.", "Claimed, not offered, and not every file is a MOV")
        XCTAssertEqual(try slice(faces, "mp3").reasonDetail, "ffmpeg")
        let same = DonutToolbar.faces(for: urls("a.mov", "b.MOV"), offers: [], claimed: { $0.id == "mov" })
        XCTAssertEqual(try slice(same, "mov").reasonKey, "Dosya zaten bu biçimde.")
    }

    func testActionsFitWhatTheyCanActOn() throws {
        let apart = faces(urls("bir/a.png", "iki/b.png"))
        let zip = try slice(apart, "action.zip")
        XCTAssertFalse(zip.enabled)
        XCTAssertEqual(zip.reasonKey, "Dosyalar aynı klasörde olmalı.")
        XCTAssertEqual(zip.fitting, 0)
        let together = try slice(faces(urls("bir/a.png", "bir/b.png")), "action.zip")
        XCTAssertTrue(together.enabled)
        XCTAssertEqual(together.fitting, 2)
        XCTAssertEqual(together.content, .action(.zip))

        let folders = faces([try fixture.folder("bir/A"), try fixture.folder("iki/B")])
        XCTAssertFalse(try slice(folders, "action.sevenZip").enabled)
        XCTAssertEqual(try slice(folders, "action.sevenZip").reasonKey, "Dosyalar aynı klasörde olmalı.")
        XCTAssertTrue(try slice(folders, "action.copyPath").enabled)
        XCTAssertEqual(try slice(folders, "action.copyPath").fitting, 2)

        let documents = faces(urls("bir/a.docx", "iki/b.rtf"))
        for id in ["action.copyPath", "action.airDrop", "action.openConverter"] {
            XCTAssertTrue(try slice(documents, id).enabled, id)
            XCTAssertEqual(try slice(documents, id).fitting, 2, id)
        }
    }

    func testActionsAndTheFlipSliceCarryTheContractsTitles() {
        let expected: [DonutAction: [String]] = [
            .zip: ["Tek ZIP’te topla", "ZIP", "doc.zipper"],
            .sevenZip: ["Tek 7Z’de topla", "7Z", "doc.zipper"],
            .extract: ["Arşivi çıkart", "Çıkart", "arrow.up.bin"],
            .openArchive: ["Arşiv yöneticisinde aç", "Arşivi aç", "archivebox"],
            .copyPath: ["Yolu kopyala", "Dosya yolu", "doc.on.clipboard"],
            .airDrop: ["AirDrop ile gönder", "AirDrop", "dot.radiowaves.left.and.right"],
            .openConverter: ["Dönüştürücüde aç", "Tümü", "slider.horizontal.3"]
        ]
        XCTAssertEqual(DonutAction.allCases.count, expected.count)
        for action in DonutAction.allCases {
            XCTAssertEqual([action.title, action.shortTitle, action.symbol], expected[action], action.rawValue)
            XCTAssertTrue(action.titleIsKey)
        }
        XCTAssertEqual([DonutSlice.flip.id, DonutSlice.flip.shortTitle, DonutSlice.flip.symbol], ["flip", "Diğerleri", "ellipsis"])
        XCTAssertEqual(DonutSlice.flip.content, .flip)
        XCTAssertTrue(DonutSlice.flip.enabled && DonutSlice.flip.titleIsKey)
    }

    // MARK: Geometry

    func testHitTestingFindsHubSlicesRimAndOutside() {
        let ring = DonutGeometry(count: 8)
        XCTAssertEqual([ring.outerRadius, ring.innerRadius, ring.margin], [140, 58, 28])
        XCTAssertEqual(ring.extent, 336)
        XCTAssertEqual(ring.hit(.zero), .hub)
        XCTAssertEqual(ring.hit(CGPoint(x: 0, y: 57.9)), .hub)
        XCTAssertEqual(ring.hit(CGPoint(x: 0, y: 58)), .slice(0), "The hub ends where the slices begin")
        XCTAssertEqual(ring.hit(CGPoint(x: 0, y: 100)), .slice(0), "Slice 0 is centred at 12 o'clock")
        XCTAssertEqual(ring.hit(CGPoint(x: 70.7, y: 70.7)), .slice(1), "Slices run clockwise")
        XCTAssertEqual(ring.hit(CGPoint(x: 100, y: 0)), .slice(2))
        XCTAssertEqual(ring.hit(CGPoint(x: 0, y: -100)), .slice(4))
        XCTAssertEqual(ring.hit(CGPoint(x: -100, y: 0)), .slice(6))
        XCTAssertEqual(ring.hit(CGPoint(x: -70.7, y: 70.7)), .slice(7))
        XCTAssertEqual(ring.hit(CGPoint(x: -10, y: 100)), .slice(0), "Slice 0 reaches to both sides of 12 o'clock")
        XCTAssertEqual(ring.hit(CGPoint(x: 0, y: 140)), .slice(0))
        XCTAssertEqual(ring.hit(CGPoint(x: 0, y: 140.5)), .rim, "A near miss lands on the band, not on a slice")
        XCTAssertEqual(ring.hit(CGPoint(x: 0, y: 168)), .rim)
        XCTAssertEqual(ring.hit(CGPoint(x: 0, y: 168.5)), .outside)
        XCTAssertEqual(ring.hit(CGPoint(x: 110, y: 110)), .rim)
        XCTAssertEqual(ring.hit(CGPoint(x: 400, y: -400)), .outside)
        XCTAssertEqual(ring.hit(CGPoint(x: CGFloat.nan, y: 0)), .outside)

        // Every direction belongs to the slice whose middle is nearest.
        for count in 1...8 {
            let ring = DonutGeometry(count: count)
            for step in 0..<720 {
                let angle = CGFloat(step) * .pi / 360
                let expected = Int((angle / ring.sweep).rounded()) % count
                // Stay off the exact borders, where rounding decides.
                guard abs((angle / ring.sweep).rounded() - angle / ring.sweep) < 0.49 else { continue }
                XCTAssertEqual(ring.hit(CGPoint(x: 100 * sin(angle), y: 100 * cos(angle))), .slice(expected), "\(count) slices, step \(step)")
            }
        }
        XCTAssertEqual(DonutGeometry(count: 0).hit(CGPoint(x: 0, y: 100)), .rim, "A ring without slices refuses everywhere")
        XCTAssertEqual(DonutGeometry(count: 0).hit(.zero), .hub)
        let small = DonutGeometry(count: 3, outerRadius: 50, innerRadius: 10, margin: 5)
        XCTAssertEqual(small.hit(CGPoint(x: 10, y: -30)), .slice(1))
        XCTAssertEqual(small.hit(CGPoint(x: -10, y: -30)), .slice(2))
        XCTAssertEqual(small.hit(CGPoint(x: 0, y: 9)), .hub)
        XCTAssertEqual(small.hit(CGPoint(x: 0, y: 53)), .rim)
        XCTAssertEqual(small.hit(CGPoint(x: 0, y: 56)), .outside)
        XCTAssertEqual(small.extent, 110)
    }

    func testAnglesAndLabelPointsFollowTheSlices() {
        let ring = DonutGeometry(count: 4)
        XCTAssertEqual(ring.sweep, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(ring.midAngle(of: 0), 0)
        XCTAssertEqual(ring.midAngle(of: 1), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(ring.midAngle(of: 3), 3 * .pi / 2, accuracy: 1e-9)
        let top = ring.labelPoint(of: 0), right = ring.labelPoint(of: 1), bottom = ring.labelPoint(of: 2), left = ring.labelPoint(of: 3)
        XCTAssertEqual(top.x, 0, accuracy: 1e-9); XCTAssertEqual(top.y, 99, accuracy: 1e-9)
        XCTAssertEqual(right.x, 99, accuracy: 1e-9); XCTAssertEqual(right.y, 0, accuracy: 1e-9)
        XCTAssertEqual(bottom.x, 0, accuracy: 1e-9); XCTAssertEqual(bottom.y, -99, accuracy: 1e-9)
        XCTAssertEqual(left.x, -99, accuracy: 1e-9); XCTAssertEqual(left.y, 0, accuracy: 1e-9)
        for count in 1...8 {
            let ring = DonutGeometry(count: count)
            for index in 0..<count { XCTAssertEqual(ring.hit(ring.labelPoint(of: index)), .slice(index), "A label sits on its own slice") }
        }
    }

    func testTheRingStaysInsideTheScreen() {
        let screen = CGRect(x: -1440, y: 120, width: 1440, height: 860)
        let extent = DonutGeometry(count: 6).extent
        XCTAssertEqual(DonutGeometry.centre(near: CGPoint(x: -700, y: 500), extent: extent, in: screen), CGPoint(x: -700, y: 500),
                       "A pointer with room around it is the centre")
        for pointer in [CGPoint(x: -1440, y: 120), CGPoint(x: -1, y: 979), CGPoint(x: -2000, y: 5000), CGPoint(x: 300, y: -40)] {
            let centre = DonutGeometry.centre(near: pointer, extent: extent, in: screen)
            let frame = CGRect(x: centre.x - extent / 2, y: centre.y - extent / 2, width: extent, height: extent)
            XCTAssertTrue(screen.contains(frame), "\(pointer)")
        }
        XCTAssertEqual(DonutGeometry.centre(near: CGPoint(x: -1440, y: 120), extent: extent, in: screen), CGPoint(x: -1272, y: 288))
        let small = CGRect(x: 100, y: 100, width: 200, height: 1000)
        let centre = DonutGeometry.centre(near: CGPoint(x: 0, y: 0), extent: extent, in: small)
        XCTAssertEqual(centre, CGPoint(x: 200, y: 268), "A screen narrower than the ring gets it centred")
    }
}
