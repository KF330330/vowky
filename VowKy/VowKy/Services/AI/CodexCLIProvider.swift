import Foundation

/// OpenAI Codex CLI (`codex exec`)。
final class CodexCLIProvider: BaseCLIProvider, AIProvider {

    init(config: CLIConfig, timeoutSeconds: Int) {
        super.init(
            commandName: "codex",
            // `codex exec` 非交互、stdin 进 prompt、stdout 输出 assistant 文本
            runArgs: ["exec", "--skip-git-repo-check", "-"],
            probeArgs: ["--version"],
            userBinaryPath: config.binaryPath,
            timeoutSeconds: timeoutSeconds
        )
    }

    var displayName: String { "codex" }

    func probe() async throws -> String {
        let binary = try resolveBinaryPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = probeArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw AIProviderError.cliExitNonZero(code: process.terminationStatus, stderr: output)
        }
        return output.isEmpty ? "OK" : output
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        // CLI 没有 system/user 分离；用 markdown 形式合并提示。
        var prompt = request.systemPrompt
        if !prompt.isEmpty { prompt += "\n\n" }
        prompt += request.userPrompt
        if request.responseFormat == .json {
            prompt += "\n\nReturn ONLY a JSON object. No prose, no markdown code fence."
        }

        let started = Date()
        let stdout = try await runWithStdin(prompt: prompt, arguments: runArgs)
        let cleaned = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw AIProviderError.empty
        }
        return AIResponse(
            text: cleaned,
            providerLabel: displayName,
            elapsed: Date().timeIntervalSince(started)
        )
    }
}
