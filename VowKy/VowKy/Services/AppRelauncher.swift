import AppKit

/// 干净重启：detached shell 先等当前进程退出、再 `open -n`，避免新旧实例重叠
/// （重叠会让全局热键 tap、常驻语音 helper 端口冲突）。
///
/// 两个调用方共用同一套重启语义：设置页切换语言（`LocalizationManager.applyLanguageAndRestart`）
/// 与音频卡死自愈（`AppState.attemptSelfHealIfIdle`）。
enum AppRelauncher {
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(pid) >/dev/null 2>&1; do sleep 0.1; done; /usr/bin/open -n \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
