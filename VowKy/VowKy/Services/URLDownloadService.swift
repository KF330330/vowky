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
    enum Phase: Sendable { case provisioningTools, resolving, fetchingSubtitles, downloading, extractingAudio }
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

/// 字幕优先级（设置项）。
enum SubtitlePriority: String, Sendable {
    case all         // 优先所有字幕（人工 + 自动）
    case manualOnly  // 仅人工字幕优先，自动字幕走本地 ASR
    case never       // 总是本地转写

    static func fromRawValue(_ raw: String) -> SubtitlePriority {
        SubtitlePriority(rawValue: raw) ?? .all
    }
}

/// 文字结果的来源（用于 UI 徽章区分）。
enum TranscriptSource: Sendable, Equatable {
    case manualSubtitle(language: String?)
    case autoSubtitle(language: String?)
}

/// `download()` 的结果：要么是待转写的本地媒体，要么是已直接拿到的字幕文字。
enum DownloadResult: Sendable {
    case media(DownloadedMedia)
    case transcript(text: String, source: TranscriptSource, title: String)
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
        subtitlePriority: SubtitlePriority,
        progress: @escaping @MainActor (DownloadProgress) -> Void
    ) async throws -> DownloadResult
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
        subtitlePriority: SubtitlePriority,
        progress: @escaping @MainActor (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
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
        // Cookie 只发给哔哩哔哩（它的 412 闸需要登录 cookie）。YouTube 带 cookie 会被迫走需要 JS runtime(nsig)
        // 的格式解析，本机无 deno/node → 连「只取字幕」都报「Requested format is not available」而失败；
        // DeepLearning/通用的公开内容也不需要 cookie。这样全局 cookie 设成浏览器后，转 YouTube 不再被搞坏。
        let cookieArguments = platform == .bilibili ? cookieArgs(cookies) : []

        // 2) 字幕优先：先尝试直接拉平台字幕（快 + 质量高）。拿到就直接出文字，跳过下载 + ASR。
        var knownTitle: String?
        if subtitlePriority != .never {
            await progress(DownloadProgress(phase: .fetchingSubtitles, fractionCompleted: -1))
            switch await trySubtitle(
                platform: platform, url: trimmed, extras: extras,
                cookies: cookieArguments, priority: subtitlePriority, tools: tools, workDir: workDir
            ) {
            case .transcript(let text, let source, let title):
                let resolved = (title?.isEmpty == false) ? title! : fallbackTitle(for: trimmed)
                return .transcript(text: text, source: source, title: resolved)
            case .noSubtitle(let title):
                knownTitle = title
            }
            try Task.checkCancellation()
        }

        // 3) 没字幕 → 下载音频走 ASR。先确定标题（复用字幕步已取到的，否则单独取，B站无cookie取不到则回退）。
        await progress(DownloadProgress(phase: .resolving, fractionCompleted: -1))
        let title: String
        if let knownTitle, !knownTitle.isEmpty {
            title = knownTitle
        } else {
            title = (try? await resolveTitle(ytDlp: tools.ytDlp, url: trimmed, extras: extras, cookies: cookieArguments))
                ?? fallbackTitle(for: trimmed)
        }
        try Task.checkCancellation()

        let media = try await downloadAudio(
            platform: platform, url: trimmed, title: title,
            extras: extras, cookies: cookieArguments, tools: tools, workDir: workDir, progress: progress
        )
        return .media(media)
    }

    // MARK: 音频下载（Pass B）+ lux 无 cookie 兜底

    private func downloadAudio(
        platform: Platform, url: String, title: String,
        extras: [String], cookies: [String], tools: ProvisionedTools, workDir: URL,
        progress: @escaping @MainActor (DownloadProgress) -> Void
    ) async throws -> DownloadedMedia {
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
        arguments += cookies
        arguments.append(url)

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
        if result.exit != 0 {
            let mapped = Self.mapError(stdout: result.stdout, stderr: result.stderr)
            // 哔哩哔哩无 cookie 被 412 拦 → 用 lux（独立二进制，无需登录）下视频再抽音频。
            if platform == .bilibili, case .rateLimited = mapped {
                return try await downloadViaLux(url: url, title: title, tools: tools, workDir: workDir, progress: progress)
            }
            throw mapped
        }

        guard let media = locateOutput(in: workDir) else {
            throw URLDownloadError.noAudioProduced
        }
        return DownloadedMedia(mediaURL: media, rawTitle: title, workDir: workDir)
    }

    private func downloadViaLux(
        url: String, title: String, tools: ProvisionedTools, workDir: URL,
        progress: @escaping @MainActor (DownloadProgress) -> Void
    ) async throws -> DownloadedMedia {
        let lux: URL
        do {
            lux = try await provisioner.ensureLux { update in
                Task { @MainActor in
                    progress(DownloadProgress(phase: .provisioningTools, fractionCompleted: update.fractionCompleted,
                                              toolName: update.tool.isEmpty ? nil : update.tool))
                }
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw URLDownloadError.toolSetupFailed(reason)
        }
        try Task.checkCancellation()

        await progress(DownloadProgress(phase: .downloading, fractionCompleted: -1))
        // lux 下载到 workDir/luxmedia.<ext>；PATH 带上 binDir 以便 lux 必要时找到 ffmpeg 合流。
        let luxArgs = ["--output-path", workDir.path, "--output-name", "luxmedia", url]
        let r = try await run(executable: lux, arguments: luxArgs, additionalPath: tools.binDir.path)
        try Task.checkCancellation()
        guard r.exit == 0 else {
            throw Self.mapError(stdout: r.stdout, stderr: r.stderr)
        }
        guard let videoFile = locateLuxOutput(in: workDir) else {
            throw URLDownloadError.noAudioProduced
        }

        // ffmpeg 抽音频成 m4a（lux 产物可能是 flv/mp4，统一交解码器一个 .m4a）。
        await progress(DownloadProgress(phase: .extractingAudio, fractionCompleted: -1))
        let m4a = workDir.appendingPathComponent("media.m4a")
        let ff = try await run(executable: tools.ffmpeg, arguments: [
            "-y", "-i", videoFile.path, "-vn", "-c:a", "aac", "-b:a", "160k", m4a.path
        ])
        try Task.checkCancellation()
        guard ff.exit == 0, FileManager.default.fileExists(atPath: m4a.path) else {
            throw URLDownloadError.noAudioProduced
        }
        try? FileManager.default.removeItem(at: videoFile)   // 删掉 lux 下的大视频，只留 m4a
        return DownloadedMedia(mediaURL: m4a, rawTitle: title, workDir: workDir)
    }

    /// lux 产物定位：workDir 里非 media.m4a 的那个媒体文件（lux 命名 luxmedia.*，但多 part 时可能带后缀）。
    private func locateLuxOutput(in workDir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        let candidates = items.filter {
            $0.lastPathComponent != "media.m4a" && !$0.hasDirectoryPath && $0.pathExtension.lowercased() != "part"
        }
        // 取最大的那个（视频文件远大于杂项）。
        return candidates.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
    }

    // MARK: 字幕优先

    private enum SubtitleOutcome {
        case transcript(text: String, source: TranscriptSource, title: String?)
        case noSubtitle(title: String?)   // 没字幕时把已取到的标题带回去，供音频路径命名复用
    }

    /// 尝试直接拉字幕。**永不抛错**：任何失败/无字幕都回 `.noSubtitle`，让主流程平滑退回音频 ASR。
    private func trySubtitle(
        platform: Platform, url: String, extras: [String], cookies: [String],
        priority: SubtitlePriority, tools: ProvisionedTools, workDir: URL
    ) async -> SubtitleOutcome {
        do {
            switch platform {
            case .deeplearningAI:
                return try await fetchDeepLearningSubtitle(
                    url: url, extras: extras, cookies: cookies, tools: tools, workDir: workDir)
            case .youtube, .bilibili, .generic:
                return try await fetchYtDlpSubtitle(
                    platform: platform, url: url, extras: extras, cookies: cookies,
                    priority: priority, tools: tools, workDir: workDir)
            }
        } catch {
            return .noSubtitle(title: nil)
        }
    }

    /// YouTube / 哔哩哔哩 / 通用：先一次 metadata 取「标题+语言+人工字幕+自动字幕」，再按优先级选轨抓取。
    private func fetchYtDlpSubtitle(
        platform: Platform, url: String, extras: [String], cookies: [String],
        priority: SubtitlePriority, tools: ProvisionedTools, workDir: URL
    ) async throws -> SubtitleOutcome {
        // 单行多字段，自定义分隔符避开标题里的换行/竖线；j 修饰符把字幕字典输出成 JSON。
        let sep = "@@VOWKYF@@"
        var metaArgs = ["--skip-download", "--no-playlist", "--no-warnings",
                        "--print", "%(title)s\(sep)%(language)s\(sep)%(subtitles)j\(sep)%(automatic_captions)j"]
        metaArgs += extras
        metaArgs += cookies
        metaArgs.append(url)

        let meta = try await run(executable: tools.ytDlp, arguments: metaArgs, isTitlePass: true)
        guard meta.exit == 0 else { return .noSubtitle(title: nil) }   // B站无 cookie 412 等 → 退音频
        guard let dataLine = meta.stdout
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { $0.contains(sep) }) else {
            return .noSubtitle(title: nil)
        }
        let parts = dataLine.components(separatedBy: sep)
        guard parts.count >= 4 else { return .noSubtitle(title: parts.first) }

        let title = (parts[0] == "NA" || parts[0].isEmpty) ? nil : parts[0]
        let language = (parts[1] == "NA" || parts[1].isEmpty) ? nil : parts[1]
        let origLang = language ?? Self.defaultLanguage(for: platform)

        // 哔哩哔哩：轻量 `--print %(subtitles)j` / `-J` 都不填充 subtitles 字段（yt-dlp 只在
        // `--list-subs`/`--write-subs` 时才去拉 B站字幕信息），必须用 list-subs 探测，
        // 否则会漏掉 AI 字幕(ai-zh)误判为「无字幕」而回退下载音频。
        if platform == .bilibili {
            return try await bilibiliSubtitleOutcome(
                url: url, title: title, prefer: origLang, priority: priority,
                extras: extras, cookies: cookies, tools: tools, workDir: workDir)
        }

        // YouTube / 通用：metadata 探针里的 subtitles / automatic_captions 字段可靠。
        let manualKeys = parseSubDict(parts[2])
        let autoKeys = parseSubDict(parts[3])

        // 人工字幕：两种模式都优先用。
        if let lang = pickManualLang(manualKeys, prefer: origLang),
           let text = try await fetchAndParseSub(
            url: url, lang: lang, isAuto: false, platform: platform,
            extras: extras, cookies: cookies, tools: tools, workDir: workDir) {
            return .transcript(text: text, source: .manualSubtitle(language: lang), title: title)
        }

        // 自动字幕：仅「优先所有字幕」时用，且只认原语言（避开 157 个翻译版）。
        if priority == .all,
           let lang = pickAutoLang(autoKeys, prefer: origLang),
           let text = try await fetchAndParseSub(
            url: url, lang: lang, isAuto: true, platform: platform,
            extras: extras, cookies: cookies, tools: tools, workDir: workDir) {
            return .transcript(text: text, source: .autoSubtitle(language: lang), title: title)
        }

        return .noSubtitle(title: title)
    }

    /// 哔哩哔哩字幕：用 `--list-subs` 探测可用轨（B站 AI 字幕 ai-zh 在轻量探针下不暴露）。
    /// 人工 CC 两模式都用、AI 字幕(ai-*)仅「优先所有」时用；抓取一律 --write-subs（B站字幕不在 auto-captions 里）。
    private func bilibiliSubtitleOutcome(
        url: String, title: String?, prefer: String, priority: SubtitlePriority,
        extras: [String], cookies: [String], tools: ProvisionedTools, workDir: URL
    ) async throws -> SubtitleOutcome {
        let listed = (try? await listSubLangs(url: url, extras: extras, cookies: cookies, tools: tools))
            ?? (manual: Set<String>(), auto: Set<String>())
        let usable = listed.manual.union(listed.auto)
            .filter { $0 != "danmaku" && $0 != "live_chat" && !$0.isEmpty }
        guard !usable.isEmpty else { return .noSubtitle(title: title) }

        let humanLangs = usable.filter { !$0.hasPrefix("ai-") }
        let aiLangs = usable.filter { $0.hasPrefix("ai-") }

        // 人工 CC 字幕优先（两模式都用）。
        if let lang = pickManualLang(humanLangs, prefer: prefer),
           let text = try await fetchAndParseSub(
            url: url, lang: lang, isAuto: false, platform: .bilibili,
            extras: extras, cookies: cookies, tools: tools, workDir: workDir) {
            return .transcript(text: text, source: .manualSubtitle(language: lang), title: title)
        }

        // AI 字幕：仅「优先所有字幕」时用（优先原语言 ai-<lang>，否则任意 ai- 轨）。
        if priority == .all {
            let aiLang = aiLangs.contains("ai-\(prefer)") ? "ai-\(prefer)" : aiLangs.sorted().first
            if let lang = aiLang,
               let text = try await fetchAndParseSub(
                url: url, lang: lang, isAuto: false, platform: .bilibili,
                extras: extras, cookies: cookies, tools: tools, workDir: workDir) {
                return .transcript(text: text, source: .autoSubtitle(language: lang), title: title)
            }
        }

        return .noSubtitle(title: title)
    }

    /// `--list-subs` 探测可用字幕语言（B站等平台的输出全在 stdout）。
    private func listSubLangs(
        url: String, extras: [String], cookies: [String], tools: ProvisionedTools
    ) async throws -> (manual: Set<String>, auto: Set<String>) {
        var args = ["--list-subs", "--skip-download", "--no-playlist", "--no-warnings"]
        args += extras
        args += cookies
        args.append(url)
        let r = try await run(executable: tools.ytDlp, arguments: args, isTitlePass: true)
        guard r.exit == 0 else { return (manual: [], auto: []) }
        return Self.parseListSubs(r.stdout)
    }

    /// 解析 `--list-subs` 表格（两段：Available subtitles / Available automatic captions），
    /// 取每行首列语言键，剔除 danmaku / live_chat。
    static func parseListSubs(_ output: String) -> (manual: Set<String>, auto: Set<String>) {
        var manual = Set<String>(), auto = Set<String>()
        var section = 0   // 0 未进入 / 1 人工字幕 / 2 自动字幕
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if lower.contains("available subtitles for") { section = 1; continue }
            if lower.contains("available automatic captions for") { section = 2; continue }
            guard section != 0 else { continue }
            if lower.hasPrefix("language") { continue }      // 表头 "Language Formats"
            if line.hasPrefix("[") || lower.hasPrefix("warning") || lower.hasPrefix("error") { continue }
            guard let lang = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
                  !lang.isEmpty, lang != "danmaku", lang != "live_chat" else { continue }
            if section == 1 { manual.insert(lang) } else { auto.insert(lang) }
        }
        return (manual: manual, auto: auto)
    }

    /// 用 yt-dlp 抓单条字幕轨为 vtt，解析成纯文本。失败回 nil。
    private func fetchAndParseSub(
        url: String, lang: String, isAuto: Bool, platform: Platform,
        extras: [String], cookies: [String], tools: ProvisionedTools, workDir: URL
    ) async throws -> String? {
        let subFlag = isAuto ? "--write-auto-subs" : "--write-subs"
        let outTemplate = workDir.appendingPathComponent("sub.%(ext)s").path
        var args = [
            "--skip-download", "--no-playlist", "--no-warnings",
            subFlag, "--sub-langs", lang, "--sub-format", "vtt/best", "--convert-subs", "vtt",
            "--ffmpeg-location", tools.binDir.path,
            "-o", outTemplate
        ]
        args += extras
        args += cookies
        args.append(url)

        let r = try await run(executable: tools.ytDlp, arguments: args)
        try Task.checkCancellation()
        guard r.exit == 0, let vtt = locateSubtitleFile(in: workDir) else { return nil }
        let raw = (try? String(contentsOf: vtt, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: vtt)
        // 仅 YouTube/通用的自动字幕是滚动重复格式；人工字幕、B站 AI 字幕都不是。
        let rolling = isAuto && (platform == .youtube || platform == .generic)
        let text = SubtitleParser.plainText(from: raw, rolling: rolling)
        return text.isEmpty ? nil : text
    }

    /// DeepLearning.AI：从 HLS master m3u8 里取 WebVTT 字幕轨（比爬 React 页面稳）。
    private func fetchDeepLearningSubtitle(
        url: String, extras: [String], cookies: [String], tools: ProvisionedTools, workDir: URL
    ) async throws -> SubtitleOutcome {
        var jArgs = ["-J", "--skip-download", "--no-playlist", "--no-warnings"]
        jArgs += extras
        jArgs += cookies
        jArgs.append(url)
        let j = try await run(executable: tools.ytDlp, arguments: jArgs, isTitlePass: true)
        guard j.exit == 0 else { return .noSubtitle(title: nil) }

        let jsonLine = j.stdout.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("{") })
            .map(String.init) ?? j.stdout
        guard let data = jsonLine.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .noSubtitle(title: nil)
        }
        let title = root["title"] as? String
        guard let master = firstManifestURL(root) else { return .noSubtitle(title: title) }
        guard let subPlaylist = try await deeplearningSubtitlePlaylist(master: master) else {
            return .noSubtitle(title: title)
        }
        let vtt = try await fetchVTTFromPlaylist(subPlaylist)
        guard !vtt.isEmpty else { return .noSubtitle(title: title) }
        let text = SubtitleParser.plainText(from: vtt, rolling: false)
        guard !text.isEmpty else { return .noSubtitle(title: title) }
        return .transcript(text: text, source: .manualSubtitle(language: "en"), title: title)
    }

    // MARK: 字幕选轨 / 解析 / HLS 小工具

    private static func defaultLanguage(for platform: Platform) -> String {
        platform == .bilibili ? "zh" : "en"
    }

    private func parseSubDict(_ json: String) -> Set<String> {
        let t = json.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{"), let data = t.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(dict.keys)
    }

    private func pickManualLang(_ keys: Set<String>, prefer: String) -> String? {
        let usable = keys.filter { $0 != "live_chat" && !$0.isEmpty }
        guard !usable.isEmpty else { return nil }
        if usable.contains(prefer) { return prefer }
        if usable.contains(prefer + "-orig") { return prefer + "-orig" }
        if let regional = usable.first(where: { $0.hasPrefix(prefer + "-") }) { return regional }
        if usable.contains("en") { return "en" }
        return usable.sorted().first
    }

    /// 自动字幕只认原语言（exact / `-orig` / 同语言区域变体 / 任意 `-orig` 键），绝不回退到任意键——否则会抓到翻译版。
    private func pickAutoLang(_ keys: Set<String>, prefer: String) -> String? {
        let usable = keys.filter { $0 != "live_chat" && !$0.isEmpty }
        guard !usable.isEmpty else { return nil }
        if usable.contains(prefer) { return prefer }
        if usable.contains(prefer + "-orig") { return prefer + "-orig" }
        if let regional = usable.first(where: { $0.hasPrefix(prefer + "-") }) { return regional }
        // language=NA/未知时：YouTube 用 `<lang>-orig` 标记原始自动字幕语言（与 language 字段无关），
        // 取任意 `-orig` 键即原语言，既修 NA 漏字幕又天然避开翻译版。
        if let orig = usable.sorted().first(where: { $0.hasSuffix("-orig") }) { return orig }
        return nil
    }

    private func locateSubtitleFile(in workDir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return items.first {
            $0.lastPathComponent.hasPrefix("sub.") && $0.pathExtension.lowercased() == "vtt"
        }
    }

    private func firstManifestURL(_ root: [String: Any]) -> URL? {
        let formats = (root["formats"] as? [[String: Any]]) ?? []
        for f in formats {
            if let m = f["manifest_url"] as? String, m.contains(".m3u8"), let u = URL(string: m) { return u }
        }
        return nil
    }

    /// 从 master m3u8 找 `#EXT-X-MEDIA:TYPE=SUBTITLES` 轨，优先英文，返回字幕子播放列表 URL。
    private func deeplearningSubtitlePlaylist(master: URL) async throws -> URL? {
        let (data, _) = try await URLSession.shared.data(from: master)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var candidates: [(lang: String, uri: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.hasPrefix("#EXT-X-MEDIA:"), line.contains("TYPE=SUBTITLES") else { continue }
            let lang = m3u8Attr(line, "LANGUAGE") ?? m3u8Attr(line, "NAME") ?? ""
            if let uri = m3u8Attr(line, "URI") { candidates.append((lang, uri)) }
        }
        guard !candidates.isEmpty else { return nil }
        let chosen = candidates.first(where: { $0.lang.lowercased().hasPrefix("en") }) ?? candidates[0]
        return URL(string: chosen.uri, relativeTo: master)?.absoluteURL
    }

    /// 抓字幕子播放列表里的 .vtt 段并拼接（通常一段；子列表本身就是 vtt 时直接返回）。
    private func fetchVTTFromPlaylist(_ playlist: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: playlist)
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        var segments: [URL] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let u = URL(string: line, relativeTo: playlist)?.absoluteURL { segments.append(u) }
        }
        if segments.isEmpty {
            return text.contains("WEBVTT") ? text : ""
        }
        var combined = ""
        for seg in segments {
            try Task.checkCancellation()
            let (segData, _) = try await URLSession.shared.data(from: seg)
            if let s = String(data: segData, encoding: .utf8) { combined += s + "\n\n" }
        }
        return combined
    }

    /// 从 m3u8 标签行抽 `KEY="value"`。
    private func m3u8Attr(_ line: String, _ key: String) -> String? {
        guard let r = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
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
        additionalPath: String? = nil,
        onStdoutLine: @escaping (String) -> Void = { _ in },
        onStderrLine: @escaping (String) -> Void = { _ in }
    ) async throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // environment 继承父进程，保住 $HOME 供 --cookies-from-browser 读取浏览器 profile。
        if let additionalPath {
            var env = ProcessInfo.processInfo.environment
            let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = additionalPath + ":" + existing
            process.environment = env
        }

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
