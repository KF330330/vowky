import XCTest
@testable import VowKy

final class PunctuationServiceTests: XCTestCase {
    func testBundledModelAddsChinesePunctuation() throws {
        let service = PunctuationService()
        service.loadModel()

        XCTAssertTrue(service.isReady)

        let result = service.addPunctuation(to: "我们都是木头人不会说话不会动")
        XCTAssertNotEqual(result, "我们都是木头人不会说话不会动")
        XCTAssertTrue(result.contains("，") || result.contains("。") || result.contains("？"))
    }

    func testExistingPunctuationIsPreserved() throws {
        let service = PunctuationService()
        service.loadModel()

        XCTAssertTrue(service.isReady)

        let text = "今天我们测试录音转写效果，主要比较两个离线模型。"
        XCTAssertEqual(service.addPunctuation(to: text), text)
    }
}
