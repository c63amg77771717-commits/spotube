import Foundation
import SwiftUI

@MainActor @Observable
final class LocalizationManager {
    enum Language: String, CaseIterable, Identifiable {
        case traditionalChinese = "zh-Hant"
        case english = "en"
        case japanese = "ja"
        case vietnamese = "vi"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .traditionalChinese: "繁體中文"
            case .english: "English"
            case .japanese: "日本語"
            case .vietnamese: "Tiếng Việt"
            }
        }

        var flag: String {
            switch self {
            case .traditionalChinese: "🇹🇼"
            case .english: "🇺🇸"
            case .japanese: "🇯🇵"
            case .vietnamese: "🇻🇳"
            }
        }

        /// Default InnerTube content language code (`hl`)
        var contentLanguage: String { rawValue }

        /// Default InnerTube region code (`gl`) paired with this language
        var contentRegion: String {
            switch self {
            case .traditionalChinese: "TW"
            case .english: "US"
            case .japanese: "JP"
            case .vietnamese: "VN"
            }
        }
    }

    @ObservationIgnored
    private static let defaultsKey = "appLanguage"

    var currentLanguage: Language {
        didSet {
            guard oldValue != currentLanguage else { return }
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: Self.defaultsKey)
            locale = Locale(identifier: currentLanguage.rawValue)
            refreshToken = UUID()
            syncContentLocale(currentLanguage)
        }
    }

    private(set) var locale: Locale
    private(set) var refreshToken: UUID = UUID()

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "zh-Hant"
        let lang = Language(rawValue: saved) ?? .traditionalChinese
        self.currentLanguage = lang
        self.locale = Locale(identifier: lang.rawValue)
    }

    func localizedString(_ key: String.LocalizationValue) -> String {
        Self.text(key)
    }

    nonisolated static func text(_ key: String.LocalizationValue) -> String {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hant"
        let langCode = ["zh-Hant", "en", "ja", "vi"].contains(saved) ? saved : "zh-Hant"
        guard let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return String(localized: key)
        }
        return String(localized: key, bundle: bundle)
    }

    /// Sync InnerTube content language & region to match app language
    private func syncContentLocale(_ lang: Language) {
        UserDefaults.standard.set(lang.contentLanguage, forKey: "language")
        UserDefaults.standard.set(lang.contentRegion, forKey: "region")
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}
