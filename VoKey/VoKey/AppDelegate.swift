import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()
        checkOptionSpaceConflict()
    }

    // MARK: - Accessibility Permission

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            showAccessibilityGuide()
        }
    }

    private func showAccessibilityGuide() {
        let alert = NSAlert()
        alert.messageText = "VoKey 需要辅助功能权限"
        alert.informativeText = "VoKey 使用全局快捷键（Option+Space）来触发语音输入，需要辅助功能权限才能正常工作。\n\n点击「打开系统设置」后，请在列表中找到 VoKey 并开启开关。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后设置")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Trigger the system prompt to open accessibility settings
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    // MARK: - Option+Space Conflict Detection

    private func checkOptionSpaceConflict() {
        // Check if the system "Select the previous input source" shortcut uses Option+Space.
        // This is stored in com.apple.symbolichotkeys, key "61" (previous input source).
        guard let hotkeys = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let items = hotkeys["AppleSymbolicHotKeys"] as? [String: Any],
              let item61 = items["61"] as? [String: Any],
              let enabled = item61["enabled"] as? Bool, enabled,
              let value = item61["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int] else {
            return
        }

        // parameters: [charCode, keyCode, modifiers]
        // Option+Space: keyCode=49, modifiers include Option (0x80000 = 524288)
        // The exact modifier mask for Option is 0x80000 (524288) in symbolic hotkeys
        if parameters.count >= 3 {
            let keyCode = parameters[1]
            let modifiers = parameters[2]
            let isSpace = (keyCode == 49)
            let hasOption = (modifiers & 0x80000) != 0
            let hasCommand = (modifiers & 0x100000) != 0
            let hasControl = (modifiers & 0x40000) != 0

            // Only conflict if it's pure Option+Space (no Cmd, no Ctrl)
            if isSpace && hasOption && !hasCommand && !hasControl {
                showConflictAlert()
            }
        }
    }

    private func showConflictAlert() {
        let alert = NSAlert()
        alert.messageText = "快捷键冲突"
        alert.informativeText = "系统的「选择上一个输入法」快捷键也使用了 Option+Space，这会与 VoKey 的语音输入快捷键冲突。\n\n请前往「系统设置 > 键盘 > 键盘快捷键 > 输入法」中修改或关闭该快捷键。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开键盘设置")
        alert.addButton(withTitle: "我知道了")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
