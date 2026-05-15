import Foundation

// MARK: - Provider kind

enum AIProviderKind: String, CaseIterable, Codable {
    case codex
    case claudeCode

    var displayName: String {
        switch self {
        case .codex:            return "Codex CLI（本机）"
        case .claudeCode:       return "Claude Code CLI（本机）"
        }
    }
}

// MARK: - Request / Response

enum AIResponseFormat: Equatable {
    case text
    case json
}

struct AIRequest: Equatable {
    let systemPrompt: String
    let userPrompt: String
    let responseFormat: AIResponseFormat
    let temperature: Double

    init(
        systemPrompt: String,
        userPrompt: String,
        responseFormat: AIResponseFormat = .text,
        temperature: Double = 0.2
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.responseFormat = responseFormat
        self.temperature = temperature
    }
}

struct AIResponse: Equatable {
    let text: String
    let providerLabel: String
    let elapsed: TimeInterval
}

// MARK: - Errors

enum AIProviderError: LocalizedError, Equatable {
    case notConfigured(String)
    case cliNotFound(String)
    case cliExitNonZero(code: Int32, stderr: String)
    case httpError(status: Int, body: String)
    case timeout
    case cancelled
    case decoding(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .notConfigured(let reason):
            return "AI 配置不完整：\(reason)"
        case .cliNotFound(let name):
            return "未找到 \(name) 命令，请在设置中填写绝对路径"
        case .cliExitNonZero(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "命令退出码 \(code)"
                : "命令退出码 \(code)：\(trimmed)"
        case .httpError(let status, let body):
            let snippet = body.prefix(200)
            return "HTTP \(status)：\(snippet)"
        case .timeout:
            return "AI 调用超时"
        case .cancelled:
            return "已取消"
        case .decoding(let reason):
            return "AI 返回内容解析失败：\(reason)"
        case .empty:
            return "AI 返回了空内容"
        }
    }
}

// MARK: - Protocol

protocol AIProvider {
    var displayName: String { get }
    func probe() async throws -> String
    func complete(_ request: AIRequest) async throws -> AIResponse
}
