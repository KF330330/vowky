import CryptoKit
import Foundation

/// 「从链接转文字」功能依赖两个外部二进制：`yt-dlp`（下载/解析视频）与 `ffmpeg`（抽音频、合成 HLS）。
/// 它们**不打包进 .app**（PyInstaller 的 yt-dlp 在 hardened runtime 下签名/公证极易出问题，且 yt-dlp 随 YouTube 改版很快过时），
/// 而是**首次用到该功能时联网下载**到 `~/Library/Application Support/VowKy/bin/`，之后缓存复用。
///
/// 该功能本质就是在线的（要下载网络视频），所以「首次联网取工具」不额外牺牲 VowKy 的「核心听写全离线」定位。
///
/// 设计要点：
/// - **优先 vowky.com 镜像、失败回退上游**。镜像清单以单文件签名信封 `manifest.signed.json` 发布，
///   用 Sparkle 同一把 Ed25519 私钥签名，App 用内置 `SUPublicEDKey` 验签后才解析；资产 sha256 钉在已签名清单里。
///   镜像任何一步失败（拉不到 / 验签不过 / HTTP 非 2xx / 校验不匹配 / 停流 / 低速 / 墙钟）→ 记日志 → 立即回退上游。
/// - **所有工具下载后强制 SHA256 校验**（fail-closed）：镜像来自已签名清单，上游沿用发布方校验文件
///   （yt-dlp=release 的 SHA2-256SUMS，ffmpeg=版本化 URL 旁的 `.sha256` sidecar，lux=goreleaser 的 checksums.txt）；
///   **取不到校验文件同样中止安装**，绝不无校验落盘。
/// - **等待上限**：大文件走 `ProgressDownloader`（进度 + 低速闸 + 墙钟）；小请求（信封 / 最新版本 API / 校验文件）
///   一律走 `fetchSmall` 的墙钟竞速，避免涓流把用户拖在「准备下载工具」界面上。
/// - **快路径**：两个工具都已装且 yt-dlp 不过期 → 零网络立即返回。
/// - 不再下载 `ffprobe`（yt-dlp 缺 ffprobe 会自动用 `ffmpeg -i` 探测；首次下载量 163 MB → 100 MB）。
///   已装 ffprobe 的老机器不删文件；`Manifest.ffprobeFetchedAt` 保留只为兼容旧 manifest.json。
/// - App 未沙盒（project.yml `ENABLE_APP_SANDBOX: NO`）+ URLSession 自写文件不带 `com.apple.quarantine`，
///   故下载的二进制无 Gatekeeper 拦截、无需公证即可作为子进程执行。

// MARK: - 错误

enum ToolProvisionError: LocalizedError, Equatable {
    /// `detail` 形如 "已下载 12.3 MB / 37.1 MB · 请求超时 (-1001)"、"速度过慢 (35 KB/s)"。
    case downloadFailed(tool: String, detail: String)
    case checksumMismatch(tool: String)
    case unpackFailed(tool: String)
    case notExecutable(tool: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let tool, let detail): return LL("file.tool.error.download", tool, detail)
        case .checksumMismatch(let tool):           return LL("file.tool.error.checksum", tool)
        case .unpackFailed(let tool):               return LL("file.tool.error.unpack", tool)
        case .notExecutable(let tool):              return LL("file.tool.error.notExecutable", tool)
        }
    }
}

// MARK: - 进度

/// 工具下载/安装进度（首次配置时驱动界面上的进度条与文案）。
struct ToolProvisionProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case checking, downloading, verifying, installing, ready }
    let phase: Phase
    let tool: String
    /// 0...1；-1 表示不定态。
    let fractionCompleted: Double
    /// 未知 = 0。
    let bytesReceived: Int64
    /// 未知 = -1。
    let totalBytes: Int64
    /// 未知 = -1。
    let bytesPerSecond: Double
    /// 1-based，本次动作序号。
    let toolIndex: Int
    /// 本次要做的动作总数（安装 + 刷新都计；0 = 无动作）。
    let toolCount: Int
    /// 本动作是「已装但刷新」；`.checking` 阶段表示两个工具都已装。
    let isRefresh: Bool

    init(
        phase: Phase,
        tool: String,
        fractionCompleted: Double,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = -1,
        bytesPerSecond: Double = -1,
        toolIndex: Int = 0,
        toolCount: Int = 0,
        isRefresh: Bool = false
    ) {
        self.phase = phase
        self.tool = tool
        self.fractionCompleted = fractionCompleted
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.toolIndex = toolIndex
        self.toolCount = toolCount
        self.isRefresh = isRefresh
    }
}

/// 已就绪的工具绝对路径。
struct ProvisionedTools: Sendable {
    let binDir: URL
    let ytDlp: URL
    let ffmpeg: URL
}

// MARK: - 端点

/// 所有外部端点集中于此并可注入，单测才能做到零真网请求。
struct ToolEndpoints: Sendable {
    var mirrorBase: URL
    var ytDlpLatestAPI: URL
    var ytDlpReleaseBase: URL
    var ffmpegRedirectBase: URL
    /// Ed25519 raw 32 字节；nil → 镜像整体禁用。
    var manifestPublicKey: Data?

