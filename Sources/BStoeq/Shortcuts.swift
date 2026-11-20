import AppKit
import Carbon
import SwiftUI
import BStoeqCore

extension Notification.Name {
    static let barletRecordingChanged = Notification.Name("BStoeq.RecordingChanged")
}

@MainActor final class ShortcutManager {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var configured: [Shortcut] = []
    private var suspended = false
    var action: ((UInt32) -> Void)?

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let owner = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
            owner.action?(id.id)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ preferences: Preferences) -> UserMessage? {
        unregister(); suspended = false
        configured = [preferences.toggleShortcut, preferences.settingsShortcut, .recovery]
        let localizer = Localizer(language: preferences.language)
        var failed: [String] = []
        // Recovery is reserved first even if a malformed old settings file slipped through.
        for index in [2, 0, 1] {
            let shortcut = configured[index]
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                EventHotKeyID(signature: 0x4241524C, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { references.append(reference) }
            else { failed.append(shortcut.displayLabel(using: localizer)) }
        }
        return failed.isEmpty ? nil : UserMessage("Bu kısayol kaydedilemedi: %@. Farklı bir kombinasyon seç.", detail: failed.joined(separator: ", "))
    }
    func suspend() { suspended = true; unregister() }
    private func unregister() { references.forEach { UnregisterEventHotKey($0) }; references.removeAll() }

    // App-targeted key events (including assistive input) do not always pass through
    // Carbon. Handle those locally. Carbon consumes physical registered hotkeys,
    // so they do not also arrive as keyDown events here.
    func handleLocal(_ event: NSEvent) -> Bool {
        guard !suspended, !event.isARepeat else { return false }
        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event), label: "")
        guard let index = configured.firstIndex(where: { $0.matches(candidate) }) else { return false }
        action?(UInt32(index + 1)); return true
    }
    static func modifiers(_ event: NSEvent) -> UInt32 {
        var result: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut
    let language: AppLanguage
    let onRecord: (Shortcut) -> Bool
    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton(); view.onRecord = onRecord; view.shortcut = shortcut
        view.localizer = Localizer(language: language); view.refreshTitle()
        return view
    }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.shortcut = shortcut; view.onRecord = onRecord; view.localizer = Localizer(language: language)
        view.refreshTitle()
    }
}

@MainActor final class RecorderButton: NSButton {
    var shortcut = Shortcut.toggle
    private(set) var recording = false
    var localizer = Localizer(language: .system)
    var onRecord: ((Shortcut) -> Bool)?
    private func L(_ key: String) -> String { localizer.text(key) }
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; isBordered = true
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self; action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refreshTitle() {
        title = recording ? L("Tuşlara bas…") : shortcut.displayLabel(using: localizer)
        setAccessibilityLabel(L("Klavye kısayolunu değiştir"))
    }
    private func setRecording(_ value: Bool) {
        guard value != recording else { return }
        recording = value
        NotificationCenter.default.post(name: .barletRecordingChanged, object: value)
    }
    // Take focus first: another recorder that is still recording announces its end
    // while resigning, and that must not re-enable the hotkeys after our own start.
    @objc private func begin() { window?.makeFirstResponder(self); setRecording(true); refreshTitle() }
    override func resignFirstResponder() -> Bool {
        setRecording(false); refreshTitle(); return super.resignFirstResponder()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { setRecording(false) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { setRecording(false); refreshTitle(); return }
        let modifiers = ShortcutManager.modifiers(event)
        var label = ""
        for (flag, symbol) in [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")] {
            if modifiers & flag != 0 { label += symbol + " " }
        }
        label += Self.keyLabel(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, space: L("Boşluk"))
        let next = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
        guard next.isValid else { title = L("⌘, ⌥ veya ⌃ ekle"); return }
        guard !next.matches(.recovery) else { title = L("Kurtarma için ayrıldı"); return }
        // Stop recording before the model re-registers hotkeys. Rejected combinations
        // restore the real saved label rather than pretending the edit succeeded.
        setRecording(false)
        if onRecord?(next) == true { shortcut = next }
        refreshTitle()
    }
    /// Function and navigation keys report private-use characters that no font can
    /// draw, so they are named by key code.
    static func keyLabel(keyCode: UInt16, characters: String?, space: String) -> String {
        let named: [UInt16: String] = [
            49: space, 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
            64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let name = named[keyCode] { return name }
        let text = characters?.uppercased() ?? ""
        let drawable = !text.isEmpty && text.unicodeScalars.allSatisfy {
            !(0xE000...0xF8FF).contains($0.value) && !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return drawable ? text : "#\(keyCode)"
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event)
    }
}
