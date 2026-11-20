import AppKit
import SwiftUI

/// The host owns the application lifecycle, menus and language. File browsing and
/// archiving start when the first window, Finder action or document is requested.
@MainActor public final class ArchiveWindowController: NSObject {
    private var language: AppLanguage
    private let changeLanguage: (String) -> Void
    private var model: AppModel?
    private var window: NSWindow?

    public init(languageCode: String, onLanguageChange: @escaping (String) -> Void) {
        language = AppLanguage(rawValue: languageCode) ?? .english
        changeLanguage = onLanguageChange
        super.init()
    }

    public func updateLanguage(_ code: String) {
        language = AppLanguage(rawValue: code) ?? .english
        if let model, model.language != language { model.language = language }
        window?.title = windowTitle
    }

    private var windowTitle: String { "BStoeq — " + Localizer(language: language).text("Archive manager") }

    public func show() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        _ = present(in: downloads ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    public func open(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard let first = files.first else { return }
        let directory = files.count == 1 && (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let model = present(in: directory ? first : first.deletingLastPathComponent())
        if directory {
            guard !model.busy, model.sheet == nil else {
                model.error = "Finish the current operation or close the dialog first."
                return
            }
            model.open(first)
        } else {
            model.receive(files)
        }
    }

    private func present(in initialFolder: URL) -> AppModel {
        if let window, let model {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return model
        }
        let model = AppModel(language: language, initialFolder: initialFolder) { [weak self] selected in
            self?.updateLanguage(selected.rawValue)
            self?.changeLanguage(selected.rawValue)
        }
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = windowTitle
        window.identifier = NSUserInterfaceItemIdentifier("BStoeq.ArchiveWorkspace")
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 940, height: 640)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(model: model).padding(.top, 28))
        window.center()
        window.setFrameAutosaveName("BStoeq.ArchiveWorkspace")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return model
    }

    /// Called by the host's local key monitor before its own shortcuts.
    public func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let window, let model, let keyWindow = NSApp.keyWindow, event.type == .keyDown,
              event.window === keyWindow, keyWindow === window || keyWindow.sheetParent === window,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == [.command, .shift], key == "z" {
            return NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: keyWindow)
        }
        guard modifiers == .command, [",", "o", "n", "e", "t", "w", "r", "0"].contains(key) else { return false }
        guard keyWindow === window, window.attachedSheet == nil, model.sheet == nil else { return true }
        if key == "w" { window.performClose(nil); return true }
        if key == "0" { show(); return true }
        guard !model.busy else { return true }
        switch key {
        case ",": model.sheet = .settings
        case "o": model.openDialog()
        case "n": model.prepareCreate()
        case "e": if model.isArchive { model.prepareExtract() }
        case "t": if model.isArchive { model.testArchive() }
        case "r": model.refresh()
        default: break
        }
        return true
    }

    /// Install this controller as NSApp.servicesProvider. macOS appends
    /// userData:error: to the NSMessage declared by the host's Info.plist.
    @objc(bstoeqArchiveService:userData:error:)
    public func bstoeqArchiveService(_ pasteboard: NSPasteboard, userData: String?,
                                     error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let text = Localizer(language: language).text
        guard let first = files.first else {
            error?.pointee = text("Select files or an archive in Finder.") as NSString
            return
        }
        let action = userData ?? "open"
        guard action == "compress" || files.count == 1 else {
            error?.pointee = text("Select one archive for this action.") as NSString
            return
        }
        let model = present(in: first.deletingLastPathComponent())
        guard !model.busy, model.sheet == nil else {
            error?.pointee = text("Finish the current operation or close the dialog first.") as NSString
            return
        }
        model.handleFinderService(action, urls: files)
    }

    public func canTerminate() -> Bool {
        guard let model, model.busy else { return true }
        show()
        let alert = NSAlert()
        alert.messageText = model.L("An operation is still running")
        alert.informativeText = model.L("Cancel the operation before quitting.")
        alert.addButton(withTitle: model.L("OK"))
        alert.runModal()
        return false
    }

    public func shutDown() {
        model?.cleanUp()
        window?.orderOut(nil)
        window = nil
        model = nil
    }
}
