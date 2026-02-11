import XCTest
@testable import VoKey

final class CancelKeyTests: XCTestCase {

    // Escape keyDown, no modifiers → .cancelRecording
    func testEscapeKeyDown_noModifiers_returnsCancelRecording() {
        let result = HotkeyEvaluator.evaluateCancelEvent(
            keyCode: 53,
            modifiers: HotkeyModifiers(option: false, command: false, control: false, shift: false),
            isKeyUp: false
        )
        XCTAssertEqual(result, .cancelRecording)
    }

    // Escape keyUp → .passThrough
    func testEscapeKeyUp_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateCancelEvent(
            keyCode: 53,
            modifiers: HotkeyModifiers(option: false, command: false, control: false, shift: false),
            isKeyUp: true
        )
        XCTAssertEqual(result, .passThrough)
    }

    // Escape + Option → .passThrough
    func testEscapeWithOption_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateCancelEvent(
            keyCode: 53,
            modifiers: HotkeyModifiers(option: true, command: false, control: false, shift: false),
            isKeyUp: false
        )
        XCTAssertEqual(result, .passThrough)
    }

    // Escape + Command → .passThrough
    func testEscapeWithCommand_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateCancelEvent(
            keyCode: 53,
            modifiers: HotkeyModifiers(option: false, command: true, control: false, shift: false),
            isKeyUp: false
        )
        XCTAssertEqual(result, .passThrough)
    }

    // Non-Escape key → .passThrough
    func testNonEscapeKey_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateCancelEvent(
            keyCode: 49, // Space
            modifiers: HotkeyModifiers(option: false, command: false, control: false, shift: false),
            isKeyUp: false
        )
        XCTAssertEqual(result, .passThrough)
    }
}
