import Foundation

// MARK: - 类型

/// cookie 来源：很多站点（尤其哔哩哔哩）不带 cookie 会被反爬拦（HTTP 412）。
enum CookieSource: Equatable, Sendable {
    case none
    case browser(String)      // "safari" | "chrome" | "firefox" | "edge" | "brave"
    case cookiesFile(URL)

    /// 持久化用的字符串（UserDefaults）。
    var rawValue: String {
        switch self {
        case .none: return "none"
        case .browser(let b): return b
        case .cookiesFile(let url): return "file:\(url.path)"
        }
    }

    static func fromRawValue(_ raw: String) -> CookieSource {
        switch raw {
        case "none", "": return .none
        case "safari", "chrome", "firefox", "edge", "brave": return .browser(raw)
        default:
            if raw.hasPrefix("file:") {
                return .cookiesFile(URL(fileURLWithPath: String(raw.dropFirst("file:".count))))
            }
            return .none
        }
    }
}

struct DownloadProgress: Sendable {
    enum Phase: Sendable { case provisioningTools, resolving, downloading, extractingAudio }
    let phase: Phase
    /// 0...1；-1 表示不定态。
    let fractionCompleted: Double
    let etaText: String?
    /// provisioningTools 阶段正在下载哪个工具（"yt-dlp"/"ffmpeg"/...）。
    let toolName: String?

    init(phase: Phase, fractionCompleted: Double, etaText: String? = nil, toolName: String? = nil) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.etaText = etaText
        self.toolName = toolName
    }
}

struct DownloadedMedia: Sendable {
    let mediaURL: URL    // workDir 内的本地 .m4a
    let rawTitle: String // 视频标题（用于命名）
    let workDir: URL     // 唯一临时子目录，调用方用完删除
}

enum URLDownloadError: LocalizedError, Equatable {
    case toolSetupFailed(String)
    case invalidURL
    case authenticationRequired
    case rateLimited
    case unsupportedURL
    case videoUnavailable
    case network
    case noAudioProduced
    case toolLaunchFailed
    case generic(String)

    var errorDescription: String? {
        switch self {
        case .toolSetupFailed(let reason): return reason
        case .invalidURL:                  return LL("file.url.error.invalidURL")
        case .authenticationRequired:      return LL("file.url.error.authRequired")
        case .rateLimited:                 return LL("file.url.error.rateLimited")
        case .unsupportedURL:              return LL("file.url.error.unsupported")
        case .videoUnavailable:            return LL("file.url.error.unavailable")
        case .network:                     return LL("file.url.error.network")
        case .noAudioProduced:             return LL("file.url.error.noAudio")
        case .toolLaunchFailed:            return LL("file.url.error.ytDlpMissing")
        case .generic(let message):        return LL("file.url.error.generic", message)
        }
    }
}

protocol URLMediaDownloading: Sendable {
    func download(
        urlString: String,
        into workDir: URL,
        cookies: CookieSource,
        progress: @escaping @MainActor (DownloadProgress) -> Void
    ) async throws -> DownloadedMedia
}

// MARK: - 服务

/// 把一个视频链接下成本地 `.m4a`：spawn 已就绪的 `yt-dlp`，强制 `-x --audio-format m4a` 让产物始终是
/// AVFoundation 能解的 AAC 容器（源可能是 webm/opus，AVFoundation 解不了，必须经 ffmpeg 转码）。
/// 转写核心（MediaAudioDecoder / FileTranscriptionService / Sherpa-ONNX）完全复用，无需改动。
final class URLDownloadService: URLMediaDownloading, @unchecked Sendable {
    private let provisioner: ToolProvisioner

    /// stdout 静默看门狗：无新行超过此时长判为卡死/网络中断（长视频下载本身合法，不设硬墙钟超时）。
    private static let stallTimeout: TimeInterval = 120
    private static let titleTimeout: TimeInterval = 45

