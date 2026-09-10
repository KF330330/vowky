import Foundation
import XCTest
@testable import VowKy

/// 频道 / 播放列表拒收（前置校验 + yt-dlp 输出兜底）与 `run()` 的中止判据。
/// 全程不联网、不 spawn yt-dlp：只用临时 shell 脚本验证进程控制逻辑。
final class URLDownloadServiceTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func setUp() {
        super.setUp()
        ToolStubURLProtocol.reset()
        // 绝不写用户真实 tools.log。
        ToolLogger.overrideLogURL = makeTempDir().appendingPathComponent("tools.log")
    }

    override func tearDown() {
        ToolLogger.overrideLogURL = nil
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VowKyURLDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// 写一个可执行的临时脚本，返回其路径。
    private func makeScript(_ body: String) throws -> URL {
        let dir = makeTempDir()
        let script = dir.appendingPathComponent("script.sh")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// provisioner：指向给定 binDir + Stub session，任何真网请求都不可能发生。
    private func makeProvisioner(binDir: URL) -> ToolProvisioner {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolStubURLProtocol.self]
        let endpoints = ToolEndpoints(
            mirrorBase: URL(string: "https://mirror.test/tools/")!,
            ytDlpLatestAPI: URL(string: "https://api.test/latest")!,
            ytDlpReleaseBase: URL(string: "https://gh.test/download/")!,
            ffmpegRedirectBase: URL(string: "https://mr.test/redirect/latest/macos/")!,
            denoReleaseBase: URL(string: "https://gh-deno.test/download/")!,
            manifestPublicKey: nil
        )
        return ToolProvisioner(
            binDirOverride: binDir,
            sessionConfiguration: config,
            endpoints: endpoints
        )
    }

    /// 完全离线的服务实例：provisioner 指向空的临时 binDir + Stub session。
    private func makeOfflineService() -> URLDownloadService {
        URLDownloadService(provisioner: makeProvisioner(binDir: makeTempDir()))
    }

    private func writeExecutable(_ body: String, to url: URL) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// 三工具齐备 + 新鲜 manifest 的服务：`ensureTools` 走快路径、零网络（每例末尾断言 requestLog 为空）。
    /// yt-dlp 换成传入脚本，每次调用把参数追加到 `binDir/calls.log`（一行一次调用）。
    private func makeReadyService(ytDlpScript: String) throws -> (service: URLDownloadService, binDir: URL) {
        let binDir = makeTempDir()
        try writeExecutable(ytDlpScript, to: binDir.appendingPathComponent("yt-dlp"))
        try writeExecutable("#!/bin/sh\nexit 0\n", to: binDir.appendingPathComponent("ffmpeg"))
        try writeExecutable("#!/bin/sh\nexit 0\n", to: binDir.appendingPathComponent("deno"))
        let now = Date().timeIntervalSince1970
        let manifest: [String: Any] = [
            "ytDlpTag": "2026.08.19",
            "ytDlpFetchedAt": now,
            "ytDlpVersionCheckedAt": now,
            "ffmpegFetchedAt": now,
            "denoTag": "v2.9.6",
            "denoFetchedAt": now
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: binDir.appendingPathComponent("manifest.json"))
        return (URLDownloadService(provisioner: makeProvisioner(binDir: binDir)), binDir)
    }

    /// yt-dlp 脚本记录下来的调用（一行一次）。
    private func callLines(_ binDir: URL) -> [String] {
        let raw = (try? String(contentsOf: binDir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return raw.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    private func toolsLogText() -> String {
        guard let url = ToolLogger.overrideLogURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 「无 cookie 即机器人验证」：带 cookie 时取标题回 Fake Title、下载写出 media.m4a。
    private static let botCheckScriptA = #"""
    #!/bin/bash
    echo "$*" >> "$(dirname "$0")/calls.log"
    if [[ " $* " == *" --cookies-from-browser "* ]]; then
      if [[ " $* " == *" --print "* ]]; then
        echo "Fake Title"
        exit 0
      fi
      prev=""
      for a in "$@"; do
        if [[ "$prev" == "-o" ]]; then : > "$(dirname "$a")/media.m4a"; fi
        prev="$a"
      done
      exit 0
    fi
    echo "ERROR: [youtube] fDQaadKysSA: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication." >&2
    exit 1
    """#

    /// 「探针成功、抓字幕才验证」：带 cookie 抓字幕才写出 zh-TW 人工字幕；一旦启动音频下载（-x）即失败。
    private static let botCheckScriptB = #"""
    #!/bin/bash
    echo "$*" >> "$(dirname "$0")/calls.log"
    if [[ " $* " == *" --print "* ]]; then
      echo 'Fake Title@@VOWKYF@@zh-TW@@VOWKYF@@{"zh-TW":[{"ext":"vtt"}]}@@VOWKYF@@{}'
      exit 0
    fi
    if [[ " $* " == *" -x "* ]]; then
      echo "unexpected audio download" >&2
      exit 9
    fi
    if [[ " $* " == *" --write-subs "* ]]; then
      if [[ " $* " == *" --cookies-from-browser "* ]]; then
        prev=""
        for a in "$@"; do
          if [[ "$prev" == "-o" ]]; then
            printf 'WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nHello subtitle\n' > "$(dirname "$a")/sub.zh-TW.vtt"
          fi
          prev="$a"
        done
        exit 0
      fi
      echo "ERROR: [youtube] fDQaadKysSA: Sign in to confirm you’re not a bot." >&2
      exit 1
    fi
    exit 0
    """#

    /// 「永远验证」：任何调用都报机器人验证。
    private static let botCheckScriptC = #"""
    #!/bin/bash
    echo "$*" >> "$(dirname "$0")/calls.log"
    echo "ERROR: [youtube] fDQaadKysSA: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication." >&2
    exit 1
    """#

    // MARK: 1) 拒收 / 放行表

    func test_rejectionReason_table() {
        let rejected = [
            "https://www.youtube.com/@HungyiLeeNTU/videos",
            "https://www.youtube.com/@HungyiLeeNTU",
            "https://youtube.com/channel/UCxxx",
            "https://www.youtube.com/c/Name",
            "https://www.youtube.com/user/Name",
            "https://www.youtube.com/playlist?list=PLxxx",
            "https://www.youtube.com/feed/subscriptions",
            "https://www.youtube.com/results?search_query=x",
            "https://space.bilibili.com/123",
            "https://www.bilibili.com/list/ml123",
            "https://www.bilibili.com/festival/bh3-7th",
        ]
        for urlString in rejected {
            XCTAssertEqual(
                URLDownloadService.rejectionReason(for: urlString),
                URLDownloadError.playlistNotSupported,
                "应拒收: \(urlString)"
            )
        }

        let allowed = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLx",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube.com/shorts/abc",
            "https://www.youtube.com/live/abc",
            "https://www.bilibili.com/video/BV1uioXYEE9F?p=2",
            "https://www.bilibili.com/festival/bh3-7th?bvid=BV1tr4y1f7p2",
            "https://b23.tv/abc",
            "https://learn.deeplearning.ai/courses/x",
        ]
        for urlString in allowed {
            XCTAssertNil(
                URLDownloadService.rejectionReason(for: urlString),
                "应放行: \(urlString)"
            )
        }
    }

    // MARK: 2) 平台识别新增分支

    func test_platform_liveAndFestival() {
        XCTAssertEqual(URLDownloadService.platform(for: "https://www.youtube.com/live/abc"), .youtube)
        XCTAssertEqual(
            URLDownloadService.platform(for: "https://www.bilibili.com/festival/bh3-7th?bvid=BV1tr4y1f7p2"),
            .bilibili
        )
    }

    // MARK: 3) 命中中止行立即掐掉进程

    func test_run_abortsOnPlaylistLine() async throws {
        let script = try makeScript("#!/bin/bash\necho \"[download] Downloading playlist: X\"\nsleep 30\n")
        let service = makeOfflineService()

        let startedAt = Date()
        let result = try await service.run(
            executable: script,
            arguments: [],
            abortIfLine: URLDownloadService.isPlaylistLine
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result.abort, .matchedLine)
        XCTAssertLessThan(elapsed, 3, "命中频道行应立刻中止，实际耗时 \(elapsed)s")
    }

    // MARK: 4) 墙钟上限

    func test_run_wallClockLimit() async throws {
        let script = try makeScript("#!/bin/bash\nsleep 30\n")
        let service = makeOfflineService()

        let startedAt = Date()
        let result = try await service.run(
            executable: script,
            arguments: [],
            wallClockLimit: 1
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result.abort, .wallClock)
        XCTAssertLessThan(elapsed, 4, "墙钟到点应中止，实际耗时 \(elapsed)s")
    }

    // MARK: 5) 频道链接在任何联网动作之前就被拒

    func test_download_rejectsPlaylistBeforeAnyWork() async throws {
        ToolStubURLProtocol.reset()
        let service = makeOfflineService()
        let workDir = makeTempDir()

        do {
            _ = try await service.download(
                urlString: "https://www.youtube.com/@x/videos",
                into: workDir,
                cookies: .none,
                subtitlePriority: .all,
                progress: { _ in }
            )
            XCTFail("频道链接应被拒收")
        } catch {
            XCTAssertEqual(error as? URLDownloadError, .playlistNotSupported)
        }

        XCTAssertTrue(
            ToolStubURLProtocol.requestLog.isEmpty,
            "拒收必须发生在任何网络动作之前: \(ToolStubURLProtocol.requestLog)"
        )
    }

    // MARK: 6) 机器人验证判定 / 探针限额 / cookie 显示名

    func test_mapError_botCheckPatterns() {
        XCTAssertEqual(
            URLDownloadService.mapError(
                stdout: "",
                stderr: "ERROR: [youtube] x: Sign in to confirm you're not a bot. Use --cookies-from-browser."),
            .botCheck(cookieLabel: nil))
        // YouTube 真实文案是弯撇号 U+2019，必须同样命中（只认 ASCII \' 会让升级重试永不触发）。
        let curly = "ERROR: [youtube] fDQaadKysSA: Sign in to confirm you\u{2019}re not a bot. "
            + "Use --cookies-from-browser or --cookies for the authentication."
        XCTAssertEqual(URLDownloadService.mapError(stdout: "", stderr: curly), .botCheck(cookieLabel: nil))
        XCTAssertTrue(URLDownloadService.isBotCheck(stdout: "", stderr: curly))
        XCTAssertEqual(
            URLDownloadService.mapError(stdout: "ERROR: The page needs to be reloaded", stderr: ""),
            .botCheck(cookieLabel: nil))
        // 年龄/私有/会员仍走 authRequired，不受影响。
        XCTAssertEqual(
            URLDownloadService.mapError(stdout: "", stderr: "ERROR: Sign in to confirm your age"),
            .authenticationRequired)
        XCTAssertTrue(URLDownloadService.isBotCheck(stdout: "", stderr: "Sign In To Confirm You're Not A Bot"))
        XCTAssertFalse(URLDownloadService.isBotCheck(stdout: "hello world", stderr: "ERROR: HTTP Error 404"))
    }

    func test_probeLimits() {
        let bare = URLDownloadService.probeLimits(cookiesInUse: false)
        XCTAssertTrue(bare.isTitlePass)
        XCTAssertEqual(bare.wallClock, 90)
        XCTAssertEqual(bare.wallClock, URLDownloadService.titlePassWallClock)
        let withCookies = URLDownloadService.probeLimits(cookiesInUse: true)
        XCTAssertFalse(withCookies.isTitlePass)
        XCTAssertEqual(withCookies.wallClock, 180)
        XCTAssertEqual(withCookies.wallClock, URLDownloadService.cookieProbeWallClock)
    }

    func test_cookieSource_displayLabel() {
        XCTAssertEqual(CookieSource.browser("chrome").displayLabel, "Chrome")
        XCTAssertEqual(CookieSource.browser("safari").displayLabel, "Safari")
        XCTAssertEqual(CookieSource.cookiesFile(URL(fileURLWithPath: "/tmp/c.txt")).displayLabel, "cookies.txt")
        XCTAssertEqual(CookieSource.none.displayLabel, "")
    }

    func test_run_setsDenoNoUpdateCheck() async throws {
        let script = try makeScript("#!/bin/bash\necho \"$DENO_NO_UPDATE_CHECK\"\n")
        let service = makeOfflineService()
        let result = try await service.run(executable: script, arguments: [])
        XCTAssertEqual(result.exit, 0)
        XCTAssertEqual(result.stdout.split(whereSeparator: \.isNewline).first.map(String.init), "1")
    }

    // MARK: 7) YouTube cookie 升级重试

    private static let botURL = "https://www.youtube.com/watch?v=fDQaadKysSA"

    /// 未配置 cookie：第一次探针就报机器人验证，立即报错（不再徒劳跑取标题/下载）。
    func test_youtubeBotCheck_noCookies_failsFastWithGuidance() async throws {
        let (service, binDir) = try makeReadyService(ytDlpScript: Self.botCheckScriptA)
        let workDir = makeTempDir()
        do {
            _ = try await service.download(
                urlString: Self.botURL, into: workDir,
                cookies: .none, subtitlePriority: .all, progress: { _ in })
            XCTFail("未配置 cookie 应直接报机器人验证")
        } catch {
            XCTAssertEqual(error as? URLDownloadError, .botCheck(cookieLabel: nil))
        }
        let lines = callLines(binDir)
        XCTAssertEqual(lines.count, 1, "应止于第一次探针: \(lines)")
        XCTAssertTrue(
            lines[0].contains("--js-runtimes deno:\(binDir.appendingPathComponent("deno").path)"),
            "缺 JS 运行时参数: \(lines[0])")
        XCTAssertFalse(lines[0].contains("--cookies-from-browser"))
        XCTAssertTrue(toolsLogText().contains("未配置 cookie，报错"), toolsLogText())
        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "\(ToolStubURLProtocol.requestLog)")
    }

    /// 已配置 cookie：升级一次后，本任务后续所有调用都带 cookie。
    func test_youtubeBotCheck_escalatesOnce_thenDownloads() async throws {
        let (service, binDir) = try makeReadyService(ytDlpScript: Self.botCheckScriptA)
        let workDir = makeTempDir()
        let result = try await service.download(
            urlString: Self.botURL, into: workDir,
            cookies: .browser("chrome"), subtitlePriority: .never, progress: { _ in })
        guard case .media(let media) = result else { return XCTFail("应返回 .media") }
        XCTAssertEqual(media.rawTitle, "Fake Title")
        let lines = callLines(binDir)
        XCTAssertEqual(lines.count, 3, "取标题 + 带 cookie 重试取标题 + 下载: \(lines)")
        XCTAssertFalse(lines[0].contains("--cookies-from-browser"))
        XCTAssertTrue(lines[1].contains("--cookies-from-browser chrome"), lines[1])
        XCTAssertTrue(lines[2].contains("--cookies-from-browser chrome"), lines[2])
        for line in lines {
            XCTAssertTrue(line.contains("--js-runtimes deno:"), "缺 JS 运行时参数: \(line)")
        }
        XCTAssertTrue(toolsLogText().contains("YouTube 机器人验证 → 带 Chrome cookie 重试"), toolsLogText())
        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "\(ToolStubURLProtocol.requestLog)")
    }

    /// 带 cookie 仍被验证：报错文案带上浏览器名，且只重试一次。
    func test_youtubeBotCheck_cookiesStillFail_reportsLabel() async throws {
        let (service, binDir) = try makeReadyService(ytDlpScript: Self.botCheckScriptC)
        let workDir = makeTempDir()
        do {
            _ = try await service.download(
                urlString: Self.botURL, into: workDir,
                cookies: .browser("chrome"), subtitlePriority: .all, progress: { _ in })
            XCTFail("带 cookie 仍验证应报错")
        } catch {
            XCTAssertEqual(error as? URLDownloadError, .botCheck(cookieLabel: "Chrome"))
            XCTAssertEqual((error as? URLDownloadError)?.errorDescription?.contains("Chrome"), true)
        }
        XCTAssertEqual(callLines(binDir).count, 2, "探针 + 带 cookie 重试探针: \(callLines(binDir))")
        // 升级一行 + 最终放弃一行，两条都要在。
        XCTAssertTrue(toolsLogText().contains("YouTube 机器人验证 → 带 Chrome cookie 重试"), toolsLogText())
        XCTAssertTrue(toolsLogText().contains("带 Chrome cookie 仍失败"), toolsLogText())
        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "\(ToolStubURLProtocol.requestLog)")
    }

    /// 探针成功、抓字幕才被验证：带 cookie 重跑整个字幕流程，拿回人工字幕，绝不退到音频下载。
    func test_youtubeBotCheck_subtitleFetchEscalates_getsManualSubtitle() async throws {
        let (service, binDir) = try makeReadyService(ytDlpScript: Self.botCheckScriptB)
        let workDir = makeTempDir()
        let result = try await service.download(
            urlString: Self.botURL, into: workDir,
            cookies: .browser("chrome"), subtitlePriority: .all, progress: { _ in })
        guard case .transcript(let text, let source, let title) = result else {
            return XCTFail("应直接拿到人工字幕")
        }
        XCTAssertEqual(text, "Hello subtitle")
        XCTAssertEqual(source, .manualSubtitle(language: "zh-TW"))
        XCTAssertEqual(title, "Fake Title")
        let lines = callLines(binDir)
        XCTAssertEqual(lines.count, 4, "探针+抓字幕 各两轮: \(lines)")
        for line in lines {
            XCTAssertFalse(line.contains(" -x "), "不该启动音频下载: \(line)")
            XCTAssertFalse(line.contains("--audio-format"), "不该启动音频下载: \(line)")
        }
        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "\(ToolStubURLProtocol.requestLog)")
    }

    /// 「总是本地转写」+ 未配置 cookie：取标题即报错，不进下载。
    func test_youtubeBotCheck_neverPriority_noCookies_stopsAtTitle() async throws {
        let (service, binDir) = try makeReadyService(ytDlpScript: Self.botCheckScriptA)
        let workDir = makeTempDir()
        do {
            _ = try await service.download(
                urlString: Self.botURL, into: workDir,
                cookies: .none, subtitlePriority: .never, progress: { _ in })
            XCTFail("未配置 cookie 应直接报机器人验证")
        } catch {
            XCTAssertEqual(error as? URLDownloadError, .botCheck(cookieLabel: nil))
        }
        XCTAssertEqual(callLines(binDir).count, 1, "取标题即止: \(callLines(binDir))")
        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "\(ToolStubURLProtocol.requestLog)")
    }

    /// 「总是本地转写」+ 带 cookie 仍验证：重试一次后报错，不进下载。
    func test_youtubeBotCheck_neverPriority_cookiesStillFail_stopsAfterRetry() async throws {
        let (service, binDir) = try makeReadyService(ytDlpScript: Self.botCheckScriptC)
        let workDir = makeTempDir()
        do {
            _ = try await service.download(
                urlString: Self.botURL, into: workDir,
                cookies: .browser("chrome"), subtitlePriority: .never, progress: { _ in })
            XCTFail("带 cookie 仍验证应报错")
        } catch {
            XCTAssertEqual(error as? URLDownloadError, .botCheck(cookieLabel: "Chrome"))
        }
        XCTAssertEqual(callLines(binDir).count, 2, "取标题 + 带 cookie 重试取标题: \(callLines(binDir))")
        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "\(ToolStubURLProtocol.requestLog)")
    }

    /// 哔哩哔哩不受影响：第一次调用就带 cookie，也不会走机器人验证升级。
    func test_bilibili_cookiesFromFirstCall_unchanged() async throws {
        let (service, binDir) = try makeReadyService(ytDlpScript: Self.botCheckScriptA)
        let workDir = makeTempDir()
        let result = try await service.download(
            urlString: "https://www.bilibili.com/video/BV1GJ411x7h7", into: workDir,
            cookies: .browser("chrome"), subtitlePriority: .never, progress: { _ in })
        guard case .media = result else { return XCTFail("应返回 .media") }
        let lines = callLines(binDir)
        XCTAssertGreaterThanOrEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("--cookies-from-browser chrome"), lines[0])
        XCTAssertFalse(toolsLogText().contains("机器人验证"), toolsLogText())
        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "\(ToolStubURLProtocol.requestLog)")
    }
}
