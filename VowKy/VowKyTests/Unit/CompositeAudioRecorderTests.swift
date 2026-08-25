import XCTest
@testable import VowKy

/// 混合模式的组合 recorder:启动顺序与回滚、两路混音累积、暂停转发、静音上报转发。
/// 两路都是 MockAudioRecorder,不碰真实音频设备。
@available(macOS 14.4, *)
final class CompositeAudioRecorderTests: XCTestCase {

    private var mic: MockAudioRecorder!
    private var system: MockAudioRecorder!
    private var composite: CompositeAudioRecorder!

    override func setUp() {
        super.setUp()
        mic = MockAudioRecorder()
        system = MockAudioRecorder()
        composite = CompositeAudioRecorder(micRecorder: mic, systemRecorder: system)
    }

    override func tearDown() {
        composite = nil
        mic = nil
        system = nil
        super.tearDown()
    }

    func test01_start_startsSystemBeforeMic() throws {
        // 脆弱的一路先起:系统声音失败时麦克风根本没被启动过(无须回滚)
        system.shouldThrowOnStart = true
        XCTAssertThrowsError(try composite.startRecording())
        XCTAssertEqual(system.startCallCount, 1)
        XCTAssertEqual(mic.startCallCount, 0)
        XCTAssertEqual(system.stopCallCount, 0)
    }

    func test02_micStartFailure_rollsBackSystemAndRethrows() {
        mic.shouldThrowOnStart = true
        mic.startError = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "麦克风启动失败"])

        XCTAssertThrowsError(try composite.startRecording()) { error in
            XCTAssertEqual((error as NSError).code, 7)
        }
        XCTAssertEqual(system.startCallCount, 1)
        XCTAssertEqual(system.stopCallCount, 1, "麦克风失败必须把已启动的系统声音停掉")
    }

    func test03_mixesBothStreams_andAccumulatesForStop() throws {
        mic.samplesToEmitOnStart = [Array(repeating: 0.1, count: 10)]
        system.samplesToEmitOnStart = [Array(repeating: 0.2, count: 10)]

        var delivered: [[Float]] = []
        composite.onSamplesCaptured = { delivered.append($0) }

        try composite.startRecording()
        let samples = composite.stopRecording()

        XCTAssertEqual(samples.count, 10)
        for sample in samples {
            XCTAssertEqual(sample, 0.3, accuracy: 1e-6)
        }
        XCTAssertEqual(delivered.flatMap { $0 }.count, 10, "混音段必须实时回调出去(下游 AsyncStream 消费)")
    }

    func test04_unevenStreams_tailFlushedOnStop() throws {
        mic.samplesToEmitOnStart = [Array(repeating: 0.1, count: 10)]
        system.samplesToEmitOnStart = [Array(repeating: 0.2, count: 6)]

        try composite.startRecording()
        let samples = composite.stopRecording()

        XCTAssertEqual(samples.count, 10, "对齐段 6 个 + 清尾 4 个,一个样本都不丢")
        XCTAssertEqual(samples[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(samples[5], 0.3, accuracy: 1e-6)
        XCTAssertEqual(samples[6], 0.1, accuracy: 1e-6, "系统声音已尽,尾段按静音补齐只剩麦克风")
        XCTAssertEqual(samples[9], 0.1, accuracy: 1e-6)
    }

    func test05_stopReturnsCompositeAccumulation_notChildSamples() throws {
        mic.samplesResult = Array(repeating: 0.9, count: 100)
        system.samplesResult = Array(repeating: 0.9, count: 100)
        mic.samplesToEmitOnStart = [Array(repeating: 0.1, count: 4)]
        system.samplesToEmitOnStart = [Array(repeating: 0.2, count: 4)]

        try composite.startRecording()
        let samples = composite.stopRecording()

        XCTAssertEqual(samples.count, 4, "子 recorder 自己累积的返回值必须丢弃")
        XCTAssertEqual(mic.stopCallCount, 1)
        XCTAssertEqual(system.stopCallCount, 1)
    }

    func test06_secondSessionStartsClean() throws {
        mic.samplesToEmitOnStart = [Array(repeating: 0.1, count: 4)]
        system.samplesToEmitOnStart = [Array(repeating: 0.2, count: 4)]

        try composite.startRecording()
        _ = composite.stopRecording()
        try composite.startRecording()
        let second = composite.stopRecording()

        XCTAssertEqual(second.count, 4, "上一会话的样本不得残留")
    }

    func test07_pauseResume_forwardsToBothRecorders() throws {
        try composite.startRecording()

        composite.pauseRecording()
        XCTAssertTrue(composite.isPaused)
        XCTAssertEqual(mic.pauseCallCount, 1)
        XCTAssertEqual(system.pauseCallCount, 1)

        composite.resumeRecording()
        XCTAssertFalse(composite.isPaused)
        XCTAssertEqual(mic.resumeCallCount, 1)
        XCTAssertEqual(system.resumeCallCount, 1)
    }

    func test08_audioLevel_isMaxOfBothRecorders() {
        mic.audioLevel = 0.2
        system.audioLevel = 0.7
        XCTAssertEqual(composite.audioLevel, 0.7, accuracy: 1e-6)

        mic.audioLevel = 0.9
        XCTAssertEqual(composite.audioLevel, 0.9, accuracy: 1e-6)
    }

    func test09_silenceReportFromSystemRecorder_isForwarded() {
        var reported: [Bool] = []
        composite.onSystemAudioSilenceChange = { reported.append($0) }

        system.onSystemAudioSilenceChange?(true)
        system.onSystemAudioSilenceChange?(false)

        XCTAssertEqual(reported, [true, false])
    }

    func test10_silenceReportFromMicRecorder_isNotForwarded() {
        var reported: [Bool] = []
        composite.onSystemAudioSilenceChange = { reported.append($0) }

        // 麦克风一路不接静音告警(告警只描述系统声音路)
        XCTAssertNil(mic.onSystemAudioSilenceChange)
        XCTAssertTrue(reported.isEmpty)
    }
}
