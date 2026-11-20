import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, turkish = "tr", english = "en", german = "de"

    public func resolved(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferred {
            let code = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
            if let language = AppLanguage(rawValue: code.lowercased()), language != .system { return language }
        }
        return .english
    }
    public var nativeName: String {
        switch self {
        case .system: "Sistem dilini kullan"
        case .turkish: "Türkçe"
        case .english: "English"
        case .german: "Deutsch"
        }
    }
}

public struct Localizer: Sendable {
    public let language: AppLanguage
    public init(language: AppLanguage, preferred: [String] = Locale.preferredLanguages) {
        self.language = language.resolved(preferred: preferred)
    }
    public static let catalog: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "Localization", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            assertionFailure("Missing localization catalog")
            return [:]
        }
        return catalog
    }()
    public func text(_ key: String, _ arguments: CVarArg...) -> String { text(key, arguments: arguments) }
    public func text(_ key: String, arguments: [CVarArg]) -> String {
        let template = Self.catalog[key]?[language.rawValue] ?? Self.catalog[key]?["en"] ?? key
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
    public func appCount(_ count: Int) -> String {
        count == 1 ? text("Bir uygulama için daha sade bir menü çubuğu.") : text("%d uygulama için daha sade bir menü çubuğu.", count)
    }
    public func seconds(_ count: Int) -> String {
        count == 1 ? text("1 saniye") : text("%d saniye", count)
    }
}

/// Store message keys rather than translated text so existing banners change language, too.
public struct UserMessage: Equatable, Sendable {
    public let key: String
    public let detail: String?
    public init(_ key: String, detail: String? = nil) { self.key = key; self.detail = detail }
    public func text(using localizer: Localizer) -> String {
        detail.map { localizer.text(key, $0) } ?? localizer.text(key)
    }
}
