import AppKit
import SwiftUI

/// Native menu-bar controls belong to macOS. These routes only open their settings;
/// they never write Control Center preferences or toggle the user's network.
@MainActor
enum SystemMenuSettings {
    enum Kind: String, CaseIterable, Identifiable {
        case wifi, battery, clock
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .battery: "Pil"
            case .clock: "Saat ve tarih"
            }
        }

        var descriptionKey: String {
            switch self {
            case .wifi: "Menü Çubuğu bölümünde Wi-Fi simgesini göster veya gizle."
            case .battery: "Pil simgesini göster veya gizle; Pil Seçenekleri’nden yüzdeyi ayarla."
            case .clock: "Saat Seçenekleri’nden tarihi, günü, saniyeyi ve saat görünümünü ayarla."
            }
        }

        var symbol: String {
            switch self {
            case .wifi: "wifi"
            case .battery: "battery.100percent"
            case .clock: "clock"
            }
        }

        fileprivate var anchor: String {
            switch self {
            case .wifi: "WiFi"
            case .battery: "Battery"
            case .clock: "Clock"
            }
        }
    }

    static let failureKey = "Sistem Ayarları açılamadı. Uygulamalar klasöründen açıp Menü Çubuğu bölümüne gidebilirsin."
    private static let paneURL = "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"

    /// The Menu Bar extension and these routes are present on macOS 27. Clock opens
    /// Clock Options; Wi-Fi and Battery lead to the Menu Bar page with those controls.
    /// An accepted URL means macOS received the request, not that settings were changed.
    @discardableResult
    static func open(_ kind: Kind) -> Bool {
        let workspace = NSWorkspace.shared
        if let preciseURL = URL(string: "\(paneURL)?\(kind.anchor)"), workspace.open(preciseURL) {
            return true
        }
        if let fallbackURL = URL(string: paneURL), workspace.open(fallbackURL) {
            return true
        }
        return false
    }

    /// Only route Apple's menu extras. A third-party app with “battery” or “Wi-Fi”
    /// in its name must keep its own menu rather than being mistaken for a system item.
    static func kind(identifier: String?, name: String, bundleID: String) -> Kind? {
        guard bundleID.hasPrefix("com.apple.") else { return nil }
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        let identity = normalized([bundleID, identifier ?? ""].joined(separator: "."))
        if identity.contains("wifi") || identity.contains("airport") { return .wifi }
        if identity.contains("battery") { return .battery }
        if identity.contains("clock") || identity.contains("datetime") { return .clock }
        let label = normalized(name)
        if ["wifi", "wlan"].contains(label) { return .wifi }
        if ["battery", "pil", "batterie"].contains(label) { return .battery }
        if ["clock", "saat", "uhr", "saatvetarih", "dateandtime", "datumunduhrzeit"].contains(label) { return .clock }
        return nil
    }
}

struct SystemMenuSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var settingsUnavailable = false

    private func L(_ key: String) -> String { model.localizer.text(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "switch.2").foregroundStyle(Palette.accent)
                Text(L("Wi-Fi, pil ve saat")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("macOS").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(L("Bu simgelerin görünürlüğünü ve görünümünü macOS ayarlarından değiştirebilirsin."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SystemMenuSettings.Kind.allCases) { kind in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 17)).foregroundStyle(Palette.accent)
                        .frame(width: 27)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L(kind.titleKey)).font(.system(size: 12, weight: .medium))
                        Text(L(kind.descriptionKey)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button {
                        settingsUnavailable = !SystemMenuSettings.open(kind)
                    } label: {
                        Label(L("macOS’ta düzenle"), systemImage: "arrow.up.forward")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("system-menu-settings-\(kind.rawValue)")
                    .accessibilityLabel("\(L(kind.titleKey)): \(L("macOS’ta düzenle"))")
                }
                if kind != .clock { Divider().opacity(0.5) }
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
        .alert(L("Sistem Ayarları açılamadı"), isPresented: $settingsUnavailable) {
            Button(L("Tamam"), role: .cancel) { }
        } message: {
            Text(L(SystemMenuSettings.failureKey))
        }
    }
}
