import XCTest
@testable import VoKey

final class HotkeyLogicTests: XCTestCase {

    // MARK: - Test 1: Option+Space keyDown → .hotkeyDown

    func testOptionSpaceKeyDown_returnsHotkeyDown() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: HotkeyConfig.defaultKeyCode,
            modifiers: HotkeyModifiers(option: true, command: false, control: false, shift: false),
            isRepeat: false,
            isKeyUp: false
        )
        XCTAssertEqual(result, .hotkeyDown)
    }

    // MARK: - Test 2: Plain Space (no modifiers) → .passThrough

    func testPlainSpace_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: HotkeyConfig.defaultKeyCode,
            modifiers: HotkeyModifiers(option: false, command: false, control: false, shift: false),
            isRepeat: false,
            isKeyUp: false
        )
        XCTAssertEqual(result, .passThrough)
    }

    // MARK: - Test 3: Option+Space with isRepeat → .passThrough

    func testOptionSpaceRepeat_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: HotkeyConfig.defaultKeyCode,
            modifiers: HotkeyModifiers(option: true, command: false, control: false, shift: false),
            isRepeat: true,
            isKeyUp: false
        )
        XCTAssertEqual(result, .passThrough)
    }

    // MARK: - Test 4: Option+Space keyUp → .hotkeyUp

    func testOptionSpaceKeyUp_returnsHotkeyUp() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: HotkeyConfig.defaultKeyCode,
            modifiers: HotkeyModifiers(option: true, command: false, control: false, shift: false),
            isRepeat: false,
            isKeyUp: true
        )
        XCTAssertEqual(result, .hotkeyUp)
    }

    // MARK: - Test 5: Cmd+Space → .passThrough (should not trigger)

    func testCmdSpace_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: HotkeyConfig.defaultKeyCode,
            modifiers: HotkeyModifiers(option: false, command: true, control: false, shift: false),
            isRepeat: false,
            isKeyUp: false
        )
        XCTAssertEqual(result, .passThrough)
    }

    // MARK: - Test 6: Option+A (non-Space key) → .passThrough

    func testOptionA_returnsPassThrough() {
        let keyCodeA: Int64 = 0 // 'A' keyCode on macOS
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: keyCodeA,
            modifiers: HotkeyModifiers(option: true, command: false, control: false, shift: false),
            isRepeat: false,
            isKeyUp: false
        )
        XCTAssertEqual(result, .passThrough)
    }
}
