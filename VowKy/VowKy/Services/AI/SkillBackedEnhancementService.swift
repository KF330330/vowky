import Foundation

/// 通过 CLI 调用 transcript-enhance skill（已装在 ~/.claude/skills 或 ~/.codex/skills）来跑 AI 后处理。
/// 与 in-process 的 TranscriptionEnhancementService 平行实现 TranscriptionEnhancing。
final class SkillBackedEnhancementService: TranscriptionEnhancing {

    private let platform: AISkillPlatform
    private let userBinaryPath: String
    private let providerLabel: String
    private let timeoutSeconds: Int
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let environment: [String: String]
    private let tempDirectory: URL

    init(
        platform: AISkillPlatform,
        userBinaryPath: String,
        providerLabel: String,
        timeoutSeconds: Int = 600,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tempDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) {
        self.platform = platform
        self.userBinaryPath = userBinaryPath
        self.providerLabel = providerLabel
        self.timeoutSeconds = max(60, timeoutSeconds)
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.tempDirectory = tempDirectory
    }

    func enhance(
        input: EnhancementInput,
        markdownPath: String,
        logFilePath: String?,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        // MVP「单 spinner」：开局三个 task 一起置为 running
        await progress(.init(task: .title,   status: .running))
        await progress(.init(task: .summary, status: .running))
        await progress(.init(task: .outline, status: .running))

        // skill 是否已装
        let skillRoot = skillDirectory()
        let skillFile = skillRoot.appendingPathComponent("SKILL.md")
        guard fileManager.fileExists(atPath: skillFile.path) else {
            let msg = "transcript-enhance skill 未安装（\(skillFile.path)），请到设置安装。"
            return await failAll(input: input, markdownPath: markdownPath, message: msg, progress: progress)
        }

        // 写 raw text 到 /tmp/vowky-input-<uuid>.txt
        let inputFile = tempDirectory.appendingPathComponent("vowky-input-\(UUID().uuidString).txt")
        do {
            try input.rawText.write(to: inputFile, atomically: true, encoding: .utf8)
        } catch {
            let msg = "写入 skill 输入文件失败：\(error.localizedDescription)"
            return await failAll(input: input, markdownPath: markdownPath, message: msg, progress: progress)
        }
        defer { try? fileManager.removeItem(at: inputFile) }

        let outputURL = URL(fileURLWithPath: markdownPath)
        do {
            try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            // 忽略；写盘阶段会再 surface
        }

        // 调 CLI
        let binary: String
        do {
            binary = try resolveBinaryPath()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return await failAll(input: input, markdownPath: markdownPath, message: msg, progress: progress)
        }

        let prompt = buildPrompt(
            inputPath: inputFile.path,
            outputPath: outputURL.path,
            audioPath: input.audioURL?.path,
            durationSeconds: input.durationSeconds
        )

        let cliStarted = Date()
        let runResult: Result<String, Error>
        do {
            let stdout = try await runCLI(binary: binary, prompt: prompt)
            runResult = .success(stdout)
        } catch {
            runResult = .failure(error)
        }

        // 写 log 头（CLI 调用结果记录）
        let logger: AIEnhancementLogger? = (logFilePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }).map { AIEnhancementLogger(url: $0) }
        logger?.appendHeader(input: input, provider: providerLabel, markdownPath: markdownPath)
        let cliElapsed = Date().timeIntervalSince(cliStarted)
        let logRequest = AIRequest(systemPrompt: "", userPrompt: prompt, responseFormat: .text, temperature: 0)
        switch runResult {
        case .success(let stdout):
            logger?.append(
                task: "skill.transcript-enhance",
                provider: providerLabel,
                request: logRequest,
                response: stdout,
                error: nil,
                elapsed: cliElapsed
            )
        case .failure(let err):
            let msg = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            logger?.append(
                task: "skill.transcript-enhance",
                provider: providerLabel,
                request: logRequest,
                response: nil,
                error: msg,
                elapsed: cliElapsed
            )
            logger?.appendFooter(titleOK: false, summaryOK: false, outlineOK: false, warnings: [msg])
            return await failAll(input: input, markdownPath: markdownPath, message: "skill 调用失败：\(msg)", progress: progress)
        }

