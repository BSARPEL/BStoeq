import AppKit
import MenuBarBridge
import BStoeqCore

// Read-only capability probe, useful on a new macOS release.
if CommandLine.arguments.contains("--diagnostics") {
    print("BStoeq \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
    print("Bundle: \(Bundle.main.bundleURL.path)")
    print("LaunchServices: \(NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppModel.bundleID)?.path ?? "not registered")")
    print("Localization entries: \(Localizer.catalog.count), languages: tr, en, de")
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("MenuBarClientCore: \(STMenuBarShim.isAvailable() ? "available" : "unavailable")")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted (optional)")")
} else {
    MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    }
}
