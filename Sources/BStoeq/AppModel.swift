import AppKit
import SwiftUI
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import BStoeqCore
import BStoeqRuntime

struct BarApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let running: Bool
    var helper = false
    var protected: Bool { id.hasPrefix("com.apple.") || id == AppModel.bundleID }
}

@MainActor final class AppModel: ObservableObject {
    nonisolated static let bundleID = "local.barlet.app"
    static let settingsWindowID = NSUserInterfaceItemIdentifier("Barlet.Settings")
    /// The status item lives in its own always-visible window, so "any visible
    /// window" is true for the whole lifetime of the app. Ask for Settings itself.
    static func settingsWindowVisible() -> Bool { settingsWindowVisible(in: NSApp?.windows ?? []) }
    static func settingsWindowVisible(in windows: [NSWindow]) -> Bool {
        windows.contains { $0.isVisible && $0.identifier == settingsWindowID }
    }
    @Published var preferences: Preferences
    @Published var apps: [BarApp] = []
    @Published var expanded = false
    @Published var revealingAll = false
    @Published private(set) var arrangingMenuBar = false
    @Published private(set) var inlineMenuBarArrangement = false
    @Published private(set) var selectedMenuAppID: String?
    /// A panel opened by hovering must not take the keyboard from the app in use.
    private(set) var revealedByHover = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var scanning = false
    @Published var owners: Set<String>?
    @Published var error: UserMessage?
    @Published var engineError: UserMessage?
    @Published var shortcutError: UserMessage?
    @Published var notice: UserMessage?
    @Published var selection = "menu"
    @Published var search = ""
    @Published var searchFocusRequest = 0
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    let engine: MenuBarEngine
    let menuLayout = MenuBarLayoutController()
    let downloads: MediaDownloadManager
    let disk: DiskScanManager
    let cache = CacheCleanupManager()
    let duplicates = DuplicateFinderManager()
    let uninstaller = AppUninstallManager()
    var onChange: (() -> Void)?
    var onShortcutChange: (() -> Void)?
    var onLanguageChange: (() -> Void)?
    var openWindow: (() -> Void)?
    var openArchives: (() -> Void)?
    var openSelectedMenu: ((BarApp, MenuActivation) -> Void)?
    var onMenuPermissionNeeded: ((BarApp) -> Void)?
    var cancelMenuOpening: (() -> Void)?
    var shouldKeepRevealed: (() -> Bool)?
    var onBeginMenuBarArrangement: (() -> Void)?
    var onFinishMenuBarArrangement: (() -> Void)?
    private var stateBeforeArrangement: (expanded: Bool, revealingAll: Bool)?
    private var pendingMenuApp: (app: BarApp, action: MenuActivation)?
    private var outsideClickWork: DispatchWorkItem?
    private var observation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var hideTimer: Timer?
    private var trustTimer: Timer?
    private var scanWork: DispatchWorkItem?
    private var scanGeneration = 0
    private var rescanRequested = false
    private var lastScan = Date.distantPast
    private var started = false
    private var sleeping = false
    private let defaults: UserDefaults

    var localizer: Localizer { Localizer(language: preferences.language) }
    func L(_ key: String, _ arguments: CVarArg...) -> String { localizer.text(key, arguments: arguments) }

    init(defaults: UserDefaults = .standard, engine: MenuBarEngine? = nil, downloads: MediaDownloadManager? = nil,
         disk: DiskScanManager? = nil) {
        self.defaults = defaults
        self.downloads = downloads ?? MediaDownloadManager()
        self.disk = disk ?? DiskScanManager()
        self.engine = engine ?? MenuBarEngine()
        preferences = Preferences()
        if let data = defaults.data(forKey: "preferences") {
            do { preferences = try JSONDecoder().decode(Preferences.self, from: data) }
            catch { self.error = UserMessage("Kayıtlı ayarlar okunamadı. Önceki veriler korunuyor; bir ayarı değiştirdiğinde yeni tercihler kaydedilir.") }
        }
        self.engine.onError = { [weak self] failure in
            let message: UserMessage?
            switch failure {
            case nil: message = nil
            case .unavailable: message = UserMessage("Bu macOS sürümünde gizleme motoruna ulaşılamıyor. Tüm simgeler görünür bırakıldı.")
            case .creationFailed: message = UserMessage("Gizleme motoru başlatılamadı. Menü çubuğun görünür bırakıldı.")
            case .timedOut: message = UserMessage("macOS yanıt vermedi. Menü çubuğun görünür bırakıldı; tekrar deneyebilirsin.")
            case .activation(let detail): message = UserMessage("Gizleme uygulanamadı: %@", detail: detail)
            }
            if self?.engineError != message { self?.engineError = message }
            if message != nil { self?.pendingMenuApp = nil }
        }
        self.engine.onApplied = { [weak self] in
            guard let self, !self.arrangingMenuBar, let request = self.pendingMenuApp,
                  self.selectedMenuAppID == request.app.id else { return }
            self.pendingMenuApp = nil
            self.openSelectedMenu?(request.app, request.action)
        }
    }

