import ConvertCore
import CoreGraphics
import XCTest

/// Sees ConvertCore the way the app and the later units see it: through a plain import. Every public
/// value type is built here and every public entry point called, so an initialiser or a `public` that
/// is missing fails in this file and not in somebody else's.
final class PublicSurfaceTests: XCTestCase {
    private var fixture: ConversionFixture!

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "surface") }
    override func tearDownWithError() throws { fixture.remove() }

    /// A converter written outside the module, with nothing but the public contract.
    private struct Upper: Converter {
        func availability(of target: ConversionTarget, for source: FileFormat, in environment: ConversionEnvironment) -> TargetAvailability {
            source.id == "txt" && target.id == "md" ? .available : target.id == "docx" ? .needs("pandoc") : .unsupported
        }
        func convert(_ request: ConversionRequest, context: ConversionContext) async throws -> [URL] {
            try await ConversionWork.run {
                try context.checkCancelled()
                guard let text = TextEncoding.decode(try Data(contentsOf: request.sources[0])) else { throw ConversionFailure("Bu belge okunamadı.") }
                if text.isEmpty { throw ConversionSkip("Belge boş.") }
                context.progress(0.5)
                context.note("Yalnızca metin aktarılır; düzen ve görseller korunmaz.")
                try Data(text.uppercased().utf8).write(to: request.outputURL())
                context.progress(1)
                return [request.outputURL()]
            }
        }
    }

    func testFormatsAndTargetsCanBeBuiltAndLookedUp() throws {
        let format = FileFormat(id: "xyz", family: .other, label: "XYZ", extensions: ["xyz", "xy"])
        XCTAssertEqual([format.id, format.label], ["xyz", "XYZ"])
        XCTAssertEqual(format.family, FileFamily.other)
        XCTAssertEqual(format.extensions, ["xyz", "xy"])
        XCTAssertEqual(FileFamily.allCases.count, 10)
        XCTAssertFalse(FormatRegistry.all.isEmpty)
        XCTAssertEqual(FormatRegistry.format(id: "png")?.family, .image)
        XCTAssertEqual(FormatRegistry.format(of: fixture.url("a.tar.gz"))?.id, "tar.gz")
        XCTAssertEqual(FormatRegistry.folder.family, .folder)

        let target = ConversionTarget(id: "md", kind: .convert, title: "MD", shortTitle: "MD", titleIsKey: false, symbol: "doc.text",
                                      format: "md", combines: false, minimumInputs: 1, suffixKey: nil, fixedSuffix: nil,
                                      overrides: OptionOverrides())
        XCTAssertEqual(target, ConversionTarget(id: "md", title: "MD", symbol: "doc.text", format: "md"))
        XCTAssertEqual(ConversionTarget.Kind.tool.rawValue, "tool")
        XCTAssertEqual([target.id, target.title, target.shortTitle, target.symbol, target.format], ["md", "MD", "MD", "doc.text", "md"])
        XCTAssertNotNil(TargetCatalog.target(id: "mp4.720p"))
        XCTAssertFalse(TargetCatalog.all.isEmpty)
        XCTAssertEqual(TargetAvailability.needs("ffmpeg"), .needs("ffmpeg"))
        XCTAssertNotEqual(TargetAvailability.available, .unsupported)

        let environment = ConversionEnvironment(ffmpeg: URL(fileURLWithPath: "/x/ffmpeg"), ffprobe: nil, encoders: ["libx264"], cwebp: nil)
        XCTAssertEqual(environment.encoders, ["libx264"])
        XCTAssertNil(environment.ffprobe); XCTAssertNil(environment.cwebp); XCTAssertNotNil(environment.ffmpeg)
        XCTAssertEqual(ConversionEnvironment(), ConversionEnvironment.detect(in: [fixture.url("empty").path]))
        XCTAssertEqual(ConversionEnvironment.installCommand(for: "ffmpeg"), "brew install ffmpeg")
    }

    func testOptionsAndSettingsCanBeBuiltChangedAndStored() throws {
        var options = ConversionOptions()
        options = ConversionOptions(imageQuality: 0.8, keepMetadata: false, pdfDPI: 300, pdfCompression: .light, paper: .a4,
                                    videoQuality: .high, videoCodec: .hevc, audioBitrate: 256, location: .subfolder("Çıktı"),
                                    trashOriginals: true, imageResize: ImageResize(mode: .longEdge, value: 1920), videoMaxHeight: 1080,
                                    removeAudio: true)
        options.imageQuality = 0.5; options.keepMetadata = true; options.pdfDPI = 150; options.pdfCompression = .strong
        options.paper = PaperSize.regional(Locale(identifier: "en_US")); options.videoQuality = .small; options.videoCodec = .h264
        options.audioBitrate = 128; options.location = .folder("/tmp/x"); options.trashOriginals = false
        options.imageResize = .quarter; options.videoMaxHeight = ConversionOptions.videoHeights[2]; options.removeAudio = false
        options.normalize()
        XCTAssertEqual(options.paper, .letter)
        XCTAssertEqual(options.applying(OptionOverrides(imageQuality: 0.7, imageResize: .half, videoQuality: .small, videoMaxHeight: 720,
                                                        videoCodec: .hevc, removeAudio: true, audioBitrate: 96)).audioBitrate, 96)
        var overrides = OptionOverrides()
        overrides.imageQuality = 0.3; overrides.imageResize = .long1280; overrides.videoQuality = .high; overrides.videoMaxHeight = 480
        overrides.videoCodec = .h264; overrides.removeAudio = false; overrides.audioBitrate = 64
        XCTAssertEqual(options.applying(overrides).videoMaxHeight, 480)

        XCTAssertEqual(ImageResize.presets.count, 5)
        XCTAssertEqual(ImageResize.Mode.percent.rawValue, "percent")
        var resize = ImageResize(mode: .percent, value: 400)
        resize.normalize()
        XCTAssertEqual(resize.value, 100)
        XCTAssertEqual(ImageResize.half.pixelSize(width: 100, height: 60).width, 50)
        XCTAssertEqual([ImageResize.original, .half, .quarter, .long1920, .long1280].count, 5)
        XCTAssertTrue(OutputLocation.isSafeName("Dönüştürülenler"))
        XCTAssertEqual(Set([OutputLocation.besideSource, .subfolder("a"), .folder("/a")]).count, 3)

        XCTAssertFalse(ConversionQuality.allCases.map(\.titleKey).contains(""))
        XCTAssertFalse(CompressionLevel.allCases.map(\.titleKey).contains(""))
        XCTAssertFalse(PaperSize.allCases.map(\.titleKey).contains(""))
        XCTAssertGreaterThan(PaperSize.a4.size.height, PaperSize.letter.size.height)
        XCTAssertFalse(ConversionVideoCodec.allCases.map(\.title).contains(""))
        XCTAssertEqual(DonutTrigger.allCases.map(\.glyph).joined(), "⌥⇧")
        XCTAssertFalse(DonutTrigger.allCases.map(\.titleKey).contains(""))
        XCTAssertNotEqual(DonutTrigger.option.modifierMask, DonutTrigger.shift.modifierMask)

        var rule = WatchRule(folder: "/Users/x/Gelen", targetID: "png", outputFolder: "Dönüştürülenler")
        rule = WatchRule(id: rule.id, folder: rule.folder, targetID: "jpg", outputFolder: rule.outputFolder, enabled: false)
        rule.enabled = true
        var settings = ConverterSettings()
        settings = ConverterSettings(donutEnabled: false, trigger: .shift, finderOnly: false, options: options, watch: [rule])
        settings.donutEnabled = true; settings.trigger = .option; settings.finderOnly = true
        settings.watch.append(WatchRule(folder: "relative", targetID: "png", outputFolder: "x"))
        settings.normalize()
        XCTAssertEqual(settings.watch, [rule])
        XCTAssertEqual(ConverterSettings.watchLimit, 20)
        XCTAssertEqual(try JSONDecoder().decode(ConverterSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(try JSONDecoder().decode(WatchRule.self, from: JSONEncoder().encode(rule)), rule)
        XCTAssertEqual(try JSONDecoder().decode(ConversionOptions.self, from: JSONEncoder().encode(options)), options)
        XCTAssertEqual(Set([rule, rule]).count, 1)
    }

    func testAConverterFromOutsideTheModuleRunsThroughTheEngine() async throws {
        let source = try fixture.write("in/not.txt", Data("merhaba ğış".utf8))
        let empty = try fixture.write("in/boş.txt", Data())
        let target = ConversionTarget(id: "md", title: "MD", format: "md")
        let limiter = ConversionLimiter(media: 1, other: 2)
        let engine = ConversionEngine(converters: [Upper()], environment: ConversionEnvironment(), limiter: limiter, fallbackFolder: fixture.fallback)
        XCTAssertEqual(engine.converters.count, 1)
        XCTAssertEqual(engine.environment, ConversionEnvironment())
        XCTAssertTrue(engine.limiter === limiter)
        XCTAssertEqual(engine.fallbackFolder, fixture.fallback)
        XCTAssertNil(Upper().note(for: target, source: FormatRegistry.format(id: "txt")!), "The protocol's default")
        XCTAssertEqual(engine.availability(of: target, for: source), .available)
        XCTAssertEqual(engine.availability(of: target), .available)
        XCTAssertEqual(engine.availability(of: try fixture.target("docx")), .needs("pandoc"))
        XCTAssertTrue(engine.claims(target, family: .document))
        XCTAssertTrue(engine.offers(for: [source]).contains { $0.id == "docx" && $0.availability == .needs("pandoc") })

        let job = ConversionJob(id: UUID(), sources: [source, empty, source], target: target, options: ConversionOptions(), nameSuffix: "büyük")
        XCTAssertEqual(job.distinctSources, [source, empty])
        XCTAssertEqual([job.target.id, job.nameSuffix], ["md", "büyük"])
        let recorder = ConversionFixture.Recorder()
        let result = await engine.run(job, moveToTrash: fixture.moveToTrash, events: recorder.record)
        let output = fixture.url("in/not büyük.md")
        XCTAssertEqual(result.job.id, job.id)
        XCTAssertEqual(result.sources, [source, empty])
        XCTAssertEqual(result.outcomes, [.converted([output]), .skipped("Belge boş.")])
        XCTAssertEqual(result.outputs, [output])
        XCTAssertEqual([result.converted, result.failed, result.skipped], [1, 0, 1])
        XCTAssertFalse(result.wasCancelled || result.originalsTrashed)
        XCTAssertEqual(result.notices, ["Yalnızca metin aktarılır; düzen ve görseller korunmaz."])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "MERHABA ĞIŞ")
        XCTAssertTrue(recorder.events.contains(.started(index: 0)))
        XCTAssertTrue(recorder.events.contains(.progress(index: 0, fraction: 0.5)))
        XCTAssertTrue(recorder.events.contains(.finished(index: 1, outcome: .skipped("Belge boş."))))
        XCTAssertTrue(ConversionEngine.liveWorkFolders().isEmpty)
        XCTAssertFalse(ConversionEngine.trashesOriginal(target, source: FormatRegistry.format(id: "txt")!, options: ConversionOptions()))
        _ = ConversionEngine.standardConverters()
        _ = ConversionEngine(converters: [], environment: ConversionEnvironment(), limiter: ConversionLimiter())
        _ = await engine.run(ConversionJob(sources: [], target: target, options: ConversionOptions()))

        // The record of that job, and the pieces a record is made of.
        let record = ConversionRecord.make(from: result, origin: .page, date: Date())
        XCTAssertEqual(record.unchangedOutputs(), [output])
        XCTAssertEqual(ConversionRecord.Output(recording: output), record.outputs.first)
        XCTAssertTrue(record.retryable().isEmpty)
        XCTAssertEqual([record.converted, record.failures, record.skipped], [1, 0, 1])
        let entry = ConversionRecord.Entry(path: "p1.png", bytes: 1, modified: Date())
        let made = ConversionRecord(id: UUID(), date: Date(), origin: ConversionRecord.Origin.watch, targetID: "png", targetTitle: "PNG",
                                    titleIsKey: false, sources: ["/a"],
                                    outputs: [ConversionRecord.Output(path: "/a sayfalar", bytes: 0, modified: Date(), files: [entry])],
                                    problems: [ConversionRecord.Problem(source: "/a", key: "k", detail: nil, failed: true)],
                                    notices: ["n"], originalsTrashed: false, converted: 0, failures: 1, skipped: 0, wasCancelled: false)
        XCTAssertEqual(try JSONDecoder().decode(ConversionRecord.self, from: JSONEncoder().encode(made)), made)
        XCTAssertEqual(made.outputs[0].files[0].path, "p1.png")
        XCTAssertEqual(ConversionRecord.problemLimit, 50)
        let built = ConversionResult(job: job, sources: [source], outcomes: [.failed(ConversionFailure("k", detail: "d"))], notices: [], originalsTrashed: false)
        XCTAssertEqual(built.failed, 1)
        XCTAssertEqual(ConversionOutcome.cancelled, .cancelled)
    }

    func testRequestsContextsAndErrorsCanBeBuiltByHand() throws {
        let work = try fixture.workFolder()
        let png = try XCTUnwrap(FormatRegistry.format(id: "png"))
        let request = ConversionRequest(sources: [fixture.url("a.heic")], formats: [try XCTUnwrap(FormatRegistry.format(id: "heic"))],
                                        target: try fixture.target("png"), outputFormat: png, options: ConversionOptions(), workFolder: work,
                                        baseName: "a", environment: ConversionEnvironment())
        XCTAssertEqual(request.outputURL().path, work.appendingPathComponent("a.png").path)
        XCTAssertEqual(request.outputURL("a_p2").lastPathComponent, "a_p2.png")
        XCTAssertEqual([request.sources.count, request.formats.count], [1, 1])
        XCTAssertEqual([request.target.id, request.outputFormat.id, request.baseName], ["png", "png", "a"])
        XCTAssertEqual(request.options, ConversionOptions())
        XCTAssertEqual(request.environment, ConversionEnvironment())
        XCTAssertEqual(request.workFolder, work)

        let quiet = ConversionContext()
        XCTAssertFalse(quiet.isCancelled())
        XCTAssertNoThrow(try quiet.checkCancelled())
        quiet.progress(0.3); quiet.note("not")
        let context = ConversionContext(isCancelled: { true }, progress: { _ in }, note: { _ in })
        XCTAssertThrowsError(try context.checkCancelled()) { XCTAssertTrue($0 is CancellationError) }
        // The fixture's own builders, as the converter units use them.
        let built = try fixture.request([try fixture.write("in/b.jpeg")], target: "half")
        XCTAssertEqual([built.baseName, built.outputFormat.id], ["b", "jpg"])
        XCTAssertEqual(built.options.imageResize, .half, "The target's overrides are applied, as the engine does")
        fixture.cancel.set()
        XCTAssertThrowsError(try fixture.context().checkCancelled())
        fixture.context().progress(0.5); fixture.context().note("n")
        XCTAssertEqual(fixture.progress, [0.5]); XCTAssertEqual(fixture.notes, ["n"])

        let failure = ConversionFailure("Dönüştürülemedi: %@", detail: "x")
        XCTAssertEqual([failure.key, failure.detail ?? ""], ["Dönüştürülemedi: %@", "x"])
        XCTAssertNil(ConversionFailure("Belge boş.").detail)
        XCTAssertEqual(ConversionSkip("Zaten yeterince küçük.").key, "Zaten yeterince küçük.")
        XCTAssertTrue((failure as Error) is ConversionFailure)
    }

    func testToolsNamingAndTextHelpersAreReachable() async throws {
        let output = try await ToolProcess.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["merhaba"], directory: fixture.root, environment: nil,
                                               capture: .data(limit: 100))
        XCTAssertEqual([output.status, Int32(output.stdout.count)], [0, 8])
        XCTAssertEqual(output.stderrTail, "")
        _ = try await ToolProcess.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["a"], capture: .lines { _ in })
        _ = try await ToolProcess.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["a"], capture: .lines(nil))
        _ = try await ToolProcess.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["a"], capture: .chunks { _ in })
        ToolProcess.terminateAll()
        XCTAssertEqual(ToolOutput(status: 1, stdout: Data([1]), stderrTail: "e").stderrTail, "e")
        XCTAssertEqual(ToolOutput(status: 0).stdout, Data())

        let destination = try fixture.folder("out")
        let published = try OutputNaming.publish(try fixture.write("work/x.tmp"), named: "sonuç", extension: "txt", in: destination)
        XCTAssertEqual(published.lastPathComponent, "sonuç.txt")
        XCTAssertEqual(OutputNaming.available(named: "sonuç", extension: "txt", in: destination).lastPathComponent, "sonuç 2.txt")
        XCTAssertEqual(OutputNaming.baseName(of: fixture.url("a.tar.gz"), format: FormatRegistry.format(id: "tar.gz")), "a")
        XCTAssertEqual(OutputNaming.cleaned("a:b"), "a-b")
        XCTAssertEqual(OutputNaming.shortened("abcdef", toBytes: 3), "abc")

        XCTAssertEqual(TextEncoding.decode(Data("düz".utf8)), "düz")
        let value: Int = try await ConversionWork.run { 6 * 7 }
        XCTAssertEqual(value, 42)
        // Named, not run: the Vision models are opt-in for tests.
        let recognise = TextRecognition.text(in:isCancelled:)
        _ = recognise
    }

    func testTheRingsModelCanBeBuiltAndAsked() throws {
        let geometry = DonutGeometry(count: 6, outerRadius: 140, innerRadius: 58, margin: 28)
        XCTAssertEqual(geometry, DonutGeometry(count: 6))
        XCTAssertEqual(geometry.hit(CGPoint(x: 0, y: 100)), DonutGeometry.Hit.slice(0))
        XCTAssertEqual(geometry.hit(.zero), .hub)
        XCTAssertEqual(geometry.hit(CGPoint(x: 0, y: 150)), .rim)
        XCTAssertEqual(geometry.hit(CGPoint(x: 0, y: 500)), .outside)
        XCTAssertEqual(geometry.midAngle(of: 3), .pi, accuracy: 1e-9)
        XCTAssertEqual(geometry.labelPoint(of: 0).y, 99, accuracy: 1e-9)
        XCTAssertEqual(geometry.extent, 336)
        XCTAssertEqual(geometry.sweep, .pi / 3, accuracy: 1e-9)
        XCTAssertEqual(DonutGeometry.centre(near: .zero, extent: 336, in: CGRect(x: 0, y: 0, width: 1000, height: 800)), CGPoint(x: 168, y: 168))
        var changed = geometry
        changed.count = 4; changed.outerRadius = 100; changed.innerRadius = 40; changed.margin = 10
        XCTAssertEqual(changed.extent, 220)

        let target = try fixture.target("png")
        let slice = DonutSlice(id: "png", content: .target(target), title: "PNG", shortTitle: "PNG", titleIsKey: false, symbol: "photo",
                               enabled: false, fitting: 0, reasonKey: "Dosya zaten bu biçimde.", reasonDetail: nil, noteKey: nil)
        let action = DonutSlice(id: "action.zip", content: .action(.zip), title: DonutAction.zip.title, shortTitle: DonutAction.zip.shortTitle,
                                titleIsKey: DonutAction.zip.titleIsKey, symbol: DonutAction.zip.symbol)
        let faces = DonutFaces(front: [slice, action, .flip], back: [DonutSlice.flip])
        XCTAssertEqual([faces.front.count, faces.back.count], [3, 1])
        XCTAssertEqual(DonutSlice.Content.flip, DonutSlice.flip.content)
        XCTAssertEqual([slice.id, slice.title, slice.shortTitle, slice.symbol], ["png", "PNG", "PNG", "photo"])
        XCTAssertFalse(slice.enabled || slice.titleIsKey)
        XCTAssertNil(slice.reasonDetail); XCTAssertNil(slice.noteKey)
        XCTAssertEqual([slice.fitting, action.fitting], [0, 0])
        XCTAssertEqual(DonutAction.allCases.count, 7)

        let files = [fixture.url("a.heic"), fixture.url("b.heic")]
        let offer = TargetOffer(target: target, availability: .available, fitting: 2, total: 2, noteKey: nil)
        XCTAssertEqual([offer.id, String(offer.fitting), String(offer.total)], ["png", "2", "2"])
        XCTAssertTrue(offer.isUsable)
        XCTAssertNil(offer.noteKey)
        XCTAssertEqual(DonutToolbar.family(of: files), .image)
        let ring = DonutToolbar.faces(for: files, offers: [offer], claimed: { $0.id == "png" || $0.id == "jpg" })
        XCTAssertEqual(ring.front.map(\.id), ["jpg", "png", "flip"])
        XCTAssertEqual(ring.back.map(\.id), ["action.zip", "flip"])
        XCTAssertEqual(DonutToolbar.faceLimit, 7)
        let engine = fixture.engine([ConversionFixture.Fake()])
        XCTAssertEqual(engine.faces(for: files).front.count, 8)
    }
}
