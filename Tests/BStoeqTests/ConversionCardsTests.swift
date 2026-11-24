import XCTest
import AppKit
import SwiftUI
import BStoeqCore
import ConvertCore
@testable import BStoeq

/// The card stack's decisions, fed with activities and a clock of the test's own. No panel is opened;
/// the rendering test draws the cards off screen into a temporary folder.
final class ConversionCardsTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let turkish = Localizer(language: .turkish)
    private var root: URL?

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    // MARK: Helpers

    private func activity(_ origin: ConversionActivity.Origin = .donut(.zero), count: Int = 3, title: String = "PNG", key: Bool = false,
                          phase: ConversionActivity.Phase = .running) -> ConversionActivity {
        ConversionActivity(id: UUID(), origin: origin, count: count, targetTitle: title, titleIsKey: key, phase: phase)
    }

    private func finished(_ activity: ConversionActivity, converted: Int = 0, failed: Int = 0, skipped: Int = 0, cancelled: Bool = false,
                          outputs: [URL] = [], problems: [ConversionActivity.Problem] = [], more: Int = 0,
                          notices: [UserMessage] = []) -> ConversionActivity {
        var done = activity
        done.phase = .finished; done.converted = converted; done.failed = failed; done.skipped = skipped; done.cancelled = cancelled
        done.outputs = outputs; done.problems = problems; done.moreProblems = more; done.notices = notices
        return done
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func failure(_ name: String) -> ConversionActivity.Problem {
        .init(name: name, message: UserMessage("Dönüştürülemedi: %@", detail: "bozuk"), failed: true)
    }

    // MARK: When a card appears

    func testRunningJobGetsACardOnlyFiveSecondsAfterItAppeared() {
        var policy = ConversionCardPolicy()
        let job = activity()
        XCTAssertEqual(policy.update([job], now: at(0), settingsVisible: false).cards, [])
        XCTAssertEqual(policy.update([job], now: at(4.9), settingsVisible: false).cards, [])
        XCTAssertEqual(policy.update([job], now: at(5), settingsVisible: false).cards, [job.id])
    }

    func testWaitingJobCountsLikeARunningOne() {
        var policy = ConversionCardPolicy()
        let job = activity(phase: .waiting)
        _ = policy.update([job], now: at(0), settingsVisible: false)
        XCTAssertEqual(policy.update([job], now: at(6), settingsVisible: false).cards, [job.id])
    }

    func testQuickJobThatWentWellNeverShowsACard() {
        var policy = ConversionCardPolicy()
        let job = activity()
        _ = policy.update([job], now: at(0), settingsVisible: false)
        let done = finished(job, converted: 3, outputs: [URL(fileURLWithPath: "/tmp/a.png")])
        XCTAssertEqual(policy.update([done], now: at(2), settingsVisible: false).cards, [])
        XCTAssertEqual(policy.update([done], now: at(9), settingsVisible: false).cards, [])
    }

    func testQuickJobWithAFailureShowsAtOnceAndLeavesAfterFifteenSeconds() {
        var policy = ConversionCardPolicy()
        let job = activity()
        _ = policy.update([job], now: at(0), settingsVisible: false)
        let done = finished(job, converted: 2, failed: 1, problems: [failure("c.heic")])
        XCTAssertEqual(policy.update([done], now: at(1), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(15.9), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(16), settingsVisible: false).cards, [])
        XCTAssertEqual(policy.update([done], now: at(30), settingsVisible: false).cards, [], "a card that has gone does not come back")
    }

    func testSkipsAndNoticesAreWorthACardToo() {
        var policy = ConversionCardPolicy()
        let skipped = finished(activity(), skipped: 1, problems: [.init(name: "a.png", message: UserMessage("Zaten yeterince küçük."), failed: false)])
        let noticed = finished(activity(.watch), converted: 1, notices: [UserMessage("Klasöre yazılamadığı için sonuç İndirilenler klasörüne kaydedildi.")])
        let stack = policy.update([skipped, noticed], now: at(0), settingsVisible: false)
        XCTAssertEqual(Set(stack.cards), [skipped.id, noticed.id])
    }

    func testLongJobThatWentWellStaysSixSecondsAfterItEnds() {
        var policy = ConversionCardPolicy()
        let job = activity()
        _ = policy.update([job], now: at(0), settingsVisible: false)
        XCTAssertEqual(policy.update([job], now: at(5), settingsVisible: false).cards, [job.id])
        let done = finished(job, converted: 3)
        XCTAssertEqual(policy.update([done], now: at(20), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(25.9), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(26), settingsVisible: false).cards, [])
    }

    func testCountdownPausesWhileThePointerIsOverTheStack() {
        var policy = ConversionCardPolicy()
        let done = finished(activity(), failed: 1, problems: [failure("a.mov")])
        XCTAssertEqual(policy.update([done], now: at(0), settingsVisible: false).cards, [done.id])
        // Hovered from 10 s to 40 s: the 15 s run on only once the pointer has left.
        XCTAssertEqual(policy.update([done], now: at(10), settingsVisible: false, hovering: true).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(39), settingsVisible: false, hovering: true).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(40), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(44.9), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(45), settingsVisible: false).cards, [])
    }

    func testCardThatAppearsDuringAHoverStartsItsTimeWhenThePointerLeaves() {
        var policy = ConversionCardPolicy()
        let job = activity()
        _ = policy.update([job], now: at(0), settingsVisible: false, hovering: true)
        let done = finished(job, failed: 1)
        XCTAssertEqual(policy.update([done], now: at(30), settingsVisible: false, hovering: true).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(60), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(74.9), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update([done], now: at(75), settingsVisible: false).cards, [])
    }

    // MARK: Origins

    func testPageJobsShowOnlyWhileTheSettingsWindowIsHidden() {
        var policy = ConversionCardPolicy()
        let job = activity(.page)
        _ = policy.update([job], now: at(0), settingsVisible: true)
        XCTAssertEqual(policy.update([job], now: at(6), settingsVisible: true).cards, [], "the page lists it itself")
        XCTAssertEqual(policy.update([job], now: at(7), settingsVisible: false).cards, [job.id])
        XCTAssertEqual(policy.update([job], now: at(8), settingsVisible: true).cards, [])
    }

    func testPageJobThatEndedOnScreenDoesNotPopUpWhenTheWindowCloses() {
        var policy = ConversionCardPolicy()
        let done = finished(activity(.page), failed: 1, problems: [failure("a.docx")])
        XCTAssertEqual(policy.update([done], now: at(0), settingsVisible: true).cards, [])
        XCTAssertEqual(policy.update([done], now: at(1), settingsVisible: false).cards, [])
    }

    func testPageJobWithAFailureShowsWhenTheWindowIsHidden() {
        var policy = ConversionCardPolicy()
        let done = finished(activity(.page), failed: 1, problems: [failure("a.docx")])
        XCTAssertEqual(policy.update([done], now: at(0), settingsVisible: false).cards, [done.id])
    }

    func testRingAndWatchJobsShowWhateverTheSettingsWindowDoes() {
        var policy = ConversionCardPolicy()
        let ring = finished(activity(.donut(CGPoint(x: 100, y: 100))), failed: 1)
        let watch = finished(activity(.watch), failed: 1)
        XCTAssertEqual(Set(policy.update([ring, watch], now: at(0), settingsVisible: true).cards), [ring.id, watch.id])
    }

    func testCopiedPathFromTheRingNeedsNoCardButAirDropTroubleDoes() {
        var policy = ConversionCardPolicy()
        let copied = finished(activity(count: 2, title: "Yolu kopyala", key: true), notices: [UserMessage("Yol kopyalandı")])
        let airDrop = finished(activity(count: 1, title: "AirDrop ile gönder", key: true), notices: [UserMessage("AirDrop şu anda kullanılamıyor.")])
        XCTAssertEqual(policy.update([copied, airDrop], now: at(0), settingsVisible: false).cards, [airDrop.id])
        XCTAssertFalse(ConversionCardPolicy.isNoteworthy(copied))
        // From the page there is no small ring to say it, so the confirmation is worth a card there.
        XCTAssertTrue(ConversionCardPolicy.isNoteworthy(finished(activity(.page), notices: [UserMessage("Yol kopyalandı")])))
    }

    // MARK: The stack

    func testStackShowsThreeNewestFirstAndCountsTheRest() {
        var policy = ConversionCardPolicy()
        var jobs: [ConversionActivity] = []
        for second in 0..<5 {
            let job = finished(activity(.watch), failed: 1)
            jobs.insert(job, at: 0)
            _ = policy.update(jobs, now: at(Double(second)), settingsVisible: false)
        }
        let stack = policy.update(jobs, now: at(5), settingsVisible: false)
        XCTAssertEqual(stack.cards, jobs.prefix(3).map(\.id))
        XCTAssertEqual(stack.more, 2)
    }

    func testCardBeyondTheThirdStartsItsTimeOnlyWhenItMovesUp() {
        var policy = ConversionCardPolicy()
        let old = activity(.watch)
        _ = policy.update([old], now: at(0), settingsVisible: false)
        let newer = (0..<3).map { _ in finished(activity(.watch), failed: 1) }
        let done = finished(old, failed: 1)
        // The old job ends fourth, out of sight, while the three newer cards run their 15 s from 1 s to 16 s.
        XCTAssertEqual(policy.update(newer + [done], now: at(1), settingsVisible: false).more, 1)
        XCTAssertEqual(policy.update(newer + [done], now: at(16), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update(newer + [done], now: at(30.9), settingsVisible: false).cards, [done.id])
        XCTAssertEqual(policy.update(newer + [done], now: at(31), settingsVisible: false).cards, [])
    }

    func testClosedCardStaysClosed() {
        var policy = ConversionCardPolicy()
        let job = finished(activity(), failed: 1)
        XCTAssertEqual(policy.update([job], now: at(0), settingsVisible: false).cards, [job.id])
        policy.close(job.id)
        XCTAssertEqual(policy.update([job], now: at(1), settingsVisible: false).cards, [])
    }

    func testRunningCardTurnsIntoAFinishedOneInPlace() {
        var policy = ConversionCardPolicy()
        let job = activity(), other = finished(activity(.watch), failed: 1)
        _ = policy.update([job], now: at(0), settingsVisible: false)
        XCTAssertEqual(policy.update([job, other], now: at(6), settingsVisible: false).cards, [other.id, job.id])
        let done = finished(job, converted: 3)
        XCTAssertEqual(policy.update([other, done], now: at(7), settingsVisible: false).cards, [other.id, done.id],
                       "the order follows when a job appeared, not when it ended")
    }

    // MARK: What a card says

    func testTitleCountsFilesAndLocalizesKeyTitles() {
        XCTAssertEqual(ConversionCardPolicy.title(activity(count: 3), localizer: turkish), "3 dosya → PNG")
        XCTAssertEqual(ConversionCardPolicy.title(activity(count: 1), localizer: turkish), "1 dosya → PNG")
        let english = Localizer(language: .english)
        XCTAssertEqual(ConversionCardPolicy.title(activity(count: 2, title: "Kapat", key: true), localizer: english),
                       english.text("%d dosya → %@", 2, "Close"), "the title key goes through the catalog")
        XCTAssertEqual(ConversionCardPolicy.title(activity(count: 2, title: "Kapat"), localizer: english),
                       english.text("%d dosya → %@", 2, "Kapat"), "a format label is never looked up")
    }

    func testOutcomeLineJoinsTheCountsThatAreNotZero() {
        XCTAssertEqual(ConversionCardPolicy.outcome(finished(activity(), converted: 7, failed: 3), localizer: turkish), "7 dönüştürüldü · 3 başarısız")
        XCTAssertEqual(ConversionCardPolicy.outcome(finished(activity(), skipped: 2), localizer: turkish), "2 atlandı")
        XCTAssertEqual(ConversionCardPolicy.outcome(finished(activity(), cancelled: true), localizer: turkish), "İptal edildi")
        XCTAssertEqual(ConversionCardPolicy.outcome(finished(activity(), converted: 1, cancelled: true), localizer: turkish), "1 dönüştürüldü · İptal edildi")
        XCTAssertNil(ConversionCardPolicy.outcome(finished(activity(), notices: [UserMessage("AirDrop şu anda kullanılamıyor.")]), localizer: turkish))
    }

    func testProblemLinesNameTheFileAndTheReasonThenTheRest() {
        let done = finished(activity(), failed: 5, problems: [failure("a.heic"), failure("b.heic"), failure("c.heic")], more: 2)
        XCTAssertEqual(ConversionCardPolicy.problemLines(done, localizer: turkish),
                       ["a.heic — Dönüştürülemedi: bozuk", "b.heic — Dönüştürülemedi: bozuk", "c.heic — Dönüştürülemedi: bozuk", "2 tane daha"])
    }

    func testButtonsFollowThePhaseOutputsAndRetry() {
        XCTAssertEqual(ConversionCardPolicy.actions(for: activity(), retryable: true), [.cancel])
        XCTAssertEqual(ConversionCardPolicy.actions(for: activity(phase: .waiting), retryable: false), [.cancel])
        let out = [URL(fileURLWithPath: "/tmp/a.png")]
        XCTAssertEqual(ConversionCardPolicy.actions(for: finished(activity(), converted: 1, failed: 1, outputs: out), retryable: true), [.reveal, .retry, .close])
        XCTAssertEqual(ConversionCardPolicy.actions(for: finished(activity(), failed: 1), retryable: false), [.close])
    }

    // MARK: Drawing

    /// Draws a stack with every kind of card off screen. With BSTOEQ_CARDS_RENDER set to a folder the
    /// pictures are also written there for a person to look at.
    @MainActor func testCardsRenderAtTheirWidthInBothAppearances() throws {
        let base = try XCTUnwrap(DiskScanner.canonicalPath(FileManager.default.temporaryDirectory.path))
        let folder = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("barlet-cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder
        var running = activity(count: 12, title: "MP4 720p"); running.fraction = 0.42
        let waiting = activity(.page, count: 1, title: "PDF", phase: .waiting)
        let failed = finished(activity(.watch, count: 10, title: "HEIC"), converted: 7, failed: 3,
                              outputs: [folder], problems: [failure("Tatil fotoğrafı 2024.png"), failure("ekran görüntüsü.png")], more: 1,
                              notices: [UserMessage("Klasöre yazılamadığı için sonuç İndirilenler klasörüne kaydedildi.")])
        let cards: [ConversionCardsController.Card] = [
            .init(activity: running, actions: [.cancel]),
            .init(activity: waiting, actions: [.cancel]),
            .init(activity: failed, actions: [.reveal, .retry, .close])
        ]
        for appearance in ["light", "dark"] {
            let content = ConversionCardsController.Content(cards: cards, more: 2, introGlyph: "⌥", language: .turkish, appearance: appearance)
            let stack = ConversionCardsController.StackView(content: content) { _ in }
            // The panel is sized from the hosting view's fitting size before it is shown: it must match the drawing.
            let fitting = NSHostingView(rootView: stack).fittingSize
            XCTAssertEqual(fitting.width, 320, accuracy: 0.5)
            // `preferredColorScheme` reaches the panel's window in the app; an off-screen renderer has none.
            let renderer = ImageRenderer(content: stack.padding(16).background(appearance == "dark" ? Color.black : Color.white)
                .environment(\.colorScheme, appearance == "dark" ? .dark : .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, (320 + 32) * 2)
            XCTAssertGreaterThan(image.height, 400)
            XCTAssertEqual(Double(image.height) / 2 - 32, Double(fitting.height), accuracy: 2)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("cards-\(appearance).png"))
            if let target = ProcessInfo.processInfo.environment["BSTOEQ_CARDS_RENDER"] {
                try data.write(to: URL(fileURLWithPath: target).appendingPathComponent("cards-\(appearance).png"))
            }
        }
    }
}
