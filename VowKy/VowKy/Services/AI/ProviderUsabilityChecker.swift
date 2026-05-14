import Foundation

/// Provider 不可用的具体原因。"不可用"= 还没法对 AI 发起调用（pre-flight 不通过）。
enum ProviderUnusableReason: LocalizedError, Equatable {
    case openAINotConfigured
    case cliNotFound(commandName: String)
    case skillNotInstalled(platform: AISkillPlatform)

    var errorDescription: String? {
        switch self {
        case .openAINotConfigured:
            return "OpenAI 兼容 API 配置不完整（Base URL / API Key / Model 任一为空）"
        case .cliNotFound(let name):
            return "未找到 \(name) 命令（请安装 CLI 或在设置里填绝对路径）"
        case .skillNotInstalled(let platform):
            return "\(platform.displayName) 平台未安装 transcript-enhance skill"
        }
    }
}

/// 在 enhance 调用前做 pre-flight，决定一个 provider kind 是否值得尝试。
struct ProviderUsabilityChecker {
    let fileManager: FileManager
    let homeDirectory: URL
    let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    /// 返回 nil 表示可用；否则返回不可用原因。
    func unusableReason(for kind: AIProviderKind, config: AIProviderConfig) -> ProviderUnusableReason? {
        switch kind {
        case .openAICompatible:
            return config.openAI.isConfigured ? nil : .openAINotConfigured
        case .codex:
            return cliBackedCheck(commandName: "codex", binaryPath: config.codex.binaryPath, platform: .codex)
        case .claudeCode:
            return cliBackedCheck(commandName: "claude", binaryPath: config.claude.binaryPath, platform: .claudeCode)
        }
    }

    private func cliBackedCheck(commandName: String, binaryPath: String, platform: AISkillPlatform) -> ProviderUnusableReason? {
        guard resolveBinary(commandName: commandName, userBinaryPath: binaryPath) != nil else {
            return .cliNotFound(commandName: commandName)
        }
        let skillFile = skillHomeDirectory(for: platform)
            .appendingPathComponent("skills")
            .appendingPathComponent("transcript-enhance")
            .appendingPathComponent("SKILL.md")
        if !fileManager.fileExists(atPath: skillFile.path) {
            return .skillNotInstalled(platform: platform)
        }
        return nil
    }

    private func resolveBinary(commandName: String, userBinaryPath: String) -> String? {
        let trimmed = userBinaryPath.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return fileManager.isExecutableFile(atPath: trimmed) ? trimmed : nil
        }
        let home = (environment["HOME"] ?? homeDirectory.path)
        let candidateDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "/usr/bin",
            "/bin",
        ]
        for dir in candidateDirs {
            let candidate = "\(dir)/\(commandName)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func skillHomeDirectory(for platform: AISkillPlatform) -> URL {
        switch platform {
        case .codex:
            if let codex = environment["CODEX_HOME"] {
                let expanded = (codex as NSString).expandingTildeInPath
                return URL(fileURLWithPath: expanded)
            }
            return homeDirectory.appendingPathComponent(".codex")
        case .claudeCode:
            return homeDirectory.appendingPathComponent(".claude")
        }
    }
}
