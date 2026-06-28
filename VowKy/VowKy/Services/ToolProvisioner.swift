import Foundation
import CryptoKit

/// 「从链接转文字」功能依赖两个外部二进制：`yt-dlp`（下载/解析视频）与 `ffmpeg`/`ffprobe`（抽音频、合成 HLS）。
/// 它们**不打包进 .app**（PyInstaller 的 yt-dlp 在 hardened runtime 下签名/公证极易出问题，且 yt-dlp 随 YouTube 改版很快过时），
/// 而是**首次用到该功能时联网下载**到 `~/Library/Application Support/VowKy/bin/`，之后缓存复用。
///
/// 该功能本质就是在线的（要下载网络视频），所以「首次联网取工具」不额外牺牲 VowKy 的「核心听写全离线」定位。
///
/// 设计要点（均已在 2026-06-28 真机验证）：
/// - yt-dlp：`yt-dlp_macos`（GitHub release，universal2，ad-hoc 签名，Apple Silicon 可直接执行）。按 release 自带的
///   `SHA2-256SUMS` 校验，无需在代码里硬编码哈希；解析最新 tag，过期(>7天)best-effort 刷新（失败则继续用旧的）。
/// - ffmpeg/ffprobe：martin-riedl.de 的 **原生 arch** 静态构建（Developer-ID 签名 + hardened runtime，可直接执行）。
///   只下当前架构，省一半体积。
/// - App 未沙盒（project.yml `ENABLE_APP_SANDBOX: NO`）+ URLSession 自写文件不带 `com.apple.quarantine`，
///   故下载的二进制无 Gatekeeper 拦截、无需公证即可作为子进程执行。
enum ToolProvisionError: LocalizedError, Equatable {
    case downloadFailed(tool: String)
    case checksumMismatch(tool: String)
    case unpackFailed(tool: String)
    case notExecutable(tool: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let tool):    return LL("file.tool.error.download", tool)
        case .checksumMismatch(let tool):  return LL("file.tool.error.checksum", tool)
        case .unpackFailed(let tool):      return LL("file.tool.error.unpack", tool)
        case .notExecutable(let tool):     return LL("file.tool.error.notExecutable", tool)
        }
    }
}

/// 工具下载/安装进度（首次配置时驱动一个轻量提示）。
struct ToolProvisionProgress: Sendable {
    enum Phase: Sendable { case checking, downloading, verifying, installing, ready }
    let phase: Phase
    let tool: String
    /// 0...1；-1 表示不定态。
    let fractionCompleted: Double
}

/// 已就绪的工具绝对路径。
struct ProvisionedTools: Sendable {
    let binDir: URL
    let ytDlp: URL
    let ffmpeg: URL
    let ffprobe: URL
}

