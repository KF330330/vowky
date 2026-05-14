import Foundation

// MARK: - Sub-configs

struct OpenAICompatibleConfig: Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    static let `default` = OpenAICompatibleConfig(
        baseURL: "https://api.openai.com/v1",
        apiKey: "",
        model: "gpt-4o-mini"
    )

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct CLIConfig: Equatable {
    /// 用户手填的绝对路径；空字符串表示由 provider 自动探测。
    var binaryPath: String

    static let empty = CLIConfig(binaryPath: "")
}

// MARK: - Root config

struct AIProviderConfig: Equatable {
    var enabled: Bool
    var autoTrigger: Bool
    var kind: AIProviderKind
    var openAI: OpenAICompatibleConfig
    var codex: CLIConfig
    var claude: CLIConfig
    var timeoutSeconds: Int

    static let `default` = AIProviderConfig(
        enabled: false,
        autoTrigger: true,
        kind: .openAICompatible,
        openAI: .default,
        codex: .empty,
        claude: .empty,
        timeoutSeconds: 90
    )
}

// MARK: - Factory + UserDefaults persistence

enum AIProviderFactory {

    enum Keys {
        static let enabled        = "ai.enabled"
        static let autoTrigger    = "ai.autoTrigger"
        static let provider       = "ai.provider"
        static let openAIBaseURL  = "ai.openai.baseURL"
        static let openAIAPIKey   = "ai.openai.apiKey"
        static let openAIModel    = "ai.openai.model"
        static let codexBinary    = "ai.codex.binaryPath"
        static let claudeBinary   = "ai.claude.binaryPath"
        static let timeoutSeconds = "ai.timeoutSeconds"
    }

    static func load(defaults: UserDefaults = .standard) -> AIProviderConfig {
        let kindRaw = defaults.string(forKey: Keys.provider) ?? AIProviderConfig.default.kind.rawValue
        let kind = AIProviderKind(rawValue: kindRaw) ?? AIProviderConfig.default.kind

        let openAI = OpenAICompatibleConfig(
            baseURL: defaults.string(forKey: Keys.openAIBaseURL) ?? OpenAICompatibleConfig.default.baseURL,
            // TODO: migrate to Keychain
            apiKey:  defaults.string(forKey: Keys.openAIAPIKey)  ?? "",
            model:   defaults.string(forKey: Keys.openAIModel)   ?? OpenAICompatibleConfig.default.model
        )

        let codex = CLIConfig(
            binaryPath: defaults.string(forKey: Keys.codexBinary) ?? ""
        )
        let claude = CLIConfig(
            binaryPath: defaults.string(forKey: Keys.claudeBinary) ?? ""
        )

        let timeoutStored = defaults.object(forKey: Keys.timeoutSeconds) as? Int
        let timeout = timeoutStored ?? AIProviderConfig.default.timeoutSeconds

        let enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? AIProviderConfig.default.enabled
        let autoTrigger = defaults.object(forKey: Keys.autoTrigger) as? Bool ?? AIProviderConfig.default.autoTrigger

        return AIProviderConfig(
            enabled: enabled,
            autoTrigger: autoTrigger,
            kind: kind,
            openAI: openAI,
            codex: codex,
            claude: claude,
            timeoutSeconds: timeout
        )
    }

    static func save(_ config: AIProviderConfig, defaults: UserDefaults = .standard) {
        defaults.set(config.enabled, forKey: Keys.enabled)
        defaults.set(config.autoTrigger, forKey: Keys.autoTrigger)
        defaults.set(config.kind.rawValue, forKey: Keys.provider)
        defaults.set(config.openAI.baseURL, forKey: Keys.openAIBaseURL)
        defaults.set(config.openAI.apiKey,  forKey: Keys.openAIAPIKey)
        defaults.set(config.openAI.model,   forKey: Keys.openAIModel)
        defaults.set(config.codex.binaryPath,  forKey: Keys.codexBinary)
        defaults.set(config.claude.binaryPath, forKey: Keys.claudeBinary)
        defaults.set(config.timeoutSeconds, forKey: Keys.timeoutSeconds)
    }

    /// 实例化当前选中的 provider。具体实现见后续阶段；本阶段先抛错以便单测 wire-up。
    static func make(_ config: AIProviderConfig) throws -> AIProvider {
        switch config.kind {
        case .openAICompatible:
            return OpenAICompatibleProvider(
                config: config.openAI,
                timeoutSeconds: config.timeoutSeconds
            )
        case .codex:
            throw AIProviderError.notConfigured("Codex CLI provider 尚未实现（Phase 3）")
        case .claudeCode:
            throw AIProviderError.notConfigured("Claude Code CLI provider 尚未实现（Phase 3）")
        }
    }
}
