import Foundation

// MARK: - Engine kind

enum TranslationEngineKind: String, Codable, CaseIterable {
    /// macOS 15+ 系统离线翻译（Translation framework）
    case apple
    /// OpenAI-compatible chat completions API（DeepSeek / Qwen / OpenAI 等）
    case llm
}

// MARK: - Target language

struct TranslationTarget: Equatable, Codable, Hashable {
    /// BCP-47 语言标识，如 "zh-Hans"、"en"、"ja"
    var bcp47: String

    var displayName: String {
        TranslationTarget.presets.first(where: { $0.target == self })?.name ?? bcp47
    }

    static let zhHans = TranslationTarget(bcp47: "zh-Hans")

    /// 设置页/窗口内语言菜单的预置列表
    static let presets: [(target: TranslationTarget, name: String)] = [
        (TranslationTarget(bcp47: "zh-Hans"), "简体中文"),
        (TranslationTarget(bcp47: "zh-Hant"), "繁體中文"),
        (TranslationTarget(bcp47: "en"), "English"),
        (TranslationTarget(bcp47: "ja"), "日本語"),
        (TranslationTarget(bcp47: "ko"), "한국어"),
        (TranslationTarget(bcp47: "fr"), "Français"),
        (TranslationTarget(bcp47: "de"), "Deutsch"),
        (TranslationTarget(bcp47: "es"), "Español"),
        (TranslationTarget(bcp47: "ru"), "Русский"),
    ]
}

// MARK: - Paragraph state

enum ParagraphTranslationState: Equatable {
    case pending
    case translated(String)
    case failed(String)
    /// 原文主语言与目标语言相同，无需翻译
    case skippedSameLanguage
}

/// 转写区一段原文 + 其译文状态。id 稳定（"c-N" 已定段 / "p-N" 预览段），供 SwiftUI diff。
struct TranscriptParagraph: Identifiable, Equatable {
    let id: String
    let text: String
    let isPartial: Bool
    var translation: ParagraphTranslationState
}

// MARK: - Config

struct TranslationConfig: Equatable {
    var enabled: Bool
    var engine: TranslationEngineKind
    var target: TranslationTarget
    var llmBaseURL: String
    var llmModel: String
    var llmAPIKey: String

    static let `default` = TranslationConfig(
        enabled: false,
        engine: TranslationConfig.defaultEngine,
        target: .zhHans,
        llmBaseURL: "",
        llmModel: "",
        llmAPIKey: ""
    )

    /// macOS 15+ 默认系统离线翻译；旧系统只能用 LLM
    static var defaultEngine: TranslationEngineKind {
        if #available(macOS 15.0, *) { return .apple }
        return .llm
    }

    /// 当前配置下 LLM 引擎是否填齐了必要项
    var isLLMConfigured: Bool {
        !llmBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !llmModel.trimmingCharacters(in: .whitespaces).isEmpty
            && !llmAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - LLM 服务商预设（设置页「快速填入」）

struct TranslationLLMPreset: Identifiable {
    /// 本地化 key；展示时由调用方 loc.string(titleKey) 解析。
    let titleKey: String
    let baseURL: String
    let model: String
    var id: String { baseURL }

    /// 排序即推荐顺序。基于 2026-06 调研：Qwen-MT 为专用翻译模型，
    /// 速度/质量/价格/国内直连综合最优；Groq 面向海外用户延迟最低。
    static let all: [TranslationLLMPreset] = [
        TranslationLLMPreset(
            titleKey: "llm.preset.qwenMt",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-mt-turbo"
        ),
        TranslationLLMPreset(
            titleKey: "llm.preset.deepseek",
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat"
        ),
        TranslationLLMPreset(
            titleKey: "llm.preset.glm",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            model: "glm-4-flash"
        ),
        TranslationLLMPreset(
            titleKey: "llm.preset.doubao",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            model: ""
        ),
        TranslationLLMPreset(
            titleKey: "llm.preset.groq",
            baseURL: "https://api.groq.com/openai/v1",
            model: "llama-3.3-70b-versatile"
        ),
    ]
}

// MARK: - UserDefaults persistence

enum TranslationConfigStore {

    enum Keys {
        static let enabled        = "translation.enabled"
        static let engine         = "translation.engine"
        static let targetLanguage = "translation.targetLanguage"
        static let llmBaseURL     = "translation.llm.baseURL"
        static let llmModel       = "translation.llm.model"
        static let llmAPIKey      = "translation.llm.apiKey"
    }

    static func load(defaults: UserDefaults = .standard) -> TranslationConfig {
        let enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? TranslationConfig.default.enabled

        var engine = defaults.string(forKey: Keys.engine)
            .flatMap(TranslationEngineKind.init(rawValue:)) ?? TranslationConfig.defaultEngine
        // 旧系统上存了 apple（如迁移机器）→ 强制回落 llm
        if engine == .apple, #unavailable(macOS 15.0) {
            engine = .llm
        }

        let target = defaults.string(forKey: Keys.targetLanguage)
            .map { TranslationTarget(bcp47: $0) } ?? TranslationConfig.default.target

        return TranslationConfig(
            enabled: enabled,
            engine: engine,
            target: target,
            llmBaseURL: defaults.string(forKey: Keys.llmBaseURL) ?? "",
            llmModel: defaults.string(forKey: Keys.llmModel) ?? "",
            llmAPIKey: defaults.string(forKey: Keys.llmAPIKey) ?? ""
        )
    }

    static func save(_ config: TranslationConfig, defaults: UserDefaults = .standard) {
        defaults.set(config.enabled, forKey: Keys.enabled)
        defaults.set(config.engine.rawValue, forKey: Keys.engine)
        defaults.set(config.target.bcp47, forKey: Keys.targetLanguage)
        defaults.set(config.llmBaseURL, forKey: Keys.llmBaseURL)
        defaults.set(config.llmModel, forKey: Keys.llmModel)
        defaults.set(config.llmAPIKey, forKey: Keys.llmAPIKey)
    }
}
