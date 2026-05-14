import Foundation

/// Anthropic Claude Code CLI (`claude --print`)。
final class ClaudeCodeCLIProvider: BaseCLIProvider, AIProvider {

    init(config: CLIConfig, timeoutSeconds: Int) {
        super.init(
            commandName: "claude",
            // claude --print 非交互；text 模式输出原始回复
            runArgs: ["--print", "--output-format", "text"],
            probeArgs: ["--version"],
            userBinaryPath: config.binaryPath,
            timeoutSeconds: timeoutSeconds
        )
    }

    var displayName: String { "claude-code" }

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
