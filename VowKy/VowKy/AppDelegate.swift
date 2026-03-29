import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let crashTimestampsKey = "crashLoop_launchTimestamps"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoCopyToClipboard": true])
        CrashLogger.logLaunch()
        logLaunchDiagnostics()

        // Crash loop detection: 30s 内 ≥3 次启动 → 重置快捷键 + 删除 backup
        if detectCrashLoop() {
            CrashLogger.log("[CrashLoop] Detected! Resetting hotkey and deleting backup")
            HotkeyConfig.resetToDefault()
            deleteBackupFile()
            showCrashLoopAlert()
        }

        // 首次启动由新手引导统一处理权限和冲突检测
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if hasCompletedOnboarding {
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

    // MARK: - Launch Diagnostics

    /// 记录启动时的关键环境信息，用于诊断 Sparkle 更新后 TCC 权限失效问题
    private func logLaunchDiagnostics() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let bundlePath = bundle.bundlePath
        let trusted = AXIsProcessTrusted()
        let lastVersion = UserDefaults.standard.string(forKey: "diag_lastVersion") ?? "(none)"

        // 检测 quarantine xattr
        let hasQuarantine: Bool = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-p", "com.apple.quarantine", bundlePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }()

        // 检测 App Translocation
        let isTranslocated = bundlePath.contains("/AppTranslocation/")

        // 获取代码签名身份
        let signingInfo: String = {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["-d", "--verbose=1", bundlePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            } catch {
                return "codesign failed: \(error.localizedDescription)"
            }
        }()

        CrashLogger.log("[Diag] === Launch Diagnostics ===")
        CrashLogger.log("[Diag] Version: \(version) (\(build)), lastVersion: \(lastVersion)")
        CrashLogger.log("[Diag] Path: \(bundlePath)")
        CrashLogger.log("[Diag] AXIsProcessTrusted: \(trusted)")
        CrashLogger.log("[Diag] Quarantine: \(hasQuarantine)")
        CrashLogger.log("[Diag] Translocated: \(isTranslocated)")
        CrashLogger.log("[Diag] Signing: \(signingInfo)")
        CrashLogger.log("[Diag] ===========================")

        // 更新记录的版本
        UserDefaults.standard.set(version, forKey: "diag_lastVersion")
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
