import CryptoKit
import Foundation
import XCTest
@testable import VowKy

// MARK: - Stub URLProtocol（全程零真网请求）

/// `canInit` 对**所有**请求返回 true：任何没被显式配置的 URL 会立刻失败并记进 `requestLog`，
/// 这样「没打到某个源」才有证明力（真网请求一律不可能发生）。
final class ToolStubURLProtocol: URLProtocol {
    enum Route {
        case ok(status: Int, body: Data, finalURL: URL?)
        case redirect(status: Int, to: URL)
        /// 涓流：每 `every` 秒发 `chunk` 字节，共 `total` 字节。
        case slow(chunk: Int, every: TimeInterval, total: Int)
        /// 停流：发完响应头与 `headersThenBytes` 字节后不再发送。
        /// 4 秒仍未被上层取消/超时则自行报 `URLError.timedOut`——真实网络栈的停流表现，
        /// 避免测试依赖「自定义 URLProtocol 下 timeoutIntervalForRequest 是否被系统强制」这一环境行为。
        case stall(headersThenBytes: Int)
    }

    private static let stateLock = NSLock()
    private static var storedRoutes: [String: Route] = [:]
    private static var storedLog: [String] = []

    static func reset() {
        stateLock.lock()
        storedRoutes = [:]
        storedLog = []
        stateLock.unlock()
    }

    static func set(_ url: String, _ route: Route) {
        stateLock.lock()
        storedRoutes[url] = route
        stateLock.unlock()
    }

    static func clearLog() {
        stateLock.lock()
        storedLog = []
        stateLock.unlock()
    }

    static var requestLog: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLog
    }

    private static func route(for url: String) -> Route? {
        stateLock.lock()
        defer { stateLock.unlock() }
        storedLog.append(url)
        return storedRoutes[url]
    }

    private let stopLock = NSLock()
    private var stopped = false
    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let route = Self.route(for: url.absoluteString) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch route {
        case .ok(let status, let body, let finalURL):
            let response = HTTPURLResponse(
                url: finalURL ?? url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)

        case .redirect(let status, let to):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Location": to.absoluteString]
            )!
            var newRequest = URLRequest(url: to)
            newRequest.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: response)

        case .slow(let chunk, let every, let total):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "\(total)"]
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                var sent = 0
                while sent < total {
                    if self.isStopped { return }
                    Thread.sleep(forTimeInterval: every)
                    if self.isStopped { return }
                    let size = min(chunk, total - sent)
                    self.client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: size))
                    sent += size
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }

        case .stall(let headersThenBytes):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "10000000"]
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if headersThenBytes > 0 {
                    self.client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: headersThenBytes))
                }
                let deadline = Date().addingTimeInterval(4)
                while Date() < deadline {
                    if self.isStopped { return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if self.isStopped { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
        }
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }
}

// MARK: - 进度采集

final class ToolProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ToolProvisionProgress] = []

    func record(_ update: ToolProvisionProgress) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }

    var all: [ToolProvisionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var downloading: [ToolProvisionProgress] { all.filter { $0.phase == .downloading } }
}

// MARK: - 测试

final class ToolProvisionerTests: XCTestCase {

    #if arch(arm64)
    private static let archPath = "arm64"
    #else
    private static let archPath = "amd64"
    #endif

    private static let buildId = "1787073674_9.0.1"
    private static let ffmpegVersion = "9.0.1"

    private var tempRoot: URL!
    private var binDir: URL!
    private var privateKey: Curve25519.Signing.PrivateKey!
    private var publicKeyData: Data!
    private var ytDlpBody: Data!
    private var ffmpegZip: Data!

    // MARK: 生命周期

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky-toolprov-\(UUID().uuidString)")
        binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        ToolLogger.overrideLogURL = tempRoot.appendingPathComponent("tools.log")

