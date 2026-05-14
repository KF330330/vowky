import Foundation

// MARK: - Public types

struct EnhancementInput: Equatable {
    let rawText: String
    let audioURL: URL?
    let startedAt: Date
    let durationSeconds: TimeInterval?
    /// "recording" | "file" | "voice"
    let sourceType: String
}

struct EnhancementProgress: Equatable {
    enum Task: String, Equatable { case title, summary, outline }
    enum Status: Equatable {
        case running
        case succeeded
        case failed(String)
    }
    let task: Task
    let status: Status
}

struct EnhancementResult: Equatable {
    let metadata: TranscriptionMetadata
    /// 已带 frontmatter 的完整 Markdown 文档内容。
    let fullMarkdownDocument: String
    let titleSucceeded: Bool
    let summarySucceeded: Bool
    let outlineSucceeded: Bool
    let warnings: [String]
}

protocol TranscriptionEnhancing {
    func enhance(
        input: EnhancementInput,
        provider: AIProvider,
        markdownPath: String,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult
}

// MARK: - Service

final class TranscriptionEnhancementService: TranscriptionEnhancing {

    init() {}

    func enhance(
        input: EnhancementInput,
        provider: AIProvider,
        markdownPath: String,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {

        await progress(.init(task: .title,   status: .running))
        await progress(.init(task: .summary, status: .running))
        await progress(.init(task: .outline, status: .running))

        async let titleAsync   = runTitle(rawText: input.rawText,   provider: provider)
        async let summaryAsync = runSummary(rawText: input.rawText, provider: provider)
        async let outlineAsync = runOutline(rawText: input.rawText, provider: provider)

        let titleOutcome: Result<String, Error>
        do { titleOutcome = .success(try await titleAsync) } catch { titleOutcome = .failure(error) }

        let summaryOutcome: Result<String, Error>
        do { summaryOutcome = .success(try await summaryAsync) } catch { summaryOutcome = .failure(error) }

        let outlineOutcome: Result<String, Error>
        do { outlineOutcome = .success(try await outlineAsync) } catch { outlineOutcome = .failure(error) }

        var warnings: [String] = []

        // Title
        let title: String
        let titleOK: Bool
        switch titleOutcome {
        case .success(let s):
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                title = fallbackTitle(from: input.rawText)
                titleOK = false
                warnings.append("AI 返回了空标题，已用原文前缀替代")
                await progress(.init(task: .title, status: .failed("空标题")))
            } else {
                title = cleaned
                titleOK = true
                await progress(.init(task: .title, status: .succeeded))
            }
        case .failure(let err):
            title = fallbackTitle(from: input.rawText)
            titleOK = false
            warnings.append("标题生成失败：\(err.localizedDescription)")
            await progress(.init(task: .title, status: .failed(err.localizedDescription)))
        }

        // Summary
        let summary: String
        let summaryOK: Bool
        switch summaryOutcome {
        case .success(let s):
            summary = s.trimmingCharacters(in: .whitespacesAndNewlines)
            summaryOK = !summary.isEmpty
            if summaryOK {
                await progress(.init(task: .summary, status: .succeeded))
            } else {
                warnings.append("AI 返回了空摘要")
                await progress(.init(task: .summary, status: .failed("空摘要")))
            }
        case .failure(let err):
            summary = ""
            summaryOK = false
            warnings.append("摘要生成失败：\(err.localizedDescription)")
            await progress(.init(task: .summary, status: .failed(err.localizedDescription)))
        }

        // Outline
        let formattedBody: String
        let outlineOK: Bool
        switch outlineOutcome {
        case .success(let aiJSON):
            let patch = OutlinePatchApplier.apply(rawText: input.rawText, aiResponse: aiJSON)
            warnings.append(contentsOf: patch.warnings)
            outlineOK = patch.appliedCount > 0
            formattedBody = patch.markdown
            if outlineOK {
                await progress(.init(task: .outline, status: .succeeded))
            } else {
                await progress(.init(task: .outline, status: .failed("无可应用的 operation")))
            }
        case .failure(let err):
            formattedBody = input.rawText
            outlineOK = false
            warnings.append("正文 outline 生成失败：\(err.localizedDescription)")
            await progress(.init(task: .outline, status: .failed(err.localizedDescription)))
        }

        let metadata = TranscriptionMetadata(
            id: UUID(),
            title: title,
            summary: summary,
            audioPath: input.audioURL?.path,
            markdownPath: markdownPath,
            generatedAt: input.startedAt,
            durationSeconds: input.durationSeconds,
            provider: provider.displayName,
            sourceType: input.sourceType,
            aiEnhancementSucceeded: titleOK || summaryOK || outlineOK,
            warnings: warnings
        )

        let fullDoc = TranscriptionMarkdownWriter.compose(metadata: metadata, body: formattedBody)

        return EnhancementResult(
            metadata: metadata,
            fullMarkdownDocument: fullDoc,
            titleSucceeded: titleOK,
            summarySucceeded: summaryOK,
            outlineSucceeded: outlineOK,
            warnings: warnings
        )
    }

    // MARK: - Three tasks

    private func runTitle(rawText: String, provider: AIProvider) async throws -> String {
        let req = AIRequest(
            systemPrompt: EnhancementPrompts.titleSystemPrompt(),
            userPrompt: EnhancementPrompts.titleUserPrompt(rawText: rawText),
            responseFormat: .text,
            temperature: 0.2
        )
        return try await provider.complete(req).text
    }

    private func runSummary(rawText: String, provider: AIProvider) async throws -> String {
        let req = AIRequest(
            systemPrompt: EnhancementPrompts.summarySystemPrompt(),
            userPrompt: EnhancementPrompts.summaryUserPrompt(rawText: rawText),
            responseFormat: .text,
            temperature: 0.3
        )
        return try await provider.complete(req).text
    }

    /// Phase 1 暂未启用分块；超长文本走 abridged 单次调用，Phase 4 再做真正的分块合并。
    private func runOutline(rawText: String, provider: AIProvider) async throws -> String {
        let req = AIRequest(
            systemPrompt: EnhancementPrompts.outlineSystemPrompt(),
            userPrompt: EnhancementPrompts.outlineUserPrompt(rawText: rawText),
            responseFormat: .json,
            temperature: 0.2
        )
        return try await provider.complete(req).text
    }

    // MARK: - Helpers

    private func fallbackTitle(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "未命名转写" }
        let head = trimmed.prefix(20)
        return trimmed.count > 20 ? "\(head)…" : String(head)
    }
}
