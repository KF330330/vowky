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

// MARK: - Priority entry

struct ProviderPriorityEntry: Codable, Equatable {
    var kind: AIProviderKind
    var enabled: Bool
}

// MARK: - Root config

struct AIProviderConfig: Equatable {
    var enabled: Bool
    var autoTrigger: Bool
    /// 顺序即 fallback 优先级。3 个 kind 必须全部出现（启用与否由 enabled 控制）。
    var providers: [ProviderPriorityEntry]
    var openAI: OpenAICompatibleConfig
    var codex: CLIConfig
    var claude: CLIConfig
    var timeoutSeconds: Int

    /// 启用的 kind，按优先级排序。
    var enabledKindsInPriorityOrder: [AIProviderKind] {
        providers.filter(\.enabled).map(\.kind)
    }

    static let `default` = AIProviderConfig(
        enabled: false,
        autoTrigger: true,
        providers: AIProviderConfig.defaultProviders,
        openAI: .default,
        codex: .empty,
        claude: .empty,
        timeoutSeconds: 90
    )

    static let defaultProviders: [ProviderPriorityEntry] = [
        ProviderPriorityEntry(kind: .claudeCode, enabled: true),
        ProviderPriorityEntry(kind: .codex, enabled: false),
        ProviderPriorityEntry(kind: .openAICompatible, enabled: false),
    ]
}

// MARK: - Factory + UserDefaults persistence

enum AIProviderFactory {

    enum Keys {
        static let enabled         = "ai.enabled"
        static let autoTrigger     = "ai.autoTrigger"
        static let provider        = "ai.provider"               // legacy 单选
        static let providersJSON   = "ai.providers.priorityJSON"  // 新：[ProviderPriorityEntry] JSON
        static let openAIBaseURL   = "ai.openai.baseURL"
        static let openAIAPIKey    = "ai.openai.apiKey"
        static let openAIModel     = "ai.openai.model"
        static let codexBinary     = "ai.codex.binaryPath"
        static let claudeBinary    = "ai.claude.binaryPath"
        static let timeoutSeconds  = "ai.timeoutSeconds"
    }

    static func load(defaults: UserDefaults = .standard) -> AIProviderConfig {
        let providers = loadProviders(defaults: defaults)

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
            providers: providers,
            openAI: openAI,
            codex: codex,
            claude: claude,
            timeoutSeconds: timeout
        )
    }

    static func save(_ config: AIProviderConfig, defaults: UserDefaults = .standard) {
        defaults.set(config.enabled, forKey: Keys.enabled)
        defaults.set(config.autoTrigger, forKey: Keys.autoTrigger)
        if let data = try? JSONEncoder().encode(config.providers),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Keys.providersJSON)
        }
        // 不再写旧 key（保留旧 key 以备回滚）
        defaults.set(config.openAI.baseURL, forKey: Keys.openAIBaseURL)
        defaults.set(config.openAI.apiKey,  forKey: Keys.openAIAPIKey)
        defaults.set(config.openAI.model,   forKey: Keys.openAIModel)
        defaults.set(config.codex.binaryPath,  forKey: Keys.codexBinary)
        defaults.set(config.claude.binaryPath, forKey: Keys.claudeBinary)
        defaults.set(config.timeoutSeconds, forKey: Keys.timeoutSeconds)
    }

    /// 按 kind 构造单个 provider 实例。
    static func makeProvider(kind: AIProviderKind, config: AIProviderConfig) -> AIProvider {
        switch kind {
        case .openAICompatible:
            return OpenAICompatibleProvider(
                config: config.openAI,
                timeoutSeconds: config.timeoutSeconds
            )
        case .codex:
            return CodexCLIProvider(
                config: config.codex,
                timeoutSeconds: config.timeoutSeconds
            )
        case .claudeCode:
            return ClaudeCodeCLIProvider(
                config: config.claude,
                timeoutSeconds: config.timeoutSeconds
            )
        }
    }

    // MARK: - Providers load with migration

    private static func loadProviders(defaults: UserDefaults) -> [ProviderPriorityEntry] {
        // 1. 新 JSON key 优先
        if let json = defaults.string(forKey: Keys.providersJSON),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ProviderPriorityEntry].self, from: data) {
            return normalize(decoded)
        }

        // 2. legacy: 旧 ai.provider 单值 → 放首位 enabled，其它尾随 disabled
        if let raw = defaults.string(forKey: Keys.provider),
           let legacyKind = AIProviderKind(rawValue: raw) {
            var result: [ProviderPriorityEntry] = [ProviderPriorityEntry(kind: legacyKind, enabled: true)]
            for kind in AIProviderKind.allCases where kind != legacyKind {
                result.append(ProviderPriorityEntry(kind: kind, enabled: false))
            }
            return result
        }

        // 3. 完全默认
        return AIProviderConfig.defaultProviders
    }

    /// 确保 result 恰好包含 AIProviderKind.allCases 每一种（顺序维持，缺的补尾，dup 去掉）。
    private static func normalize(_ raw: [ProviderPriorityEntry]) -> [ProviderPriorityEntry] {
        var seen: Set<AIProviderKind> = []
        var result: [ProviderPriorityEntry] = []
        for entry in raw where !seen.contains(entry.kind) {
            seen.insert(entry.kind)
            result.append(entry)
        }
        for kind in AIProviderKind.allCases where !seen.contains(kind) {
            result.append(ProviderPriorityEntry(kind: kind, enabled: false))
        }
        return result
    }
}
