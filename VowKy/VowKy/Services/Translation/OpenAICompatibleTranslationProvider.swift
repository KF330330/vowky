import Foundation

/// OpenAI-compatible chat completions 翻译：每段一次非流式请求，temperature 0，
/// system prompt 限定只输出译文。兼容 DeepSeek / Qwen / OpenAI 等。
final class OpenAICompatibleTranslationProvider: TranslationProviding {
    private let config: TranslationConfig
    private let session: URLSession

    init(config: TranslationConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        guard config.isLLMConfigured else { throw TranslationError.notConfigured }
        guard let url = Self.chatCompletionsURL(baseURL: config.llmBaseURL) else {
            throw TranslationError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.llmAPIKey.trimmingCharacters(in: .whitespaces))",
                         forHTTPHeaderField: "Authorization")

        let model = config.llmModel.trimmingCharacters(in: .whitespaces)
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
        ]
        if Self.isQwenMTModel(model) {
            // Qwen-MT 专用翻译模型：仅接受单条 user 消息（不吃 system 指令），
            // 语言对通过非标准顶层参数 translation_options 指定（官方要求，缺了会报错）。
            // 文档：https://help.aliyun.com/zh/model-studio/qwen-mt-api
            body["messages"] = [["role": "user", "content": text]]
            body["translation_options"] = [
                "source_lang": "auto",
                "target_lang": Self.qwenMTLanguageName(for: target),
            ]
        } else {
            let languageName = target.displayName
            body["messages"] = [
                [
                    "role": "system",
                    "content": "You are a translation engine. Translate the user's text into \(languageName) (\(target.bcp47)). Output ONLY the translation, no explanations, no quotes.",
                ],
                ["role": "user", "content": text],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TranslationError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationError.underlying(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TranslationError.http(http.statusCode)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw TranslationError.emptyResult
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyResult }
        return trimmed
    }

    /// 阿里 Qwen-MT 专用翻译模型（qwen-mt-turbo / qwen-mt-plus 等）
    static func isQwenMTModel(_ model: String) -> Bool {
        model.lowercased().hasPrefix("qwen-mt")
    }

    /// Qwen-MT translation_options.target_lang 要求语言英文全称
    static func qwenMTLanguageName(for target: TranslationTarget) -> String {
        switch target.bcp47 {
        case "zh-Hans": return "Chinese"
        case "zh-Hant": return "Traditional Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "ru": return "Russian"
        default: return target.bcp47
        }
    }

    /// baseURL 规范化：去尾部斜杠；末尾没有 /chat/completions 则补上
    /// （用户可能填 "https://api.deepseek.com" 或 ".../v1" 或完整 endpoint）。
    static func chatCompletionsURL(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if !base.hasSuffix("/chat/completions") {
            base += "/chat/completions"
        }
        guard let url = URL(string: base), url.scheme != nil else { return nil }
        return url
    }
}
