import Foundation

enum AppLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en"
    case japanese = "ja"
    case chinese = "zh-Hans"

    static let defaultsKey = "appLanguageV1"

    var nativeName: String {
        switch self {
        case .korean: return "한국어"
        case .english: return "English"
        case .japanese: return "日本語"
        case .chinese: return "简体中文"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .korean: return "ko_KR"
        case .english: return "en_US"
        case .japanese: return "ja_JP"
        case .chinese: return "zh_CN"
        }
    }

    fileprivate var translationIndex: Int? {
        switch self {
        case .korean: return nil
        case .english: return 0
        case .japanese: return 1
        case .chinese: return 2
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .korean
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("local.mac-thermal.languageDidChange")
}

/// App-only language choice. It never changes the user's macOS language settings.
enum L10n {
    private static let lock = NSLock()
    private static var selectedLanguage = AppLanguage.load()

    static var language: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return selectedLanguage
    }

    static func setLanguage(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        lock.lock()
        let changed = selectedLanguage != language
        selectedLanguage = language
        language.save(defaults: defaults)
        lock.unlock()
        guard changed else { return }
        let notify = { NotificationCenter.default.post(name: .appLanguageDidChange, object: nil) }
        if Thread.isMainThread { notify() }
        else { DispatchQueue.main.async(execute: notify) }
    }

    // Korean keys are also the Korean source text. Translations are original
    // project text ordered as English, Japanese, and Simplified Chinese.
    static let translations: [String: [String]] = panelTranslations.merging(systemTranslations) { panel, _ in panel }.merging(cleanupTranslations) { existing, _ in existing }

    static func text(_ key: String) -> String {
        text(key, language: language)
    }

    static func text(_ key: String, language: AppLanguage) -> String {
        guard let index = language.translationIndex,
              let values = translations[key], values.indices.contains(index) else { return key }
        return values[index]
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, language: language, arguments: arguments)
    }

    static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        formatted(key, language: language, arguments: arguments)
    }

    private static func formatted(_ key: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        String(format: text(key, language: language), locale: Locale(identifier: language.localeIdentifier), arguments: arguments)
    }
}
