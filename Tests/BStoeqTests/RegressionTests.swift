import XCTest
import AppKit
import BStoeqCore
@testable import BStoeq

private final class AlwaysVisibleWindow: NSWindow {
    override var isVisible: Bool { true }
}

final class RegressionTests: XCTestCase {
    @MainActor private func makeModel() throws -> (AppModel, () -> Void) {
        let suite = "local.barlet.regression-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults)
        return (model, { model.stop(); defaults.removePersistentDomain(forName: suite) })
    }

    /// The status item's own window is always visible; only Settings may enable
    /// the periodic accessibility scans.
    func testOnlyTheSettingsWindowCountsAsVisibleSettings() async {
        await MainActor.run {
            let statusLike = AlwaysVisibleWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            let settings = AlwaysVisibleWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            settings.identifier = AppModel.settingsWindowID
            let closedSettings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            closedSettings.identifier = AppModel.settingsWindowID
            XCTAssertFalse(AppModel.settingsWindowVisible(in: []))
            XCTAssertFalse(AppModel.settingsWindowVisible(in: [statusLike]))
            XCTAssertFalse(AppModel.settingsWindowVisible(in: [statusLike, closedSettings]))
            XCTAssertTrue(AppModel.settingsWindowVisible(in: [statusLike, settings]))
        }
    }

    func testStartingASecondRecorderKeepsHotkeysSuspended() async {
        await MainActor.run {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            let first = RecorderButton(), second = RecorderButton()
            first.frame = NSRect(x: 0, y: 0, width: 100, height: 30)
            second.frame = NSRect(x: 120, y: 0, width: 100, height: 30)
            window.contentView?.addSubview(first); window.contentView?.addSubview(second)
            var recording: [Bool] = []
            let token = NotificationCenter.default.addObserver(forName: .barletRecordingChanged, object: nil, queue: nil) {
                recording.append($0.object as? Bool ?? false)
            }
            defer { NotificationCenter.default.removeObserver(token) }

            first.performClick(nil)
            XCTAssertEqual(recording, [true])
            second.performClick(nil)
            XCTAssertFalse(first.recording)
            XCTAssertTrue(second.recording)
            // The last announcement decides whether the global hotkeys are registered.
            XCTAssertEqual(recording, [true, false, true])
            XCTAssertTrue(window.makeFirstResponder(nil))
            XCTAssertFalse(second.recording)
            XCTAssertEqual(recording.last, false)
        }
    }

    func testClosingSettingsRestoresHotkeysWhileARecorderHasFocus() async {
        await MainActor.run {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let recorder = RecorderButton()
            window.contentView?.addSubview(recorder)
            var changes: [Bool] = []
            let observer = NotificationCenter.default.addObserver(forName: .barletRecordingChanged, object: nil, queue: nil) {
                if let recording = $0.object as? Bool { changes.append(recording) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            recorder.performClick(nil)
            XCTAssertTrue(recorder.recording)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            XCTAssertFalse(recorder.recording)
            recorder.performClick(nil)
            window.close()
            XCTAssertFalse(recorder.recording)
            XCTAssertEqual(changes, [true, false, true, false])
        }
    }

    func testFunctionAndNavigationKeysGetReadableLabels() async {
        await MainActor.run {
            XCTAssertEqual(RecorderButton.keyLabel(keyCode: 122, characters: "\u{F704}", space: "Boşluk"), "F1")
            XCTAssertEqual(RecorderButton.keyLabel(keyCode: 111, characters: "\u{F70F}", space: "Boşluk"), "F12")
            XCTAssertEqual(RecorderButton.keyLabel(keyCode: 49, characters: " ", space: "Leertaste"), "Leertaste")
            XCTAssertEqual(RecorderButton.keyLabel(keyCode: 11, characters: "b", space: "Boşluk"), "B")
            XCTAssertEqual(RecorderButton.keyLabel(keyCode: 123, characters: "\u{F702}", space: "Boşluk"), "←")
            // An unnamed key with an undrawable character falls back to its code.
            XCTAssertEqual(RecorderButton.keyLabel(keyCode: 114, characters: "\u{F746}", space: "Boşluk"), "#114")
            XCTAssertEqual(RecorderButton.keyLabel(keyCode: 10, characters: nil, space: "Boşluk"), "#10")
        }
    }

    func testOnlyHoverRevealsAreMarkedAsHover() async throws {
        try await MainActor.run {
            let (model, cleanUp) = try makeModel()
            defer { cleanUp() }
            model.update { $0.revealOnHover = true }
            model.revealFromHover()
            XCTAssertTrue(model.expanded)
            XCTAssertTrue(model.revealedByHover)
            model.hide()
            XCTAssertFalse(model.revealedByHover)
            model.toggle()
            XCTAssertTrue(model.expanded)
            XCTAssertFalse(model.revealedByHover)
            model.hide()
            model.revealFromHover()
            model.revealEverything()
            XCTAssertFalse(model.revealedByHover)
        }
    }

    func testNamesAreKeptOnlyForAppsWithASavedRule() async throws {
        try await MainActor.run {
            let (model, cleanUp) = try makeModel()
            defer { cleanUp() }
            let app = BarApp(id: "local.barlet.regression.fixture", name: "Fixture", icon: nil, running: true)
            model.reconcileApps([app])
            model.assign(app.id, to: .hidden)
            XCTAssertEqual(model.preferences.names, [app.id: "Fixture"])
            model.assign(app.id, to: .visible)
            XCTAssertTrue(model.preferences.assignments.isEmpty)
            XCTAssertTrue(model.preferences.names.isEmpty)
        }
    }
}
