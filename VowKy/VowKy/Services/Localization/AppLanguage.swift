import Foundation

/// App 内可选语言。默认英文。rawValue 同时用作 .strings/.lproj/release-notes 的语言标识。
enum AppLanguage: String, CaseIterable, Identifiable {
    case en
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    /// 选择器里展示的名字（各自用本语言书写，便于用户在任意当前语言下都认得出）。
    var displayName: String {
        switch self {
        case .en:     return "English"
        case .zhHans: return "简体中文"
        }
    }
}