    var availableApps: [BarApp] {
        apps.filter { app in
            if preferences.assignments[app.id] != nil { return true }
            guard let owners else { return !app.protected && !app.helper }
            return owners.contains(app.id)
        }
    }
    var hiddenIDs: Set<String> {
        guard !arrangingMenuBar else { return [] }
        return VisibilityPlan.hiddenIDs(assignments: preferences.assignments, expanded: expanded,
            revealAll: revealingAll, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            showWhenActive: preferences.showWhenActive, ownID: Self.bundleID,
            mode: preferences.revealMode, selectedAppID: selectedMenuAppID)
    }
    var panelPresented: Bool { !arrangingMenuBar && expanded && !revealingAll && preferences.revealMode != .menuBar && selectedMenuAppID == nil }
    var panelApps: [BarApp] { apps.filter { $0.running && !$0.protected && visibility($0.id) == .hidden } }
    var conflict: Bool {
        NSWorkspace.shared.runningApplications.contains {
            let id = ($0.bundleIdentifier ?? "").lowercased()
            return id.contains("bartender") || id == "com.jordanbaird.ice" || id.contains("pelmet")
        }
    }
    func visibility(_ id: String) -> ItemVisibility { preferences.assignments[id] ?? .visible }

    func start() {
        guard !started else { return }
        started = true
        refreshApps()
        observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.started else { return }
                self.refreshApps(); self.scheduleScan()
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.started else { return }
                    self.refreshApps(); self.scheduleScan()
                }
            })
        }
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.apply() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated {
                self?.prepareForSleep()
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated {
                self?.sleeping = false; self?.refreshApps(); self?.scheduleAutoHide(); self?.scheduleScan()
                    if self?.selection == "menu", Self.settingsWindowVisible() { self?.menuLayout.start() }
            }
        })
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started, !self.sleeping else { return }
                let newTrust = AXIsProcessTrusted()
                if newTrust != self.trusted {
                    self.trusted = newTrust
                    self.scanGeneration += 1; self.scanning = false; self.owners = nil
                    if newTrust { self.scanOwners() }
                    self.onChange?()
                }
                // Apps can create an extra long after launch. Refresh only while settings are visible.
                if self.trusted && Date().timeIntervalSince(self.lastScan) > 20 && Self.settingsWindowVisible() {
                    self.scanOwners()
                }
                // Only Settings shows this switch; do not ask the service for it all day.
                if Self.settingsWindowVisible() { self.refreshLoginState() }
            }
        }
        if trusted { scanOwners() }
    }

    func update(_ change: (inout Preferences) -> Void) {
        let previous = preferences
        change(&preferences); preferences.normalize()
        save()
        if previous.revealMode != preferences.revealMode { hide() }
        if let selectedMenuAppID, visibility(selectedMenuAppID) != .hidden { hide() }
        if previous.assignments != preferences.assignments || previous.showWhenActive != preferences.showWhenActive { apply() }
        if previous.autoHide != preferences.autoHide || previous.autoHideDelay != preferences.autoHideDelay { scheduleAutoHide() }
        if previous.toggleShortcut != preferences.toggleShortcut || previous.settingsShortcut != preferences.settingsShortcut { onShortcutChange?() }
        if previous.language != preferences.language { onLanguageChange?() }
        onChange?()
    }

    func assign(_ id: String, to visibility: ItemVisibility) {
        guard let app = apps.first(where: { $0.id == id }), !app.protected else { return }
        update { $0.assignments[id] = visibility == .visible ? nil : visibility; $0.names[id] = visibility == .visible ? nil : app.name }
    }
    func toggle() { toggle(byHover: false) }
    private func toggle(byHover: Bool) {
        guard !arrangingMenuBar else { return }
        cancelMenuSelection()
        expanded.toggle(); revealingAll = false
        revealedByHover = byHover && expanded
        apply(); scheduleAutoHide(); onChange?()
    }
    func hide() {
        guard !arrangingMenuBar else { return }
        cancelMenuSelection()
        expanded = false; revealingAll = false; revealedByHover = false
        hideTimer?.invalidate(); apply(); onChange?()
    }
    func revealEverything() {
        // The recovery shortcut remains available during arrangement without
        // briefly reapplying the hidden layout before revealing every icon.
        endMenuBarArrangement(restoreState: false)
        cancelMenuSelection()
        expanded = true; revealingAll = true; revealedByHover = false
        engine.clear(); engineError = nil
        hideTimer?.invalidate(); onChange?()
    }
    func revealFromHover() {
        guard !arrangingMenuBar, !expanded, preferences.revealOnHover else { return }; toggle(byHover: true)
    }
    func panelKeyboardActivity() {
        if panelPresented { scheduleAutoHide() }
    }
    func outsideClick() {
        guard !arrangingMenuBar, expanded, !revealingAll, preferences.hideOnOutsideClick else { return }
        scheduleOutsideClickCheck()
    }
    private func scheduleOutsideClickCheck() {
        outsideClickWork?.cancel()
        // Let a native menu process the click before deciding whether it has closed.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.arrangingMenuBar, self.expanded, !self.revealingAll,
                  self.preferences.hideOnOutsideClick else { return }
            // Decide only after the button is released. Hiding during a long press on
            // our own Hide button would be undone by that button's toggle on release.
            if NSEvent.pressedMouseButtons != 0 { self.scheduleOutsideClickCheck(); return }
            guard self.shouldKeepRevealed?() != true else { return }
            self.hide()
        }
        outsideClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func selectPanelApp(_ app: BarApp, action: MenuActivation = .primary, revealOnly: Bool = false) {
        guard !arrangingMenuBar, app.running, !app.protected, visibility(app.id) == .hidden,
              apps.contains(where: { $0.id == app.id && $0.running }) else { return }
        trusted = AXIsProcessTrusted()
        if !trusted && !revealOnly { onMenuPermissionNeeded?(app); return }
        cancelMenuSelection()
        expanded = true; revealingAll = false; selectedMenuAppID = app.id
        pendingMenuApp = revealOnly ? nil : (app, action)
        // Close our panel before the engine completion opens the app's real menu.
        onChange?(); apply()
        // Keep a selected native menu reachable until the user dismisses it.
        // A timer based on our panel cannot reliably see custom menus/popovers
        // belonging to another process and must not hide them mid-interaction.
        hideTimer?.invalidate()
    }

    private func cancelMenuSelection() {
        outsideClickWork?.cancel(); outsideClickWork = nil
        pendingMenuApp = nil; selectedMenuAppID = nil; cancelMenuOpening?()
    }

    func beginMenuBarArrangement(showGuide: Bool = true) {
        guard !arrangingMenuBar, !sleeping else { return }
        stateBeforeArrangement = (expanded, revealingAll)
        arrangingMenuBar = true
        inlineMenuBarArrangement = !showGuide
        cancelMenuSelection()
        hideTimer?.invalidate(); hideTimer = nil
        expanded = false; revealingAll = false
        // Release both active and pending visibility leases so the real macOS
        // status items can be moved, including items normally always hidden.
        engine.clear(); engineError = nil
        onChange?()
        if showGuide { onBeginMenuBarArrangement?() }
    }

    func finishMenuBarArrangement() {
        endMenuBarArrangement(restoreState: true)
    }

    private func endMenuBarArrangement(restoreState: Bool) {
        guard arrangingMenuBar else { return }
        // Release a forwarded drag before restoring any hiding restriction.
        menuLayout.cancelMove()
        let previous = stateBeforeArrangement
        stateBeforeArrangement = nil
        arrangingMenuBar = false
        inlineMenuBarArrangement = false
        cancelMenuSelection()
        if restoreState, let previous {
            expanded = previous.expanded
            revealingAll = previous.revealingAll
        }
        onFinishMenuBarArrangement?()
        if restoreState {
            apply(); scheduleAutoHide(); onChange?()
        }
    }

    func prepareForSleep() {
        menuLayout.stop()
        sleeping = true
        endMenuBarArrangement(restoreState: false)
        hide()
        engine.clear()
    }

    func refreshApps() {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { app -> BarApp? in
            guard !app.isTerminated, let id = app.bundleIdentifier, id != Self.bundleID,
                  app.activationPolicy == .regular || app.activationPolicy == .accessory else { return nil }
            return BarApp(id: id, name: app.localizedName ?? id, icon: app.icon, running: true,
                helper: app.bundleURL?.path.contains(".app/Contents/") ?? false)
        }
        reconcileApps(runningApps)
    }

    func reconcileApps(_ runningApps: [BarApp]) {
        var values: [String: BarApp] = [:]
        for app in runningApps where app.running { values[app.id] = app }
        // Keep offline entries for editing saved rules in Settings, never in the live panel.
        for id in preferences.assignments.keys where values[id] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            values[id] = BarApp(id: id, name: preferences.names[id] ?? id,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }, running: false)
        }
        apps = values.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let selectedMenuAppID, !apps.contains(where: { $0.id == selectedMenuAppID && $0.running }) {
            hide()
        } else {
            apply(); onChange?()
        }
    }

    func apply() {
        guard started, !sleeping else { return }
        guard !arrangingMenuBar else { engine.clear(); return }
        let running = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
        let hidden = hiddenIDs
        engine.apply(allowed: hidden.intersection(running).isEmpty ? nil :
            VisibilityPlan.allowedIDs(running: running, hidden: hidden, ownID: Self.bundleID))
    }

    private func scheduleAutoHide() {
        hideTimer?.invalidate(); hideTimer = nil
        guard started, !sleeping, !arrangingMenuBar, expanded, !revealingAll, selectedMenuAppID == nil, preferences.autoHide else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: preferences.autoHideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.arrangingMenuBar else { return }
                let pointer = NSEvent.mouseLocation
                let inMenuBar = NSScreen.screens.contains {
                    $0.frame.contains(pointer) && pointer.y >= $0.frame.maxY - max(28, $0.safeAreaInsets.top)
                }
                if inMenuBar || NSEvent.pressedMouseButtons != 0 || self.shouldKeepRevealed?() == true { self.scheduleAutoHide() }
                else { self.hide() }
            }
        }
    }

    private func scheduleScan() {
        scanWork?.cancel()
        guard started, trusted else { return }
        let work = DispatchWorkItem { [weak self] in self?.scanOwners() }
        scanWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    func scanOwners() {
        guard started, !sleeping, AXIsProcessTrusted() else { return }
        guard !scanning else { rescanRequested = true; return }
        scanning = true; scanGeneration += 1
        let generation = scanGeneration
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
            app.bundleIdentifier.map { (app.processIdentifier, $0) }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found = Set<String>()
            for (pid, id) in candidates {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.12)
                var result: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &result) == .success,
                   result != nil { found.insert(id) }
            }
            let snapshot = found
            DispatchQueue.main.async {
                guard let self, self.started, self.scanGeneration == generation else { return }
                self.scanning = false; self.lastScan = Date()
                self.owners = AXIsProcessTrusted() && !snapshot.isEmpty ? snapshot : nil
                if self.rescanRequested { self.rescanRequested = false; self.scheduleScan() }
            }
        }
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func refreshLoginState() {
        let enabled = SMAppService.mainApp.status == .enabled
        if loginEnabled != enabled { loginEnabled = enabled }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                notice = UserMessage("Oturum açılışında başlatmak için Sistem Ayarları’nda BStoeq’e izin ver.")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { self.error = UserMessage("Başlangıç ayarı kaydedilemedi: %@", detail: error.localizedDescription) }
    }
    func exportSettings() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "BStoeq-settings.json"
        panel.allowedContentTypes = [.json]; panel.title = L("Ayarları dışa aktar"); panel.prompt = L("Kaydet")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: url, options: .atomic)
            notice = UserMessage("Ayarların dışa aktarıldı.")
        } catch { self.error = UserMessage("Ayarlar kaydedilemedi: %@", detail: error.localizedDescription) }
    }
    func importSettings() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]; panel.title = L("Ayarları içe aktar"); panel.prompt = L("Aç")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let restored = try JSONDecoder().decode(Preferences.self, from: data)
            update { $0 = restored }; refreshApps(); notice = UserMessage("Ayarların içe aktarıldı.")
        } catch { self.error = UserMessage("Bu ayar dosyası okunamadı: %@", detail: error.localizedDescription) }
    }
    private func save() {
        do { defaults.set(try JSONEncoder().encode(preferences), forKey: "preferences") }
        catch { self.error = UserMessage("Ayarlar kaydedilemedi: %@", detail: error.localizedDescription) }
    }
    func stop() {
        menuLayout.stop()
        downloads.cancelAll()
        disk.cancelScan()
        cache.cancelScan()
        cache.stopCleaning()
        duplicates.stop()
        uninstaller.stop()
        started = false
        endMenuBarArrangement(restoreState: false)
        cancelMenuSelection()
        expanded = false; revealingAll = false
        scanGeneration += 1; scanning = false
        hideTimer?.invalidate(); trustTimer?.invalidate(); scanWork?.cancel(); observation = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll(); engine.clear()
    }
}