    /// MediaAudioDecoder 接受的扩展名（保持一致，产物必须落在其中）。
    private static let decodableExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "flac", "mp4", "mov", "m4v"
    ]

    init(provisioner: ToolProvisioner = .shared) {
        self.provisioner = provisioner
    }

    // MARK: 平台识别（照搬 ReadVideo 的匹配）

    enum Platform {
        case youtube, bilibili, deeplearningAI, generic
    }

    static func platform(for urlString: String) -> Platform {
        let s = urlString.lowercased()
        if s.contains("youtube.com/watch") || s.contains("youtu.be/")
            || s.contains("youtube.com/shorts") || s.contains("youtube.com/embed") {
            return .youtube
        }
        if s.contains("bilibili.com/video") || s.contains("b23.tv/") || s.contains("bilibili.com/s/video") {
            return .bilibili
        }
        if s.contains("learn.deeplearning.ai/courses")
            || s.contains("deeplearning.ai/short-courses") || s.contains("deeplearning.ai/courses") {
            return .deeplearningAI
        }
        return .generic
    }

    private func extraArgs(for platform: Platform) -> [String] {
        switch platform {
        case .youtube:
            return ["--extractor-args", "youtubetab:skip=authcheck"]
        case .bilibili, .deeplearningAI, .generic:
            return []
        }
    }

    private func cookieArgs(_ source: CookieSource) -> [String] {
        switch source {
        case .none: return []
        case .browser(let b): return ["--cookies-from-browser", b]
        case .cookiesFile(let url): return ["--cookies", url.path]
        }
    }

    // MARK: 主流程

    func download(
        urlString: String,
        into workDir: URL,
        cookies: CookieSource,
        progress: @escaping @MainActor (DownloadProgress) -> Void
    ) async throws -> DownloadedMedia {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let _ = URL(string: trimmed), trimmed.hasPrefix("http") else {
            throw URLDownloadError.invalidURL
        }

        // 1) 确保工具就绪（首次会联网下载 yt-dlp/ffmpeg/ffprobe）。
        await progress(DownloadProgress(phase: .provisioningTools, fractionCompleted: -1))
        let tools: ProvisionedTools
        do {
            tools = try await provisioner.ensureTools { update in
                Task { @MainActor in
                    progress(DownloadProgress(
                        phase: .provisioningTools,
                        fractionCompleted: update.fractionCompleted,
                        toolName: update.tool.isEmpty ? nil : update.tool
                    ))
                }
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw URLDownloadError.toolSetupFailed(reason)
        }
        try Task.checkCancellation()

        let platform = Self.platform(for: trimmed)
        let extras = extraArgs(for: platform)
        let cookieArguments = cookieArgs(cookies)

        // 2) Pass A：取标题 + 快速失败（在长下载前暴露 bot-check / 登录 / 不支持 等错误）。
        await progress(DownloadProgress(phase: .resolving, fractionCompleted: -1))
        let title = try await resolveTitle(
            ytDlp: tools.ytDlp, url: trimmed, extras: extras, cookies: cookieArguments
        )
        try Task.checkCancellation()

        // 3) Pass B：下载并提取音频为 m4a。
        let outputTemplate = workDir.appendingPathComponent("media.%(ext)s").path
        var arguments = [
            "-f", "bestaudio/best",
            "-x", "--audio-format", "m4a",
            "--no-playlist", "--no-mtime", "--no-warnings", "--newline",
            "--no-update",
            "--progress-template", "download:PROG|%(progress._percent_str)s|%(progress.eta)s",
            "--ffmpeg-location", tools.binDir.path,
            "-o", outputTemplate
        ]
        arguments += extras
        arguments += cookieArguments
        arguments.append(trimmed)

        let result = try await run(
            executable: tools.ytDlp,
            arguments: arguments,
            onStdoutLine: { line in
                if let update = Self.parseProgress(line) {
                    Task { @MainActor in progress(update) }
                } else if Self.isExtractingLine(line) {
                    Task { @MainActor in
                        progress(DownloadProgress(phase: .extractingAudio, fractionCompleted: -1))
                    }
                }
            },
            onStderrLine: { line in
                if Self.isExtractingLine(line) {
                    Task { @MainActor in
                        progress(DownloadProgress(phase: .extractingAudio, fractionCompleted: -1))
                    }
                }
            }
        )

        try Task.checkCancellation()
        guard result.exit == 0 else {
            throw Self.mapError(stdout: result.stdout, stderr: result.stderr)
        }

        // 4) 定位产物：必须是解码器认识的扩展名。
        guard let media = locateOutput(in: workDir) else {
            throw URLDownloadError.noAudioProduced
        }
        return DownloadedMedia(mediaURL: media, rawTitle: title, workDir: workDir)
    }

    // MARK: Pass A

    private func resolveTitle(ytDlp: URL, url: String, extras: [String], cookies: [String]) async throws -> String {
        var arguments = ["--skip-download", "--no-playlist", "--no-warnings", "--print", "%(title)s"]
        arguments += extras
        arguments += cookies
        arguments.append(url)

        let result = try await run(executable: ytDlp, arguments: arguments, isTitlePass: true)
        if result.exit != 0 {
            throw Self.mapError(stdout: result.stdout, stderr: result.stderr)
        }
        let title = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        return title.isEmpty ? fallbackTitle(for: url) : title
    }

    private func fallbackTitle(for url: String) -> String {
        if let comps = URLComponents(string: url),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return "video-\(v)"
        }
        let last = URL(string: url)?.lastPathComponent ?? ""
        return last.isEmpty ? "video" : last
    }

    // MARK: 产物定位

    private func locateOutput(in workDir: URL) -> URL? {
        let fm = FileManager.default
        // 优先 media.m4a。
        let preferred = workDir.appendingPathComponent("media.m4a")
        if fm.fileExists(atPath: preferred.path) { return preferred }
        guard let items = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return items.first { Self.decodableExtensions.contains($0.pathExtension.lowercased()) }
    }

    // MARK: 进度解析

    /// 形如「PROG| 30.5%|2」。
    static func parseProgress(_ line: String) -> DownloadProgress? {
        guard line.hasPrefix("PROG|") else { return nil }
        let parts = line.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        let percentText = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let percent = Double(percentText) else { return nil }
        let eta = parts.count >= 3 ? parts[2].trimmingCharacters(in: .whitespaces) : nil
        let etaText = (eta == nil || eta == "NA" || eta?.isEmpty == true) ? nil : eta
        return DownloadProgress(
            phase: .downloading,
            fractionCompleted: min(1, max(0, percent / 100)),
            etaText: etaText
        )
    }

    static func isExtractingLine(_ line: String) -> Bool {
        line.contains("[ExtractAudio]") || line.contains("[ffmpeg]") || line.contains("[Merger]")
    }

    // MARK: 错误映射

    static func mapError(stdout: String, stderr: String) -> URLDownloadError {
        let text = (stderr + "\n" + stdout)
        let lower = text.lowercased()

        if lower.contains("sign in to confirm you're not a bot")
            || lower.contains("sign in to confirm your age")
            || lower.contains("confirm your age")
            || lower.contains("private video")
            || lower.contains("members-only")
            || lower.contains("login required")
            || lower.contains("requires authentication") {
            return .authenticationRequired
        }
        if lower.contains("http error 412") || lower.contains("precondition failed") {
            return .rateLimited
        }
        if lower.contains("unsupported url") || lower.contains("is not a valid url") {
            return .unsupportedURL
        }
        if lower.contains("video unavailable")
            || lower.contains("has been removed")
            || lower.contains("not available in your country")
            || lower.contains("this video is no longer available") {
            return .videoUnavailable
        }
        if lower.contains("unable to download webpage")
            || lower.contains("getaddrinfo")
            || lower.contains("failed to resolve")
            || lower.contains("temporary failure in name resolution")
            || lower.contains("network is unreachable")
            || lower.contains("connection")
            || lower.contains("timed out") {
            return .network
        }
        // 取最后一条「ERROR:」行作为通用信息。
        let errorLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { $0.hasPrefix("ERROR:") || $0.hasPrefix("ERROR ") })
        let message = errorLine?.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces)
        return .generic(message?.isEmpty == false ? message! : LL("file.url.error.genericFallback"))
    }

    // MARK: 进程运行（合并行回调 + 看门狗 + 取消）

    struct RunResult { let exit: Int32; let stdout: String; let stderr: String }

    private func run(
        executable: URL,
        arguments: [String],
        isTitlePass: Bool = false,
        onStdoutLine: @escaping (String) -> Void = { _ in },
        onStderrLine: @escaping (String) -> Void = { _ in }
    ) async throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // environment 继承父进程，保住 $HOME 供 --cookies-from-browser 读取浏览器 profile。

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lastOutput = AtomicTimestamp()
        let stdoutReader = LineCollector(onLine: onStdoutLine)
        let stderrReader = LineCollector(onLine: onStderrLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lastOutput.touch()
            stdoutReader.feed(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lastOutput.touch()
            stderrReader.feed(data)
        }

        let guardian = ContinuationGuard()
        process.terminationHandler = { _ in guardian.fire() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw URLDownloadError.toolLaunchFailed
        }

        let timeout = isTitlePass ? Self.titleTimeout : Self.stallTimeout
        let watchdog = Task.detached {
            while true {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                if Task.isCancelled { return }
                guard process.isRunning else { return }
                if lastOutput.secondsSinceLast() > timeout {
                    process.terminate()
                    return
                }
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                guardian.setContinuation(cont)
            }
        } onCancel: {
            process.terminate()
        }

        watchdog.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutReader.finish()
        stderrReader.finish()

        return RunResult(
            exit: process.terminationStatus,
            stdout: stdoutReader.recentText,
            stderr: stderrReader.recentText
        )
    }
}

