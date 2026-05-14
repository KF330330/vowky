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
        markdownPath: String,
        logFilePath: String?,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult
}

// 旧调用方（不传 logFilePath）的默认实现：转发到带 logFilePath 的版本，传 nil。
extension TranscriptionEnhancing {
    func enhance(
        input: EnhancementInput,
        markdownPath: String,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        await enhance(
            input: input,
            markdownPath: markdownPath,
            logFilePath: nil,
            progress: progress
        )
    }
}

// MARK: - Service

final class TranscriptionEnhancementService: TranscriptionEnhancing {

    private let provider: AIProvider

    init(provider: AIProvider) {
        self.provider = provider
    }

    func enhance(
        input: EnhancementInput,
        markdownPath: String,
        logFilePath: String?,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        let provider = self.provider

        let logger: AIEnhancementLogger?
        if let path = logFilePath, !path.isEmpty {
            logger = AIEnhancementLogger(url: URL(fileURLWithPath: path))
            logger?.appendHeader(
                input: input,
                provider: provider.displayName,
                markdownPath: markdownPath
            )
        } else {
            logger = nil
        }

        await progress(.init(task: .title,   status: .running))
        await progress(.init(task: .summary, status: .running))
        await progress(.init(task: .outline, status: .running))

        async let titleAsync   = runTitle(rawText: input.rawText,   provider: provider, logger: logger)
        async let summaryAsync = runSummary(rawText: input.rawText, provider: provider, logger: logger)
        async let outlineAsync = runOutline(rawText: input.rawText, provider: provider, logger: logger)

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

        logger?.appendFooter(
            titleOK: titleOK,
            summaryOK: summaryOK,
            outlineOK: outlineOK,
            warnings: warnings
        )

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

    private func runTitle(rawText: String, provider: AIProvider, logger: AIEnhancementLogger?) async throws -> String {
        let req = AIRequest(
            systemPrompt: EnhancementPrompts.titleSystemPrompt(),
            userPrompt: EnhancementPrompts.titleUserPrompt(rawText: rawText),
            responseFormat: .text,
            temperature: 0.2
        )
        return try await loggedComplete(task: "title", request: req, provider: provider, logger: logger)
    }

    private func runSummary(rawText: String, provider: AIProvider, logger: AIEnhancementLogger?) async throws -> String {
        let req = AIRequest(
            systemPrompt: EnhancementPrompts.summarySystemPrompt(),
            userPrompt: EnhancementPrompts.summaryUserPrompt(rawText: rawText),
            responseFormat: .text,
            temperature: 0.3
        )
        return try await loggedComplete(task: "summary", request: req, provider: provider, logger: logger)
    }

    /// 短文本单次调用；超长文本按句子边界分块，每块独立调一次，
    /// 客户端合并所有 operations 后由 OutlinePatchApplier 在全文上重新定位。
    private func runOutline(rawText: String, provider: AIProvider, logger: AIEnhancementLogger?) async throws -> String {
        let chunks = EnhancementPrompts.chunkForOutline(rawText)
        if chunks.count <= 1 {
            let req = AIRequest(
                systemPrompt: EnhancementPrompts.outlineSystemPrompt(),
                userPrompt: EnhancementPrompts.outlineUserPrompt(rawText: rawText),
                responseFormat: .json,
                temperature: 0.2
            )
            return try await loggedComplete(task: "outline", request: req, provider: provider, logger: logger)
        }

        var mergedOps: [[String: Any]] = []
        var anySuccess = false
        var lastError: Error?

        for (i, chunk) in chunks.enumerated() {
            let req = AIRequest(
                systemPrompt: EnhancementPrompts.outlineSystemPrompt(),
                userPrompt: EnhancementPrompts.outlineUserPrompt(rawText: chunk),
                responseFormat: .json,
                temperature: 0.2
            )
            do {
                let taskName = "outline.chunk[\(i + 1)/\(chunks.count)]"
                let response = try await loggedComplete(task: taskName, request: req, provider: provider, logger: logger)
                let stripped = OutlinePatchApplier.stripMarkdownFence(response)
                if let data = stripped.data(using: .utf8),
                   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ops = root["operations"] as? [[String: Any]] {
                    mergedOps.append(contentsOf: ops)
                    anySuccess = true
                }
            } catch {
                lastError = error
                // 单块失败：继续下一块；anchor 在全文上重新定位，丢失若干 ops 不影响其他
            }
        }

        if !anySuccess, let err = lastError {
            throw err
        }

        let mergedJSON: [String: Any] = ["version": 1, "operations": mergedOps]
        let data = try JSONSerialization.data(withJSONObject: mergedJSON)
        return String(data: data, encoding: .utf8) ?? "{\"version\":1,\"operations\":[]}"
    }

    /// 调用 provider.complete 并把 prompt/response/error/耗时写日志。
    private func loggedComplete(
        task: String,
        request: AIRequest,
        provider: AIProvider,
        logger: AIEnhancementLogger?
    ) async throws -> String {
        let started = Date()
        do {
            let response = try await provider.complete(request)
            let elapsed = Date().timeIntervalSince(started)
            logger?.append(
                task: task,
                provider: provider.displayName,
                request: request,
                response: response.text,
                error: nil,
                elapsed: elapsed
            )
            return response.text
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            logger?.append(
                task: task,
                provider: provider.displayName,
                request: request,
                response: nil,
                error: error.localizedDescription,
                elapsed: elapsed
            )
            throw error
        }
    }

    // MARK: - Helpers

    private func fallbackTitle(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "未命名转写" }
        let head = trimmed.prefix(20)
        return trimmed.count > 20 ? "\(head)…" : String(head)
    }
}

