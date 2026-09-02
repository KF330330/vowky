import AVFoundation
import XCTest
@testable import VowKy

// MARK: - AudioRecorder 看门狗 / AVCaptureSession 后端（不需要真麦克风）
//
// 覆盖 2026-09-02 卡死事故的修复不变量：
// 1) 后端 start/stop 卡死时，调用方有界返回，绝不把 App 拖死；
// 2) 卡死后下一次录音换新后端，仍能正常出样本；
// 3) stop 卡死时已录到的样本不丢；
// 4) 后端送来的多声道 buffer 仍走原有 downmix + 重采样链路。

// MARK: - 测试替身

/// 指定阶段永久阻塞的后端，模拟 AVFoundation 框架级卡死。
private final class HangingMicBackend: MicCaptureBackend {
    enum Phase { case start, stop }

    private let phase: Phase

    init(hangOn phase: Phase) {
        self.phase = phase
    }

    var nativeFormat: AVAudioFormat? { nil }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if phase == .start {
            DispatchSemaphore(value: 0).wait()
        }
    }

    func stop() {
        if phase == .stop {
            DispatchSemaphore(value: 0).wait()
        }
    }
}

/// 合成后端：在自己的串行队列上送出 48 kHz 双声道非交织 Float32 的 440 Hz 正弦。
private final class SyntheticMicBackend: MicCaptureBackend {
    static let totalFrames = 48_000
    static let blockFrames = 1024
    static let sampleRate: Double = 48_000
    static let amplitude: Float = 0.5

    private let queue = DispatchQueue(label: "test.synthetic.mic")
    private let hangOnStop: Bool
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SyntheticMicBackend.sampleRate,
        channels: 2,
        interleaved: false
    )!

    init(hangOnStop: Bool = false) {
        self.hangOnStop = hangOnStop
    }

    var nativeFormat: AVAudioFormat? { format }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let fmt = format
        queue.async {
            var phase = 0.0
            let increment = 2.0 * Double.pi * 440.0 / SyntheticMicBackend.sampleRate
            var emitted = 0
            while emitted < SyntheticMicBackend.totalFrames {
                let frames = min(SyntheticMicBackend.blockFrames, SyntheticMicBackend.totalFrames - emitted)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
                      let channels = buffer.floatChannelData else { return }
                buffer.frameLength = AVAudioFrameCount(frames)
                for i in 0..<frames {
                    let value = Float(sin(phase)) * SyntheticMicBackend.amplitude
                    channels[0][i] = value
                    channels[1][i] = value
                    phase += increment
                    if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                }
                emitted += frames
                onBuffer(buffer)
            }
        }
    }

    func stop() {
        queue.sync {}
        if hangOnStop {
            DispatchSemaphore(value: 0).wait()
        }
    }
}

/// 跨线程累计 onSamplesCaptured 的小工具。
private final class SampleCollector {
    private let lock = NSLock()
    private var _count = 0
    private var _callbackCount = 0
    private var _sawMainThreadCallback = false

    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var callbackCount: Int { lock.lock(); defer { lock.unlock() }; return _callbackCount }
    var sawMainThreadCallback: Bool { lock.lock(); defer { lock.unlock() }; return _sawMainThreadCallback }

    func record(_ samples: [Float]) {
        let onMain = Thread.isMainThread
        lock.lock()
        _count += samples.count
        _callbackCount += 1
        if onMain { _sawMainThreadCallback = true }
        lock.unlock()
    }
}

// MARK: - 测试

