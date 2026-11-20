import AppKit
import SwiftUI
import BStoeqCore
import ArchiveWorkspace

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private lazy var archives = ArchiveWindowController(languageCode: model.localizer.language.rawValue) { [weak self] code in
        guard let self, let language = AppLanguage(rawValue: code), language != self.model.preferences.language else { return }
        self.model.update { $0.language = language }
    }
    private var readyForDocuments = false
    private var pendingDocuments: [URL] = []
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var shortcuts: ShortcutManager!
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var recordingObserver: NSObjectProtocol?
    private func L(_ key: String) -> String { model.L(key) }
    private let hoverMonitor = HoverMonitor()
    private let revealPanel = RevealPanelController()
    private let menuAccess = MenuItemAccess()
    private let arrangementPanel = MenuArrangementPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard checkInstallation() else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: AppModel.bundleID).count <= 1 else {
            NSRunningApplication.runningApplications(withBundleIdentifier: AppModel.bundleID)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?.activate()
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = archives
        NSUpdateDynamicServices()
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Keep this identifier stable so macOS retains the user's Command-drag position.
        statusItem.autosaveName = "Barlet.Control"
        // Reordering remains native; dragging out of the bar must not remove our only control.
        statusItem.behavior = []
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(L("BStoeq — gizli simgeleri göster veya gizle"))
        }
        hoverMonitor.onHover = { [weak self] in
            self?.revealPanel.rememberAnchor(NSEvent.mouseLocation)
            self?.model.revealFromHover()
        }
        revealPanel.onDismiss = { [weak self] in self?.model.hide() }
        model.openSelectedMenu = { [weak self] app, action in self?.menuAccess.open(app, action: action) }
        model.onMenuPermissionNeeded = { [weak self] app in self?.showMenuPermissionHelp(for: app) }
        model.cancelMenuOpening = { [weak self] in self?.menuAccess.cancel() }
        model.shouldKeepRevealed = { [weak self] in
            self?.revealPanel.containsPointer == true || self?.menuAccess.isInteracting == true
        }
        menuAccess.onUnavailable = { [weak self] in
            self?.model.notice = UserMessage("Uygulamanın simgesi üst çubukta gösterildi. Menüsü otomatik açılmıyorsa simgeye tıkla.")
        }
        model.onChange = { [weak self] in self?.updateStatus() }
        model.onLanguageChange = { [weak self] in
            guard let self else { return }
            self.archives.updateLanguage(self.model.localizer.language.rawValue)
            self.installMainMenu()
            self.registerShortcuts()
        }
        model.openWindow = { [weak self] in self?.showSettings() }
        model.openArchives = { [weak self] in self?.openArchives() }
        model.onBeginMenuBarArrangement = { [weak self] in
            guard let self else { return }
            self.model.menuLayout.stop()
            self.settingsWindow?.orderOut(nil)
            self.arrangementPanel.show(model: self.model)
        }
        model.onFinishMenuBarArrangement = { [weak self] in self?.arrangementPanel.close() }
        shortcuts = ShortcutManager()
        shortcuts.action = { [weak self] id in
            guard let self else { return }
            if self.model.arrangingMenuBar {
                if id == 2 { self.arrangementPanel.show(model: self.model) }
                else if id == 3 { self.model.revealEverything() }
                return
            }
            switch id {
            case 1: self.model.toggle()
            case 2:
                self.model.selection = "menu"
                self.showSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.model.searchFocusRequest += 1
                }
            default: self.model.revealEverything()
            }
        }
        model.onShortcutChange = { [weak self] in self?.registerShortcuts() }
        registerShortcuts()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.archives.handleKeyEquivalent(event) { return nil }
            if self.model.arrangingMenuBar && event.keyCode == 53 {
                self.model.finishMenuBarArrangement(); return nil
            }
            if event.keyCode == 53 && self.model.panelPresented { self.model.hide(); return nil }
            self.model.panelKeyboardActivity()
            return self.shortcuts.handleLocal(event) ? nil : event
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if !self.revealPanel.contains(event), event.window !== self.statusItem?.button?.window {
                self.model.outsideClick()
            }
            return event
        }
        recordingObserver = NotificationCenter.default.addObserver(forName: .barletRecordingChanged, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                if notification.object as? Bool == true { self.shortcuts.suspend() }
                else { self.registerShortcuts() }
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            let isMenuBar = NSScreen.screens.contains {
                $0.frame.contains(point) && point.y >= $0.frame.maxY - max(28, $0.safeAreaInsets.top)
            }
            if !isMenuBar { self?.model.outsideClick() }
        }
        // Partial downloads of a previous run have no row to resume them from.
        model.downloads.discardStaleWorkingFiles()
        // Give the status-item scene its image before applying a menu-bar restriction.
        updateStatus(); model.start()
        readyForDocuments = true
        let arguments = CommandLine.arguments.dropFirst()
        let fileArguments = arguments.filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        let documents = (pendingDocuments + fileArguments).filter { seen.insert($0.standardizedFileURL.path).inserted }
        pendingDocuments.removeAll()
        if !documents.isEmpty {
            archives.open(documents)
        } else if arguments.contains("--archives") {
            openArchives()
        } else if arguments.contains("--arrange-menu-bar") {
            model.beginMenuBarArrangement()
        } else if !UserDefaults.standard.bool(forKey: "hasLaunched") || ProcessInfo.processInfo.arguments.contains("--settings") {
            showSettings(); UserDefaults.standard.set(true, forKey: "hasLaunched")
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard readyForDocuments else { pendingDocuments.append(contentsOf: urls); return }
        archives.open(urls)
    }

    private func checkInstallation() -> Bool {
        // macOS 27 resolves assessment-mode allowlists through LaunchServices. A copy
        // launched from a build/download folder can lose its own control icon.
        let location = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard !location.path.hasPrefix("/Applications/") || location.pathExtension != "app" else { return true }

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        let installed = URL(fileURLWithPath: "/Applications/BStoeq.app", isDirectory: true)
        let hasInstalledCopy = Bundle(url: installed)?.bundleIdentifier == AppModel.bundleID
        let alert = NSAlert()
        alert.messageText = L("BStoeq’i Uygulamalar klasöründen aç")
        alert.informativeText = L("Menü çubuğu simgesinin görünmesi için BStoeq.app dosyasını Uygulamalar klasörüne taşı ve oradan aç. Kayıtlı ayarların korunur.")
        alert.addButton(withTitle: hasInstalledCopy ? L("Kurulu BStoeq’i aç") : L("Uygulamalar klasörünü aç"))
        alert.addButton(withTitle: L("BStoeq’ten çık"))
        if alert.runModal() == .alertFirstButtonReturn {
            let destination = hasInstalledCopy ? installed : installed.deletingLastPathComponent()
            if !NSWorkspace.shared.open(destination) {
                let failure = NSAlert()
                failure.messageText = L("Uygulamalar klasörü açılamadı. Finder’dan /Applications/BStoeq.app dosyasını aç.")
                failure.runModal()
            }
        }
        NSApp.terminate(nil)
        return false
    }

    private func registerShortcuts() {
        model.shortcutError = shortcuts.register(model.preferences)
    }
    private func showMenuPermissionHelp(for app: BarApp) {
        model.hide()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Uygulama menülerini açmak için izin gerekiyor")
        alert.informativeText = L("BStoeq’in diğer uygulamaların sağ ve sol tık menülerini açabilmesi için Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik bölümünde BStoeq’i etkinleştir. Bu izin olmadan yalnızca simgeyi üst çubukta gösterebiliriz.")
        alert.addButton(withTitle: L("Sistem Ayarlarını aç"))
        alert.addButton(withTitle: L("Yalnızca üst çubukta göster"))
        alert.addButton(withTitle: L("Vazgeç"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.requestAccessibility()
        case .alertSecondButtonReturn: model.selectPanelApp(app, revealOnly: true)
        default: break
        }
    }
    private func updateStatus() {
        hoverMonitor.setEnabled(!model.arrangingMenuBar && model.preferences.revealOnHover && model.trusted)
        revealPanel.sync(model: model)
        guard let button = statusItem?.button else { return }
        let symbol = model.arrangingMenuBar ? "arrow.left.and.right" : model.expanded ? (model.panelPresented ? "chevron.up" : "chevron.right") : model.preferences.icon
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BStoeq")
        button.image?.isTemplate = true
        button.setAccessibilityLabel(L("BStoeq — gizli simgeleri göster veya gizle"))
        let action = model.expanded ? L("Simgeleri gizle") : L("Gizlileri göster")
        button.toolTip = "BStoeq · \(action) · \(model.preferences.toggleShortcut.displayLabel(using: model.localizer))\n" + L("Sağ tık: seçenekler · ⌥ tık: tümünü göster") + "\n" + L("⌘ sürükle: simgenin yerini değiştir")
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        // A native Command-drag release must not toggle hiding or open the reveal panel.
        if event?.type == .leftMouseUp && event?.modifierFlags.contains(.command) == true { return }
        revealPanel.rememberAnchor(NSEvent.mouseLocation)
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            if model.arrangingMenuBar {
                menu.addItem(withTitle: L("Düzenlemeyi bitir"), action: #selector(finishArrangement), keyEquivalent: "")
                menu.addItem(withTitle: L("BStoeq ayarları…"), action: #selector(openSettings), keyEquivalent: "")
                menu.addItem(.separator())
                menu.addItem(withTitle: L("BStoeq’ten çık"), action: #selector(quit), keyEquivalent: "")
                for item in menu.items { item.target = self }
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                return
            }
            menu.addItem(withTitle: L("Menü çubuğunu düzenle…"), action: #selector(beginArrangement), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: model.expanded ? L("Gizli simgeleri kapat") : L("Gizli simgeleri göster"), action: #selector(toggleItems), keyEquivalent: "")
            menu.addItem(withTitle: L("Tüm simgeleri geri getir"), action: #selector(showAll), keyEquivalent: "")
            let modeMenu = NSMenu(title: L("Açılma biçimi"))
            for mode in RevealMode.allCases {
                let item = modeMenu.addItem(withTitle: L(mode.title), action: #selector(changeRevealMode(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = mode.rawValue
                item.state = model.preferences.revealMode == mode ? .on : .off
            }
            let modeItem = menu.addItem(withTitle: L("Açılma biçimi"), action: nil, keyEquivalent: "")
            modeItem.submenu = modeMenu
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Video veya müzik indir…"), action: #selector(openDownloads), keyEquivalent: "")
            menu.addItem(withTitle: L("Disk alanını tara…"), action: #selector(openDisk), keyEquivalent: "")
            menu.addItem(withTitle: L("Temizliği aç…"), action: #selector(openCleanup), keyEquivalent: "")
            menu.addItem(withTitle: L("Arşiv yöneticisini aç…"), action: #selector(openArchives), keyEquivalent: "")
            menu.addItem(withTitle: L("BStoeq ayarları…"), action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(withTitle: L("BStoeq’ten çık"), action: #selector(quit), keyEquivalent: "")
            for item in menu.items { item.target = self }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } else if model.arrangingMenuBar { arrangementPanel.show(model: model) }
        else if event?.modifierFlags.contains(.option) == true { model.revealEverything() }
        else { model.toggle() }
    }
    @objc private func changeRevealMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = RevealMode(rawValue: raw) else { return }
        model.update { $0.revealMode = mode }
    }
    @objc private func beginArrangement() { model.beginMenuBarArrangement() }
    @objc private func finishArrangement() { model.finishMenuBarArrangement() }
    @objc private func toggleItems() { model.toggle() }
    @objc private func showAll() { model.revealEverything() }
    @objc private func openSettings() { showSettings() }
    @objc private func openDownloads() { model.selection = "downloads"; showSettings() }
    @objc private func openDisk() { model.selection = "disk"; showSettings() }
    @objc private func openCleanup() { model.selection = "cache"; showSettings() }
    @objc private func openArchives() {
        if model.arrangingMenuBar { model.finishMenuBarArrangement() }
        if model.panelPresented { model.hide() }
        archives.show()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func showSettings() {
        if model.arrangingMenuBar { model.finishMenuBarArrangement() }
        if model.panelPresented { model.hide() }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "BStoeq"; window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentView = NSHostingView(rootView: SettingsView(model: model).padding(.top, 28))
            window.minSize = NSSize(width: 980, height: 750)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.identifier = AppModel.settingsWindowID
            window.center(); window.setFrameAutosaveName("Barlet.Settings")
            settingsWindow = window
        }
        // Settings remain usable without turning this menu-bar utility into a
        // regular Dock app. Keep the accessory policy for the entire lifetime.
        NSApp.setActivationPolicy(.accessory)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // A reopened window does not replay onAppear; restart the live editor only
        // when its page is the one on screen. Other pages never read the menu bar.
        if model.selection == "menu" { model.menuLayout.start() }
        model.refreshLoginState()
        NSApp.activate()
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            model.finishMenuBarArrangement()
            model.menuLayout.stop()
        }
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        archives.canTerminate() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        archives.shutDown()
        hoverMonitor.stop(); model.stop(); shortcuts?.stop(); revealPanel.stop(); menuAccess.cancel(); arrangementPanel.close()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("BStoeq ayarları…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: L("Arşiv yöneticisini aç…"), action: #selector(openArchives), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("Menü çubuğunu düzenle…"), action: #selector(beginArrangement), keyEquivalent: "").target = self
        // This utility stays in the menu bar when settings close. Keep explicit
        // quit in the status-item menu only, with no accidental Command-Q exit.
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: L("Düzen"))
        for (title, selector, key) in [(L("Geri al"), "undo:", "z"), (L("Kes"), "cut:", "x"), (L("Kopyala"), "copy:", "c"), (L("Yapıştır"), "paste:", "v"), (L("Tümünü seç"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: L("Pencere"))
        windowMenu.addItem(withTitle: L("Kapat"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }
}