// MARK: - Logger

/// AI 调用日志记录器。线程安全（通过 DispatchQueue 串行化 append）。
final class AIEnhancementLogger: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.vowky.ai-log", qos: .utility)

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(url: URL) {
        self.url = url
        queue.sync {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
    }

    func appendHeader(input: EnhancementInput, provider: String, markdownPath: String) {
        var lines: [String] = []
        lines.append("############################################################")
        lines.append("# AI Enhancement Log — \(Self.timestampFormatter.string(from: Date()))")
        lines.append("# provider: \(provider)")
        lines.append("# source_type: \(input.sourceType)")
        if let audio = input.audioURL { lines.append("# audio: \(audio.path)") }
        lines.append("# markdown: \(markdownPath)")
        lines.append("# raw_chars: \(input.rawText.count)")
        lines.append("############################################################")
        lines.append("")
        write(lines.joined(separator: "\n") + "\n")
    }

    func appendFooter(titleOK: Bool, summaryOK: Bool, outlineOK: Bool, warnings: [String]) {
        var lines: [String] = []
        lines.append("############################################################")
        lines.append("# Summary: title=\(titleOK ? "OK" : "FAIL") summary=\(summaryOK ? "OK" : "FAIL") outline=\(outlineOK ? "OK" : "FAIL")")
        if warnings.isEmpty {
            lines.append("# warnings: (none)")
        } else {
            lines.append("# warnings:")
            for w in warnings { lines.append("#   - \(w)") }
        }
        lines.append("############################################################")
        lines.append("")
        write(lines.joined(separator: "\n") + "\n")
    }

    func append(
        task: String,
        provider: String,
        request: AIRequest,
        response: String?,
        error: String?,
        elapsed: TimeInterval
    ) {
        let ts = Self.timestampFormatter.string(from: Date())
        var lines: [String] = []
        lines.append("============================================================")
        lines.append("[\(ts)] task=\(task) provider=\(provider) elapsed=\(String(format: "%.1f", elapsed))s")
        lines.append("--- prompt (system) ---")
        lines.append(request.systemPrompt)
        lines.append("--- prompt (user) ---")
        lines.append(request.userPrompt)
        if let response {
            lines.append("--- response ---")
            lines.append(response)
        }
        if let error {
            lines.append("--- ERROR ---")
            lines.append(error)
        }
        lines.append("")
        write(lines.joined(separator: "\n") + "\n")
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let targetURL = url
        queue.sync {
            if let handle = try? FileHandle(forWritingTo: targetURL) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }
}