    static func production() -> ToolEndpoints {
        let raw = (Bundle.main.infoDictionary?["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }
        return ToolEndpoints(
            mirrorBase: URL(string: "https://vowky.com/downloads/tools/")!,
            ytDlpLatestAPI: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!,
            ytDlpReleaseBase: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/")!,
            ffmpegRedirectBase: URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/")!,
            manifestPublicKey: raw?.count == 32 ? raw : nil
        )
    }
}

// MARK: - 镜像清单

/// 镜像清单（schema 1）。只经由 `decodeSignedEnvelope` 产生——即：**验签通过才可能存在**。
struct ToolMirrorManifest: Decodable, Sendable, Equatable {
    struct Asset: Decodable, Sendable, Equatable {
        let buildId: String?
        let asset: String
        let sha256: String
        let size: Int64
    }
    struct FFmpeg: Decodable, Sendable, Equatable {
        let version: String
        let arm64: Asset
        let amd64: Asset
    }
    struct YtDlp: Decodable, Sendable, Equatable {
        let tag: String
        let asset: String
        let sha256: String
        let size: Int64
    }

    let schema: Int
    let generatedAt: String
    let ytDlp: YtDlp
    let ffmpeg: FFmpeg

    private struct Envelope: Decodable {
        let schema: Int
        let manifest: String
        let signature: String
    }

    /// 解析签名信封 `{"schema":1,"manifest":"<base64 原始清单字节>","signature":"<base64 ed25519>"}`。
    /// 信封 schema≠1 / base64 无效 / 签名不过 / 清单 schema≠1 / sha256 非 64 hex / asset 含 ".." 或以 "/" 开头 → nil。
    static func decodeSignedEnvelope(_ data: Data, publicKey: Data) -> ToolMirrorManifest? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.schema == 1,
              let manifestBytes = Data(base64Encoded: envelope.manifest),
              let signature = Data(base64Encoded: envelope.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: manifestBytes),
              let manifest = try? JSONDecoder().decode(ToolMirrorManifest.self, from: manifestBytes),
              manifest.schema == 1 else {
            return nil
        }
        let assets = [
            (manifest.ytDlp.asset, manifest.ytDlp.sha256),
            (manifest.ffmpeg.arm64.asset, manifest.ffmpeg.arm64.sha256),
            (manifest.ffmpeg.amd64.asset, manifest.ffmpeg.amd64.sha256),
        ]
        for (asset, sha) in assets {
            guard isValidSHA256(sha), isSafeRelativeAsset(asset) else { return nil }
        }
        return manifest
    }

    func ffmpegAsset(archPath: String) -> Asset {
        archPath == "arm64" ? ffmpeg.arm64 : ffmpeg.amd64
    }

    static func assetURL(base: URL, asset: String) -> URL {
        base.appendingPathComponent(asset)
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func isSafeRelativeAsset(_ asset: String) -> Bool {
        !asset.isEmpty && !asset.contains("..") && !asset.hasPrefix("/")
    }
}

// MARK: - Provisioner

/// 串行化的工具准备器：多个下载任务并发调用 `ensureTools()` 时，actor 天然避免重复下载/竞态。
actor ToolProvisioner {
    static let shared = ToolProvisioner()

    private let fileManager = FileManager.default
    private let session: URLSession
    private let downloader: ProgressDownloader
    private let binDirOverride: URL?
    private let endpoints: ToolEndpoints
    private let mirrorPolicy: DownloadPolicy
    private let upstreamPolicy: DownloadPolicy
    private let smallRequestWallClock: TimeInterval
    private let envelopeWallClock: TimeInterval
    private let analytics: @Sendable (String, [String: Any]) -> Void

    // 当前运行架构对应的 ffmpeg 构建（universal 主 app 在各自 slice 上编译，`#if arch` 即反映运行架构）。
    #if arch(arm64)
    private static let ffmpegArchPath = "arm64"
    #else
    private static let ffmpegArchPath = "amd64"
    #endif

    /// 取不到「最新 tag」且镜像也不可用时的兜底（2026-06-28 验证可用）。
    private static let fallbackYtDlpTag = "2026.06.09"
    /// 版本确认的有效期：超过就要重新查一次上游。
    private static let ytDlpVersionValidity: TimeInterval = 7 * 24 * 3600
    /// 查询失败后的退避窗口。
    private static let ytDlpRefreshBackoff: TimeInterval = 24 * 3600

    // lux（哔哩哔哩无 cookie 兜底）：goreleaser 资产名 `lux_<version>_Darwin_<arch>.tar.gz`（version 去掉前缀 v）。
    #if arch(arm64)
    private static let luxArchName = "arm64"
    #else
    private static let luxArchName = "x86_64"
    #endif
    private static let fallbackLuxTag = "v0.24.1"

    init(
        binDirOverride: URL? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        endpoints: ToolEndpoints? = nil,
        mirrorPolicy: DownloadPolicy = DownloadPolicy(maxDuration: 240),
        upstreamPolicy: DownloadPolicy = DownloadPolicy(maxDuration: 900),
        smallRequestWallClock: TimeInterval = 15,
        envelopeWallClock: TimeInterval = 10,
        analytics: (@Sendable (String, [String: Any]) -> Void)? = nil
    ) {
        let config: URLSessionConfiguration
        if let sessionConfiguration {
            config = sessionConfiguration
        } else {
            config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 900
            config.waitsForConnectivity = false
        }
        self.session = URLSession(configuration: config)
        self.downloader = ProgressDownloader(session: session)
        self.binDirOverride = binDirOverride
        self.smallRequestWallClock = smallRequestWallClock
        self.envelopeWallClock = envelopeWallClock
        self.analytics = analytics ?? { event, data in
            AnalyticsService.shared.track(event, data: data)
        }

        var resolvedEndpoints = endpoints ?? ToolEndpoints.production()
        var resolvedMirrorPolicy = mirrorPolicy
        #if DEBUG
        // 只读 UserDefaults 的 Debug 覆盖，用于真机验收里确定性地触发「镜像失败 → 回退上游」。
        // 仅对生产实例生效（单测都显式注入 binDirOverride + endpoints，保持完全 hermetic）。
        if binDirOverride == nil && endpoints == nil {
            let defaults = UserDefaults.standard
            if let base = defaults.string(forKey: "vowky.debug.toolMirrorBase"),
               let url = URL(string: base) {
                resolvedEndpoints.mirrorBase = url
            }
            let kbps = defaults.integer(forKey: "vowky.debug.toolMirrorMinThroughputKBps")
            if kbps > 0 {
                resolvedMirrorPolicy.minBytesPerSecond = Double(kbps) * 1024
            }
            if defaults.object(forKey: "vowky.debug.toolMirrorGraceSeconds") != nil {
                let grace = defaults.double(forKey: "vowky.debug.toolMirrorGraceSeconds")
                if grace >= 0 { resolvedMirrorPolicy.graceSeconds = grace }
            }
        }
        #endif
        self.endpoints = resolvedEndpoints
        self.mirrorPolicy = resolvedMirrorPolicy
        self.upstreamPolicy = upstreamPolicy
    }

    // MARK: - 公开 API

    /// 确保 yt-dlp / ffmpeg 都已就绪，返回它们的绝对路径。缺失则下载；yt-dlp 过期则尽力刷新。
    func ensureTools(progress: (@Sendable (ToolProvisionProgress) -> Void)? = nil) async throws -> ProvisionedTools {
        let startedAt = Date()
        let binDir = try ensureBinDir()
        let ytDlp = binDir.appendingPathComponent("yt-dlp")
        let ffmpeg = binDir.appendingPathComponent("ffmpeg")
        let ytInstalled = isInstalled(ytDlp)
        let ffInstalled = isInstalled(ffmpeg)
        let tools = ProvisionedTools(binDir: binDir, ytDlp: ytDlp, ffmpeg: ffmpeg)

        // 快路径：工具齐备且版本新鲜 → 零网络立即返回。
        if ytInstalled && ffInstalled && !isYtDlpStale() {
            ToolLogger.log("工具齐备，跳过网络")
            progress?(ToolProvisionProgress(phase: .ready, tool: "", fractionCompleted: -1, toolCount: 0))
            return tools
        }

        ToolLogger.logSessionStart(installed: ["yt-dlp": ytInstalled, "ffmpeg": ffInstalled])
        progress?(ToolProvisionProgress(
            phase: .checking, tool: "", fractionCompleted: -1, isRefresh: ytInstalled && ffInstalled
        ))

        // 镜像清单与上游最新版本并发查询（两者都是有墙钟上限的小请求）。
        async let mirrorQuery = fetchMirrorManifest()
        async let upstreamQuery = resolveYtDlpTag()
        let mirror = await mirrorQuery
        let upstream = await upstreamQuery
        try Task.checkCancellation()

        var actions: [ToolAction] = []
        if !ytInstalled {
            let target = Self.newerTag(upstream, mirror?.ytDlp.tag) ?? Self.fallbackYtDlpTag
            actions.append(.installYtDlp(target: target, preferMirror: mirror?.ytDlp.tag == target))
        } else if let plan = refreshPlan(
            installed: readManifest().ytDlpTag ?? "0", upstream: upstream, mirror: mirror
        ) {
            actions.append(plan)
        }
        if !ffInstalled {
            actions.append(.installFFmpeg)
        }

        let count = actions.count
        for (offset, action) in actions.enumerated() {
            let index = offset + 1
            switch action {
            case .installYtDlp(let target, let preferMirror):
                try await runYtDlpAction(
                    target: target, preferMirror: preferMirror, isRefresh: false,
                    dest: ytDlp, mirror: mirror, upstream: upstream,
                    index: index, count: count, progress: progress
                )
            case .refreshYtDlp(let target, let preferMirror):
                // 刷新是 best-effort：网络不行就继续用旧版本，绝不因刷新失败阻断功能。
                do {
                    try await runYtDlpAction(
                        target: target, preferMirror: preferMirror, isRefresh: true,
                        dest: ytDlp, mirror: mirror, upstream: upstream,
                        index: index, count: count, progress: progress
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    writeManifest(ytDlpRefreshCheckedAt: .some(Date()))
                    ToolLogger.log("yt-dlp 刷新失败，继续用旧版本: \(Self.shortDescription(error))")
                }
            case .installFFmpeg:
                try await installFFmpeg(
                    dest: ffmpeg, mirror: mirror, index: index, count: count, progress: progress
                )
            }
            try Task.checkCancellation()
        }

        progress?(ToolProvisionProgress(phase: .ready, tool: "", fractionCompleted: -1, toolCount: count))
        ToolLogger.log(String(format: "ensureTools done in %.1fs", Date().timeIntervalSince(startedAt)))
        return tools
    }

    /// 仅确保 ffmpeg 可用。供本地媒体在 AVFoundation 无法解码个别坏包时本机降级，
    /// 媒体不会离开设备，也避免为了这条恢复路径额外准备 yt-dlp。
    func ensureFFmpeg(progress: (@Sendable (ToolProvisionProgress) -> Void)? = nil) async throws -> URL {
        let binDir = try ensureBinDir()
        let ffmpeg = binDir.appendingPathComponent("ffmpeg")
        progress?(ToolProvisionProgress(phase: .checking, tool: "ffmpeg", fractionCompleted: -1))
        if !isInstalled(ffmpeg) {
            try await installFFmpegFromUpstream(dest: ffmpeg, index: 1, count: 1, progress: progress)
        }
        progress?(ToolProvisionProgress(phase: .ready, tool: "ffmpeg", fractionCompleted: -1, toolCount: 0))
        return ffmpeg
    }

    /// 懒加载 lux（仅哔哩哔哩无 cookie 兜底时才用，故不进 `ensureTools` 的 eager 路径）。返回可执行绝对路径。
    func ensureLux(progress: (@Sendable (ToolProvisionProgress) -> Void)? = nil) async throws -> URL {
        let binDir = try ensureBinDir()
        let lux = binDir.appendingPathComponent("lux")
        if isInstalled(lux) { return lux }
        try await provisionLux(to: lux, progress: progress)
        return lux
    }

    /// 工具是否已全部就绪（用于「首次告知弹窗」判断要不要联网）。
    func toolsAlreadyInstalled() -> Bool {
        guard let binDir = try? binDirectoryURL() else { return false }
        return isInstalled(binDir.appendingPathComponent("yt-dlp"))
            && isInstalled(binDir.appendingPathComponent("ffmpeg"))
    }

    /// 让下次 `ensureTools()` 强制重下 yt-dlp（供 URLDownloadService 在疑似 yt-dlp 过时失败后重试一次）。
    func invalidateYtDlp() {
        guard let binDir = try? binDirectoryURL() else { return }
        try? fileManager.removeItem(at: binDir.appendingPathComponent("yt-dlp"))
        writeManifest(ytDlpFetchedAt: .some(nil))
    }

    // MARK: - 动作规划

    private enum ToolAction {
        case installYtDlp(target: String, preferMirror: Bool)
        case refreshYtDlp(target: String, preferMirror: Bool)
        case installFFmpeg
    }

    /// **永不降级**：只有当「已知的最新版本」严格高于本机已装版本时才刷新。
    /// 查不到最新版本 → 只写 24 h 退避，绝不把「查询失败」当成「已确认最新」。
    private func refreshPlan(installed: String, upstream: String?, mirror: ToolMirrorManifest?) -> ToolAction? {
        let mirrorTag = mirror?.ytDlp.tag
        guard let target = Self.newerTag(upstream, mirrorTag) else {
            writeManifest(ytDlpRefreshCheckedAt: .some(Date()))
            ToolLogger.log("yt-dlp 刷新：无法获知最新版本，24h 后再试")
            return nil
        }
        if Self.compareYtDlpTags(installed, target) != .orderedAscending {
            if upstream != nil {
                writeManifest(ytDlpVersionCheckedAt: .some(Date()))
                ToolLogger.log("yt-dlp 已是最新 \(installed)")
            } else {
                writeManifest(ytDlpRefreshCheckedAt: .some(Date()))
                ToolLogger.log("yt-dlp 本机 \(installed) 不低于镜像 \(mirrorTag ?? "-")，上游未知，24h 后再查")
            }
            return nil
        }
        return .refreshYtDlp(target: target, preferMirror: mirrorTag == target)
    }

    /// 两个 tag 中较新的那个（都为 nil 则 nil）。
    static func newerTag(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return compareYtDlpTags(a, b) == .orderedAscending ? b : a
        }
    }

    /// 按 "." 切分逐段比较：两段都是数字按数值比，否则按字符串比；缺段视为 0。
    static func compareYtDlpTags(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let right = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : "0"
            let b = index < right.count ? right[index] : "0"
            if let ai = Int(a), let bi = Int(b) {
                if ai != bi { return ai < bi ? .orderedAscending : .orderedDescending }
            } else if a != b {
                return a < b ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    // MARK: - 镜像清单

    private func fetchMirrorManifest() async -> ToolMirrorManifest? {
        guard let publicKey = endpoints.manifestPublicKey else {
            ToolLogger.log("mirror 禁用：无公钥")
            return nil
        }
        let url = endpoints.mirrorBase.appendingPathComponent("manifest.signed.json")
        let data: Data
        do {
            data = try await fetchSmall(url, wallClock: envelopeWallClock)
        } catch {
            ToolLogger.log("mirror manifest 不可用: \(Self.shortDescription(error))")
            return nil
        }
        guard let manifest = ToolMirrorManifest.decodeSignedEnvelope(data, publicKey: publicKey) else {
            ToolLogger.log("mirror manifest 签名/格式无效，忽略镜像")
            analytics("link_tool_provision", ["tool": "manifest", "src": "mirror", "ok": 0, "err": "sig_invalid"])
            return nil
        }
        ToolLogger.log(
            "mirror manifest ok: yt-dlp=\(manifest.ytDlp.tag) ffmpeg=\(manifest.ffmpeg.version) "
            + "generatedAt=\(manifest.generatedAt) 签名 OK"
        )
        return manifest
    }

    /// 取上游最新 release tag；网络/解析失败返回 nil（**不**回退到内置 tag——查不到不等于确认过）。
    private func resolveYtDlpTag() async -> String? {
        var request = URLRequest(url: endpoints.ytDlpLatestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let data = try? await fetchSmall(request, wallClock: smallRequestWallClock),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else {
            return nil
        }
        return tag
    }

    // MARK: - yt-dlp

    private func runYtDlpAction(
        target: String,
        preferMirror: Bool,
        isRefresh: Bool,
        dest: URL,
        mirror: ToolMirrorManifest?,
        upstream: String?,
        index: Int,
        count: Int,
        progress: (@Sendable (ToolProvisionProgress) -> Void)?
    ) async throws {
        let tool = "yt-dlp"
        let installedTag = readManifest().ytDlpTag ?? "0"
        var lastError: Error?

        // 1) 优先镜像（仅当镜像清单里的 tag 就是目标 tag）。
        if preferMirror, let mirror {
            do {
                let tmp = try await downloadVerified(
                    tool: tool, source: "mirror",
                    url: ToolMirrorManifest.assetURL(base: endpoints.mirrorBase, asset: mirror.ytDlp.asset),
                    expectedSHA: mirror.ytDlp.sha256, policy: mirrorPolicy,
                    index: index, count: count, isRefresh: isRefresh, progress: progress
                )
                try finishYtDlpInstall(
                    tmp: tmp, dest: dest, tag: mirror.ytDlp.tag, upstream: upstream,
                    index: index, count: count, isRefresh: isRefresh, progress: progress
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                ToolLogger.log("yt-dlp mirror 失败，回退上游: \(Self.shortDescription(error))")
            }
        }

        // 2) 上游 GitHub release。
        do {
            let base = endpoints.ytDlpReleaseBase.appendingPathComponent(target)
            let sumsURL = base.appendingPathComponent("SHA2-256SUMS")
            let expected = await fetchExpectedSHA(checksumURL: sumsURL, assetName: "yt-dlp_macos")
            let tmp = try await downloadVerified(
                tool: tool, source: "upstream",
                url: base.appendingPathComponent("yt-dlp_macos"),
                expectedSHA: expected, policy: upstreamPolicy,
                index: index, count: count, isRefresh: isRefresh, progress: progress
            )
            try finishYtDlpInstall(
                tmp: tmp, dest: dest, tag: target, upstream: upstream,
                index: index, count: count, isRefresh: isRefresh, progress: progress
            )
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }

        // 3) 上游不可达时，退回镜像里的旧版本（仍严格高于本机已装版本才装）。
        if let mirror, mirror.ytDlp.tag != target,
           Self.compareYtDlpTags(mirror.ytDlp.tag, installedTag) == .orderedDescending {
            ToolLogger.log("上游 \(target) 不可达，安装镜像旧版 \(mirror.ytDlp.tag)")
            let tmp = try await downloadVerified(
                tool: tool, source: "mirror",
                url: ToolMirrorManifest.assetURL(base: endpoints.mirrorBase, asset: mirror.ytDlp.asset),
                expectedSHA: mirror.ytDlp.sha256, policy: mirrorPolicy,
                index: index, count: count, isRefresh: isRefresh, progress: progress
            )
            try finishYtDlpInstall(
                tmp: tmp, dest: dest, tag: mirror.ytDlp.tag, upstream: upstream,
                index: index, count: count, isRefresh: isRefresh, progress: progress
            )
            return
        }
        throw lastError ?? ToolProvisionError.downloadFailed(tool: tool, detail: "no source")
    }

    private func finishYtDlpInstall(
        tmp: URL,
        dest: URL,
        tag: String,
        upstream: String?,
        index: Int,
        count: Int,
        isRefresh: Bool,
        progress: (@Sendable (ToolProvisionProgress) -> Void)?
    ) throws {
        defer { try? fileManager.removeItem(at: tmp) }
        progress?(ToolProvisionProgress(
            phase: .installing, tool: "yt-dlp", fractionCompleted: -1,
            toolIndex: index, toolCount: count, isRefresh: isRefresh
        ))
        try install(from: tmp, to: dest, tool: "yt-dlp")
        // 「版本已确认」只在**查到了上游最新版且本机装的不低于它**时成立；否则留 nil 并写 24h 退避。
        let confirmed = upstream.map { Self.compareYtDlpTags(tag, $0) != .orderedAscending } ?? false
        writeManifest(
            ytDlpFetchedAt: .some(Date()),
            ytDlpTag: tag,
            ytDlpVersionCheckedAt: .some(confirmed ? Date() : nil),
            ytDlpRefreshCheckedAt: .some(confirmed ? nil : Date())
        )
    }

    // MARK: - ffmpeg

    private func installFFmpeg(
        dest: URL,
        mirror: ToolMirrorManifest?,
        index: Int,
        count: Int,
        progress: (@Sendable (ToolProvisionProgress) -> Void)?
    ) async throws {
        if let mirror {
            let asset = mirror.ffmpegAsset(archPath: Self.ffmpegArchPath)
            do {
                let tmp = try await downloadVerified(
                    tool: "ffmpeg", source: "mirror",
                    url: ToolMirrorManifest.assetURL(base: endpoints.mirrorBase, asset: asset.asset),
                    expectedSHA: asset.sha256, policy: mirrorPolicy,
                    index: index, count: count, isRefresh: false, progress: progress
                )
                defer { try? fileManager.removeItem(at: tmp) }
                try unpackAndInstall(zip: tmp, name: "ffmpeg", dest: dest, index: index, count: count, progress: progress)
                writeManifest(staticTool: "ffmpeg")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                ToolLogger.log("ffmpeg mirror 失败，回退上游: \(Self.shortDescription(error))")
            }
        }
        try await installFFmpegFromUpstream(dest: dest, index: index, count: count, progress: progress)
    }

    /// martin-riedl 只在**版本化最终 URL** 旁提供 `<asset>.zip.sha256`（redirect URL 下是 404），
    /// 所以用重定向后的最终地址拼 sidecar，强制校验，取不到即中止。
    private func installFFmpegFromUpstream(
        dest: URL,
        index: Int,
        count: Int,
        progress: (@Sendable (ToolProvisionProgress) -> Void)?
    ) async throws {
        let zipURL = endpoints.ffmpegRedirectBase
            .appendingPathComponent(Self.ffmpegArchPath)
            .appendingPathComponent("release")
            .appendingPathComponent("ffmpeg.zip")
        let tmp = try await downloadVerified(
            tool: "ffmpeg", source: "upstream", url: zipURL,
            expectedSHA: nil, policy: upstreamPolicy,
            index: index, count: count, isRefresh: false, progress: progress,
            expectedSHAProvider: { [weak self] finalURL in
                guard let self, let shaURL = URL(string: finalURL.absoluteString + ".sha256") else { return nil }
                return await self.fetchExpectedSHA(checksumURL: shaURL, assetName: finalURL.lastPathComponent)
            }
        )
        defer { try? fileManager.removeItem(at: tmp) }
        try unpackAndInstall(zip: tmp, name: "ffmpeg", dest: dest, index: index, count: count, progress: progress)
        writeManifest(staticTool: "ffmpeg")
    }

    private func unpackAndInstall(
        zip: URL,
        name: String,
        dest: URL,
        index: Int,
        count: Int,
        progress: (@Sendable (ToolProvisionProgress) -> Void)?
    ) throws {
        progress?(ToolProvisionProgress(
            phase: .installing, tool: name, fractionCompleted: -1, toolIndex: index, toolCount: count
        ))
        let unpackDir = zip.deletingLastPathComponent().appendingPathComponent("unpack-\(name)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: unpackDir) }

        // ditto 稳健处理 macOS zip。
        guard runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, unpackDir.path]) == 0 else {
            throw ToolProvisionError.unpackFailed(tool: name)
        }
        guard let extracted = firstExecutableLikeFile(named: name, in: unpackDir) else {
            throw ToolProvisionError.unpackFailed(tool: name)
        }
        try install(from: extracted, to: dest, tool: name)
    }

    // MARK: - lux（tar.gz 内单个二进制）

    private func provisionLux(to dest: URL, progress: (@Sendable (ToolProvisionProgress) -> Void)?) async throws {
        let tool = "lux"
        let tag = await resolveLuxTag()
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let asset = "lux_\(version)_Darwin_\(Self.luxArchName).tar.gz"
        let base = "https://github.com/iawia002/lux/releases/download/\(tag)"
        guard let url = URL(string: "\(base)/\(asset)"),
              let sumsURL = URL(string: "\(base)/lux_\(version)_checksums.txt") else {
            throw ToolProvisionError.downloadFailed(tool: tool, detail: "bad url")
        }

        // goreleaser 的 checksums.txt 强制校验，取不到即中止。
        let expected = await fetchExpectedSHA(checksumURL: sumsURL, assetName: asset)
        let tgz = try await downloadVerified(
            tool: tool, source: "upstream", url: url, expectedSHA: expected,
            policy: upstreamPolicy, index: 1, count: 1, isRefresh: false, progress: progress
        )
        defer { try? fileManager.removeItem(at: tgz) }

        progress?(ToolProvisionProgress(phase: .installing, tool: tool, fractionCompleted: -1, toolIndex: 1, toolCount: 1))
        let unpackDir = tgz.deletingLastPathComponent().appendingPathComponent("unpack-\(tool)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: unpackDir) }

        // tar.gz 用 tar 解包（ditto -k 只认 zip）。资产根部就是一个 `lux` 可执行。
        guard runProcess("/usr/bin/tar", ["-xzf", tgz.path, "-C", unpackDir.path]) == 0 else {
            throw ToolProvisionError.unpackFailed(tool: tool)
        }
        guard let extracted = firstExecutableLikeFile(named: "lux", in: unpackDir) else {
            throw ToolProvisionError.unpackFailed(tool: tool)
        }
        try install(from: extracted, to: dest, tool: tool)
        writeManifest(luxFetchedAt: Date())
    }

    private func resolveLuxTag() async -> String {
        guard let url = URL(string: "https://api.github.com/repos/iawia002/lux/releases/latest") else {
            return Self.fallbackLuxTag
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let data = try? await fetchSmall(request, wallClock: smallRequestWallClock),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else {
            return Self.fallbackLuxTag
        }
        return tag
    }

    // MARK: - 统一下载 + 校验

    /// 下载 → 进度上报 → SHA256 fail-closed → 返回临时文件。
    /// 成功/失败/取消都写一行 `ToolLogger` 并埋一次点。
    ///
    /// `expectedSHAProvider` 供「校验文件地址依赖重定向后最终 URL」的上游 ffmpeg 使用：
    /// 下载完成拿到 finalURL 后再解析期望哈希（返回 nil 即视为取不到 → fail-closed）。
    private func downloadVerified(
        tool: String,
        source: String,
        url: URL,
        expectedSHA: String?,
        policy: DownloadPolicy,
        index: Int,
        count: Int,
        isRefresh: Bool,
        progress: (@Sendable (ToolProvisionProgress) -> Void)?,
        expectedSHAProvider: (@Sendable (URL) async -> String?)? = nil
    ) async throws -> URL {
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("vowky-tool-\(tool)-\(UUID().uuidString)")
        let startedAt = Date()
        let samples = LatestSampleBox()

        progress?(ToolProvisionProgress(
            phase: .downloading, tool: tool, fractionCompleted: -1,
            toolIndex: index, toolCount: count, isRefresh: isRefresh
        ))

        let outcome: (finalURL: URL, httpStatus: Int)
        do {
            outcome = try await downloader.download(from: url, to: destination, policy: policy) { sample in
                samples.record(sample)
                progress?(ToolProvisionProgress(
                    phase: .downloading,
                    tool: tool,
                    fractionCompleted: sample.totalBytes > 0
                        ? Double(sample.bytesReceived) / Double(sample.totalBytes)
                        : -1,
                    bytesReceived: sample.bytesReceived,
                    totalBytes: sample.totalBytes,
                    bytesPerSecond: sample.bytesPerSecond,
                    toolIndex: index,
                    toolCount: count,
                    isRefresh: isRefresh
                ))
            }
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            report(tool: tool, source: source, url: url, http: 0, sample: samples.latest,
                   startedAt: startedAt, result: "cancel", isRefresh: isRefresh)
            throw CancellationError()
        } catch let error as ProgressDownloadError {
            try? fileManager.removeItem(at: destination)
            let (result, reason) = Self.classify(error)
            report(tool: tool, source: source, url: url, http: Self.httpCode(error), sample: samples.latest,
                   startedAt: startedAt, result: result, isRefresh: isRefresh)
            throw ToolProvisionError.downloadFailed(
                tool: tool, detail: Self.detail(sample: samples.latest, reason: reason)
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            report(tool: tool, source: source, url: url, http: 0, sample: samples.latest,
                   startedAt: startedAt, result: "other", isRefresh: isRefresh)
            throw ToolProvisionError.downloadFailed(
                tool: tool, detail: Self.detail(sample: samples.latest, reason: error.localizedDescription)
            )
        }

        progress?(ToolProvisionProgress(
            phase: .verifying, tool: tool, fractionCompleted: -1,
            toolIndex: index, toolCount: count, isRefresh: isRefresh
        ))
        do {
            try Task.checkCancellation()
        } catch {
            try? fileManager.removeItem(at: destination)
            report(tool: tool, source: source, url: outcome.finalURL, http: outcome.httpStatus,
                   sample: samples.latest, startedAt: startedAt, result: "cancel", isRefresh: isRefresh)
            throw CancellationError()
        }

        let expected: String?
        if let expectedSHAProvider {
            expected = await expectedSHAProvider(outcome.finalURL)
        } else {
            expected = expectedSHA
        }
        guard let expected, expected.count == 64,
              let actual = try? sha256Hex(of: destination),
              actual.caseInsensitiveCompare(expected) == .orderedSame else {
            try? fileManager.removeItem(at: destination)
            report(tool: tool, source: source, url: outcome.finalURL, http: outcome.httpStatus,
                   sample: samples.latest, startedAt: startedAt, result: "checksum", isRefresh: isRefresh)
            throw ToolProvisionError.checksumMismatch(tool: tool)
        }

        report(tool: tool, source: source, url: outcome.finalURL, http: outcome.httpStatus,
               sample: samples.latest, startedAt: startedAt, result: "ok", isRefresh: isRefresh)
        return destination
    }

    private func report(
        tool: String, source: String, url: URL, http: Int,
        sample: DownloadProgressSample?, startedAt: Date, result: String, isRefresh: Bool
    ) {
        let seconds = Date().timeIntervalSince(startedAt)
        let received = sample?.bytesReceived ?? 0
        let total = sample?.totalBytes ?? -1
        let kbPerSecond = seconds > 0 ? Int(Double(received) / seconds / 1024) : 0
        ToolLogger.log(
            "\(tool) source=\(source) url=\(url.absoluteString) http=\(http) "
            + "bytes=\(received)/\(total) "
            + String(format: "secs=%.1f ", seconds)
            + "avg=\(kbPerSecond)KB/s result=\(result)"
        )
        analytics("link_tool_provision", [
            "tool": tool,
            "src": source,
            "ok": result == "ok" ? 1 : 0,
            "refresh": isRefresh ? 1 : 0,
            "secs": Int(seconds),
            "kb_s": kbPerSecond,
            "err": result,
        ])
    }

    private static func classify(_ error: ProgressDownloadError) -> (result: String, reason: String) {
        switch error {
        case .httpStatus(let code):
            return ("http_\(code)", "HTTP \(code)")
        case .tooSlow(let average):
            return ("too_slow", "速度过慢 (\(Int(average / 1024)) KB/s)")
        case .exceededMaxDuration(let seconds):
            return ("max_duration", "超过最长等待时间 (\(Int(seconds)) 秒)")
        case .transport(let code, let description):
            switch code {
            case NSURLErrorTimedOut: return ("timeout", "\(description) (\(code))")
            case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return ("offline", "\(description) (\(code))")
            default: return ("other", "\(description) (\(code))")
            }
        }
    }

    private static func httpCode(_ error: ProgressDownloadError) -> Int {
        if case .httpStatus(let code) = error { return code }
        return 0
    }

    private static func detail(sample: DownloadProgressSample?, reason: String) -> String {
        guard let sample, sample.bytesReceived > 0 else { return reason }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: sample.bytesReceived)
        if sample.totalBytes > 0 {
            return "已下载 \(received) / \(formatter.string(fromByteCount: sample.totalBytes)) · \(reason)"
        }
        return "已下载 \(received) · \(reason)"
    }

    private static func shortDescription(_ error: Error) -> String {
        if let provisionError = error as? ToolProvisionError {
            return provisionError.errorDescription ?? "\(provisionError)"
        }
        return error.localizedDescription
    }

    // MARK: - 小请求（统一墙钟竞速）

    private enum SmallRequestError: Error, CustomStringConvertible {
        case wallClock(TimeInterval)
        case httpStatus(Int)
        case tooLarge(Int)

        var description: String {
            switch self {
            case .wallClock(let seconds): return "超时 (>\(Int(seconds))s)"
            case .httpStatus(let code): return "HTTP \(code)"
            case .tooLarge(let bytes): return "响应过大 (\(bytes) 字节)"
            }
        }

        var localizedDescription: String { description }
    }

    private func fetchSmall(_ url: URL, wallClock: TimeInterval, maxBytes: Int = 2 * 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await fetchSmall(request, wallClock: wallClock, maxBytes: maxBytes)
    }

    /// 让 `session.data(for:)` 与 `Task.sleep(wallClock)` 竞速：先到者胜、另一方取消。
    /// **本文件所有 `session.data` 调用都必须经由这里**，否则涓流响应可以把小请求拖到分钟级。
    private func fetchSmall(
        _ request: URLRequest, wallClock: TimeInterval, maxBytes: Int = 2 * 1024 * 1024
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            let session = self.session
            group.addTask {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw SmallRequestError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard data.count <= maxBytes else {
                    throw SmallRequestError.tooLarge(data.count)
                }
                return data
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, wallClock) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw SmallRequestError.wallClock(wallClock)
            }
            guard let data = first else {
                try Task.checkCancellation()
                throw SmallRequestError.wallClock(wallClock)
            }
            return data
        }
    }

    /// 下载并解析校验文件，返回目标资产的期望 SHA256。
    /// 兼容两种格式：`<sha256>  <文件名>` 多行（yt-dlp SUMS / goreleaser checksums.txt），
    /// 以及整个文件只有一个 64 位十六进制 token 的单哈希 sidecar（martin-riedl 的 `<asset>.sha256`）。
    private func fetchExpectedSHA(checksumURL: URL, assetName: String) async -> String? {
        guard let data = try? await fetchSmall(checksumURL, wallClock: smallRequestWallClock),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, String(parts.last!) == assetName {
                return String(parts[0])
            }
        }
        if lines.count == 1 {
            let parts = lines[0].split(whereSeparator: \.isWhitespace)
            if let first = parts.first, first.count == 64 {
                return String(first)
            }
        }
        return nil
    }

    // MARK: - 目录

    private func binDirectoryURL() throws -> URL {
        if let binDirOverride { return binDirOverride }
        let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: false)
        return appSupport.appendingPathComponent("VowKy/bin", isDirectory: true)
    }

    private func ensureBinDir() throws -> URL {
        let dir = try binDirectoryURL()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isInstalled(_ url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

    // MARK: - 安装 / 工具方法

    /// 落位：复制到目标 → chmod 0755 → 确认签名有效（无效则 ad-hoc 重签，满足 Apple Silicon AMFI）。
    ///
    /// 安全不变量：**调用方必须先对下载内容做强制 SHA256 校验再调用本方法**（各 provision 路径均已 fail-closed）。
    /// 信任判定完全由校验承担；这里的 ad-hoc 重签只是让「内容已验证但签名在复制后失效」的二进制可执行，
    /// 不构成信任放行。
    private func install(from source: URL, to dest: URL, tool: String) throws {
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: source, to: dest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        if runProcess("/usr/bin/codesign", ["--verify", "--quiet", dest.path]) != 0 {
            _ = runProcess("/usr/bin/codesign", ["--force", "--sign", "-", dest.path])
        }
        guard isInstalled(dest) else {
            throw ToolProvisionError.notExecutable(tool: tool)
        }
    }

    /// 找到解包目录里那个真正的可执行（martin-riedl zip 里通常就是根部一个同名文件）。
    private func firstExecutableLikeFile(named name: String, in dir: URL) -> URL? {
        let direct = dir.appendingPathComponent(name)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    private func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 120) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }
        do {
            try proc.run()
        } catch {
            return -1
        }
        // 有界等待：卡死的子进程不再永久阻塞整个 actor（先 SIGTERM，2 秒不退再 SIGKILL）。
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 5)
            }
            return -1
        }
        return proc.terminationStatus
    }

