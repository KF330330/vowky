import Foundation
import XCTest
@testable import VowKy

/// 频道 / 播放列表拒收（前置校验 + yt-dlp 输出兜底）与 `run()` 的中止判据。
/// 全程不联网、不 spawn yt-dlp：只用临时 shell 脚本验证进程控制逻辑。
final class URLDownloadServiceTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
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

    /// 完全离线的服务实例：provisioner 指向临时 binDir + Stub session，任何真网请求都不可能发生。
    private func makeOfflineService() -> URLDownloadService {
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
        let provisioner = ToolProvisioner(
            binDirOverride: makeTempDir(),
            sessionConfiguration: config,
            endpoints: endpoints
        )
        return URLDownloadService(provisioner: provisioner)
    }

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
}
