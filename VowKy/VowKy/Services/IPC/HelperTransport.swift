import Foundation

/// helper 就绪标志(speech / punct),供代理类同步读取(协议的 isReady 是同步的)。
/// 用锁保护,可跨线程安全读写。
final class HelperReadyState: @unchecked Sendable {
    private let lock = NSLock()
    private var speech = false
    private var punct = false

    var speechReady: Bool { lock.lock(); defer { lock.unlock() }; return speech }
    var punctReady: Bool { lock.lock(); defer { lock.unlock() }; return punct }

    func set(speech: Bool, punct: Bool) {
        lock.lock(); self.speech = speech; self.punct = punct; lock.unlock()
    }
    func clear() { set(speech: false, punct: false) }
}

/// 主 app 与常驻 helper(vowky-speechd)之间的传输层。
/// 持有子进程 + stdin/stdout 管道,所有进程/管道操作在私有串行队列上完成,
/// 因而天然「单请求/单响应」串行;阻塞 IO 不会占用 MainActor / 协作线程池。
final class HelperTransport: @unchecked Sendable {

    static let shared = HelperTransport()

    let readyState = HelperReadyState()

    private let queue = DispatchQueue(label: "com.vowky.speechhelper.transport")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?

    // respawn 退避:窗口内重启次数超限则暂不再起,优雅退化到下次 app 启动。
    private var spawnTimestamps: [Date] = []
    private static let spawnWindow: TimeInterval = 30
    private static let maxSpawnsInWindow = 3
    private static let handshakeTimeout: TimeInterval = 60  // 覆盖冷启动模型加载

    private static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vowky-speechd")
    }

    private init() {}

    // MARK: - 公开 API

    var speechReady: Bool { readyState.speechReady }
    var punctReady: Bool { readyState.punctReady }

    /// 启动并预热(spawn + handshake,握手往返会一直等到 helper 加载完模型)。app 启动时调用。
    func ensureStarted() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                _ = self.ensureStartedLocked()
                cont.resume()
            }
        }
    }

    /// 异步请求(识别走这条,不阻塞 MainActor)。失败返回 nil。
    func request(_ payload: Data, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            queue.async {
                cont.resume(returning: self.performLocked(payload, timeout: timeout))
            }
        }
    }

    /// 同步请求(标点走这条:协议方法是同步的)。阻塞调用线程等待往返,
    /// 时长与改造前在进程内跑 CT-Transformer 相当。失败返回 nil。
    func requestSync(_ payload: Data, timeout: TimeInterval) -> Data? {
        queue.sync { performLocked(payload, timeout: timeout) }
    }

    /// 关闭 helper(app 退出 / Sparkle 安装前):关 stdin → helper 收 EOF 退出;兜底 terminate。
    func shutdown() {
        queue.sync { teardownLocked() }
    }

    // MARK: - 队列内实现

    private func performLocked(_ payload: Data, timeout: TimeInterval) -> Data? {
        guard ensureStartedLocked() else { return nil }
        guard let inFD = stdinHandle?.fileDescriptor,
              let outFD = stdoutHandle?.fileDescriptor else {
            teardownLocked(); return nil
        }
        guard SpeechIPCWire.writeFrame(fd: inFD, payload: payload) else {
            teardownLocked(); return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        guard let response = SpeechIPCWire.readFrame(fd: outFD, deadline: deadline) else {
            teardownLocked(); return nil
        }
        return response
    }

    @discardableResult
    private func ensureStartedLocked() -> Bool {
        if let process, process.isRunning { return true }
        guard spawnLocked() else { return false }

        // handshake:helper 先加载模型再服务,握手往返自然阻塞到模型就绪。
        let req = SpeechIPCWire.encodeHandshakeRequest()
        guard let inFD = stdinHandle?.fileDescriptor,
              let outFD = stdoutHandle?.fileDescriptor,
              SpeechIPCWire.writeFrame(fd: inFD, payload: req),
              let resp = SpeechIPCWire.readFrame(fd: outFD, deadline: Date().addingTimeInterval(Self.handshakeTimeout)),
              let ready = SpeechIPCWire.decodeHandshakeResponse(resp) else {
            teardownLocked()
            return false
        }
        readyState.set(speech: ready.speech, punct: ready.punct)
        return true
    }

    private func spawnLocked() -> Bool {
        let now = Date()
        spawnTimestamps = spawnTimestamps.filter { now.timeIntervalSince($0) < Self.spawnWindow }
        guard spawnTimestamps.count < Self.maxSpawnsInWindow else {
            NSLog("[HelperTransport] spawn backoff: too many restarts in window")
            return false
        }
        spawnTimestamps.append(now)

        let url = Self.helperURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            NSLog("[HelperTransport] helper not executable at \(url.path)")
            return false
        }

        let proc = Process()
        proc.executableURL = url
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // stderr 继承父进程,helper 的 NSLog 诊断可见。
        proc.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.queue.async {
                // 仅当死的是「当前」进程才清理,避免误清刚 respawn 的新进程。
                if self.process === terminated { self.handleTerminationLocked() }
            }
        }
        do {
            try proc.run()
        } catch {
            NSLog("[HelperTransport] failed to spawn: \(error.localizedDescription)")
            return false
        }
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        return true
    }

    private func handleTerminationLocked() {
        readyState.clear()
        stdinHandle = nil
        stdoutHandle = nil
        process = nil
    }

    private func teardownLocked() {
        readyState.clear()
        try? stdinHandle?.close()  // 关 stdin → helper EOF 退出
        stdinHandle = nil
        try? stdoutHandle?.close()
        stdoutHandle = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }
}
