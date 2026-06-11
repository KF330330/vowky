import XCTest
@testable import VowKy

final class OpenAICompatibleTranslationProviderTests: XCTestCase {

    // MARK: - baseURL 规范化

    func test01_chatCompletionsURL_appendsPath() {
        XCTAssertEqual(
            OpenAICompatibleTranslationProvider.chatCompletionsURL(baseURL: "https://api.deepseek.com")?.absoluteString,
            "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslationProvider.chatCompletionsURL(baseURL: "https://api.deepseek.com/v1/")?.absoluteString,
            "https://api.deepseek.com/v1/chat/completions"
        )
        // 用户填了完整 endpoint 不重复追加
        XCTAssertEqual(
            OpenAICompatibleTranslationProvider.chatCompletionsURL(baseURL: "https://x.com/v1/chat/completions")?.absoluteString,
            "https://x.com/v1/chat/completions"
        )
        XCTAssertNil(OpenAICompatibleTranslationProvider.chatCompletionsURL(baseURL: ""))
        XCTAssertNil(OpenAICompatibleTranslationProvider.chatCompletionsURL(baseURL: "   "))
    }

    // MARK: - 请求与响应（URLProtocol stub）

    private func makeProvider(config: TranslationConfig? = nil) -> OpenAICompatibleTranslationProvider {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubURLProtocol.self]
        return OpenAICompatibleTranslationProvider(
            config: config ?? Self.validConfig,
            session: URLSession(configuration: sessionConfig)
        )
    }

    static let validConfig = TranslationConfig(
        enabled: true,
        engine: .llm,
        target: .zhHans,
        llmBaseURL: "https://api.test.com/v1",
        llmModel: "test-model",
        llmAPIKey: "sk-test-key"
    )

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func test02_requestBody_andAuthHeader() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let body = #"{"choices":[{"message":{"content":"你好"}}]}"#
            return (200, Data(body.utf8))
        }

        let result = try await makeProvider().translate("Hello", to: .zhHans)
        XCTAssertEqual(result, "你好")

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.test.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")

        let bodyData = try XCTUnwrap(request.bodyStreamData ?? request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["temperature"] as? Int, 0)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1]["content"] as? String, "Hello")
        XCTAssertTrue((messages[0]["content"] as? String ?? "").contains("zh-Hans"))
    }

    func test03_httpError_mapped() async {
        StubURLProtocol.handler = { _ in (401, Data("{}".utf8)) }
        do {
            _ = try await makeProvider().translate("Hello", to: .zhHans)
            XCTFail("应抛出 http 错误")
        } catch let error as TranslationError {
            XCTAssertEqual(error, .http(401))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func test04_emptyContent_throwsEmptyResult() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"  "}}]}"#.utf8))
        }
        do {
            _ = try await makeProvider().translate("Hello", to: .zhHans)
            XCTFail("应抛出 emptyResult")
        } catch let error as TranslationError {
            XCTAssertEqual(error, .emptyResult)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func test06_qwenMT_usesTranslationOptions_noSystemMessage() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            return (200, Data(#"{"choices":[{"message":{"content":"你好"}}]}"#.utf8))
        }

        var config = Self.validConfig
        config.llmModel = "qwen-mt-turbo"
        let result = try await makeProvider(config: config).translate("Hello", to: .zhHans)
        XCTAssertEqual(result, "你好")

        let request = try XCTUnwrap(capturedRequest)
        let bodyData = try XCTUnwrap(request.bodyStreamData ?? request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        let options = try XCTUnwrap(json["translation_options"] as? [String: Any], "qwen-mt 必须带 translation_options")
        XCTAssertEqual(options["source_lang"] as? String, "auto")
        XCTAssertEqual(options["target_lang"] as? String, "Chinese")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "qwen-mt 仅支持单条 user 消息")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "Hello")
    }

    func test07_regularModel_hasNoTranslationOptions() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            return (200, Data(#"{"choices":[{"message":{"content":"你好"}}]}"#.utf8))
        }

        _ = try await makeProvider().translate("Hello", to: .zhHans)
        let request = try XCTUnwrap(capturedRequest)
        let bodyData = try XCTUnwrap(request.bodyStreamData ?? request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertNil(json["translation_options"], "普通模型不应携带 qwen-mt 专用参数")
    }

    func test08_qwenMTLanguageNames() {
        XCTAssertTrue(OpenAICompatibleTranslationProvider.isQwenMTModel("qwen-mt-turbo"))
        XCTAssertTrue(OpenAICompatibleTranslationProvider.isQwenMTModel("Qwen-MT-Plus"))
        XCTAssertFalse(OpenAICompatibleTranslationProvider.isQwenMTModel("qwen-turbo"))
        XCTAssertEqual(
            OpenAICompatibleTranslationProvider.qwenMTLanguageName(for: TranslationTarget(bcp47: "zh-Hant")),
            "Traditional Chinese"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslationProvider.qwenMTLanguageName(for: TranslationTarget(bcp47: "ja")),
            "Japanese"
        )
    }

    func test05_notConfigured_throwsBeforeNetwork() async {
        var config = Self.validConfig
        config.llmAPIKey = ""
        StubURLProtocol.handler = { _ in
            XCTFail("未配置时不应发请求")
            return (200, Data())
        }
        do {
            _ = try await makeProvider(config: config).translate("Hello", to: .zhHans)
            XCTFail("应抛出 notConfigured")
        } catch let error as TranslationError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }
}

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLSession 会把 httpBody 转成 bodyStream，stub 里要从流读回
    var bodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
