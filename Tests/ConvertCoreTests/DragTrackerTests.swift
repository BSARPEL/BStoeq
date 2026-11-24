import XCTest
import ConvertCore

/// The drag state machine, fed the way `DragMonitor` feeds it: types only when the tracker asks for them.
/// The dragged-file filter works on real files made in the fixture.
final class DragTrackerTests: XCTestCase {
    private var fixture: ConversionFixture!

    override func setUpWithError() throws { fixture = try ConversionFixture(area: "drag") }
    override func tearDownWithError() throws { fixture.remove() }

    private static let option: UInt = 1 << 19, shift: UInt = 1 << 17, command: UInt = 1 << 20
    private static let capsLock: UInt = 1 << 16, numericPad: UInt = 1 << 21, function: UInt = 1 << 23
    private static let finderDrag = ["com.apple.finder.node", "public.file-url", "NSFilenamesPboardType"]
    private static let otherAppDrag = ["public.file-url", "public.utf8-plain-text"]
    private static let textDrag = ["public.utf8-plain-text", "public.rtf"]

    /// What the pasteboard holds and which keys are down, as the monitor would read them.
    private struct World {
        var down = false, count = 10, types: [String] = [], modifiers: UInt = 0, time: TimeInterval = 100
        var typeReads = 0
    }

    /// One poll: the types go along only when asked for, as in the app.
    @discardableResult
    private func poll(_ tracker: inout DragTracker, _ world: inout World, advance: TimeInterval = 0.016) -> DragTracker.Action {
        world.time += advance
        let asked = world.down && tracker.wantsTypes(changeCount: world.count)
        if asked { world.typeReads += 1 }
        return tracker.update(DragTracker.Sample(buttonDown: world.down, changeCount: world.count, types: asked ? world.types : nil,
                                                 modifiers: world.modifiers, time: world.time))
    }
    /// Polls for a while and gives every action that was not `.none`.
    private func run(_ tracker: inout DragTracker, _ world: inout World, ticks: Int = 10) -> [DragTracker.Action] {
        (0..<ticks).map { _ in poll(&tracker, &world) }.filter { $0 != .none }
    }
    /// The button goes down; the source app then writes the drag pasteboard.
    private func startDrag(_ tracker: inout DragTracker, _ world: inout World, types: [String] = finderDrag) -> [DragTracker.Action] {
        world.down = true
        var actions = [tracker.press(changeCount: world.count)]
        actions += run(&tracker, &world, ticks: 3)
        world.count += 1; world.types = types
        return (actions + run(&tracker, &world)).filter { $0 != .none }
    }

    func testAPlainClickNeverOpensTheRingAndNeverReadsTheTypes() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.down = true; world.modifiers = Self.option
        XCTAssertEqual(tracker.press(changeCount: world.count), .none)
        XCTAssertEqual(run(&tracker, &world, ticks: 30), [], "The drag pasteboard did not change: this is no drag")
        XCTAssertEqual(world.typeReads, 0, "Only the change count is read while it has not moved")
        world.down = false
        XCTAssertEqual(run(&tracker, &world), [])
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testADragWithoutFilesDoesNotOpenAndItsTypesAreJudgedOnce() {
        var tracker = DragTracker(finderOnly: false, changeCount: 10), world = World()
        world.modifiers = Self.option
        XCTAssertEqual(startDrag(&tracker, &world, types: Self.textDrag), [])
        XCTAssertEqual(run(&tracker, &world, ticks: 30), [])
        XCTAssertEqual(world.typeReads, 1, "Types already judged for this change count are not read again")
    }

