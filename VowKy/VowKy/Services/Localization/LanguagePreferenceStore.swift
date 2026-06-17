import Foundation

/// 语言偏好持久化。镜像 TranslationConfigStore / HotkeyConfig 的写法：纯静态 load/save，UserDefaults 存储。
enum LanguagePreferenceStore {

    enum Keys {
        static let appLanguage = "app.language"
    }

    /// 读不到偏好 → 默认中文（**不**查系统语言）。这就是「默认中文，无视系统语言」的强制点。
    static func load(defaults: UserDefaults = .standard) -> AppLanguage {
        guard let raw = defaults.string(forKey: Keys.appLanguage),
              let lang = AppLanguage(rawValue: raw) else {
            return .zhHans
        }
        return lang
    }

    static func save(_ lang: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(lang.rawValue, forKey: Keys.appLanguage)
    }
}