        // 读最终 .md
        guard let markdownContent = try? String(contentsOf: outputURL, encoding: .utf8), !markdownContent.isEmpty else {
            let msg = "skill 调用结束但未生成 .md 输出（\(outputURL.path)）"
            logger?.appendFooter(titleOK: false, summaryOK: false, outlineOK: false, warnings: [msg])
            return await failAll(input: input, markdownPath: markdownPath, message: msg, progress: progress)
        }

        let parsed = parseFrontmatter(markdownContent)
        let title = parsed.title.isEmpty ? fallbackTitle(from: input.rawText) : parsed.title
        let summary = parsed.summary

        await progress(.init(task: .title,   status: .succeeded))
        await progress(.init(task: .summary, status: .succeeded))
        await progress(.init(task: .outline, status: .succeeded))

        let metadata = TranscriptionMetadata(
            id: UUID(),
            title: title,
            summary: summary,
            audioPath: input.audioURL?.path,
            markdownPath: markdownPath,
            generatedAt: input.startedAt,
            durationSeconds: input.durationSeconds,
            provider: "skill+\(providerLabel)",
            sourceType: input.sourceType,
            aiEnhancementSucceeded: true,
            warnings: []
        )

        logger?.appendFooter(titleOK: true, summaryOK: !summary.isEmpty, outlineOK: true, warnings: [])

