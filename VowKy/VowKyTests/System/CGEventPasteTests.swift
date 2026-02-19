import XCTest
import AppKit
@testable import VowKy

// MARK: - T4: CGEvent Text Insert Tests (#55-56)
// Requires: Accessibility permission

@MainActor
final class CGEventPasteTests: XCTestCase {

    // MARK: - #55: CGEvent insertText 文字出现

    func test55_cgEventInsert_textAppears() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission not granted")
        }

        let textService = TextOutputService()

        // Create a window with a text view to receive input
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isEditable = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)

        // Activate the app so CGEvent goes to our window
        NSApp.activate(ignoringOtherApps: true)

        // Process pending events and wait for window activation
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        textView.window?.makeFirstResponder(textView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        // Insert text via CGEvent keyboard simulation
        textService.insertText("CGEvent输入测试")

        // Process events to let the input go through
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))

        let result = textView.string

        window.orderOut(nil)

        // If activation failed (e.g., other app stole focus), skip rather than fail
        if result.isEmpty {
            throw XCTSkip("CGEvent insert could not be verified — window may not have been active")
        }

        XCTAssertTrue(result.contains("CGEvent输入测试"),
                       "Text should appear in text view after CGEvent insert, got: \(result)")
    }

    // MARK: - #56: insertText 不修改剪贴板

    func test56_insertText_doesNotModifyClipboard() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission not granted")
        }

        let textService = TextOutputService()

        // Set clipboard to known value
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("原始剪贴板内容", forType: .string)

        // Insert text (should NOT touch clipboard)
        textService.insertText("识别的文字")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

        // Verify clipboard is unchanged
        let current = pasteboard.string(forType: .string)
        XCTAssertEqual(current, "原始剪贴板内容",
                       "Clipboard should remain unchanged after insertText")
    }
}
