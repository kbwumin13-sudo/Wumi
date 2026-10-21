import Foundation
import SwiftUI

/// In-app language choice. "system" follows macOS; others switch every DirDesk window immediately.
/// The same ten languages as the original; the picker lists those whose table is in the app bundle.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case brazilianPortuguese = "pt-BR"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    /// Names are shown in their own language, like the original language picker.
    var displayName: String {
        switch self {
        case .system: L("System Default")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .italian: "Italiano"
        case .brazilianPortuguese: "Português (Brasil)"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    /// Languages offered in Settings: System Default, English and every language with a table in the bundle.
    static var available: [AppLanguage] {
        allCases.filter { $0 == .system || $0 == .english || Bundle.main.path(forResource: $0.rawValue, ofType: "lproj") != nil }
    }

    var resolvedCode: String {
        switch self {
        case .system:
            let supported = Self.available.filter { $0 != .system }.map(\.rawValue)
            return Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages).first ?? "en"
        default:
            return rawValue
        }
    }

    /// Locale used for dates and numbers in this language.
    static func localeIdentifier(for code: String) -> String {
        switch code {
        case "zh-Hans": "zh_Hans_CN"
        case "zh-Hant": "zh_Hant_TW"
        case "fr": "fr_FR"
        case "de": "de_DE"
        case "es": "es_ES"
        case "it": "it_IT"
        case "pt-BR": "pt_BR"
        case "ja": "ja_JP"
        case "ko": "ko_KR"
        default: "en_US"
        }
    }
}

/// Looks up strings in the selected language's table, falling back to the English key.
final class Localizer: @unchecked Sendable {
    static let shared = Localizer()

    private let lock = NSLock()
    private var bundle: Bundle?
    private(set) var code = "en"

    init() {
        let stored = UserDefaults.standard.string(forKey: "dirdesk-app-language-v1").flatMap(AppLanguage.init) ?? .system
        apply(stored)
    }

    func apply(_ language: AppLanguage) {
        let code = language.resolvedCode
        let path = Bundle.main.path(forResource: code, ofType: "lproj")
        lock.lock()
        self.code = code
        bundle = path.flatMap(Bundle.init(path:))
        lock.unlock()
    }

    func string(_ key: String) -> String {
        lock.lock()
        let bundle = self.bundle
        lock.unlock()
        guard let bundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    var locale: Locale {
        Locale(identifier: AppLanguage.localeIdentifier(for: code))
    }
}

/// Localized string for an English source key.
func L(_ key: String) -> String {
    Localizer.shared.string(key)
}

/// Localized format string with arguments, e.g. LF("%lld items", count).
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localizer.shared.string(key), locale: Localizer.shared.locale, arguments: arguments)
}