        privateKey = Curve25519.Signing.PrivateKey()
        publicKeyData = privateKey.publicKey.rawRepresentation
        ytDlpBody = Data((0..<1_200_000).map { _ in UInt8.random(in: 0...255) })
        ffmpegZip = try makeFFmpegZip()
        ToolStubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        ToolStubURLProtocol.reset()
        ToolLogger.overrideLogURL = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        binDir = nil
        try super.tearDownWithError()
    }

    // MARK: 夹具

    /// 用 `ditto -c -k` 打一个内含单个名为 `ffmpeg` 的文件的 zip（与 martin-riedl 的产物结构一致）。
    private func makeFFmpegZip() throws -> Data {
        let src = tempRoot.appendingPathComponent("zipsrc", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: src.appendingPathComponent("ffmpeg"))
        let zipURL = tempRoot.appendingPathComponent("ffmpeg.zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", src.path, zipURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "ditto 打包失败")
        return try Data(contentsOf: zipURL)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: URL 常量

    private let mirrorBase = "https://mirror.test/tools/"
    private var envelopeURL: String { mirrorBase + "manifest.signed.json" }
    private func mirrorYtURL(_ tag: String) -> String { mirrorBase + "yt-dlp/\(tag)/yt-dlp_macos" }
    private func mirrorFFURL(_ buildId: String) -> String {
        mirrorBase + "ffmpeg/\(buildId)/\(Self.archPath)/ffmpeg.zip"
    }
    private let latestAPIURL = "https://api.test/releases/latest"
    private func upstreamYtURL(_ tag: String) -> String { "https://gh.test/releases/download/\(tag)/yt-dlp_macos" }
    private func upstreamSumsURL(_ tag: String) -> String { "https://gh.test/releases/download/\(tag)/SHA2-256SUMS" }
    private var upstreamFFRedirectURL: String { "https://mr.test/redirect/latest/macos/\(Self.archPath)/release/ffmpeg.zip" }
    private var upstreamFFFinalURL: String { "https://mr.test/download/macos/\(Self.archPath)/\(Self.buildId)/ffmpeg.zip" }

    private func makeEndpoints(publicKey: Data?) -> ToolEndpoints {
        ToolEndpoints(
            mirrorBase: URL(string: mirrorBase)!,
            ytDlpLatestAPI: URL(string: latestAPIURL)!,
            ytDlpReleaseBase: URL(string: "https://gh.test/releases/download/")!,
            ffmpegRedirectBase: URL(string: "https://mr.test/redirect/latest/macos/")!,
            manifestPublicKey: publicKey
        )
    }

    private static let fastPolicy = DownloadPolicy(
        minBytesPerSecond: 50_000, throughputWindow: 1, graceSeconds: 0.5, maxDuration: 5
    )

    private func makeProvisioner(
        publicKey: Data?? = nil,
        mirrorPolicy: DownloadPolicy? = nil,
        upstreamPolicy: DownloadPolicy? = nil
    ) -> ToolProvisioner {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolStubURLProtocol.self]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.urlCache = nil
        let key: Data?
        if case let .some(value) = publicKey { key = value } else { key = publicKeyData }
        return ToolProvisioner(
            binDirOverride: binDir,
            sessionConfiguration: config,
            endpoints: makeEndpoints(publicKey: key),
            mirrorPolicy: mirrorPolicy ?? Self.fastPolicy,
            upstreamPolicy: upstreamPolicy ?? Self.fastPolicy,
            smallRequestWallClock: 2,
            envelopeWallClock: 2,
            analytics: { _, _ in }   // 单测绝不发真实埋点
        )
    }

    // MARK: 清单 / 信封

    private func manifestBytes(
        ytTag: String,
        ytSHA: String? = nil,
        ffSHA: String? = nil,
        ytAsset: String? = nil,
        buildId: String = ToolProvisionerTests.buildId
    ) -> Data {
        let ytHash = ytSHA ?? sha256Hex(ytDlpBody)
        let ffHash = ffSHA ?? sha256Hex(ffmpegZip)
        let ffAsset: (String) -> [String: Any] = { arch in
            [
                "buildId": buildId,
                "asset": "ffmpeg/\(buildId)/\(arch)/ffmpeg.zip",
                "sha256": ffHash,
                "size": self.ffmpegZip.count,
            ]
        }
        let dict: [String: Any] = [
            "schema": 1,
            "generatedAt": "2026-09-05T00:00:00Z",
            "ytDlp": [
                "tag": ytTag,
                "asset": ytAsset ?? "yt-dlp/\(ytTag)/yt-dlp_macos",
                "sha256": ytHash,
                "size": ytDlpBody.count,
            ],
            "ffmpeg": [
                "version": Self.ffmpegVersion,
                "arm64": ffAsset("arm64"),
                "amd64": ffAsset("amd64"),
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    private func envelopeBytes(manifest: Data, schema: Int = 1, corruptManifest: Bool = false) -> Data {
        let signature = try! privateKey.signature(for: manifest)
        var payload = manifest
        if corruptManifest {
            // 签名针对原始字节，这里改一字节 → 验签必然失败。
            payload[payload.count / 2] = payload[payload.count / 2] &+ 1
        }
        let dict: [String: Any] = [
            "schema": schema,
            "manifest": payload.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ]
        return try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    /// 注册镜像三件套（信封 + yt-dlp 资产 + ffmpeg 资产）。
    private func stubMirror(
        ytTag: String,
        ytSHA: String? = nil,
        ffSHA: String? = nil,
        envelopeSchema: Int = 1,
        corruptManifest: Bool = false,
        buildId: String = ToolProvisionerTests.buildId
    ) {
        let manifest = manifestBytes(ytTag: ytTag, ytSHA: ytSHA, ffSHA: ffSHA, buildId: buildId)
        let envelope = envelopeBytes(manifest: manifest, schema: envelopeSchema, corruptManifest: corruptManifest)
        ToolStubURLProtocol.set(envelopeURL, .ok(status: 200, body: envelope, finalURL: nil))
        ToolStubURLProtocol.set(mirrorYtURL(ytTag), .ok(status: 200, body: ytDlpBody, finalURL: nil))
        ToolStubURLProtocol.set(mirrorFFURL(buildId), .ok(status: 200, body: ffmpegZip, finalURL: nil))
    }

    private func stubLatestAPI(tag: String) {
        let body = try! JSONSerialization.data(withJSONObject: ["tag_name": tag])
        ToolStubURLProtocol.set(latestAPIURL, .ok(status: 200, body: body, finalURL: nil))
    }

    private func stubUpstreamYtDlp(tag: String, binaryStatus: Int = 200, sumsStatus: Int = 200) {
        let sums = "\(sha256Hex(ytDlpBody))  yt-dlp_macos\n0000  yt-dlp\n"
        ToolStubURLProtocol.set(
            upstreamSumsURL(tag),
            .ok(status: sumsStatus, body: sumsStatus == 200 ? Data(sums.utf8) : Data(), finalURL: nil)
        )
        ToolStubURLProtocol.set(
            upstreamYtURL(tag),
            .ok(status: binaryStatus, body: binaryStatus == 200 ? ytDlpBody : Data(), finalURL: nil)
        )
    }

    /// 上游 ffmpeg：`redirect/latest/...` 请求返回 200，但响应 URL 是版本化最终地址
    /// （等效于 307 之后的结果），sidecar 挂在最终地址旁。
    private func stubUpstreamFFmpeg() {
        ToolStubURLProtocol.set(
            upstreamFFRedirectURL,
            .ok(status: 200, body: ffmpegZip, finalURL: URL(string: upstreamFFFinalURL)!)
        )
        ToolStubURLProtocol.set(
            upstreamFFFinalURL + ".sha256",
            .ok(status: 200, body: Data("\(sha256Hex(ffmpegZip))\n".utf8), finalURL: nil)
        )
    }

    // MARK: 本地夹具

    private func installFakeTool(_ name: String, bytes: Data = Data("fake\n".utf8)) throws {
        let url = binDir.appendingPathComponent(name)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeLocalManifest(
        tag: String? = nil, fetchedAt: Date? = nil, versionCheckedAt: Date? = nil, refreshCheckedAt: Date? = nil
    ) throws {
        var dict: [String: Any] = [:]
        if let tag { dict["ytDlpTag"] = tag }
        if let fetchedAt { dict["ytDlpFetchedAt"] = fetchedAt.timeIntervalSince1970 }
        if let versionCheckedAt { dict["ytDlpVersionCheckedAt"] = versionCheckedAt.timeIntervalSince1970 }
        if let refreshCheckedAt { dict["ytDlpRefreshCheckedAt"] = refreshCheckedAt.timeIntervalSince1970 }
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: binDir.appendingPathComponent("manifest.json"))
    }

    private func readLocalManifest() -> [String: Any] {
        guard let data = try? Data(contentsOf: binDir.appendingPathComponent("manifest.json")),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func toolsLog() -> String {
        guard let url = ToolLogger.overrideLogURL, let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func isExecutable(_ name: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent(name).path)
    }

    // MARK: - 1. 标签相同优先镜像

    func test_mirrorPreferred_whenTagsEqual() async throws {
        let tag = "2026.08.19"
        stubMirror(ytTag: tag)
        stubLatestAPI(tag: tag)

        let recorder = ToolProgressRecorder()
        let provisioner = makeProvisioner()
        let tools = try await provisioner.ensureTools { recorder.record($0) }

        XCTAssertTrue(isExecutable("yt-dlp"))
        XCTAssertTrue(isExecutable("ffmpeg"))
        XCTAssertEqual(tools.ytDlp.lastPathComponent, "yt-dlp")

        let log = ToolStubURLProtocol.requestLog
        XCTAssertFalse(log.contains { $0.contains("gh.test") }, "不应请求上游 GitHub: \(log)")
        XCTAssertFalse(log.contains { $0.contains("mr.test") }, "不应请求上游 martin-riedl: \(log)")
        XCTAssertEqual(log.filter { $0.contains("api.test") }.count, 1)
        XCTAssertTrue(log.contains(mirrorYtURL(tag)))
        XCTAssertTrue(log.contains(mirrorFFURL(Self.buildId)))

        let downloading = recorder.downloading
        XCTAssertTrue(downloading.contains { $0.totalBytes > 0 && $0.fractionCompleted > 0 },
                      "应有带总量的下载进度样本")
        let last = try XCTUnwrap(downloading.last)
        XCTAssertEqual(last.bytesReceived, last.totalBytes)
        XCTAssertTrue(downloading.allSatisfy { !$0.isRefresh })
        let pairs = Set(downloading.map { "\($0.toolIndex)/\($0.toolCount)" })
        XCTAssertTrue(pairs.contains("1/2"), "缺 1/2 样本: \(pairs)")
        XCTAssertTrue(pairs.contains("2/2"), "缺 2/2 样本: \(pairs)")
        let ready = try XCTUnwrap(recorder.all.last)
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertEqual(ready.toolCount, 2)

        let checkedAt = try XCTUnwrap(readLocalManifest()["ytDlpVersionCheckedAt"] as? Double)
        XCTAssertLessThan(abs(Date().timeIntervalSince1970 - checkedAt), 60)
        XCTAssertTrue(toolsLog().contains("签名 OK"))
    }

    // MARK: - 2. 齐备且新鲜 → 零网络

    func test_allInstalledFresh_zeroNetwork() async throws {
        try installFakeTool("yt-dlp")
        try installFakeTool("ffmpeg")
        try writeLocalManifest(tag: "2026.08.19", fetchedAt: Date(), versionCheckedAt: Date())

        let recorder = ToolProgressRecorder()
        _ = try await makeProvisioner().ensureTools { recorder.record($0) }

        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "快路径不得发起任何请求: \(ToolStubURLProtocol.requestLog)")
        let ready = try XCTUnwrap(recorder.all.last)
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertEqual(ready.toolCount, 0)
    }

    // MARK: - 3. 信封拉不到 → 回退上游

    func test_mirrorEnvelopeUnavailable_fallsBackUpstream() async throws {
        let tag = "2026.08.19"
        ToolStubURLProtocol.set(envelopeURL, .ok(status: 500, body: Data(), finalURL: nil))
        stubLatestAPI(tag: tag)
        stubUpstreamYtDlp(tag: tag)
        stubUpstreamFFmpeg()

        _ = try await makeProvisioner().ensureTools(progress: nil)

        XCTAssertTrue(isExecutable("yt-dlp"))
        XCTAssertTrue(isExecutable("ffmpeg"))
        let log = ToolStubURLProtocol.requestLog
        XCTAssertTrue(log.contains(upstreamYtURL(tag)))
        XCTAssertTrue(log.contains(upstreamSumsURL(tag)))
        XCTAssertTrue(log.contains(upstreamFFRedirectURL))
        XCTAssertTrue(log.contains(upstreamFFFinalURL + ".sha256"))
        XCTAssertTrue(toolsLog().contains("mirror manifest 不可用"), toolsLog())
    }

    // MARK: - 4. 签名无效 → 完全忽略镜像

    func test_mirrorSignatureInvalid_ignoresMirror() async throws {
        let tag = "2026.08.19"
        stubMirror(ytTag: tag, corruptManifest: true)
        stubLatestAPI(tag: tag)
        stubUpstreamYtDlp(tag: tag)
        stubUpstreamFFmpeg()

        _ = try await makeProvisioner().ensureTools(progress: nil)

        let log = ToolStubURLProtocol.requestLog
        XCTAssertFalse(log.contains(mirrorYtURL(tag)), "验签失败仍请求了镜像资产")
        XCTAssertFalse(log.contains(mirrorFFURL(Self.buildId)), "验签失败仍请求了镜像资产")
        XCTAssertTrue(toolsLog().contains("签名/格式无效"), toolsLog())
        XCTAssertTrue(isExecutable("yt-dlp"))
        XCTAssertTrue(isExecutable("ffmpeg"))
    }

    // MARK: - 5. 镜像哈希不匹配 → 回退上游

    func test_mirrorChecksumMismatch_fallsBackUpstream() async throws {
        let tag = "2026.08.19"
        let wrong = String(repeating: "a", count: 64)
        stubMirror(ytTag: tag, ytSHA: wrong, ffSHA: wrong)
        stubLatestAPI(tag: tag)
        stubUpstreamYtDlp(tag: tag)
        stubUpstreamFFmpeg()

        _ = try await makeProvisioner().ensureTools(progress: nil)

        XCTAssertTrue(isExecutable("yt-dlp"))
        XCTAssertTrue(isExecutable("ffmpeg"))
        let log = ToolStubURLProtocol.requestLog
        XCTAssertTrue(log.contains(mirrorYtURL(tag)))
        XCTAssertTrue(log.contains(upstreamYtURL(tag)))
        XCTAssertTrue(toolsLog().contains("回退上游"), toolsLog())
        XCTAssertTrue(toolsLog().contains("result=checksum"), toolsLog())
    }

    // MARK: - 6. 上游校验文件缺失 → fail-closed

    func test_upstreamChecksumMissing_failsClosed() async throws {
        let tag = "2026.08.19"
        ToolStubURLProtocol.set(envelopeURL, .ok(status: 500, body: Data(), finalURL: nil))
        stubLatestAPI(tag: tag)
        stubUpstreamYtDlp(tag: tag, sumsStatus: 404)
        stubUpstreamFFmpeg()

        do {
            _ = try await makeProvisioner().ensureTools(progress: nil)
            XCTFail("取不到校验文件必须中止安装")
        } catch let error as ToolProvisionError {
            XCTAssertEqual(error, .checksumMismatch(tool: "yt-dlp"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDir.appendingPathComponent("yt-dlp").path))
    }

    // MARK: - 7. 信封涓流 → 墙钟兜住

    func test_envelopeTrickle_boundedByWallClock() async throws {
        let tag = "2026.08.19"
        ToolStubURLProtocol.set(envelopeURL, .slow(chunk: 64, every: 0.1, total: 100_000))
        stubLatestAPI(tag: tag)
        stubUpstreamYtDlp(tag: tag)
        stubUpstreamFFmpeg()

        let started = Date()
        _ = try await makeProvisioner().ensureTools(progress: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 8, "信封涓流必须被墙钟截断")
        XCTAssertTrue(isExecutable("yt-dlp"))
        XCTAssertTrue(toolsLog().contains("mirror manifest 不可用"), toolsLog())
    }

    // MARK: - 8. 校验文件涓流 → 有界 fail-closed

    func test_checksumFileTrickle_failsClosedBounded() async throws {
        let tag = "2026.08.19"
        ToolStubURLProtocol.set(envelopeURL, .ok(status: 500, body: Data(), finalURL: nil))
        stubLatestAPI(tag: tag)
        ToolStubURLProtocol.set(upstreamYtURL(tag), .ok(status: 200, body: ytDlpBody, finalURL: nil))
        ToolStubURLProtocol.set(upstreamSumsURL(tag), .slow(chunk: 8, every: 0.1, total: 10_000))

        let started = Date()
        do {
            _ = try await makeProvisioner().ensureTools(progress: nil)
            XCTFail("校验文件取不到必须中止")
        } catch let error as ToolProvisionError {
            XCTAssertEqual(error, .checksumMismatch(tool: "yt-dlp"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    // MARK: - 9. 停流 → 请求超时后切上游

    func test_stall_failsWithinRequestTimeout_thenUpstream() async throws {
        let tag = "2026.08.19"
        stubMirror(ytTag: tag)
        // 停流用例把宽限拉长，确保命中的是「超时」而不是「低速」。
        ToolStubURLProtocol.set(mirrorYtURL(tag), .stall(headersThenBytes: 1024))
        stubLatestAPI(tag: tag)
        stubUpstreamYtDlp(tag: tag)

        let policy = DownloadPolicy(minBytesPerSecond: 50_000, throughputWindow: 1, graceSeconds: 10, maxDuration: 30)
        let started = Date()
        _ = try await makeProvisioner(mirrorPolicy: policy, upstreamPolicy: policy).ensureTools(progress: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 6)
        XCTAssertTrue(isExecutable("yt-dlp"))
        let log = toolsLog()
        XCTAssertTrue(log.contains("source=mirror") && log.contains("result=timeout"), log)
        XCTAssertTrue(ToolStubURLProtocol.requestLog.contains(upstreamYtURL(tag)))
    }

    // MARK: - 10. 涓流 → 低速判定后切上游

    func test_trickle_failsTooSlow_thenUpstream() async throws {
        let tag = "2026.08.19"
        stubMirror(ytTag: tag)
        ToolStubURLProtocol.set(mirrorYtURL(tag), .slow(chunk: 1024, every: 0.1, total: 5_000_000))
        stubLatestAPI(tag: tag)
        stubUpstreamYtDlp(tag: tag)

        let started = Date()
        _ = try await makeProvisioner().ensureTools(progress: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 4)
        XCTAssertTrue(isExecutable("yt-dlp"))
        XCTAssertTrue(toolsLog().contains("result=too_slow"), toolsLog())
        XCTAssertTrue(ToolStubURLProtocol.requestLog.contains(upstreamYtURL(tag)))
    }

    // MARK: - 11. 墙钟上限

    func test_maxDuration_enforced() async throws {
        let tag = "2026.08.19"
        stubMirror(ytTag: tag)
        // 速度足够（约 2 MB/s，不触发低速），只可能被墙钟截断。
        ToolStubURLProtocol.set(mirrorYtURL(tag), .slow(chunk: 200_000, every: 0.1, total: 200_000_000))
        stubLatestAPI(tag: tag)
        stubUpstreamYtDlp(tag: tag)

        _ = try await makeProvisioner().ensureTools(progress: nil)

        XCTAssertTrue(toolsLog().contains("result=max_duration"), toolsLog())
        XCTAssertTrue(isExecutable("yt-dlp"))
        XCTAssertTrue(ToolStubURLProtocol.requestLog.contains(upstreamYtURL(tag)))
    }

    // MARK: - 12. 取消 → CancellationError

    func test_cancellation_throwsCancellationError() async throws {
        let tag = "2026.08.19"
        stubMirror(ytTag: tag)
        ToolStubURLProtocol.set(mirrorYtURL(tag), .slow(chunk: 100_000, every: 0.05, total: 50_000_000))
        stubLatestAPI(tag: tag)

        let provisioner = makeProvisioner()
        let task = Task { try await provisioner.ensureTools(progress: nil) }

        // 等到镜像资产真正开始下载再取消。
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !ToolStubURLProtocol.requestLog.contains(mirrorYtURL(tag)) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应正常返回")
        } catch is CancellationError {
            // 期望
        } catch {
            XCTFail("取消必须抛 CancellationError，实得 \(error)")
        }
        XCTAssertTrue(toolsLog().contains("result=cancel"), toolsLog())
    }

    // MARK: - 13. 不再下载 ffprobe

    func test_noFFprobeDownloaded() async throws {
        let tag = "2026.08.19"
        stubMirror(ytTag: tag)
        stubLatestAPI(tag: tag)

        _ = try await makeProvisioner().ensureTools(progress: nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: binDir.path).sorted()
        XCTAssertEqual(names, ["ffmpeg", "manifest.json", "yt-dlp"])
    }

    // MARK: - 14. 首装：上游更新 → 装上游

    func test_firstInstall_upstreamNewerThanMirror_installsUpstream() async throws {
        stubMirror(ytTag: "2026.08.19")
        stubLatestAPI(tag: "2026.09.01")
        stubUpstreamYtDlp(tag: "2026.09.01")

        _ = try await makeProvisioner().ensureTools(progress: nil)

        let log = ToolStubURLProtocol.requestLog
        XCTAssertTrue(log.contains(upstreamYtURL("2026.09.01")))
        XCTAssertFalse(log.contains(mirrorYtURL("2026.08.19")))
        XCTAssertTrue(log.contains(mirrorFFURL(Self.buildId)), "ffmpeg 仍应来自镜像")
        let manifest = readLocalManifest()
        XCTAssertEqual(manifest["ytDlpTag"] as? String, "2026.09.01")
        XCTAssertNotNil(manifest["ytDlpVersionCheckedAt"] as? Double)
    }

    // MARK: - 15. 首装：上游下不下来 → 退镜像旧版

    func test_firstInstall_upstreamNewer_downloadFails_fallsBackToMirrorTag() async throws {
        stubMirror(ytTag: "2026.08.19")
        stubLatestAPI(tag: "2026.09.01")
        stubUpstreamYtDlp(tag: "2026.09.01", binaryStatus: 500)

        _ = try await makeProvisioner().ensureTools(progress: nil)

        let manifest = readLocalManifest()
        XCTAssertEqual(manifest["ytDlpTag"] as? String, "2026.08.19")
        XCTAssertNil(manifest["ytDlpVersionCheckedAt"] as? Double, "退回旧版不得算作已确认最新")
        let refreshedAt = try XCTUnwrap(manifest["ytDlpRefreshCheckedAt"] as? Double)
        XCTAssertLessThan(abs(Date().timeIntervalSince1970 - refreshedAt), 60)
        XCTAssertTrue(toolsLog().contains("安装镜像旧版"), toolsLog())
    }

    // MARK: - 16. 首装：上游未知 → 装镜像

    func test_firstInstall_upstreamUnknown_installsMirror() async throws {
        stubMirror(ytTag: "2026.08.19")
        ToolStubURLProtocol.set(latestAPIURL, .ok(status: 500, body: Data(), finalURL: nil))

        _ = try await makeProvisioner().ensureTools(progress: nil)

        let manifest = readLocalManifest()
        XCTAssertEqual(manifest["ytDlpTag"] as? String, "2026.08.19")
        XCTAssertNil(manifest["ytDlpVersionCheckedAt"] as? Double)
        XCTAssertTrue(ToolStubURLProtocol.requestLog.contains(mirrorYtURL("2026.08.19")))
    }

    // MARK: - 17. 过期刷新：镜像更新 → 升级

    func test_staleRefresh_upgradesWhenNewer() async throws {
        try installFakeTool("yt-dlp")
        try installFakeTool("ffmpeg")
        try writeLocalManifest(
            tag: "2026.08.01",
            fetchedAt: Date().addingTimeInterval(-30 * 24 * 3600),
            versionCheckedAt: Date().addingTimeInterval(-30 * 24 * 3600)
        )
        stubMirror(ytTag: "2026.08.19")
        ToolStubURLProtocol.set(latestAPIURL, .ok(status: 500, body: Data(), finalURL: nil))

        let recorder = ToolProgressRecorder()
        _ = try await makeProvisioner().ensureTools { recorder.record($0) }

        XCTAssertEqual(readLocalManifest()["ytDlpTag"] as? String, "2026.08.19")
        XCTAssertTrue(ToolStubURLProtocol.requestLog.contains(mirrorYtURL("2026.08.19")))
        let downloading = recorder.downloading
        XCTAssertTrue(downloading.allSatisfy { $0.isRefresh }, "刷新动作的样本必须标记 isRefresh")
        XCTAssertTrue(downloading.allSatisfy { $0.toolIndex == 1 && $0.toolCount == 1 })
        XCTAssertTrue(downloading.contains { $0.totalBytes > 0 })
    }

    // MARK: - 18. 过期刷新：绝不降级

    func test_staleRefresh_neverDowngrades() async throws {
        let original = Data("installed-2026.09.01\n".utf8)
        try installFakeTool("yt-dlp", bytes: original)
        try installFakeTool("ffmpeg")
        let checkedAt = Date().addingTimeInterval(-30 * 24 * 3600)
        try writeLocalManifest(tag: "2026.09.01", fetchedAt: checkedAt, versionCheckedAt: checkedAt)
        stubMirror(ytTag: "2026.08.19")
        ToolStubURLProtocol.set(latestAPIURL, .ok(status: 500, body: Data(), finalURL: nil))

        _ = try await makeProvisioner().ensureTools(progress: nil)

        XCTAssertFalse(ToolStubURLProtocol.requestLog.contains { $0.contains("yt-dlp_macos") },
                       "不得为降级发起任何下载: \(ToolStubURLProtocol.requestLog)")
        XCTAssertEqual(try Data(contentsOf: binDir.appendingPathComponent("yt-dlp")), original)
        let manifest = readLocalManifest()
        XCTAssertEqual(manifest["ytDlpTag"] as? String, "2026.09.01")
        XCTAssertEqual(try XCTUnwrap(manifest["ytDlpVersionCheckedAt"] as? Double),
                       checkedAt.timeIntervalSince1970, accuracy: 1)
        let refreshedAt = try XCTUnwrap(manifest["ytDlpRefreshCheckedAt"] as? Double)
        XCTAssertLessThan(abs(Date().timeIntervalSince1970 - refreshedAt), 60)
        XCTAssertTrue(toolsLog().contains("不低于镜像"), toolsLog())
    }

    // MARK: - 19. 目标未知 → 只写退避

    func test_staleRefresh_unknownTarget_setsBackoffOnly() async throws {
        try installFakeTool("yt-dlp")
        try installFakeTool("ffmpeg")
        let checkedAt = Date().addingTimeInterval(-30 * 24 * 3600)
        try writeLocalManifest(tag: "2026.08.01", fetchedAt: checkedAt, versionCheckedAt: checkedAt)
        ToolStubURLProtocol.set(envelopeURL, .ok(status: 500, body: Data(), finalURL: nil))
        ToolStubURLProtocol.set(latestAPIURL, .ok(status: 500, body: Data(), finalURL: nil))

        _ = try await makeProvisioner().ensureTools(progress: nil)

        let manifest = readLocalManifest()
        XCTAssertEqual(try XCTUnwrap(manifest["ytDlpVersionCheckedAt"] as? Double),
                       checkedAt.timeIntervalSince1970, accuracy: 1)
        let refreshedAt = try XCTUnwrap(manifest["ytDlpRefreshCheckedAt"] as? Double)
        XCTAssertLessThan(abs(Date().timeIntervalSince1970 - refreshedAt), 60)

        // 退避窗口内再来一次：走快路径，零网络。
        ToolStubURLProtocol.clearLog()
        _ = try await makeProvisioner().ensureTools(progress: nil)
        XCTAssertTrue(ToolStubURLProtocol.requestLog.isEmpty, "退避期内不应再查上游: \(ToolStubURLProtocol.requestLog)")
    }

    // MARK: - 20. 信封解析纯函数

    func test_envelopeDecode() throws {
        let manifest = manifestBytes(ytTag: "2026.08.19")

        // 正常
        let good = try XCTUnwrap(
            ToolMirrorManifest.decodeSignedEnvelope(envelopeBytes(manifest: manifest), publicKey: publicKeyData)
        )
        XCTAssertEqual(good.schema, 1)
        XCTAssertEqual(good.ytDlp.tag, "2026.08.19")
        XCTAssertEqual(good.ytDlp.asset, "yt-dlp/2026.08.19/yt-dlp_macos")
        XCTAssertEqual(good.ffmpeg.version, Self.ffmpegVersion)
        XCTAssertEqual(good.ffmpegAsset(archPath: "arm64").buildId, Self.buildId)
        XCTAssertEqual(good.ytDlp.size, Int64(ytDlpBody.count))

        // 信封 schema ≠ 1
        XCTAssertNil(ToolMirrorManifest.decodeSignedEnvelope(
            envelopeBytes(manifest: manifest, schema: 2), publicKey: publicKeyData
        ))

        // base64 无效
        let badBase64 = try! JSONSerialization.data(withJSONObject: [
            "schema": 1, "manifest": "!!!not-base64!!!", "signature": "!!!",
        ])
        XCTAssertNil(ToolMirrorManifest.decodeSignedEnvelope(badBase64, publicKey: publicKeyData))

        // 签名不过（清单被改）
        XCTAssertNil(ToolMirrorManifest.decodeSignedEnvelope(
            envelopeBytes(manifest: manifest, corruptManifest: true), publicKey: publicKeyData
        ))

        // sha256 非 hex
        let badSHA = manifestBytes(ytTag: "2026.08.19", ytSHA: String(repeating: "z", count: 64))
        XCTAssertNil(ToolMirrorManifest.decodeSignedEnvelope(
            envelopeBytes(manifest: badSHA), publicKey: publicKeyData
        ))

        // asset 路径穿越
        let badAsset = manifestBytes(ytTag: "2026.08.19", ytAsset: "../../etc/passwd")
        XCTAssertNil(ToolMirrorManifest.decodeSignedEnvelope(
            envelopeBytes(manifest: badAsset), publicKey: publicKeyData
        ))

        // 版本比较
        XCTAssertEqual(ToolProvisioner.compareYtDlpTags("2026.08.19", "2026.9.1"), .orderedAscending)
        XCTAssertEqual(ToolProvisioner.compareYtDlpTags("2026.09.01", "2026.08.19"), .orderedDescending)
        XCTAssertEqual(ToolProvisioner.compareYtDlpTags("2026.08.19", "2026.08.19"), .orderedSame)
    }
}
