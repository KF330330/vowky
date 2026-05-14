import Foundation

/// 按 `AIProviderConfig.providers` 的优先级，挑第一个可用的 provider 完成 enhance。
/// 不可用（pre-flight 失败）的跳过；调用成功一次就返回；全部不可用时返回 failure result。
/// 注意：provider 已可调用、但 AI 调用本身失败（超时/HTTP 错/非零退出）不会 fallback。
final class EnhancementRouter: TranscriptionEnhancing {

    private let configLoader: () -> AIProviderConfig
    private let checker: ProviderUsabilityChecker

    init(
        configLoader: @escaping () -> AIProviderConfig = { AIProviderFactory.load() },
        checker: ProviderUsabilityChecker = ProviderUsabilityChecker()
    ) {
        self.configLoader = configLoader
        self.checker = checker
    }

    func enhance(
        input: EnhancementInput,
        markdownPath: String,
        logFilePath: String?,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        let config = configLoader()
        let order = config.enabledKindsInPriorityOrder

        if order.isEmpty {
            return await emitFailure(
                input: input,
                markdownPath: markdownPath,
                skipped: [("(无)", "未启用任何 AI provider，请到设置勾选")],
                progress: progress
            )
        }

        var skipped: [(label: String, reason: String)] = []
        for kind in order {
            if let reason = checker.unusableReason(for: kind, config: config) {
                skipped.append((kind.displayName, reason.errorDescription ?? "不可用"))
                continue
            }
            let provider = AIProviderFactory.makeProvider(kind: kind, config: config)
            let service = makeService(kind: kind, provider: provider, config: config)
            return await service.enhance(
                input: input,
                markdownPath: markdownPath,
                logFilePath: logFilePath,
                progress: progress
            )
        }

        return await emitFailure(
            input: input,
            markdownPath: markdownPath,
            skipped: skipped,
            progress: progress
        )
    }

    // MARK: - Helpers

    private func makeService(
        kind: AIProviderKind,
        provider: AIProvider,
        config: AIProviderConfig
    ) -> TranscriptionEnhancing {
        switch kind {
        case .openAICompatible:
            return TranscriptionEnhancementService(provider: provider)
        case .codex:
            return SkillBackedEnhancementService(
                platform: .codex,
                userBinaryPath: config.codex.binaryPath,
                providerLabel: provider.displayName
            )
        case .claudeCode:
            return SkillBackedEnhancementService(
                platform: .claudeCode,
                userBinaryPath: config.claude.binaryPath,
                providerLabel: provider.displayName
            )
        }
    }

    private func emitFailure(
        input: EnhancementInput,
        markdownPath: String,
        skipped: [(label: String, reason: String)],
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        let header = "无可用 AI provider，已跳过："
        let lines = skipped.map { "\($0.label): \($0.reason)" }
        let summary = lines.isEmpty ? header : "\(header)\n" + lines.joined(separator: "\n")

        await progress(.init(task: .title,   status: .failed(summary)))
        await progress(.init(task: .summary, status: .failed(summary)))
        await progress(.init(task: .outline, status: .failed(summary)))

        let title = fallbackTitle(from: input.rawText)
        let metadata = TranscriptionMetadata(
            id: UUID(),
            title: title,
            summary: "",
            audioPath: input.audioURL?.path,
            markdownPath: markdownPath,
            generatedAt: input.startedAt,
            durationSeconds: input.durationSeconds,
            provider: "router(no-provider-usable)",
            sourceType: input.sourceType,
            aiEnhancementSucceeded: false,
            warnings: [summary]
        )
        let doc = TranscriptionMarkdownWriter.compose(metadata: metadata, body: input.rawText)
        return EnhancementResult(
            metadata: metadata,
            fullMarkdownDocument: doc,
            titleSucceeded: false,
            summarySucceeded: false,
            outlineSucceeded: false,
            warnings: [summary]
        )
    }

    private func fallbackTitle(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "未命名转写" }
        let head = trimmed.prefix(20)
        return trimmed.count > 20 ? "\(head)…" : String(head)
    }
}
