import Foundation

/// 单次下载过程中的一个采样点（供 UI 显示「已下载 / 总量 / 速度」）。
struct DownloadProgressSample: Sendable, Equatable {
    let bytesReceived: Int64
    /// 未知 = -1。
    let totalBytes: Int64
    /// 未知 = -1；近 `DownloadPolicy.throughputWindow` 秒滑窗均速。
    let bytesPerSecond: Double
}

/// 大文件下载的「等待上限」策略：既要能容忍慢网，又不能在停流/涓流时无限等。
struct DownloadPolicy: Sendable, Equatable {
    /// 低速判定阈值（字节/秒）。
    var minBytesPerSecond: Double = 100 * 1024
    /// 低速判定的滑窗长度。
    var throughputWindow: TimeInterval = 30
    /// 起步宽限：这段时间内不做低速判定（TLS 握手 / 重定向 / 首包）。
    var graceSeconds: TimeInterval = 20
    /// 单次尝试的墙钟上限。
    var maxDuration: TimeInterval
}

enum ProgressDownloadError: Error, Equatable {
    case httpStatus(Int)
    /// `URLError.Code.rawValue` + `localizedDescription`。
    case transport(code: Int, description: String)
    case tooSlow(avgBytesPerSecond: Double)
    case exceededMaxDuration(seconds: TimeInterval)
}

/// 带进度、带低速/墙钟保护、可取消的下载器。
///
/// 存在的理由：`URLSession.download(from:)` 没有进度回调（工具下载全程 0%），
/// 且 `timeoutIntervalForRequest` 只对**完全停流**生效——每来一个字节就重置，
/// 「涓流」场景下唯一的闸是 `timeoutIntervalForResource`（分钟级），用户侧表现为无限卡住。
final class ProgressDownloader: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    /// 成功返回（重定向后最终 URL, HTTP 状态码）；文件已搬到 `destination`。
    ///
    /// - 外层 Task 取消 → `task.cancel()` → 抛 `CancellationError`（绝不包装成其它错误）。
    /// - `onProgress` 节流：距上次 ≥0.5 s 或 fraction 变化 ≥1% 才回调；完成时必回调一次最终值。
    func download(
        from url: URL,
        to destination: URL,
        policy: DownloadPolicy,
        onProgress: @escaping @Sendable (DownloadProgressSample) -> Void
    ) async throws -> (finalURL: URL, httpStatus: Int) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.downloadTask(with: request)
        let delegate = ProgressDownloadDelegate(
            destination: destination,
            requestURL: url,
            policy: policy,
            onProgress: onProgress
        )
        task.delegate = delegate

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation: continuation, task: task)
            }
        } onCancel: {
            delegate.requestCancel()
        }
    }
}

