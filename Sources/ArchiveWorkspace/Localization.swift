import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case turkish = "tr", english = "en", german = "de"
    var id: String { rawValue }
    var title: String { switch self { case .turkish: "Türkçe"; case .english: "English"; case .german: "Deutsch" } }
}

struct Localizer {
    let language: AppLanguage
    static let catalog: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return values
    }()
    func text(_ key: String) -> String {
        for prefix in ["ARCHIVE_PATH_CONFLICT", "ARCHIVE_RENAME_CONFLICT", "SOURCE_MISSING"] where key.hasPrefix(prefix + ": ") {
            return (Self.catalog[prefix]?[language.rawValue] ?? prefix) + "\n" + String(key.dropFirst(prefix.count + 2))
        }
        return Self.catalog[key]?[language.rawValue] ?? key
    }
}

/// Keep status and alert text localizable while the workspace is open; paths and
/// other tool-provided details remain verbatim when the host changes language.
struct ArchiveNotice: ExpressibleByStringLiteral {
    let key: String
    let detail: String?

    init(_ key: String, detail: String? = nil) {
        self.key = key
        self.detail = detail
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    func text(using translate: (String) -> String, separator: String = "\n") -> String {
        guard let detail, !detail.isEmpty else { return translate(key) }
        return translate(key) + separator + detail
    }
}
