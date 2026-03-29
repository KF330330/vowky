import Foundation
import CoreGraphics

struct HotkeyConfig {
    var keyCode: Int64
    var needsOption: Bool
    var needsCommand: Bool
    var needsControl: Bool
    var needsShift: Bool
    var isModifierOnly: Bool  // true = 单修饰键短按触发模式
    var isHoldMode: Bool      // true = 长按说话模式, false = 按键切换模式

    // MARK: - Defaults

    static let defaultKeyCode: Int64 = 42 // Backslash (\)
    static let defaultOption = false
    static let defaultCommand = true
    static let defaultControl = false
    static let defaultShift = false
    static let defaultIsModifierOnly = false
    static let defaultIsHoldMode = false

    // MARK: - UserDefaults Keys

    private static let keyCodeKey = "hotkey_keyCode"
    private static let optionKey = "hotkey_option"
    private static let commandKey = "hotkey_command"
    private static let controlKey = "hotkey_control"
    private static let shiftKey = "hotkey_shift"
    private static let isModifierOnlyKey = "hotkey_isModifierOnly"
    private static let isHoldModeKey = "hotkey_isHoldMode"

    // MARK: - Read / Write

    static var current: HotkeyConfig {
        let defaults = UserDefaults.standard
        let hasStored = defaults.object(forKey: keyCodeKey) != nil
        guard hasStored else {
            return HotkeyConfig(
                keyCode: defaultKeyCode,
                needsOption: defaultOption,
                needsCommand: defaultCommand,
                needsControl: defaultControl,
                needsShift: defaultShift,
                isModifierOnly: defaultIsModifierOnly,
                isHoldMode: defaultIsHoldMode
            )
        }
        return HotkeyConfig(
            keyCode: Int64(defaults.integer(forKey: keyCodeKey)),
            needsOption: defaults.bool(forKey: optionKey),
            needsCommand: defaults.bool(forKey: commandKey),
            needsControl: defaults.bool(forKey: controlKey),
            needsShift: defaults.bool(forKey: shiftKey),
            isModifierOnly: defaults.bool(forKey: isModifierOnlyKey),
            isHoldMode: defaults.bool(forKey: isHoldModeKey)
        )
    }

    static func resetToDefault() {
        let config = HotkeyConfig(
            keyCode: defaultKeyCode,
            needsOption: defaultOption,
            needsCommand: defaultCommand,
            needsControl: defaultControl,
            needsShift: defaultShift,
            isModifierOnly: defaultIsModifierOnly,
            isHoldMode: defaultIsHoldMode
        )
        config.save()
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
        defaults.set(needsOption, forKey: Self.optionKey)
        defaults.set(needsCommand, forKey: Self.commandKey)
        defaults.set(needsControl, forKey: Self.controlKey)
        defaults.set(needsShift, forKey: Self.shiftKey)
        defaults.set(isModifierOnly, forKey: Self.isModifierOnlyKey)
        defaults.set(isHoldMode, forKey: Self.isHoldModeKey)
    }

    // MARK: - Display Name

    // MARK: - Modifier-Only Helpers

    /// 返回目标修饰键对应的 CGEventFlags
    var modifierFlag: CGEventFlags? {
        guard isModifierOnly else { return nil }
        switch keyCode {
        case 55: return .maskCommand
        case 56: return .maskShift
        case 58: return .maskAlternate
        case 59: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    /// 修饰键 keyCode → 显示名
    static func modifierName(for keyCode: Int64) -> String {
        switch keyCode {
        case 55: return "⌘"
        case 56: return "⇧"
        case 58: return "⌥"
        case 59: return "⌃"
        case 63: return "Fn"
        default: return "Key\(keyCode)"
        }
    }

    // MARK: - Display Name

    var displayName: String {
        if isModifierOnly {
            return Self.modifierName(for: keyCode)
        }
        var parts: [String] = []
        if needsControl { parts.append("⌃") }
        if needsOption { parts.append("⌥") }
        if needsShift { parts.append("⇧") }
        if needsCommand { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: Int64) -> String {
        let names: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: ".", 47: "M",
            48: "Tab", 49: "Space", 50: "`", 51: "Delete",
            53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 109: "F10", 111: "F12",
            118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}
