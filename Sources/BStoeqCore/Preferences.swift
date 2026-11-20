import Foundation

public enum RevealMode: String, Codable, CaseIterable, Sendable {
    case menuBar, bar, list
    public var title: String {
        switch self {
        case .menuBar: "Üst menü çubuğu"
        case .bar: "Alt simge çubuğu"
        case .list: "Aramalı liste"
        }
    }
    public var symbol: String {
        switch self {
        case .menuBar: "menubar.rectangle"
        case .bar: "rectangle.bottomthird.inset.filled"
        case .list: "list.bullet.rectangle"
        }
    }
}

public enum ItemVisibility: String, Codable, CaseIterable, Sendable {
    case visible, hidden, alwaysHidden
    public var title: String {
        switch self {
        case .visible: "Her zaman görünür"
        case .hidden: "Gizli"
        case .alwaysHidden: "Daima gizli"
        }
    }
    public var symbol: String {
        switch self {
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "lock"
        }
    }
}

public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public static let toggle = Shortcut(keyCode: 11, modifiers: 2304, label: "⌥ ⌘ B")
    public static let settings = Shortcut(keyCode: 40, modifiers: 2304, label: "⌥ ⌘ K")
    public static let recovery = Shortcut(keyCode: 29, modifiers: 2304, label: "⌥ ⌘ 0")
    public func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    public var isValid: Bool {
        keyCode <= 126 && !(53...63).contains(keyCode) &&
        modifiers & ~UInt32(256 | 512 | 2048 | 4096) == 0 && modifiers & UInt32(256 | 2048 | 4096) != 0
    }
    public func displayLabel(using localizer: Localizer) -> String {
        guard keyCode == 49 else { return label }
        let symbols = [(UInt32(4096), "⌃"), (2048, "⌥"), (512, "⇧"), (256, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1)
        return (symbols + [localizer.text("Boşluk")]).joined(separator: " ")
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var assignments: [String: ItemVisibility] = [:]
    public var names: [String: String] = [:]
    public var autoHide = true
    public var autoHideDelay: Double = 5
    public var hideOnOutsideClick = true
    public var revealOnHover = false
    public var showWhenActive = false
    public var icon = "circle.lefthalf.filled"
    public var toggleShortcut = Shortcut.toggle
    public var settingsShortcut = Shortcut.settings
    public var appearance = "system"
    public var language: AppLanguage = .system
    public var revealMode: RevealMode = .bar
    public var downloadKind: MediaKind = .video
    public var videoQuality: VideoQuality = .p1080
    public var audioFormat: AudioFormat = .mp3
    /// Empty means the user's Downloads folder.
    public var downloadFolder = ""
    /// For a video link that also names a playlist: take the whole list.
    public var downloadWholePlaylist = true
    public static let iconNames = ["circle.lefthalf.filled": "Yarım daire", "ellipsis": "Noktalar", "chevron.left": "Ok", "square.grid.2x2": "Izgara", "leaf": "Yaprak"]
    public static let icons = ["circle.lefthalf.filled", "ellipsis", "chevron.left", "square.grid.2x2", "leaf"]
    public init() {}

    // A missing key in an older settings file must not erase existing assignments.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try c.decodeIfPresent([String: ItemVisibility].self, forKey: .assignments) ?? [:]
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        autoHide = try c.decodeIfPresent(Bool.self, forKey: .autoHide) ?? true
        autoHideDelay = min(60, max(1, try c.decodeIfPresent(Double.self, forKey: .autoHideDelay) ?? 5))
        hideOnOutsideClick = try c.decodeIfPresent(Bool.self, forKey: .hideOnOutsideClick) ?? true
        revealOnHover = try c.decodeIfPresent(Bool.self, forKey: .revealOnHover) ?? false
        showWhenActive = try c.decodeIfPresent(Bool.self, forKey: .showWhenActive) ?? false
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "circle.lefthalf.filled"
        toggleShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .toggleShortcut) ?? .toggle
        settingsShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .settingsShortcut) ?? .settings
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        // Existing v1.0 users keep Turkish. Fresh installs follow their system language.
        language = AppLanguage(rawValue: try c.decodeIfPresent(String.self, forKey: .language) ?? "tr") ?? .system
        // Preserve the original behavior when restoring an older settings file.
        revealMode = RevealMode(rawValue: try c.decodeIfPresent(String.self, forKey: .revealMode) ?? "menuBar") ?? .menuBar
        // Unknown values from a newer or edited file fall back instead of failing the import.
        downloadKind = MediaKind(rawValue: try c.decodeIfPresent(String.self, forKey: .downloadKind) ?? "") ?? .video
        videoQuality = VideoQuality(rawValue: try c.decodeIfPresent(String.self, forKey: .videoQuality) ?? "") ?? .p1080
        audioFormat = AudioFormat(rawValue: try c.decodeIfPresent(String.self, forKey: .audioFormat) ?? "") ?? .mp3
        downloadFolder = try c.decodeIfPresent(String.self, forKey: .downloadFolder) ?? ""
        downloadWholePlaylist = try c.decodeIfPresent(Bool.self, forKey: .downloadWholePlaylist) ?? true
        normalize()
    }

    public mutating func normalize() {
        // Names only label saved rules for apps that are not running; drop the rest.
        if names.count > assignments.count || names.keys.contains(where: { assignments[$0] == nil }) {
            names = names.filter { assignments[$0.key] != nil }
        }
        if !autoHideDelay.isFinite { autoHideDelay = 5 }
        autoHideDelay = min(60, max(1, autoHideDelay.rounded()))
        if !Self.icons.contains(icon) { icon = Self.icons[0] }
        if !["system", "light", "dark"].contains(appearance) { appearance = "system" }
        if !toggleShortcut.isValid || toggleShortcut.matches(.recovery) { toggleShortcut = .toggle }
        if !settingsShortcut.isValid || settingsShortcut.matches(.recovery) { settingsShortcut = .settings }
        if toggleShortcut.matches(settingsShortcut) { toggleShortcut = .toggle; settingsShortcut = .settings }
        if !downloadFolder.isEmpty && !downloadFolder.hasPrefix("/") { downloadFolder = "" }
    }
}

public enum VisibilityPlan {
    public static func hiddenIDs(assignments: [String: ItemVisibility], expanded: Bool,
                                 revealAll: Bool, frontmost: String?, showWhenActive: Bool,
                                 ownID: String, mode: RevealMode = .menuBar,
                                 selectedAppID: String? = nil) -> Set<String> {
        guard !revealAll else { return [] }
        return Set(assignments.compactMap { id, visibility in
            guard id != ownID, !id.hasPrefix("com.apple.") else { return nil }
            switch visibility {
            case .visible: return nil
            case .alwaysHidden: return id
            case .hidden:
                return (expanded && (mode == .menuBar || id == selectedAppID)) ||
                    (showWhenActive && id == frontmost) ? nil : id
            }
        })
    }
    public static func allowedIDs(running: Set<String>, hidden: Set<String>, ownID: String) -> Set<String> {
        running.subtracting(hidden).union([ownID])
    }
}
