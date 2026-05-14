import Foundation

/// OpenAI 兼容的 Chat Completions HTTP 客户端。
/// 兼容 OpenAI / DeepSeek / Qwen / OpenRouter / SiliconFlow / Together 等。
final class OpenAICompatibleProvider: AIProvider {

    private let config: OpenAICompatibleConfig
    private let timeoutSeconds: Int
    private let session: URLSession

    init(
        config: OpenAICompatibleConfig,
        timeoutSeconds: Int = 90,
        session: URLSession = .shared
    ) {
        self.config = config
        self.timeoutSeconds = max(10, timeoutSeconds)
        self.session = session
    }

    var displayName: String { "openai-compatible@\(host)" }

    private var host: String {
        URL(string: config.baseURL)?.host ?? "unknown"
    }

    // MARK: - Probe

    func probe() async throws -> String {
        guard config.isConfigured else {
            throw AIProviderError.notConfigured("base URL / API key / model 必填")
        }
        let request = AIRequest(
            systemPrompt: "You are a connectivity test endpoint.",
            userPrompt: "Reply with the single word: OK",
            responseFormat: .text,
            temperature: 0
        )
        let response = try await complete(request)
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Complete

    func complete(_ request: AIRequest) async throws -> AIResponse {
        guard config.isConfigured else {
            throw AIProviderError.notConfigured("base URL / API key / model 必填")
        }

        let urlRequest = try buildURLRequest(for: request)
        let started = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw AIProviderError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw AIProviderError.timeout
        } catch {
            throw AIProviderError.httpError(status: -1, body: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.httpError(status: -1, body: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.httpError(status: http.statusCode, body: body)
        }

        let text = try Self.extractAssistantText(from: data)
        guard !text.isEmpty else {
            throw AIProviderError.empty
        }

        return AIResponse(
            text: text,
            providerLabel: displayName,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Request construction

    private func buildURLRequest(for request: AIRequest) throws -> URLRequest {
        let baseURL = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let endpoint = URL(string: "\(baseURL)/chat/completions") else {
            throw AIProviderError.notConfigured("base URL 无法解析为合法 URL")
        }

        var systemPrompt = request.systemPrompt
        if request.responseFormat == .json,
           !systemPrompt.lowercased().contains("only json") {
            systemPrompt += "\n\nReturn ONLY a JSON object. No prose, no markdown code fence."
        }

        var body: [String: Any] = [
            "model": config.model,
            "temperature": request.temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": request.userPrompt]
            ]
        ]
        if request.responseFormat == .json {
            body["response_format"] = ["type": "json_object"]
        }

        let data = try JSONSerialization.data(withJSONObject: body)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(timeoutSeconds)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = data
        return urlRequest
    }

    // MARK: - Response parsing

    /// 解析 OpenAI 兼容响应中的 `choices[0].message.content`。
    static func extractAssistantText(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw AIProviderError.decoding("响应非 JSON 对象：\(snippet)")
        }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
            throw AIProviderError.decoding("响应缺少 choices")
        }
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let text = first["text"] as? String {
            return text
        }
        throw AIProviderError.decoding("响应缺少 message.content")
    }
}