// MARK: - 小工具

/// 串行喂入 stdout/stderr 数据、按 \n 切行回调，并保留尾部若干行用于错误映射。
/// 只在单个 readabilityHandler 的串行队列上被读写，故 @unchecked Sendable 安全。
private final class LineCollector: @unchecked Sendable {
    private var buffer = Data()
    private var lines: [String] = []
    private let maxLines = 400
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        buffer.append(data)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            emit(lineData)
        }
    }

    func finish() {
        if !buffer.isEmpty {
            emit(buffer)
            buffer.removeAll()
        }
    }

    private func emit(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8) else { return }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        lines.append(trimmed)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        onLine(trimmed)
    }

    var recentText: String { lines.joined(separator: "\n") }
}

/// 线程安全的「最后一次输出时间」holder（readabilityHandler 与看门狗跨线程访问）。
private final class AtomicTimestamp: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    func secondsSinceLast() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

/// 保证 CheckedContinuation 只 resume 一次，且无视「设置 continuation」与「进程退出」的先后顺序。
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var cont: CheckedContinuation<Void, Never>?

    func setContinuation(_ c: CheckedContinuation<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if resumed { c.resume() } else { cont = c }
    }

    func fire() {
        lock.lock(); defer { lock.unlock() }
        if resumed { return }
        resumed = true
        let c = cont
        cont = nil
        c?.resume()
    }
}