final class AudioRecorderWatchdogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // AudioRecorder.startRecording() 有麦克风权限门。实测：测试宿主刚启动的头几十毫秒里，
        // AVCaptureDevice.authorizationStatus 会先回 .notDetermined（TCC 状态还没解析出来），
        // 单独跑本类时正好撞上，注入的假后端也会被权限门挡掉。这里等状态稳定再开跑。
        let deadline = Date().addingTimeInterval(5)
        var status = AVCaptureDevice.authorizationStatus(for: .audio)
        while status == .notDetermined && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            status = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        NSLog("[WatchdogTests] mic authorization status settled: \(status.rawValue)")
    }

    private func makeRecorder(_ factory: @escaping AudioRecorder.BackendFactory) -> AudioRecorder {
        AudioRecorder(backendFactory: factory, timeouts: .init(start: 0.3, stop: 0.3))
    }

    /// 等待收集器累计到指定样本数（轮询，避免依赖回调时序）。
    private func waitForSamples(_ collector: SampleCollector, atLeast target: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.count >= target { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return collector.count >= target
    }

    // MARK: - #01 start 卡死：有界抛错 + 主线程上报

    func test01_startHang_throwsStartTimedOut_firesOnWedgedOnMain() {
        let recorder = makeRecorder { HangingMicBackend(hangOn: .start) }

        let wedged = expectation(description: "onWedged fired")
        var wedgedPhase: String?
        var wedgedOnMain = false
        recorder.onWedged = { phase in
            wedgedPhase = phase
            wedgedOnMain = Thread.isMainThread
            wedged.fulfill()
        }

        let started = Date()
        var caught: Error?
        XCTAssertThrowsError(try recorder.startRecording()) { caught = $0 }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.3, "start 卡死时必须有界返回，实际耗时 \(elapsed)s")
        guard case .startTimedOut? = caught as? AudioRecorderError else {
            return XCTFail("应抛 startTimedOut，实际 \(String(describing: caught))")
        }

        wait(for: [wedged], timeout: 2.0)
        XCTAssertEqual(wedgedPhase, "start")
        XCTAssertTrue(wedgedOnMain, "onWedged 必须在主队列回调")
    }

    // MARK: - #02 卡死之后下一次录音换新后端且正常出样本

    func test02_afterStartWedge_nextStartUsesFreshBackend() throws {
        let callCount = NSCounter()
        let recorder = makeRecorder {
            if callCount.increment() == 1 {
                return HangingMicBackend(hangOn: .start)
            }
            return SyntheticMicBackend()
        }

        XCTAssertThrowsError(try recorder.startRecording())

        let collector = SampleCollector()
        recorder.onSamplesCaptured = { collector.record($0) }

        try recorder.startRecording()
        XCTAssertTrue(waitForSamples(collector, atLeast: 15_000, timeout: 5.0),
                      "换新后端后应能正常出样本，实际 \(collector.count)")

        let samples = recorder.stopRecording()
        XCTAssertGreaterThanOrEqual(samples.count, 15_000, "实际 \(samples.count)")
        XCTAssertLessThanOrEqual(samples.count, 17_000, "实际 \(samples.count)")
    }

    // MARK: - #03 stop 卡死：样本不丢 + 上报 stop

    func test03_stopHang_returnsAggregatedSamples_firesOnWedgedStop() throws {
        let recorder = makeRecorder { SyntheticMicBackend(hangOnStop: true) }

        let wedged = expectation(description: "onWedged fired")
        var wedgedPhase: String?
        recorder.onWedged = { phase in
            wedgedPhase = phase
            wedged.fulfill()
        }

        let collector = SampleCollector()
        recorder.onSamplesCaptured = { collector.record($0) }

        try recorder.startRecording()
        XCTAssertTrue(waitForSamples(collector, atLeast: 15_000, timeout: 5.0),
                      "合成后端应能出满样本，实际 \(collector.count)")

        let started = Date()
        let samples = recorder.stopRecording()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.3, "stop 卡死时必须有界返回，实际耗时 \(elapsed)s")
        XCTAssertGreaterThanOrEqual(samples.count, 15_000, "stop 卡死也不能丢样本，实际 \(samples.count)")
        XCTAssertLessThanOrEqual(samples.count, 17_000, "实际 \(samples.count)")

        wait(for: [wedged], timeout: 2.0)
        XCTAssertEqual(wedgedPhase, "stop")
    }

    // MARK: - #04 双声道 48 kHz → 单声道 16 kHz 的 downmix + 重采样

    func test04_syntheticStereo48k_downmixResample_nonZero_callbackFired() throws {
        let recorder = makeRecorder { SyntheticMicBackend() }

        let collector = SampleCollector()
        recorder.onSamplesCaptured = { collector.record($0) }

        try recorder.startRecording()
        XCTAssertTrue(waitForSamples(collector, atLeast: 15_000, timeout: 5.0),
                      "实际 \(collector.count)")

        let samples = recorder.stopRecording()
        XCTAssertGreaterThanOrEqual(samples.count, 15_000, "实际 \(samples.count)")
        XCTAssertLessThanOrEqual(samples.count, 17_000, "实际 \(samples.count)")

        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 0.3, "downmix/重采样后不能衰减到近零，实际峰值 \(peak)")

        XCTAssertGreaterThanOrEqual(collector.callbackCount, 1)
        XCTAssertFalse(collector.sawMainThreadCallback, "onSamplesCaptured 不应在主线程触发")
    }

    // MARK: - #05 未启动时的并发 stop（镜像 ThreadSafetyTests #45）

    func test05_stopWithoutStart_10Concurrent_returnsEmptyFast() {
        let recorder = makeRecorder { SyntheticMicBackend() }

        let started = Date()
        let results = NSResultBox()
        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            let samples = recorder.stopRecording()
            results.append(samples.isEmpty)
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5, "未启动时 stop 必须立即返回，实际耗时 \(elapsed)s")
        XCTAssertEqual(results.values.count, 10)
        XCTAssertTrue(results.values.allSatisfy { $0 }, "未启动时 stop 应返回空样本")
    }
}

// MARK: - 小工具

private final class NSCounter {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class NSResultBox {
    private let lock = NSLock()
    private var _values: [Bool] = []

    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return _values }

    func append(_ value: Bool) {
        lock.lock(); _values.append(value); lock.unlock()
    }
}
