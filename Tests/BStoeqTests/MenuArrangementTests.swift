import XCTest
import AppKit
import BStoeqCore
import BStoeqRuntime
@testable import BStoeq

final class MenuArrangementTests: XCTestCase {
    func testArrangementShowsEveryIconWithoutRewritingPreferences() async throws {
        try await MainActor.run {
            let fixture = try ArrangementFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            let preferences = model.preferences
            let storedPreferences = fixture.defaults.data(forKey: "preferences")
            var starts = 0, finishes = 0
            model.onBeginMenuBarArrangement = { starts += 1 }
            model.onFinishMenuBarArrangement = { finishes += 1 }
            XCTAssertEqual(model.hiddenIDs, Set(fixture.apps.map(\.id)))

            model.beginMenuBarArrangement()
            model.beginMenuBarArrangement()
            XCTAssertTrue(model.arrangingMenuBar)
            XCTAssertTrue(model.hiddenIDs.isEmpty)
            XCTAssertFalse(model.panelPresented)
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(model.preferences, preferences)
            XCTAssertEqual(fixture.defaults.data(forKey: "preferences"), storedPreferences)

            model.finishMenuBarArrangement()
            model.finishMenuBarArrangement()
            XCTAssertFalse(model.arrangingMenuBar)
            XCTAssertFalse(model.expanded)
            XCTAssertFalse(model.revealingAll)
            XCTAssertEqual(model.hiddenIDs, Set(fixture.apps.map(\.id)))
            XCTAssertEqual(finishes, 1)
            XCTAssertEqual(model.preferences, preferences)
            XCTAssertEqual(fixture.defaults.data(forKey: "preferences"), storedPreferences)
        }
    }

    func testInlineArrangementKeepsSettingsOpenAndAppliesEditedRulesOnFinish() async throws {
        try await MainActor.run {
            let fixture = try ArrangementFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            var guideOpens = 0
            model.onBeginMenuBarArrangement = { guideOpens += 1 }
            model.beginMenuBarArrangement(showGuide: false)
            XCTAssertTrue(model.arrangingMenuBar)
            XCTAssertEqual(guideOpens, 0)
            XCTAssertTrue(model.inlineMenuBarArrangement)
            model.assign(fixture.apps[0].id, to: .visible)
            model.assign(fixture.apps[1].id, to: .hidden)
            XCTAssertTrue(model.hiddenIDs.isEmpty)
            model.finishMenuBarArrangement()
            XCTAssertEqual(model.hiddenIDs, Set([fixture.apps[1].id]))
            XCTAssertFalse(model.inlineMenuBarArrangement)
            let saved = try JSONDecoder().decode(Preferences.self, from: XCTUnwrap(fixture.defaults.data(forKey: "preferences")))
            XCTAssertEqual(saved.assignments, [fixture.apps[1].id: .hidden])
        }
    }

    func testArrangementRestoresEachOrdinaryRevealState() async throws {
        try await MainActor.run {
            let fixture = try ArrangementFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            for mode in RevealMode.allCases {
                model.update { $0.revealMode = mode }
                for (expanded, revealingAll) in [(false, false), (true, false), (true, true)] {
                    model.expanded = expanded
                    model.revealingAll = revealingAll
                    let hidden = model.hiddenIDs
                    let panel = model.panelPresented
                    model.beginMenuBarArrangement()
                    XCTAssertTrue(model.hiddenIDs.isEmpty)
                    XCTAssertFalse(model.panelPresented)
                    model.finishMenuBarArrangement()
                    XCTAssertEqual(model.expanded, expanded)
                    XCTAssertEqual(model.revealingAll, revealingAll)
                    XCTAssertEqual(model.hiddenIDs, hidden)
                    XCTAssertEqual(model.panelPresented, panel)
                }
            }
        }
    }

    func testTogglesHoverAndStalePanelClicksCannotInterruptArrangement() async throws {
        try await MainActor.run {
            let fixture = try ArrangementFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            model.update { $0.revealOnHover = true }
            model.expanded = true
            model.beginMenuBarArrangement()
            model.toggle()
            model.hide()
            model.revealFromHover()
            model.outsideClick()
            model.panelKeyboardActivity()
            model.selectPanelApp(fixture.apps[0], revealOnly: true)
            model.reconcileApps(fixture.apps)
            model.refreshApps()
            model.apply()
            XCTAssertTrue(model.arrangingMenuBar)
            XCTAssertTrue(model.hiddenIDs.isEmpty)
            XCTAssertFalse(model.panelPresented)
            XCTAssertNil(model.selectedMenuAppID)
            model.finishMenuBarArrangement()
            XCTAssertTrue(model.expanded)
            XCTAssertFalse(model.revealingAll)
        }
    }

