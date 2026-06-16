import Foundation
import SwiftUI

/// 全 App 唯一的本地化中枢。`@Published language` 改变时，所有观察它的 SwiftUI 视图
/// （含各个独立 NSHostingController 窗口 + 菜单栏 popover）同时失效重渲染 → 切换语言实时生效、无需重启。
///
/// 字符串来源：bundle 里的 `<lang>.strings`。加载用多策略兜底（参考 ReleaseNotesLoader）：
/// 因为本项目把 `VowKy/Resources` 当 group 扁平化加入 bundle，`.strings` 实际落在 Contents/Resources 根，
/// 所以平铺 basename 是主路径；子目录 / `.lproj` 作为防御性兜底，万一 XcodeGen 行为变化也不至于全空。
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published private(set) var language: AppLanguage

    private var table: [String: String]

    private init() {
        let lang = LanguagePreferenceStore.load()
        self.language = lang
        self.table = LocalizationManager.loadTable(for: lang)
    }

    /// 切换语言：持久化 + 重载字符串表 + 触发全量重渲染。
    func setLanguage(_ lang: AppLanguage) {
        guard lang != language else { return }
        LanguagePreferenceStore.save(lang)
        table = LocalizationManager.loadTable(for: lang)
        language = lang   // @Published → objectWillChange → 所有依赖视图重算 body
    }

    /// 查表取本地化串；命中后用 String(format:) 处理 %@ / %lld 等占位符。查不到回退 key 本身（保证不空白、不崩）。
    func string(_ key: String, _ args: CVarArg...) -> String {
        string(key, arguments: args)
    }

    /// 数组版（供变参转发，避免变参套娃）。
    func string(_ key: String, arguments args: [CVarArg]) -> String {
        let format = table[key] ?? key
        guard !args.isEmpty else { return format }
        return String(format: format, arguments: args)
    }

    // MARK: - 多策略加载

    /// 非隔离的一次性查表（不走缓存）：给 @MainActor 之外的调用方用（如 ReleaseNotesLoader、错误串、测试）。
    nonisolated static func string(_ key: String, language: AppLanguage, _ args: CVarArg...) -> String {
        string(key, language: language, arguments: args)
    }

    nonisolated static func string(_ key: String, language: AppLanguage, arguments args: [CVarArg]) -> String {
        let format = loadTable(for: language)[key] ?? key
        guard !args.isEmpty else { return format }
        return String(format: format, arguments: args)
    }

    nonisolated private static func loadTable(for lang: AppLanguage) -> [String: String] {
        let code = lang.rawValue
        let bundle = Bundle.main

        // 1) 平铺 basename：Contents/Resources/<lang>.strings（本项目实测命中这条）
        if let url = bundle.url(forResource: code, withExtension: "strings"),
           let dict = parseStrings(at: url) {
            return dict
        }
        // 2) 子目录：Contents/Resources/Localization/<lang>.strings
        if let url = bundle.url(forResource: code, withExtension: "strings", subdirectory: "Localization"),
           let dict = parseStrings(at: url) {
            return dict
        }
        // 3) 标准 .lproj：Contents/Resources/<lang>.lproj/Localizable.strings
        if let lprojPath = bundle.path(forResource: code, ofType: "lproj"),
           let lproj = Bundle(path: lprojPath),
           let url = lproj.url(forResource: "Localizable", withExtension: "strings"),
           let dict = parseStrings(at: url) {
            return dict
        }
        return [:]
    }

    /// 解析 .strings。注意：Xcode 构建时会把源文件（UTF-8 文本）转成 **UTF-16**（带 BOM）甚至二进制 plist，
    /// 直接按 UTF-8 读会失败返回空表 → 全 App 退化成显示 key。NSDictionary(contentsOf:) 能正确处理
    /// UTF-8 / UTF-16 / 二进制三种形态，是读 .strings 的稳健方式。
    nonisolated private static func parseStrings(at url: URL) -> [String: String]? {
        guard let dict = NSDictionary(contentsOf: url) as? [String: String], !dict.isEmpty else {
            return nil
        }
        return dict
    }
}

/// 非 SwiftUI 处（Service 错误、NSAlert、window.title 等）的便捷取串入口。
/// 注意：它不建立 SwiftUI 依赖，取的是「调用瞬间」的当前语言，适合一次性读取的场景。
@MainActor
func L(_ key: String, _ args: CVarArg...) -> String {
    LocalizationManager.shared.string(key, arguments: args)
}

/// 非隔离版取串：给 @MainActor 之外的调用方用（错误类型、AppDelegate 弹窗、后台服务）。
/// 语言从持久化偏好读取，反映用户当前选择；每次重新读表（仅用于低频错误/弹窗路径，开销可忽略）。
nonisolated func LL(_ key: String, _ args: CVarArg...) -> String {
    LocalizationManager.string(key, language: LanguagePreferenceStore.load(), arguments: args)
}
