import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let crashTimestampsKey = "crashLoop_launchTimestamps"
    private static let lastLaunchedVersionKey = "lastLaunchedVersion"

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashLogger.logLaunch()

        // Crash loop detection: 30s 内 ≥3 次启动 → 重置快捷键 + 删除 backup
        if detectCrashLoop() {
            CrashLogger.log("[CrashLoop] Detected! Resetting hotkey and deleting backup")
            HotkeyConfig.resetToDefault()
            deleteBackupFile()
            showCrashLoopAlert()
        }

        // 第一层防御：移除 quarantine xattr，防止 App Translocation 导致 TCC 失效
        removeQuarantineXattr()
        checkAppTranslocation()

        // 首次启动由新手引导统一处理权限和冲突检测
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if hasCompletedOnboarding {
            // 第二层防御：检测更新后权限丢失，执行 tccutil reset 恢复
            let handledByPostUpdate = handlePostUpdatePermissionIfNeeded()
            if !handledByPostUpdate {
                checkAccessibilityPermission()
            }
            checkOptionSpaceConflict()
        }
    }

    // MARK: - Crash Loop Detection

    /// Records current launch timestamp. Returns true if ≥3 launches within 30 seconds.
    private func detectCrashLoop() -> Bool {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        var timestamps = defaults.array(forKey: Self.crashTimestampsKey) as? [Double] ?? []

        // Keep only timestamps within the last 30 seconds
        timestamps = timestamps.filter { now - $0 < 30 }
        timestamps.append(now)
        defaults.set(timestamps, forKey: Self.crashTimestampsKey)

        CrashLogger.log("[CrashLoop] Launch count in 30s window: \(timestamps.count)")
        return timestamps.count >= 3
    }

    private func deleteBackupFile() {
        let tmpBackup = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_recording_backup.wav")
        try? FileManager.default.removeItem(at: tmpBackup)
        CrashLogger.log("[CrashLoop] Deleted backup file")
    }

    private func showCrashLoopAlert() {
        let config = HotkeyConfig.current
        let alert = NSAlert()
        alert.messageText = "VowKy 检测到启动异常"
        alert.informativeText = "VowKy 在短时间内多次重启，可能是快捷键冲突导致。已将快捷键重置为默认值（\(config.displayName)）。\n\n您可以在设置中重新自定义快捷键。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "我知道了")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashLogger.log("[App] applicationWillTerminate — graceful exit")
    }

    // MARK: - Anti-Translocation (Layer 1)

    /// 移除 quarantine xattr，防止 Sparkle 更新后 macOS App Translocation
    private func removeQuarantineXattr() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", bundlePath]
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                CrashLogger.log("[AntiTranslocation] Quarantine xattr removed from \(bundlePath)")
            }
        } catch {
            CrashLogger.log("[AntiTranslocation] xattr removal failed: \(error.localizedDescription)")
        }
    }

    /// 检测当前是否在 App Translocation 临时路径运行
    /// macOS 会将带 quarantine 的 app 移到 /private/var/folders/.../AppTranslocation/ 下运行
    private func checkAppTranslocation() {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/AppTranslocation/") {
            CrashLogger.log("[AntiTranslocation] App is translocated! Path: \(bundlePath)")
            showTranslocationAlert()
        }
    }

    private func showTranslocationAlert() {
        let alert = NSAlert()
        alert.messageText = "VowKy 需要移动到应用程序文件夹"
        alert.informativeText = "macOS 安全机制限制了 VowKy 的运行位置，可能导致快捷键无法使用。\n\n请将 VowKy 拖动到「应用程序」文件夹后重新打开。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开应用程序文件夹")
        alert.addButton(withTitle: "稍后处理")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
    }

    // MARK: - Post-Update Permission Recovery (Layer 2)

    /// 检测 Sparkle 更新后 TCC 权限丢失，执行 tccutil reset 恢复
    /// 返回 true 表示已处理（调用方应跳过通用权限检查）
    private func handlePostUpdatePermissionIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let lastVersion = defaults.string(forKey: Self.lastLaunchedVersionKey)

        defer {
            defaults.set(currentVersion, forKey: Self.lastLaunchedVersionKey)
        }

        // 首次记录版本 或 版本未变 → 跳过
        guard let lastVersion = lastVersion, lastVersion != currentVersion else {
            return false
        }

        CrashLogger.log("[PostUpdate] Version changed: \(lastVersion) → \(currentVersion)")

        // 版本变了但权限还在 → 无需处理
        if AXIsProcessTrusted() {
            CrashLogger.log("[PostUpdate] Permission still valid after update")
            return false
        }

        // 权限丢失 → 执行 tccutil reset 清除脏 TCC 条目
        CrashLogger.log("[PostUpdate] Permission lost after update, running tccutil reset")
        runTCCUtilReset()
        showPostUpdatePermissionAlert(fromVersion: lastVersion, toVersion: currentVersion)
        return true
    }

    private func runTCCUtilReset() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", "com.vowky.app"]
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            process.waitUntilExit()
            CrashLogger.log("[PostUpdate] tccutil reset exit code: \(process.terminationStatus)")
        } catch {
            CrashLogger.log("[PostUpdate] tccutil reset failed: \(error.localizedDescription)")
        }
    }

    private func showPostUpdatePermissionAlert(fromVersion: String, toVersion: String) {
        let alert = NSAlert()
        alert.messageText = "更新后需要重新授权"
        alert.informativeText = "VowKy 已从 v\(fromVersion) 更新到 v\(toVersion)。\n\nmacOS 要求应用更新后重新授予辅助功能权限，请在接下来的系统对话框中点击「打开系统设置」并开启 VowKy 的开关。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
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
        alert.messageText = "VowKy 需要辅助功能权限"
        let hotkeyName = HotkeyConfig.current.displayName
        alert.informativeText = "VowKy 使用全局快捷键（\(hotkeyName)）来触发语音输入，需要辅助功能权限才能正常工作。\n\n点击「打开系统设置」后，请在列表中找到 VowKy 并开启开关。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后设置")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Trigger the system prompt to open accessibility settings
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
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
        alert.informativeText = "系统的「选择上一个输入法」快捷键也使用了 Option+Space，这会与 VowKy 的语音输入快捷键冲突。\n\n请前往「系统设置 > 键盘 > 键盘快捷键 > 输入法」中修改或关闭该快捷键。"
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
