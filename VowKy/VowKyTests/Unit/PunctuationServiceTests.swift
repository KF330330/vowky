import XCTest
@testable import VowKy

final class PunctuationServiceTests: XCTestCase {

    // 测试 Mock 标点服务
    func testMockPunctuationService_addsSuffix() {
        let mock = MockPunctuationService()
        let result = mock.addPunctuation(to: "你好世界")
        XCTAssertEqual(result, "你好世界。")
        XCTAssertEqual(mock.addPunctuationCallCount, 1)
    }

    // 测试真实标点服务（需要模型文件）
    func testRealPunctuationService_withModel() throws {
        let service = PunctuationService()

        // Try to find model in bundle or common paths
        let modelPath = Bundle.main.path(forResource: "punct-model", ofType: "onnx")
        guard let path = modelPath, FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Punctuation model not available in test bundle")
        }

        service.loadModel(modelPath: path)
        guard service.isReady else {
            throw XCTSkip("Punctuation model failed to load")
        }

        let result = service.addPunctuation(to: "你好世界今天天气不错")
        XCTAssertNotEqual(result, "你好世界今天天气不错",
                          "Punctuation should modify the text")
        // The exact punctuation depends on the model, so just verify it changed
        print("Punctuation result: \(result)")
    }

    // 测试模型未加载时透传
    func testPunctuationService_noModel_passThrough() {
        let service = PunctuationService()
        // Don't load model
        XCTAssertFalse(service.isReady)
        let result = service.addPunctuation(to: "测试文本")
        XCTAssertEqual(result, "测试文本", "Should pass through when model not loaded")
    }

    // 测试无效路径
    func testPunctuationService_invalidPath_notReady() {
        let service = PunctuationService()
        service.loadModel(modelPath: "/nonexistent/path/model.onnx")
        XCTAssertFalse(service.isReady, "Should not be ready with invalid path")
    }
}