    func testArrangementCancelsPendingOutsideClickEvenAfterFinishing() async throws {
        let fixture = try await MainActor.run { try ArrangementFixture() }
        await MainActor.run {
            fixture.model.expanded = true
            fixture.model.outsideClick()
            fixture.model.beginMenuBarArrangement()
            fixture.model.finishMenuBarArrangement()
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await MainActor.run {
            defer { fixture.cleanUp() }
            XCTAssertTrue(fixture.model.expanded)
            XCTAssertFalse(fixture.model.arrangingMenuBar)
        }
    }

    func testArrangementCancelsNativeMenuAndDoesNotReopenIt() async throws {
        try await MainActor.run {
            let fixture = try ArrangementFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            model.selectPanelApp(fixture.apps[0], revealOnly: true)
            XCTAssertEqual(model.selectedMenuAppID, fixture.apps[0].id)
            var cancelled = 0
            var opened = 0
            model.cancelMenuOpening = { cancelled += 1 }
            model.openSelectedMenu = { _, _ in opened += 1 }
            model.beginMenuBarArrangement()
            XCTAssertGreaterThan(cancelled, 0)
            model.engine.onApplied?()
            model.finishMenuBarArrangement()
            model.engine.onApplied?()
            XCTAssertNil(model.selectedMenuAppID)
            XCTAssertEqual(opened, 0)
            XCTAssertTrue(model.panelPresented)
        }
    }

    func testArrangementReleasesEngineAndRefreshCannotApplyHiddenLayout() async throws {
        try await MainActor.run {
            let fixture = try ArrangementFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            model.start()
            model.engine.apply(allowed: [AppModel.bundleID])
            XCTAssertEqual(fixture.backend.activations, 1)
            model.beginMenuBarArrangement()
            XCTAssertEqual(fixture.backend.invalidations, 1)
            let activations = fixture.backend.activations
            model.update { $0.showWhenActive = true; $0.autoHideDelay = 1 }
            model.reconcileApps(fixture.apps)
            model.refreshApps()
            model.apply()
            XCTAssertEqual(fixture.backend.activations, activations)
            XCTAssertTrue(model.hiddenIDs.isEmpty)
            XCTAssertTrue(model.arrangingMenuBar)
        }
    }

    func testRecoveryShortcutEndsArrangementWithEverythingVisible() async throws {
        try await MainActor.run {
            let fixture = try ArrangementFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            var finishes = 0
            model.onFinishMenuBarArrangement = { finishes += 1 }
            model.beginMenuBarArrangement()
            model.revealEverything()
            XCTAssertFalse(model.arrangingMenuBar)
            XCTAssertEqual(finishes, 1)
            XCTAssertTrue(model.expanded)
            XCTAssertTrue(model.revealingAll)
            XCTAssertTrue(model.hiddenIDs.isEmpty)
            XCTAssertFalse(model.panelPresented)
            XCTAssertEqual(model.visibility(fixture.apps[1].id), .alwaysHidden)
        }
    }

    func testSleepAndStopDismissArrangementAndPreserveRules() async throws {
        try await MainActor.run {
            for sleeping in [true, false] {
                let fixture = try ArrangementFixture()
                defer { fixture.cleanUp() }
                let model = fixture.model
                let preferences = model.preferences
                var finishes = 0
                model.onFinishMenuBarArrangement = { finishes += 1 }
                model.expanded = true
                model.beginMenuBarArrangement()
                if sleeping { model.prepareForSleep() } else { model.stop() }
                XCTAssertFalse(model.arrangingMenuBar)
                XCTAssertFalse(model.expanded)
                XCTAssertNil(model.selectedMenuAppID)
                XCTAssertEqual(finishes, 1)
                XCTAssertEqual(model.preferences, preferences)
                if sleeping {
                    model.beginMenuBarArrangement()
                    XCTAssertFalse(model.arrangingMenuBar)
                }
            }
        }
    }
}

@MainActor private final class ArrangementFixture {
    let suite = "local.barlet.arrangement-tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let backend = ArrangementBackend()
    let model: AppModel
    let apps = [
        BarApp(id: "local.barlet.arrangement.hidden", name: "Hidden", icon: nil, running: true),
        BarApp(id: "local.barlet.arrangement.always-hidden", name: "Always hidden", icon: nil, running: true)
    ]

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        model = AppModel(defaults: defaults, engine: MenuBarEngine(backend: backend))
        model.reconcileApps(apps)
        model.assign(apps[0].id, to: .hidden)
        model.assign(apps[1].id, to: .alwaysHidden)
    }

    func cleanUp() {
        model.stop()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor private final class ArrangementBackend: MenuBarBackend {
    let available = true
    var activations = 0
    var invalidations = 0

    func activate(allowed: Set<String>, completion: @escaping (String?) -> Void) -> AnyObject? {
        activations += 1
        return NSObject()
    }

    func invalidate(_ token: AnyObject) { invalidations += 1 }
}
