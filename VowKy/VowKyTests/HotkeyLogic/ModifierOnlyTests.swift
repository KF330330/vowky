import XCTest
@testable import VowKy

final class ModifierOnlyTests: XCTestCase {

    // MARK: - Display Name

    func testModifierOnlyDisplayName_fn() {
        let config = HotkeyConfig(
            keyCode: 63, needsOption: false, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: true,
            isHoldMode: false
        )
        XCTAssertEqual(config.displayName, "Fn")
    }

    func testModifierOnlyDisplayName_control() {
        let config = HotkeyConfig(
            keyCode: 59, needsOption: false, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: true,
            isHoldMode: false
        )
        XCTAssertEqual(config.displayName, "⌃")
    }

    func testModifierOnlyDisplayName_option() {
        let config = HotkeyConfig(
            keyCode: 58, needsOption: false, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: true,
            isHoldMode: false
        )
        XCTAssertEqual(config.displayName, "⌥")
    }

    func testModifierOnlyDisplayName_command() {
        let config = HotkeyConfig(
            keyCode: 55, needsOption: false, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: true,
            isHoldMode: false
        )
        XCTAssertEqual(config.displayName, "⌘")
    }

    func testModifierOnlyDisplayName_shift() {
        let config = HotkeyConfig(
            keyCode: 56, needsOption: false, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: true,
            isHoldMode: false
        )
        XCTAssertEqual(config.displayName, "⇧")
    }

    // MARK: - Modifier Flag

    func testModifierFlag_fn() {
        let config = HotkeyConfig(
            keyCode: 63, needsOption: false, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: true,
            isHoldMode: false
        )
        XCTAssertEqual(config.modifierFlag, .maskSecondaryFn)
    }

    func testModifierFlag_control() {
        let config = HotkeyConfig(
            keyCode: 59, needsOption: false, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: true,
            isHoldMode: false
        )
        XCTAssertEqual(config.modifierFlag, .maskControl)
    }

    func testModifierFlag_notModifierOnly_returnsNil() {
        let config = HotkeyConfig(
            keyCode: 49, needsOption: true, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: false,
            isHoldMode: false
        )
        XCTAssertNil(config.modifierFlag)
    }

    // MARK: - Standard combo mode unaffected

    func testComboMode_displayName_unchanged() {
        let config = HotkeyConfig(
            keyCode: 42, needsOption: false, needsCommand: true,
            needsControl: false, needsShift: false, isModifierOnly: false,
            isHoldMode: false
        )
        XCTAssertEqual(config.displayName, "⌘\\")
    }

    // MARK: - Persistence

    func testModifierOnlyConfig_saveAndLoad() {
        let config = HotkeyConfig(
            keyCode: 63, needsOption: false, needsCommand: false,
            needsControl: false, needsShift: false, isModifierOnly: true,
            isHoldMode: false
        )
        config.save()

        let loaded = HotkeyConfig.current
        XCTAssertEqual(loaded.keyCode, 63)
        XCTAssertTrue(loaded.isModifierOnly)

        // Restore default
        HotkeyConfig.resetToDefault()
    }

    func testComboConfig_saveAndLoad_isModifierOnlyFalse() {
        let config = HotkeyConfig(
            keyCode: 42, needsOption: false, needsCommand: true,
            needsControl: false, needsShift: false, isModifierOnly: false,
            isHoldMode: false
        )
        config.save()

        let loaded = HotkeyConfig.current
        XCTAssertEqual(loaded.keyCode, 42)
        XCTAssertFalse(loaded.isModifierOnly)
        XCTAssertTrue(loaded.needsCommand)

        // Restore default
        HotkeyConfig.resetToDefault()
    }
}
