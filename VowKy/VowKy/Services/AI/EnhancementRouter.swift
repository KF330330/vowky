import Foundation

/// 根据用户当前选择的 AI provider，把 enhance 调用路由到 in-process 服务或 skill-backed 服务。
/// - openAICompatible → `TranscriptionEnhancementService`（HTTP 直接调）
/// - codex / claudeCode → `SkillBackedEnhancementService`（调本机 CLI 跑 transcript-enhance skill）
final class EnhancementRouter: TranscriptionEnhancing {

    private let configLoader: () -> AIProviderConfig

    init(configLoader: @escaping () -> AIProviderConfig = { AIProviderFactory.load() }) {
        self.configLoader = configLoader
    }

    func enhance(
        input: EnhancementInput,
        provider: AIProvider,
        markdownPath: String,
        logFilePath: String?,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        let config = configLoader()
        let service: TranscriptionEnhancing = makeService(for: config)
        return await service.enhance(
            input: input,
            provider: provider,
            markdownPath: markdownPath,
            logFilePath: logFilePath,
            progress: progress
        )
    }

    private func makeService(for config: AIProviderConfig) -> TranscriptionEnhancing {
        switch config.kind {
        case .openAICompatible:
            return TranscriptionEnhancementService()
        case .codex:
            return SkillBackedEnhancementService(
                platform: .codex,
                userBinaryPath: config.codex.binaryPath
            )
        case .claudeCode:
            return SkillBackedEnhancementService(
                platform: .claudeCode,
                userBinaryPath: config.claude.binaryPath
            )
        }
    }
}