    // MARK: - manifest（记录版本与检查时间，用于过期判断）

    private struct Manifest: Codable {
        var ytDlpTag: String?
        var ytDlpFetchedAt: Date?
        /// 上一次「成功查到上游最新版且本机不低于它」的时间。
        var ytDlpVersionCheckedAt: Date?
        /// 上一次「查询/刷新失败」的时间，用于 24 h 退避。
        var ytDlpRefreshCheckedAt: Date?
        var ffmpegFetchedAt: Date?
        /// 已不再下载 ffprobe；字段保留只为兼容旧 manifest.json（老机器上的 ffprobe 文件也不删）。
        var ffprobeFetchedAt: Date?
        var luxFetchedAt: Date?
        var arch: String?
    }

    private func manifestURL() -> URL? {
        try? binDirectoryURL().appendingPathComponent("manifest.json")
    }

    private func readManifest() -> Manifest {
        guard let url = manifestURL(),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder.toolManifest.decode(Manifest.self, from: data) else {
            return Manifest()
        }
        return manifest
    }

    /// 双层可选：`nil` = 不改动该字段，`.some(nil)` = 显式清空。
    private func writeManifest(
        ytDlpFetchedAt: Date?? = nil,
        ytDlpTag: String? = nil,
        ytDlpVersionCheckedAt: Date?? = nil,
        ytDlpRefreshCheckedAt: Date?? = nil,
        staticTool: String? = nil,
        luxFetchedAt: Date? = nil
    ) {
        guard let url = manifestURL() else { return }
        var manifest = readManifest()
        if case let .some(value) = ytDlpFetchedAt { manifest.ytDlpFetchedAt = value }
        if let ytDlpTag { manifest.ytDlpTag = ytDlpTag }
        if case let .some(value) = ytDlpVersionCheckedAt { manifest.ytDlpVersionCheckedAt = value }
        if case let .some(value) = ytDlpRefreshCheckedAt { manifest.ytDlpRefreshCheckedAt = value }
        if staticTool == "ffmpeg" { manifest.ffmpegFetchedAt = Date() }
        if let luxFetchedAt { manifest.luxFetchedAt = luxFetchedAt }
        manifest.arch = Self.ffmpegArchPath
        if let data = try? JSONEncoder.toolManifest.encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 过期 = 「没有 7 天内的版本确认」且「不在 24 h 失败退避窗口内」。
    private func isYtDlpStale() -> Bool {
        let manifest = readManifest()
        let now = Date()
        let versionFresh = manifest.ytDlpVersionCheckedAt
            .map { now.timeIntervalSince($0) <= Self.ytDlpVersionValidity } ?? false
        let backoffActive = manifest.ytDlpRefreshCheckedAt
            .map { now.timeIntervalSince($0) <= Self.ytDlpRefreshBackoff } ?? false
        return !versionFresh && !backoffActive
    }
}

/// 下载回调来自 URLSession 的 delegate 队列，用一把锁存最后一个样本供日志/错误详情使用。
private final class LatestSampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: DownloadProgressSample?

    func record(_ sample: DownloadProgressSample) {
        lock.lock()
        self.sample = sample
        lock.unlock()
    }

    var latest: DownloadProgressSample? {
        lock.lock()
        defer { lock.unlock() }
        return sample
    }
}

private extension JSONDecoder {
    static let toolManifest: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

private extension JSONEncoder {
    static let toolManifest: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}