    func testAPasteboardReadBeforeItsTypesAreWrittenIsAskedAgain() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.down = true; world.modifiers = Self.option
        _ = tracker.press(changeCount: world.count)
        world.count += 1; world.types = []
        XCTAssertEqual(run(&tracker, &world, ticks: 5), [], "Cleared but not yet written")
        XCTAssertEqual(world.typeReads, 5)
        world.types = Self.finderDrag
        XCTAssertEqual(run(&tracker, &world), [.open])
    }

    func testAFileDragWithoutTheKeyOpensOnlyWhenTheKeyIsPressedLater() {
        var tracker = DragTracker(changeCount: 10), world = World()
        XCTAssertEqual(startDrag(&tracker, &world), [])
        XCTAssertEqual(run(&tracker, &world, ticks: 60), [], "Dragging alone is Finder's business")
        XCTAssertEqual(tracker.phase, .pressed)
        world.modifiers = Self.option
        XCTAssertEqual(run(&tracker, &world), [.open], "Pressing the key after the drag began opens the ring")
        XCTAssertTrue(tracker.isOpen)
    }

    func testTheKeyHeldBeforeTheDragStartsOpensTheRingAsSoonAsTheDragIsKnown() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.modifiers = Self.option
        world.down = true
        _ = tracker.press(changeCount: world.count)
        _ = run(&tracker, &world, ticks: 10)
        world.count += 1; world.types = Self.finderDrag
        XCTAssertEqual(poll(&tracker, &world), .open, "The key has been held long enough already: no further wait")
    }

    func testTheKeyMustBeHeldAloneForTheSettleTime() {
        var tracker = DragTracker(changeCount: 10), world = World()
        XCTAssertEqual(startDrag(&tracker, &world), [])
        world.modifiers = Self.option
        XCTAssertEqual(poll(&tracker, &world, advance: 0.01), .none)
        XCTAssertEqual(poll(&tracker, &world, advance: 0.03), .none, "40 ms is still a key on its way to a chord")
        world.modifiers = Self.option | Self.command
        XCTAssertEqual(run(&tracker, &world, ticks: 30), [], "Option-Command is Finder's alias drag, not the trigger")
        world.modifiers = Self.option
        XCTAssertEqual(poll(&tracker, &world), .none, "Back to Option alone: the wait starts again")
        XCTAssertEqual(poll(&tracker, &world, advance: 0.05), .none)
        XCTAssertEqual(poll(&tracker, &world, advance: 0.03), .open)
    }

    func testAnExtraModifierKeepsTheRingClosedButCapsLockFnAndTheNumericPadDoNot() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.modifiers = Self.option | Self.shift
        XCTAssertEqual(startDrag(&tracker, &world), [], "The trigger must be matched exactly")
        XCTAssertEqual(run(&tracker, &world, ticks: 30), [])
        world.modifiers = Self.option | Self.capsLock | Self.function | Self.numericPad
        XCTAssertEqual(run(&tracker, &world), [.open])

        var shiftTracker = DragTracker(trigger: .shift, changeCount: 10), other = World()
        other.modifiers = Self.option
        XCTAssertEqual(startDrag(&shiftTracker, &other), [], "Option is not the Shift trigger")
        other.modifiers = Self.shift
        XCTAssertEqual(run(&shiftTracker, &other), [.open])
    }

    func testTheRingFollowsTheButtonNotTheKeyAndClosesOnRelease() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.modifiers = Self.option
        XCTAssertEqual(startDrag(&tracker, &world), [.open])
        world.modifiers = 0
        XCTAssertEqual(run(&tracker, &world, ticks: 30), [], "Letting go of the key keeps the ring")
        world.modifiers = Self.option
        XCTAssertEqual(run(&tracker, &world), [], "An open ring is not opened twice")
        world.down = false
        XCTAssertEqual(poll(&tracker, &world), .close)
        XCTAssertEqual(run(&tracker, &world), [], "Closed once")
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testAStaleChangeCountFromAfterTheLastDropDoesNotMakeTheNextClickADrag() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.modifiers = Self.option
        XCTAssertEqual(startDrag(&tracker, &world), [.open])
        world.down = false
        XCTAssertEqual(poll(&tracker, &world), .close)
        // An app writes the drag pasteboard after the drop, while the button is up.
        world.count += 1; world.types = Self.finderDrag
        XCTAssertEqual(run(&tracker, &world, ticks: 3), [], "The idle refresh takes the new count as the baseline")
        world.down = true
        XCTAssertEqual(run(&tracker, &world, ticks: 30), [], "A press seen only through polling keeps that baseline")

        // The same with the mouse-down seen: the count at the press is the baseline.
        var pressed = DragTracker(changeCount: 3), again = World()
        again.modifiers = Self.option; again.count = 7; again.types = Self.finderDrag; again.down = true
        XCTAssertEqual(pressed.press(changeCount: again.count), .none)
        XCTAssertEqual(run(&pressed, &again, ticks: 30), [], "What was written before the press is not this press's drag")
        XCTAssertEqual(again.typeReads, 0)
    }

    func testAPressWhoseMouseDownWasMissedIsStillFollowed() {
        var tracker = DragTracker(changeCount: 10), world = World()
        XCTAssertEqual(run(&tracker, &world, ticks: 2), [], "Button up: the baseline is refreshed")
        world.down = true; world.modifiers = Self.option
        _ = run(&tracker, &world, ticks: 2)
        world.count += 1; world.types = Self.finderDrag
        XCTAssertEqual(run(&tracker, &world), [.open])
    }

    func testTheRingOpensAgainAfterARelease() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.modifiers = Self.option
        XCTAssertEqual(startDrag(&tracker, &world), [.open])
        world.down = false
        XCTAssertEqual(poll(&tracker, &world), .close)
        XCTAssertEqual(startDrag(&tracker, &world), [.open], "A new drag opens a new ring")
    }

    func testAPressWhileTheRingIsOpenClosesIt() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.modifiers = Self.option
        XCTAssertEqual(startDrag(&tracker, &world), [.open])
        XCTAssertEqual(tracker.press(changeCount: world.count), .close, "The release was missed")
        XCTAssertEqual(tracker.phase, .pressed)
    }

    func testADismissedRingOpensAgainOnlyAfterTheKeyIsPressedAnew() {
        var tracker = DragTracker(changeCount: 10), world = World()
        world.modifiers = Self.option
        XCTAssertEqual(startDrag(&tracker, &world), [.open])
        tracker.dismiss()
        XCTAssertEqual(tracker.phase, .dismissed)
        XCTAssertEqual(run(&tracker, &world, ticks: 30), [], "The key still held does not reopen what Esc closed")
        world.modifiers = 0
        XCTAssertEqual(run(&tracker, &world), [])
        world.modifiers = Self.option
        XCTAssertEqual(run(&tracker, &world), [.open], "A fresh press of the key does")
        world.down = false
        XCTAssertEqual(poll(&tracker, &world), .close)
        tracker.dismiss()
        XCTAssertEqual(tracker.phase, .idle, "Dismissing a closed ring changes nothing")
    }

    func testFinderOnlyRefusesDragsFromOtherAppsAndTheSwitchLetsThemIn() {
        var tracker = DragTracker(finderOnly: true, changeCount: 10), world = World()
        world.modifiers = Self.option
        XCTAssertEqual(startDrag(&tracker, &world, types: Self.otherAppDrag), [], "No Finder node: another app's drag")
        world.down = false; _ = poll(&tracker, &world)
        XCTAssertEqual(startDrag(&tracker, &world, types: Self.finderDrag), [.open])

        var everywhere = DragTracker(finderOnly: false, changeCount: 10), other = World()
        other.modifiers = Self.option
        XCTAssertEqual(startDrag(&everywhere, &other, types: Self.otherAppDrag), [.open])
        other.down = false; _ = poll(&everywhere, &other)
        XCTAssertEqual(startDrag(&everywhere, &other, types: ["NSFilenamesPboardType"]), [.open],
                       "The older file list type counts as a file drag")
    }

    func testDraggedFilesAreExistingFileURLsEachOnceWithinTheLimit() throws {
        let first = try fixture.write("İstanbul/rapor.pdf")
        let second = try fixture.write("foto şğü.heic")
        let folder = try fixture.folder("Klasör")
        let urls = [first, URL(string: "https://example.com/a.pdf")!, fixture.url("yok.png"), second,
                    URL(fileURLWithPath: first.deletingLastPathComponent().path + "/./rapor.pdf"),
                    first, folder, URL(fileURLWithPath: "/")]
        let found = DragTracker.files(urls)
        XCTAssertEqual(found.files.map(\.lastPathComponent), ["rapor.pdf", "foto şğü.heic", "Klasör"])
        XCTAssertEqual(found.total, 3)

        let many = try (0..<7).map { try fixture.write("çok/\($0).txt") }
        let capped = DragTracker.files(many + many, limit: 5)
        XCTAssertEqual(capped.files, Array(many.prefix(5)), "Order kept, cut at the limit")
        XCTAssertEqual(capped.total, 7, "The total still counts what lies beyond the limit")
    }
}
