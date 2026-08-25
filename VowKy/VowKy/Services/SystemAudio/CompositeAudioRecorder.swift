import Foundation

/// 混合模式(会议主路径):麦克风收自己 + 系统声音收对方,两路在 16k 域 FIFO 对齐求和。
/// 麦克风一路传**新建的** `AudioRecorder()` 实例而不是共享单例——共享单例是热键听写在用的,
/// 给它加状态就是碰红线;新实例复用已验证的权限/下混/重采样/暂停语义,且 backupService 为 nil 不写备份。
@available(macOS 14.4, *)
final class CompositeAudioRecorder: AudioRecorderProtocol, SystemAudioSilenceReporting {

    private var micRecorder: AudioRecorderProtocol
    private var systemRecorder: AudioRecorderProtocol

    private let lock = NSLock()
    /// 两路回调都投到这条队列上再 push/drain:混音器因此始终单线程访问,不需要自己加锁。
    private let processingQueue = DispatchQueue(label: "com.vowky.audio.composite")
    /// 只在 processingQueue 上访问。每次 start 全新建(不跨会话残留)。
    private var mixer = StreamFIFOMixer(streamCount: 2)

    private var recordedSamples: [Float] = []
    private var _isPaused = false

    private static let micStreamIndex = 0
    private static let systemStreamIndex = 1

    var onSamplesCaptured: (([Float]) -> Void)?
    var onSystemAudioSilenceChange: ((Bool) -> Void)?

    init(micRecorder: AudioRecorderProtocol, systemRecorder: AudioRecorderProtocol) {
        self.micRecorder = micRecorder
        self.systemRecorder = systemRecorder

        self.micRecorder.onSamplesCaptured = { [weak self] samples in
            self?.ingest(streamIndex: CompositeAudioRecorder.micStreamIndex, samples: samples)
        }
        self.systemRecorder.onSamplesCaptured = { [weak self] samples in
            self?.ingest(streamIndex: CompositeAudioRecorder.systemStreamIndex, samples: samples)
        }
        (self.systemRecorder as? SystemAudioSilenceReporting)?.onSystemAudioSilenceChange = { [weak self] silent in
            self?.onSystemAudioSilenceChange?(silent)
        }
    }

    /// 波形取两路较响的一路:任一路有声音都要动起来。
    var audioLevel: Float {
        max(micRecorder.audioLevel, systemRecorder.audioLevel)
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isPaused
    }

    func startRecording() throws {
        lock.lock()
        recordedSamples = []
        _isPaused = false
        lock.unlock()
        processingQueue.sync { mixer = StreamFIFOMixer(streamCount: 2) }

        // 脆弱的一路先起(失败时无须回滚麦克风);麦克风失败再把系统声音停掉,错误原样上抛。
        try systemRecorder.startRecording()
        do {
            try micRecorder.startRecording()
        } catch {
            NSLog("[VowKy][Composite] mic start failed — rolling back system audio: \(error.localizedDescription)")
            _ = systemRecorder.stopRecording()
            throw error
        }
    }

    func stopRecording() -> [Float] {
        // 子 recorder 自己累积的样本直接丢弃:混音累积以本类为准。
        // 两者的 stopRecording 都会同步排空自己的处理队列,故其回调此刻已全部投递到本类队列。
        _ = micRecorder.stopRecording()
        _ = systemRecorder.stopRecording()

        processingQueue.sync {
            emit(mixer.flushRemainder())
        }

        lock.lock()
        let samples = recordedSamples
        recordedSamples = []
        _isPaused = false
        lock.unlock()

        let duration = Double(samples.count) / 16000
        NSLog("[VowKy][Composite] Returning \(samples.count) mixed samples (duration=\(String(format: "%.1f", duration))s)")
        return samples
    }

    func pauseRecording() {
        lock.lock()
        _isPaused = true
        lock.unlock()
        micRecorder.pauseRecording()
        systemRecorder.pauseRecording()
    }

    func resumeRecording() {
        lock.lock()
        _isPaused = false
        lock.unlock()
        micRecorder.resumeRecording()
        systemRecorder.resumeRecording()
    }

    // MARK: - Private

    private func ingest(streamIndex: Int, samples: [Float]) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.mixer.push(streamIndex: streamIndex, samples: samples)
            self.emit(self.mixer.drainMixed())
        }
    }

    /// 只在 processingQueue 上调用。
    private func emit(_ mixed: [Float]) {
        guard !mixed.isEmpty else { return }
        lock.lock()
        recordedSamples.append(contentsOf: mixed)
        lock.unlock()
        onSamplesCaptured?(mixed)
    }
}
