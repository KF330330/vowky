import Foundation
import AVFoundation

/// 麦克风录音器。
///
/// 采集后端走 `MicCaptureBackend`（默认 AVCaptureSession），**不再触碰 AVAudioEngine**：
/// 2026-09-02 实锤 AVAudioEngine 的 inputNode 首次绑定存在框架内部锁序反转，会把整个 App 卡死。
/// 另加看门狗：后端 start/stop 都在控制队列上执行、主线程只做有界等待，超时即放弃该后端
/// （generation 自增让迟到 buffer 全丢）、换新控制队列，并通过 onWedged 上报。
final class AudioRecorder: AudioRecorderProtocol {

    private var recordedSamples: [Float] = []
    private let lock = NSLock()
    /// tap 回调只做 downmix/重采样后立刻把样本切到这条串行队列；
    /// 聚合、备份写盘、下游回调都不在 AVAudioEngine 实时线程上跑，且 FIFO 保序。
    private let processingQueue = DispatchQueue(label: "com.vowky.audio.processing")

    /// Optional backup service for content protection
    var backupService: AudioBackupProtocol?

    private var _audioLevel: Float = 0
    /// 跨线程读安全（processingQueue 写 / 主线程 UI 轮询读）
    var audioLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return _audioLevel
    }
    var onSamplesCaptured: (([Float]) -> Void)?

    private var _isPaused = false
    /// 跨线程读安全（主线程写 / tap 实时线程读）
    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isPaused
    }

    func pauseRecording() {
        lock.lock()
        _isPaused = true
        _audioLevel = 0
        lock.unlock()
        NSLog("[VowKy][Audio] pauseRecording() — dropping samples, engine stays alive")
    }

    func resumeRecording() {
        lock.lock()
        _isPaused = false
        lock.unlock()
        NSLog("[VowKy][Audio] resumeRecording()")
    }

    private let targetSampleRate: Double = 16000

    private lazy var targetFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
    }()

    // MARK: - 采集后端与看门狗

    typealias BackendFactory = () -> MicCaptureBackend

    struct Timeouts {
        var start: TimeInterval = 4
        var stop: TimeInterval = 4
    }

    /// 看门狗超时后在主队列回调一次；phase ∈ {"start","stop"}。
    var onWedged: ((String) -> Void)?

    /// 默认后端工厂。DEBUG 下 VOWKY_DEBUG_WEDGE=start|stop 返回故意卡死的后端，供端到端验证看门狗。
    static let defaultBackendFactory: BackendFactory = {
        let session = MicCaptureSession()
        #if DEBUG
        if let wedge = ProcessInfo.processInfo.environment["VOWKY_DEBUG_WEDGE"],
           wedge == "start" || wedge == "stop" {
            return DebugHangingMicBackend(wrapping: session, hangOn: wedge)
        }
        #endif
        return session
    }

    private let backendFactory: BackendFactory
    private let timeouts: Timeouts
    /// 麦克风授权状态提供者。可注入，好让单测在不碰宿主真实 TCC 状态的前提下跑权限门。
    private let authorizationStatusProvider: () -> AVAuthorizationStatus

    /// lock 保护；活动后端，空闲时 nil
    private var backend: MicCaptureBackend?
    /// lock 保护；每次 start 与每次 wedge 各 +1。迟到/卡死后端送来的 buffer 靠它甄别丢弃。
    private var generation: UInt64 = 0
    /// lock 保护；wedge 时整条换新——旧队列上还压着一个永不返回的调用
    private var controlQueue = DispatchQueue(label: "com.vowky.audio.control.0")
    /// lock 保护；卡死对象故意持有不释放（卡死 AVCaptureSession 的 dealloc 可能再阻塞）
    private var abandoned: [MicCaptureBackend] = []

    /// 每次 start 一份，仅在后端 capture 队列上访问
    private final class ConversionState {
        var converter: AVAudioConverter?
        var monoInputFormat: AVAudioFormat?
        var sampleRate: Double = 0
        var didLogFailure = false
    }

    private final class ErrorBox {
        var error: Error?
    }

    /// 跨 requestAccess 闭包回传授权结果（nil = 回调还没来）
    private final class AuthorizationResultBox {
        var value: Bool?
    }

    init(
        backendFactory: @escaping BackendFactory = AudioRecorder.defaultBackendFactory,
        timeouts: Timeouts = Timeouts(),
        authorizationStatusProvider: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        }
    ) {
        self.backendFactory = backendFactory
        self.timeouts = timeouts
        self.authorizationStatusProvider = authorizationStatusProvider
    }

    func startRecording() throws {
        NSLog("[VowKy][Audio] startRecording() called")
        // Support VOWKY_TEST_AUDIO env var for testing
        if let testAudioDir = ProcessInfo.processInfo.environment["VOWKY_TEST_AUDIO"] {
            try startFromTestAudio(directory: testAudioDir)
            return
        }

        // 权限门在调用线程上、看门狗之外：只有 .notDetermined 分支会做一次 0.5 s 的有界等待。
        switch authorizationStatusProvider() {
        case .authorized:
            break
        case .notDetermined:
            // 已授权但 TCC 状态短暂未解析（宿主/冷启动竞态，2026-09-02 实测）时，requestAccess 会立刻
            // 回 true（不弹窗）；真未决时会弹系统授权框，回调要等用户操作——只等 0.5 s，等不到就报
            // 「请在弹窗中允许后重试」，绝不带着未授权的设备去启动采集（否则只录到静音）。
            // requestAccess 的回调不在主队列，故主线程上这段有界等待不会自锁。
            let sem = DispatchSemaphore(value: 0)
            let grantedBox = AuthorizationResultBox()
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                grantedBox.value = granted
                CrashLogger.log("[Audio] mic permission result: \(granted)")
                sem.signal()
            }
            if sem.wait(timeout: .now() + 0.5) == .timedOut {
                CrashLogger.log("[Audio] mic permission still pending after 0.5s — prompt likely showing")
                throw AudioRecorderError.microphonePermissionPending
            }
            if grantedBox.value != true {
                throw AudioRecorderError.microphoneAccessDenied
            }
        case .denied, .restricted:
            throw AudioRecorderError.microphoneAccessDenied
        @unknown default:
            break
        }

        guard let targetFmt = targetFormat else {
            throw AudioRecorderError.formatCreationFailed
        }

        // 重复 start：先把上一个后端收掉（stopRecording 自带超时保护，不会在这里卡住）
        lock.lock()
        let hasActiveBackend = backend != nil
        lock.unlock()
        if hasActiveBackend {
            _ = stopRecording()
        }

        lock.lock()
        recordedSamples = []
        _audioLevel = 0
        _isPaused = false
        generation += 1
        let gen = generation
        let queue = controlQueue
        let newBackend = backendFactory()
        backend = newBackend
        lock.unlock()

        let conversion = ConversionState()
        let box = ErrorBox()
        let sem = DispatchSemaphore(value: 0)

        queue.async { [weak self] in
            do {
                try newBackend.start(onBuffer: { [weak self] buffer in
                    self?.handleCaptured(buffer, generation: gen, state: conversion, targetFormat: targetFmt)
                })
            } catch {
                box.error = error
            }
            sem.signal()
            // 已被看门狗放弃的 start 迟到完成时，在这条废弃队列上尽力收尾，绝不回主线程
            if self?.isCurrentGeneration(gen) == false {
                newBackend.stop()
            }
        }

        if sem.wait(timeout: .now() + timeouts.start) == .timedOut {
            wedge(phase: "start", generation: gen, backend: newBackend)
            throw AudioRecorderError.startTimedOut
        }

        if let startError = box.error {
            lock.lock()
            if backend === newBackend { backend = nil }
            lock.unlock()
            throw (startError as? AudioRecorderError) ?? AudioRecorderError.captureStartFailed(startError)
        }

        let nativeDesc = newBackend.nativeFormat.map { "\($0.sampleRate)Hz/\($0.channelCount)ch" } ?? "pending"
        CrashLogger.log("[Audio] capture started gen=\(gen) native=\(nativeDesc)")
    }

    func stopRecording() -> [Float] {
        NSLog("[VowKy][Audio] stopRecording() called")

        lock.lock()
        let activeBackend = backend
        let gen = generation
        let queue = controlQueue
        backend = nil
        lock.unlock()

        guard let activeBackend else {
            NSLog("[VowKy][Audio] No backend — returning empty samples")
            return []
        }

        let sem = DispatchSemaphore(value: 0)
        queue.async {
            activeBackend.stop()
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeouts.stop) == .timedOut {
            // 不提前返回：仍要走排空屏障，把已捕获的样本收割回去（用户说的话不能丢）
            wedge(phase: "stop", generation: gen, backend: activeBackend)
        }

        // 排空处理队列：确保所有已捕获的 buffer 都完成聚合与备份写盘，避免截尾
        processingQueue.sync {}

        lock.lock()
        let samples = recordedSamples
        recordedSamples = []
        _audioLevel = 0
        _isPaused = false
        lock.unlock()

        // 统计音频采样信息，帮助诊断是否录到有效音频（单次遍历，不建中间数组）
        var maxVal: Float = 0
        var sumVal: Float = 0
        for s in samples {
            let a = abs(s)
            if a > maxVal { maxVal = a }
            sumVal += a
        }
        let avgVal = samples.isEmpty ? 0 : sumVal / Float(samples.count)
        let duration = Double(samples.count) / targetSampleRate
        NSLog("[VowKy][Audio] Returning \(samples.count) samples (duration=\(String(format: "%.1f", duration))s, maxAmp=\(String(format: "%.4f", maxVal)), avgAmp=\(String(format: "%.6f", avgVal)))")
        CrashLogger.log("[Audio] samples=\(samples.count) duration=\(String(format: "%.1f", duration))s maxAmp=\(String(format: "%.4f", maxVal)) avgAmp=\(String(format: "%.6f", avgVal))")
        return samples
    }

    // MARK: - 看门狗

    private func isCurrentGeneration(_ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }

    /// 后端 capture 队列上的入口：甄别代际 → 按采样率惰性建/重建转换器 → 交给原有 processBuffer。
    private func handleCaptured(
        _ buffer: AVAudioPCMBuffer,
        generation gen: UInt64,
        state: ConversionState,
        targetFormat: AVAudioFormat
    ) {
        // 卡死或迟到后端送来的 buffer 一律丢弃
        guard isCurrentGeneration(gen) else { return }

        guard buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved else {
            if !state.didLogFailure {
                state.didLogFailure = true
                CrashLogger.log("[Audio] backend delivered unsupported buffer format: \(buffer.format)")
            }
            return
        }

        if state.converter == nil || state.sampleRate != buffer.format.sampleRate {
            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 1,
                interleaved: false
            ), let conv = AVAudioConverter(from: monoFormat, to: targetFormat) else {
                if !state.didLogFailure {
                    state.didLogFailure = true
                    CrashLogger.log("[Audio] converter build failed for \(buffer.format.sampleRate) Hz")
                }
                return
            }
            state.monoInputFormat = monoFormat
            state.converter = conv
            state.sampleRate = buffer.format.sampleRate
            CrashLogger.log("[Audio] converter (re)built for \(buffer.format.sampleRate) Hz")
        }

        guard let converter = state.converter, let monoInputFormat = state.monoInputFormat else { return }
        processBuffer(buffer, converter: converter, monoInputFormat: monoInputFormat, targetFormat: targetFormat)
    }

    /// 后端调用超时：放弃它（不再等、不再收它的样本），换新控制队列，上报主队列。
    private func wedge(phase: String, generation gen: UInt64, backend wedgedBackend: MicCaptureBackend) {
        let timeout = phase == "start" ? timeouts.start : timeouts.stop
        CrashLogger.log("[Audio] WATCHDOG: \(phase) timed out after \(timeout)s gen=\(gen) — abandoning backend")

        lock.lock()
        generation += 1
        abandoned.append(wedgedBackend)
        if backend === wedgedBackend { backend = nil }
        controlQueue = DispatchQueue(label: "com.vowky.audio.control.\(generation)")
        lock.unlock()

        let callback = onWedged
        DispatchQueue.main.async { callback?(phase) }
    }

    // MARK: - Private

    private func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        monoInputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) {
        // 暂停期间在 downmix/重采样之前直接丢弃，tap 回调近零开销
        if isPaused { return }

        // Step 1: 手动 downmix 多声道到 mono（求所有声道平均值）
        guard let inputData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        guard let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: monoInputFormat,
            frameCapacity: AVAudioFrameCount(frameLength)
        ) else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frameLength)
        guard let monoOut = monoBuffer.floatChannelData else { return }

        if channelCount == 1 {
            memcpy(monoOut[0], inputData[0], frameLength * MemoryLayout<Float>.size)
        } else {
            let invChannels = 1.0 / Float(channelCount)
            for i in 0..<frameLength {
                var sum: Float = 0
                for c in 0..<channelCount {
                    sum += inputData[c][i]
                }
                monoOut[0][i] = sum * invChannels
            }
        }

        // Step 2: 走 converter 做单声道→16kHz 单声道重采样
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = UInt32(Double(frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var error: NSError?
        var hasProvided = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvided = true
            outStatus.pointee = .haveData
            return monoBuffer
        }

        if let error = error {
            NSLog("[VowKy][Audio] Converter error: \(error)")
            return
        }

        guard let data = outputBuffer.floatChannelData else { return }

        let samples = Array(UnsafeBufferPointer(
            start: data[0],
            count: Int(outputBuffer.frameLength)
        ))

        // 实时 tap 线程到此为止：加锁、数组扩容、磁盘写全部转移到串行队列
        processingQueue.async { [weak self] in
            guard let self else { return }
            let rms = self.computeRMS(samples)

            self.lock.lock()
            self.recordedSamples.append(contentsOf: samples)
            self._audioLevel = rms
            self.lock.unlock()

            // Write to backup file for content protection
            self.backupService?.appendSamples(samples)
            self.onSamplesCaptured?(samples)
        }
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    /// Load test audio from a directory (for VOWKY_TEST_AUDIO env var support)
    private func startFromTestAudio(directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        let wavFiles = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "wav" } ?? []

        guard let firstWav = wavFiles.first else {
            throw AudioRecorderError.testAudioNotFound(directory)
        }

        guard let audioFile = try? AVAudioFile(forReading: firstWav) else {
            throw AudioRecorderError.testAudioNotFound(directory)
        }

        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioRecorderError.formatCreationFailed
        }

        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw AudioRecorderError.formatCreationFailed
        }

        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))

        lock.lock()
        recordedSamples = samples
        lock.unlock()
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case formatCreationFailed
    case converterCreationFailed(sourceSampleRate: Double, sourceChannels: UInt32)
    case captureStartFailed(Error?)
    case testAudioNotFound(String)
    case noInputDevice
    case microphonePermissionPending
    case microphoneAccessDenied
    case startTimedOut

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return LL("audioRecorder.error.formatCreationFailed")
        case .converterCreationFailed(let rate, let channels):
            return LL("audioRecorder.error.converterCreationFailed", Int(rate), Int(channels))
        case .captureStartFailed(let underlying):
            return LL("audioRecorder.error.captureStartFailed", underlying?.localizedDescription ?? "-")
        case .testAudioNotFound(let path):
            return LL("audioRecorder.error.testAudioNotFound", path)
        case .noInputDevice:
            return LL("audioRecorder.error.noInputDevice")
        case .microphonePermissionPending:
            return LL("audioRecorder.error.microphonePermissionPending")
        case .microphoneAccessDenied:
            return LL("audioRecorder.error.microphoneAccessDenied")
        case .startTimedOut:
            return LL("audioRecorder.error.startTimedOut")
        }
    }
}