        return EnhancementResult(
            metadata: metadata,
            fullMarkdownDocument: markdownContent,
            titleSucceeded: true,
            summarySucceeded: !summary.isEmpty,
            outlineSucceeded: true,
            warnings: []
        )
    }

    // MARK: - Helpers

    private func skillDirectory() -> URL {
        let root: URL
        switch platform {
        case .codex:
            root = environment["CODEX_HOME"].map { (path: String) -> URL in
                let expanded = (path as NSString).expandingTildeInPath
                return URL(fileURLWithPath: expanded)
            } ?? homeDirectory.appendingPathComponent(".codex")
        case .claudeCode:
            root = homeDirectory.appendingPathComponent(".claude")
        }
        return root.appendingPathComponent("skills").appendingPathComponent("transcript-enhance")
    }

    private func buildPrompt(
        inputPath: String,
        outputPath: String,
        audioPath: String?,
        durationSeconds: TimeInterval?
    ) -> String {
        var lines: [String] = []
        lines.append("使用 transcript-enhance skill 处理这份转写稿。")
        lines.append("")
        lines.append("INPUT=\(inputPath)")
        lines.append("OUTPUT=\(outputPath)")
        if let audioPath { lines.append("AUDIO=\(audioPath)") }
        if let durationSeconds { lines.append("DURATION_SECONDS=\(Int(durationSeconds.rounded()))") }
        lines.append("")
        lines.append("要求：")
        lines.append("1. 严格遵守 SKILL.md 的 Step 0-8 全部流程，不要省略 validate。")
        lines.append("2. 不要修改原文一个字符（byte-for-byte preserve）。")
        lines.append("3. 最终输出文件路径必须等于 OUTPUT。")
        lines.append("4. AI 日志写到 OUTPUT 同目录下的 .ai-log.txt。")
        lines.append("5. 如果 AUDIO 提供了，frontmatter 中加 audio_path 字段。")
        lines.append("6. 如果 DURATION_SECONDS 提供了，frontmatter 中加 duration_seconds 字段。")
        lines.append("7. 完成后**只输出一行**：DONE")
        lines.append("8. 失败时输出一行：FAILED: <reason>")
        return lines.joined(separator: "\n")
    }

    private func runCLI(binary: String, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = cliArguments()

            var env = ProcessInfo.processInfo.environment
            let pathList = Self.candidateBinaryDirectories.joined(separator: ":")
            let existingPath = env["PATH"] ?? ""
            env["PATH"] = existingPath.isEmpty ? pathList : "\(pathList):\(existingPath)"
            env["HOME"] = env["HOME"] ?? NSHomeDirectory()
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timeoutSource = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            timeoutSource.schedule(deadline: .now() + .seconds(timeoutSeconds), repeating: .never)

            let timedOut = AtomicSkillFlag()
            let completed = AtomicSkillFlag()

            timeoutSource.setEventHandler {
                if !completed.value {
                    timedOut.value = true
                    if process.isRunning { process.terminate() }
                }
            }
            timeoutSource.resume()

            process.terminationHandler = { proc in
                completed.value = true
                timeoutSource.cancel()
                if timedOut.value {
                    continuation.resume(throwing: AIProviderError.timeout)
                    return
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let status = proc.terminationStatus
                if status != 0 {
                    continuation.resume(throwing: AIProviderError.cliExitNonZero(
                        code: status,
                        stderr: stderr.isEmpty ? stdout : stderr
                    ))
                    return
                }
                continuation.resume(returning: stdout)
            }

            do {
                try process.run()
            } catch {
                completed.value = true
                timeoutSource.cancel()
                continuation.resume(throwing: AIProviderError.cliExitNonZero(
                    code: -1,
                    stderr: "无法启动命令：\(error.localizedDescription)"
                ))
                return
            }

            if let data = prompt.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }
    }

    private func cliArguments() -> [String] {
        switch platform {
        case .claudeCode:
            return [
                "--print",
                "--output-format", "text",
                "--permission-mode", "bypassPermissions",
            ]
        case .codex:
            return [
                "exec",
                "--skip-git-repo-check",
                "--dangerously-bypass-approvals-and-sandbox",
                "-",
            ]
        }
    }

    private func resolveBinaryPath() throws -> String {
        let trimmed = userBinaryPath.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            if fileManager.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
            throw AIProviderError.cliNotFound("\(commandName())（用户指定路径无法执行：\(trimmed)）")
        }
        for dir in Self.candidateBinaryDirectories {
            let candidate = "\(dir)/\(commandName())"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        if let resolved = try? Self.shellCommandV(commandName()) {
            return resolved
        }
        throw AIProviderError.cliNotFound(commandName())
    }

    private func commandName() -> String {
        switch platform {
        case .codex: return "codex"
        case .claudeCode: return "claude"
        }
    }

    static var candidateBinaryDirectories: [String] {
        CLIPathResolver.candidateDirectories(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func shellCommandV(_ name: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    // MARK: - Failure helper

    @MainActor
    private func failAll(
        input: EnhancementInput,
        markdownPath: String,
        message: String,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        progress(.init(task: .title,   status: .failed(message)))
        progress(.init(task: .summary, status: .failed(message)))
        progress(.init(task: .outline, status: .failed(message)))

        let title = fallbackTitle(from: input.rawText)
        let metadata = TranscriptionMetadata(
            id: UUID(),
            title: title,
            summary: "",
            audioPath: input.audioURL?.path,
            markdownPath: markdownPath,
            generatedAt: input.startedAt,
            durationSeconds: input.durationSeconds,
            provider: "skill+\(providerLabel)",
            sourceType: input.sourceType,
            aiEnhancementSucceeded: false,
            warnings: [message]
        )
        let doc = TranscriptionMarkdownWriter.compose(metadata: metadata, body: input.rawText)
        return EnhancementResult(
            metadata: metadata,
            fullMarkdownDocument: doc,
            titleSucceeded: false,
            summarySucceeded: false,
            outlineSucceeded: false,
            warnings: [message]
        )
    }

    private func fallbackTitle(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "未命名转写" }
        let head = trimmed.prefix(20)
        return trimmed.count > 20 ? "\(head)…" : String(head)
    }

    // MARK: - Frontmatter parsing

    private func parseFrontmatter(_ markdown: String) -> (title: String, summary: String) {
        guard markdown.hasPrefix("---\n") else { return ("", "") }
        let afterOpen = markdown.dropFirst(4)
        guard let endRange = afterOpen.range(of: "\n---") else { return ("", "") }
        let frontmatter = afterOpen[..<endRange.lowerBound]
        var title = ""
        var summary = ""
        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if title.isEmpty, let v = scalarValue(line: s, key: "title") { title = v }
            if summary.isEmpty, let v = scalarValue(line: s, key: "summary") { summary = v }
        }
        return (title, summary)
    }

    private func scalarValue(line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        var v = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
            v = v.replacingOccurrences(of: "\\\"", with: "\"")
                 .replacingOccurrences(of: "\\n", with: "\n")
                 .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return v
    }
}

private final class AtomicSkillFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
