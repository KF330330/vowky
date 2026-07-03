import XCTest
@testable import VowKy

final class HotkeyLogicTests: XCTestCase {

    /// 显式传入 Option+Space 配置：测试不再依赖本机 UserDefaults 里的真实热键设置
    /// （此前 evaluateEvent 默认读 HotkeyConfig.current，机器改过热键这些测试就全挂）。
    private static let optionSpace = HotkeyConfig(
        keyCode: 49,  // Space
        needsOption: true,
        needsCommand: false,
        needsControl: false,
        needsShift: false,
        isModifierOnly: false,
        isHoldMode: false
    )

    // MARK: - Test 1: Option+Space keyDown → .hotkeyDown

    func testOptionSpaceKeyDown_returnsHotkeyDown() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: Self.optionSpace.keyCode,
            modifiers: HotkeyModifiers(option: true, command: false, control: false, shift: false),
            isRepeat: false,
            isKeyUp: false,
            config: Self.optionSpace
        )
        XCTAssertEqual(result, .hotkeyDown)
    }

    // MARK: - Test 2: Plain Space (no modifiers) → .passThrough

    func testPlainSpace_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: Self.optionSpace.keyCode,
            modifiers: HotkeyModifiers(option: false, command: false, control: false, shift: false),
            isRepeat: false,
            isKeyUp: false,
            config: Self.optionSpace
        )
        XCTAssertEqual(result, .passThrough)
    }

    // MARK: - Test 3: Option+Space with isRepeat → .passThrough

    func testOptionSpaceRepeat_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: Self.optionSpace.keyCode,
            modifiers: HotkeyModifiers(option: true, command: false, control: false, shift: false),
            isRepeat: true,
            isKeyUp: false,
            config: Self.optionSpace
        )
        XCTAssertEqual(result, .passThrough)
    }

    // MARK: - Test 4: Option+Space keyUp → .hotkeyUp

    func testOptionSpaceKeyUp_returnsHotkeyUp() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: Self.optionSpace.keyCode,
            modifiers: HotkeyModifiers(option: true, command: false, control: false, shift: false),
            isRepeat: false,
            isKeyUp: true,
            config: Self.optionSpace
        )
        XCTAssertEqual(result, .hotkeyUp)
    }

    // MARK: - Test 5: Cmd+Space → .passThrough (should not trigger)

    func testCmdSpace_returnsPassThrough() {
        let result = HotkeyEvaluator.evaluateEvent(
            keyCode: Self.optionSpace.keyCode,
            modifiers: HotkeyModifiers(option: false, command: true, control: false, shift: false),
            isRepeat: false,
            isKeyUp: false,
            config: Self.optionSpace
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
            isKeyUp: false,
            config: Self.optionSpace
        )
        XCTAssertEqual(result, .passThrough)
    }
}