/// 串行化的工具准备器：多个下载任务并发调用 `ensureTools()` 时，actor 天然避免重复下载/竞态。
actor ToolProvisioner {
    static let shared = ToolProvisioner()

    private let fileManager = FileManager.default
    private let session: URLSession

    // 当前运行架构对应的 ffmpeg 构建（universal 主 app 在各自 slice 上编译，`#if arch` 即反映运行架构）。
    #if arch(arm64)
    private static let ffmpegArchPath = "arm64"
    #else
    private static let ffmpegArchPath = "amd64"
    #endif

    private static let ffmpegZipURL = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(ffmpegArchPath)/release/ffmpeg.zip")!
    private static let ffprobeZipURL = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(ffmpegArchPath)/release/ffprobe.zip")!

    /// 取不到「最新 tag」时的兜底（2026-06-28 验证可用）。
    private static let fallbackYtDlpTag = "2026.06.09"
    private static let ytDlpRefreshInterval: TimeInterval = 7 * 24 * 3600

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - 公开 API

    /// 确保 yt-dlp / ffmpeg / ffprobe 都已就绪，返回它们的绝对路径。缺失则下载；yt-dlp 过期则尽力刷新。
    func ensureTools(progress: (@Sendable (ToolProvisionProgress) -> Void)? = nil) async throws -> ProvisionedTools {
        let binDir = try ensureBinDir()
        let ytDlp = binDir.appendingPathComponent("yt-dlp")
        let ffmpeg = binDir.appendingPathComponent("ffmpeg")
        let ffprobe = binDir.appendingPathComponent("ffprobe")

        progress?(ToolProvisionProgress(phase: .checking, tool: "yt-dlp", fractionCompleted: -1))

        if !isInstalled(ytDlp) {
            try await provisionYtDlp(to: ytDlp, progress: progress)
        } else if isYtDlpStale() {
            // 已装但过期：best-effort 刷新；网络不行就继续用旧的，绝不因刷新失败阻断功能。
            try? await provisionYtDlp(to: ytDlp, progress: progress)
        }

        if !isInstalled(ffmpeg) {
            try await provisionStaticTool(name: "ffmpeg", zipURL: Self.ffmpegZipURL, dest: ffmpeg, progress: progress)
        }
        if !isInstalled(ffprobe) {
            try await provisionStaticTool(name: "ffprobe", zipURL: Self.ffprobeZipURL, dest: ffprobe, progress: progress)
        }

        progress?(ToolProvisionProgress(phase: .ready, tool: "", fractionCompleted: 1))
        return ProvisionedTools(binDir: binDir, ytDlp: ytDlp, ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    /// 工具是否已全部就绪（用于「首次告知弹窗」判断要不要联网）。
    func toolsAlreadyInstalled() -> Bool {
        guard let binDir = try? binDirectoryURL() else { return false }
        return isInstalled(binDir.appendingPathComponent("yt-dlp"))
            && isInstalled(binDir.appendingPathComponent("ffmpeg"))
            && isInstalled(binDir.appendingPathComponent("ffprobe"))
    }

    /// 让下次 `ensureTools()` 强制重下 yt-dlp（供 URLDownloadService 在疑似 yt-dlp 过时失败后重试一次）。
    func invalidateYtDlp() {
        guard let binDir = try? binDirectoryURL() else { return }
        try? fileManager.removeItem(at: binDir.appendingPathComponent("yt-dlp"))
        writeManifest(ytDlpFetchedAt: nil)
    }

    // MARK: - 目录

    private func binDirectoryURL() throws -> URL {
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

    // MARK: - yt-dlp

    private func provisionYtDlp(to dest: URL, progress: (@Sendable (ToolProvisionProgress) -> Void)?) async throws {
        let tool = "yt-dlp"
        let tag = await resolveYtDlpTag()
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)"
        guard let binURL = URL(string: "\(base)/yt-dlp_macos"),
              let sumsURL = URL(string: "\(base)/SHA2-256SUMS") else {
            throw ToolProvisionError.downloadFailed(tool: tool)
        }

        progress?(ToolProvisionProgress(phase: .downloading, tool: tool, fractionCompleted: -1))
        let tmp = try await downloadToTemp(from: binURL, tool: tool)
        defer { try? fileManager.removeItem(at: tmp) }

        // 用 release 自带的 SHA2-256SUMS 校验，无需硬编码哈希。
        progress?(ToolProvisionProgress(phase: .verifying, tool: tool, fractionCompleted: -1))
        if let expected = await expectedYtDlpSHA(from: sumsURL) {
            let actual = try sha256Hex(of: tmp)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw ToolProvisionError.checksumMismatch(tool: tool)
            }
        }

        progress?(ToolProvisionProgress(phase: .installing, tool: tool, fractionCompleted: -1))
        try install(from: tmp, to: dest, tool: tool)
        writeManifest(ytDlpFetchedAt: Date(), ytDlpTag: tag)
    }

    /// 取最新 release tag；网络/解析失败回退到内置兜底 tag。
    private func resolveYtDlpTag() async -> String {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else {
            return Self.fallbackYtDlpTag
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else {
            return Self.fallbackYtDlpTag
        }
        return tag
    }

    private func expectedYtDlpSHA(from sumsURL: URL) async -> String? {
        guard let (data, response) = try? await session.data(from: sumsURL),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        // 每行形如「<sha256>  yt-dlp_macos」。
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[1] == "yt-dlp_macos" {
                return String(parts[0])
            }
        }
        return nil
    }

    // MARK: - ffmpeg / ffprobe（zip 内单个二进制）

    private func provisionStaticTool(
        name: String,
        zipURL: URL,
        dest: URL,
        progress: (@Sendable (ToolProvisionProgress) -> Void)?
    ) async throws {
        progress?(ToolProvisionProgress(phase: .downloading, tool: name, fractionCompleted: -1))
        let zipTmp = try await downloadToTemp(from: zipURL, tool: name)
        defer { try? fileManager.removeItem(at: zipTmp) }

        progress?(ToolProvisionProgress(phase: .installing, tool: name, fractionCompleted: -1))
        let unpackDir = zipTmp.deletingLastPathComponent().appendingPathComponent("unpack-\(name)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: unpackDir) }

        // ditto 稳健处理 macOS zip。
        guard runProcess("/usr/bin/ditto", ["-x", "-k", zipTmp.path, unpackDir.path]) == 0 else {
            throw ToolProvisionError.unpackFailed(tool: name)
        }
        guard let extracted = firstExecutableLikeFile(named: name, in: unpackDir) else {
            throw ToolProvisionError.unpackFailed(tool: name)
        }
        try install(from: extracted, to: dest, tool: name)
        writeManifest(staticTool: name)
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

    // MARK: - 安装 / 校验 / 工具方法

    /// 落位：复制到目标 → chmod 0755 → 确认签名有效（无效则 ad-hoc 重签，满足 Apple Silicon AMFI）。
    private func install(from source: URL, to dest: URL, tool: String) throws {
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: source, to: dest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        // 下载的二进制本身有签名（yt-dlp=ad-hoc、ffmpeg=Developer-ID）。复制后若校验失败，ad-hoc 重签让其可执行。
        if runProcess("/usr/bin/codesign", ["--verify", "--quiet", dest.path]) != 0 {
            _ = runProcess("/usr/bin/codesign", ["--force", "--sign", "-", dest.path])
        }
        guard isInstalled(dest) else {
            throw ToolProvisionError.notExecutable(tool: tool)
        }
    }

    /// 流式下载到临时文件（URLSession 自写文件不带 quarantine）。
    private func downloadToTemp(from url: URL, tool: String) async throws -> URL {
        do {
            let (tempURL, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? fileManager.removeItem(at: tempURL)
                throw ToolProvisionError.downloadFailed(tool: tool)
            }
            // download() 的临时文件返回后即可能被清理，立刻搬到我们自己的临时位置。
            let dest = fileManager.temporaryDirectory
                .appendingPathComponent("vowky-tool-\(tool)-\(UUID().uuidString)")
            if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
            try fileManager.moveItem(at: tempURL, to: dest)
            return dest
        } catch let error as ToolProvisionError {
            throw error
        } catch {
            throw ToolProvisionError.downloadFailed(tool: tool)
        }
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
    private func runProcess(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: - manifest（记录刷新时间，用于过期判断）

    private struct Manifest: Codable {
        var ytDlpTag: String?
        var ytDlpFetchedAt: Date?
        var ffmpegFetchedAt: Date?
        var ffprobeFetchedAt: Date?
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

    private func writeManifest(ytDlpFetchedAt: Date?? = nil, ytDlpTag: String? = nil, staticTool: String? = nil) {
        guard let url = manifestURL() else { return }
        var manifest = readManifest()
        if case let .some(value) = ytDlpFetchedAt { manifest.ytDlpFetchedAt = value }
        if let tag = ytDlpTag { manifest.ytDlpTag = tag }
        if staticTool == "ffmpeg" { manifest.ffmpegFetchedAt = Date() }
        if staticTool == "ffprobe" { manifest.ffprobeFetchedAt = Date() }
        manifest.arch = Self.ffmpegArchPath
        if let data = try? JSONEncoder.toolManifest.encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func isYtDlpStale() -> Bool {
        guard let fetchedAt = readManifest().ytDlpFetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > Self.ytDlpRefreshInterval
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
