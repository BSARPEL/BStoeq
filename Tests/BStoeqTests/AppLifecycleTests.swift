import XCTest
import AppKit
import BStoeqCore
@testable import BStoeq

final class AppLifecycleTests: XCTestCase {
    func testQuitAndRelaunchUpdateLivePanelWithoutLosingSavedRule() async throws {
        try await MainActor.run {
            let suite = "local.barlet.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            let app = BarApp(id: "local.barlet.lifecycle-fixture", name: "Fixture", icon: nil, running: true)
            model.reconcileApps([app])
            model.assign(app.id, to: .hidden)
            let saved = model.preferences
            model.expanded = true
            var counts: [Int] = []
            model.onChange = { counts.append(model.panelApps.count) }

            model.reconcileApps([])
            XCTAssertTrue(model.panelApps.isEmpty)
            XCTAssertTrue(model.panelPresented)
            XCTAssertEqual(model.availableApps.first?.running, false)
            XCTAssertEqual(model.availableApps.first?.name, "Fixture")
            XCTAssertEqual(model.preferences, saved)

            model.reconcileApps([app])
            XCTAssertEqual(model.panelApps.map(\.id), [app.id])
            XCTAssertEqual(model.availableApps.first?.running, true)
            XCTAssertEqual(counts, [0, 1])
            XCTAssertEqual(AppModel(defaults: defaults).preferences, saved)
        }
    }

    func testQuittingSelectedAppDismissesMenuAndRejectsStaleClick() async throws {
        try await MainActor.run {
            let suite = "local.barlet.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            let app = BarApp(id: "local.barlet.lifecycle-fixture", name: "Fixture", icon: nil, running: true)
            model.reconcileApps([app])
            model.assign(app.id, to: .hidden)
            model.selectPanelApp(app, revealOnly: true)
            XCTAssertEqual(model.selectedMenuAppID, app.id)
            var cancelled = false
            model.cancelMenuOpening = { cancelled = true }

            model.reconcileApps([])
            XCTAssertNil(model.selectedMenuAppID)
            XCTAssertFalse(model.expanded)
            XCTAssertTrue(cancelled)
            XCTAssertEqual(model.visibility(app.id), .hidden)
            model.selectPanelApp(app, revealOnly: true)
            XCTAssertNil(model.selectedMenuAppID)
            XCTAssertFalse(model.expanded)
        }
    }

    func testBothPanelModesExcludeOfflineAndAlwaysHiddenApps() async throws {
        try await MainActor.run {
            let suite = "local.barlet.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            let apps = ["hidden", "offline", "secret", "visible"].map {
                BarApp(id: "local.barlet.test.\($0)", name: $0, icon: nil, running: true)
            }
            model.reconcileApps(apps)
            model.assign(apps[0].id, to: .hidden)
            model.assign(apps[1].id, to: .hidden)
            model.assign(apps[2].id, to: .alwaysHidden)
            model.reconcileApps(apps.filter { $0.name != "offline" })
            for mode in [RevealMode.bar, .list] {
                model.update { $0.revealMode = mode }
                XCTAssertEqual(model.panelApps.map(\.name), ["hidden"])
                XCTAssertEqual(model.hiddenIDs, Set([apps[0].id, apps[1].id, apps[2].id]))
                XCTAssertEqual(model.visibility(apps[1].id), .hidden)
            }
        }
    }
}
