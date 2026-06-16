import Foundation
import Security

/// 「自动更新」链路专用的独立日志，落盘到
/// `~/Library/Application Support/VowKy/update.log`。
///
/// 设计目的（应对自更新功能反复被其他改动误伤的问题）：
/// 每次发版只需打开这一份日志，确认顶部「自检」几行全部 OK、且整条生命周期没有 ⛔️/❌，
/// 即可相信更新功能未被破坏，无需每次手动端到端验证。
///
/// 与 `CrashLogger` 分离（各写各的文件），互不干扰、便于单独排查更新问题。
/// 全部为静态、线程安全（文件追加）的纯日志，不改变任何更新行为。
enum UpdateLogger {

    private static let maxFileSize = 100 * 1024 // 100KB，超出后保留后半段

    private static var logURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VowKy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("update.log")
    }()

    /// 日志文件绝对路径（供「显示日志」入口或排查时定位）。
    static var logFilePath: String { logURL.path }

    // MARK: - 会话开始 + 自检

    /// App 启动、updater 启动成功后调用：写会话分隔头 + 一次性「健康自检」。
    /// 自检覆盖历史上每一次自更新出问题的根因点，方便发版后一眼确认。
    static func logSessionStart(autoCheck: Bool, autoDownload: Bool, interval: TimeInterval, lastCheck: Date?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        appendToFile("\n========== VowKy Update Session  v\(version) (build \(build))  \(timestamp()) ==========\n")
        logDiagnostics(autoCheck: autoCheck, autoDownload: autoDownload, interval: interval, lastCheck: lastCheck)
    }

    /// 健康自检：把「判断更新功能是否健康」所需的关键事实一次性写进日志。
    static func logDiagnostics(autoCheck: Bool, autoDownload: Bool, interval: TimeInterval, lastCheck: Date?) {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? "❌ MISSING"
        let edKey = (info["SUPublicEDKey"] as? String) ?? ""
        let hasSecPolicy = info["NSUpdateSecurityPolicy"] != nil

        log("自检 feedURL                = \(feed)")
        log("自检 SUPublicEDKey          = \(edKey.isEmpty ? "❌ MISSING（appcast 签名将被拒）" : "✅ present (\(edKey.prefix(8))…)")")
        log("自检 NSUpdateSecurityPolicy = \(hasSecPolicy ? "✅ present" : "⚠️ absent")")
        log("自检 自动检查更新           = \(autoCheck ? "ON" : "OFF")")
        log("自检 自动下载更新           = \(autoDownload ? "ON" : "OFF")")
        log("自检 检查间隔               = \(Int(interval))s")
        if let lastCheck { log("自检 上次检查时间           = \(lastCheck)") }
        log("自检 主进程代码签名         = \(selfCodeSignatureStatus())   // 必须 VALID；INVALID 会被 macOS「App 管理」拦截原地自更新")
        log("自检 安全时间戳             = \(selfSecureTimestampStatus())   // 自更新硬性要求；无安全时间戳则点更新报「更新错误」")
    }

    /// 单条带时间戳的日志。
    static func log(_ message: String) {
        appendToFile("[\(timestamp())] \(message)\n")
    }

    // MARK: - 代码签名金丝雀

    /// 检查「主进程当前活动代码签名」是否有效 —— 历史上自更新反复出问题的根因金丝雀：
    /// 主 app 一旦（被误改）链接 ONNX 或带上 `allow-unsigned-executable-memory`，运行后活签名失效，
    /// macOS Sequoia/Tahoe 的「App 管理」会拒绝原地替换 → 自更新「装不上」。
    /// 这里只读取、只记录，不做任何拦截。
    static func selfCodeSignatureStatus() -> String {
        var code: SecCode?
        let copyStatus = SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
        guard copyStatus == errSecSuccess, let code else {
            return "unknown (SecCodeCopySelf=\(copyStatus))"
        }
        let checkStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
        return checkStatus == errSecSuccess ? "VALID" : "INVALID (OSStatus \(checkStatus))"
    }

    /// 检查「主进程自身代码签名是否带 Apple 安全时间戳」。
    /// 无安全时间戳（只有本地 Signed Time）的包，会被 macOS Sequoia/Tahoe「App 管理」拒绝
    /// 「同开发者自更新豁免」→ Sparkle 原地替换被拦 → 用户点更新报「更新错误」。这是历史上
    /// SKIP_NOTARIZE 测试包「能下载、装不上」的真因。通过 spawn `codesign -dvv` 读自身签名信息
    /// （与 `AppDelegate.logLaunchDiagnostics` 同一手法；本 App 未沙箱，允许 Process）。
    static func selfSecureTimestampStatus() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", Bundle.main.bundlePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe   // codesign 的 -d 信息写到 stderr
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            if out.contains("\nTimestamp=") || out.hasPrefix("Timestamp=") {
                return "✅ 有（可自更新）"
            }
            if out.contains("Signed Time=") {
                return "❌ 无安全时间戳（仅 Signed Time → 会被 App 管理拦截自更新）"
            }
            return "未知（codesign 输出无 Timestamp/Signed Time 字段）"
        } catch {
            return "未知（codesign 调用失败: \(error.localizedDescription)）"
        }
    }

    // MARK: - Private

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private static func appendToFile(_ text: String) {
        let url = logURL
        let data = Data(text.utf8)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }

        // 超过上限就截断，保留后半段（最近的日志最有用）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxFileSize {
            truncateFile(at: url, keepBytes: maxFileSize / 2)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.synchronize()
        try? handle.close()
    }

    private static func truncateFile(at url: URL, keepBytes: Int) {
        guard let data = try? Data(contentsOf: url) else { return }
        let start = max(0, data.count - keepBytes)
        let kept = data[start...]
        try? kept.write(to: url)
    }
}