// MARK: - Delegate

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Outcome = (finalURL: URL, httpStatus: Int)

    private let destination: URL
    private let requestURL: URL
    private let policy: DownloadPolicy
    private let onProgress: @Sendable (DownloadProgressSample) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var task: URLSessionDownloadTask?
    private var watchdog: Task<Void, Never>?

    private var finished = false
    private var pendingError: ProgressDownloadError?
    private var cancelRequested = false
    private var cancelRequestedAt: Date?

    private var startedAt = Date()
    private var samples: [(time: Date, bytes: Int64)] = []
    private var expectedBytes: Int64 = -1
    private var lastCallbackAt = Date.distantPast
    private var lastFraction: Double = -2
    private var movedFile = false
    private var finalURL: URL?
    private var httpStatus = 0

    init(
        destination: URL,
        requestURL: URL,
        policy: DownloadPolicy,
        onProgress: @escaping @Sendable (DownloadProgressSample) -> Void
    ) {
        self.destination = destination
        self.requestURL = requestURL
        self.policy = policy
        self.onProgress = onProgress
    }

    // MARK: 生命周期

    func start(continuation: CheckedContinuation<Outcome, Error>, task: URLSessionDownloadTask) {
        lock.lock()
        self.continuation = continuation
        self.task = task
        startedAt = Date()
        samples = [(startedAt, 0)]
        let alreadyCancelled = cancelRequested
        lock.unlock()

        if alreadyCancelled {
            task.cancel()
            return
        }
        task.resume()
        startWatchdog()
    }

    func requestCancel() {
        lock.lock()
        cancelRequested = true
        cancelRequestedAt = Date()
        let running = task
        lock.unlock()
        running?.cancel()
    }

    private func startWatchdog() {
        let watchdogTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.tick() { return }
            }
        }
        lock.lock()
        watchdog = watchdogTask
        lock.unlock()
    }

    /// 返回 true 表示看门狗可以退出。
    private func tick() -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return true
        }
        let now = Date()
        // 取消后若 URLSession 迟迟不回调完成，自己收尾，避免调用方永久挂起。
        if cancelRequested, let requestedAt = cancelRequestedAt, now.timeIntervalSince(requestedAt) > 2 {
            lock.unlock()
            finish(.failure(CancellationError()))
            return true
        }
        let elapsed = now.timeIntervalSince(startedAt)
        if pendingError == nil, elapsed > policy.maxDuration {
            pendingError = .exceededMaxDuration(seconds: elapsed)
            let running = task
            lock.unlock()
            running?.cancel()
            return false
        }
        if pendingError == nil, elapsed > policy.graceSeconds {
            let average = averageThroughputLocked(now: now)
            if average < policy.minBytesPerSecond {
                pendingError = .tooSlow(avgBytesPerSecond: average)
                let running = task
                lock.unlock()
                running?.cancel()
                return false
            }
        }
        lock.unlock()
        return false
    }

    private func finish(_ result: Result<Outcome, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let watchdogTask = watchdog
        watchdog = nil
        lock.unlock()

        watchdogTask?.cancel()
        continuation?.resume(with: result)
    }

    /// 调用方需持锁。样本是「时刻 → 累计字节」，用 `now` 而非最后一个样本的时刻算分母，
    /// 这样「突然停流」也会让均速迅速衰减到 0 而被低速闸抓住。
    private func averageThroughputLocked(now: Date) -> Double {
        guard let latest = samples.last, let first = samples.first else { return 0 }
        let windowStart = now.addingTimeInterval(-policy.throughputWindow)
        let anchor = samples.last(where: { $0.time <= windowStart }) ?? first
        let seconds = max(0.001, now.timeIntervalSince(anchor.time))
        return Double(latest.bytes - anchor.bytes) / seconds
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        let now = Date()
        samples.append((now, totalBytesWritten))
        // 只保留滑窗两倍长度的样本，避免长下载堆积。
        let cutoff = now.addingTimeInterval(-policy.throughputWindow * 2)
        if samples.count > 8, let keepFrom = samples.lastIndex(where: { $0.time <= cutoff }), keepFrom > 0 {
            samples.removeFirst(keepFrom)
        }
        expectedBytes = totalBytesExpectedToWrite
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : -1
        let shouldEmit = now.timeIntervalSince(lastCallbackAt) >= 0.5
            || (fraction >= 0 && abs(fraction - lastFraction) >= 0.01)
        if shouldEmit {
            lastCallbackAt = now
            lastFraction = fraction
        }
        let average = averageThroughputLocked(now: now)
        lock.unlock()

        if shouldEmit {
            onProgress(DownloadProgressSample(
                bytesReceived: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                bytesPerSecond: average
            ))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: location)
            lock.lock()
            if pendingError == nil { pendingError = .httpStatus(status) }
            lock.unlock()
            return
        }
        // 回调返回后 `location` 立即失效，必须**同步**搬走。
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.lock()
            if pendingError == nil {
                pendingError = .transport(code: -1, description: error.localizedDescription)
            }
            lock.unlock()
            return
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?
            .int64Value ?? 0
        lock.lock()
        movedFile = true
        finalURL = response?.url ?? downloadTask.originalRequest?.url ?? requestURL
        httpStatus = status
        let total = expectedBytes > 0 ? expectedBytes : size
        let average = averageThroughputLocked(now: Date())
        lock.unlock()

        // 完成时必回调一次最终值（节流不适用）。
        onProgress(DownloadProgressSample(bytesReceived: size, totalBytes: total, bytesPerSecond: average))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = pendingError
        let moved = movedFile
        let resolvedURL = finalURL
        let status = httpStatus
        lock.unlock()

        if let error {
            let urlError = error as? URLError
            if urlError?.code == .cancelled {
                if let pending {
                    finish(.failure(pending))
                } else {
                    finish(.failure(CancellationError()))
                }
                return
            }
            if let pending {
                finish(.failure(pending))
                return
            }
            let nsError = error as NSError
            finish(.failure(ProgressDownloadError.transport(
                code: urlError?.errorCode ?? nsError.code,
                description: error.localizedDescription
            )))
            return
        }

        if let pending {
            finish(.failure(pending))
            return
        }
        guard moved, let resolvedURL else {
            finish(.failure(ProgressDownloadError.transport(code: -1, description: "下载未产生文件")))
            return
        }
        finish(.success((finalURL: resolvedURL, httpStatus: status)))
    }
}
