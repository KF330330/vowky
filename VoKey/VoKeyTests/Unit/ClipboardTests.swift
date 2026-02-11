import XCTest
import AppKit
@testable import VoKey

/// Tests #21-25: TextOutputService tests.
/// Verifies insertText does not touch clipboard and handles various text types.
final class ClipboardTests: XCTestCase {

    private var service: TextOutputService!

    override func setUp() {
        super.setUp()
        service = TextOutputService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - #21 insertText does not modify clipboard

    func testInsertText_doesNotModifyClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let beforeCount = pasteboard.changeCount

        // insertText should NOT touch the clipboard
        service.insertText("test text")

        let afterCount = pasteboard.changeCount
        let content = pasteboard.string(forType: .string)
        XCTAssertEqual(afterCount, beforeCount,
                       "Clipboard changeCount should not change after insertText")
        XCTAssertEqual(content, "original",
                       "Clipboard content should remain unchanged")
    }

    // MARK: - #22 insertText handles empty string

    func testInsertText_emptyString_noError() {
        // Should not crash or error on empty string
        service.insertText("")
        // No assertion needed — just verifying no crash
    }

    // MARK: - #23 insertText handles Unicode

    func testInsertText_unicode_noError() {
        // Should handle Chinese, emoji, and other unicode without crashing
        service.insertText("你好世界 🎤 日本語テスト العربية")
        // No assertion needed — just verifying no crash
    }

    // MARK: - #24 insertText handles long text

    func testInsertText_longText_noError() {
        // Text longer than 20 chars should be split into chunks
        let longText = String(repeating: "测试", count: 50) // 100 chars
        service.insertText(longText)
        // No assertion needed — verifying chunking doesn't crash
    }

    // MARK: - #25 TextOutputService can be created

    func testServiceCreation() {
        let svc = TextOutputService()
        XCTAssertNotNil(svc, "TextOutputService should be creatable")
    }
}
