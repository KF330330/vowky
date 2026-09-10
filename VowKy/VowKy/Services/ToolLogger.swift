import CFNetwork
import Foundation

/// 「链接转文字」外部工具（yt-dlp / ffmpeg / deno / lux）准备链路专用的独立日志，落盘到
/// `~/Library/Application Support/VowKy/tools.log`。
///
/// 设计目的：首次转链接要串行下载约 140 MB 外部工具，用户侧一旦「卡住」，
/// 只需要这一份日志就能判断卡在哪一步（镜像/上游、哪个工具、多少字节、什么速度、什么错误）。
/// 与 `UpdateLogger` 同结构、各写各的文件，互不干扰。
/// 全部为静态、线程安全（文件追加）的纯日志，不改变任何下载行为。
enum ToolLogger {

    private static let maxFileSize = 100 * 1024 // 100KB，超出后保留后半段

    /// 单测注入用：指向临时文件，避免污染用户真实 `tools.log`。
    nonisolated(unsafe) static var overrideLogURL: URL?

    private static let defaultLogURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VowKy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tools.log")
    }()

    private static var logURL: URL { overrideLogURL ?? defaultLogURL }

    /// 日志文件绝对路径（供错误提示里的「详细日志」指路）。
    static var logFilePath: String { logURL.path }

    // MARK: - 会话开始

    /// 每次真正要联网准备工具时调用（快路径不写），写会话分隔头 + 已装状态 + 系统代理开关。
    static func logSessionStart(installed: [String: Bool]) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        appendToFile("\n========== VowKy Tools  v\(version) (build \(build)) \(archName())  \(timestamp()) ==========\n")
        let summary = ["yt-dlp", "ffmpeg", "deno"]
            .map { "\($0)=\((installed[$0] ?? false) ? "Y" : "N")" }
            .joined(separator: " ")
        log("已装: \(summary)")
        log("系统代理: \(proxySummary())")
    }

    /// 单条带时间戳的日志。
    static func log(_ message: String) {
        appendToFile("[\(timestamp())] \(message)\n")
    }

    // MARK: - Private

    private static func archName() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    /// 只读系统代理的**开关布尔**（不记录任何主机/端口/PAC 地址等可能敏感的内容）。
    private static func proxySummary() -> String {
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        func on(_ key: String) -> String {
            let value = settings[key]
            if let number = value as? NSNumber { return number.boolValue ? "ON" : "OFF" }
            return "OFF"
        }
        return "HTTP=\(on(kCFNetworkProxiesHTTPEnable as String)) "
            + "HTTPS=\(on("HTTPSEnable")) "
            + "SOCKS=\(on(kCFNetworkProxiesSOCKSEnable as String)) "
            + "PAC=\(on(kCFNetworkProxiesProxyAutoConfigEnable as String))"
    }

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

        // 必须用可抛错的新 API：旧版 `seekToEndOfFile()`/`write(_:)` 在磁盘满等 I/O 错误下抛
        // Objective-C 异常（NSFileHandleOperationException），`try?` 挡不住，会整个 App 崩溃。
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            // 日志写失败静默忽略，绝不影响工具准备流程。
        }
    }

    private static func truncateFile(at url: URL, keepBytes: Int) {
        guard let data = try? Data(contentsOf: url) else { return }
        let start = max(0, data.count - keepBytes)
        let kept = data[start...]
        try? kept.write(to: url)
    }
}
