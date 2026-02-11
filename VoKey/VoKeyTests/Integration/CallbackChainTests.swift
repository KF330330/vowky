import XCTest
@testable import VoKey

// MARK: - T3: Callback Chain Tests (#38-43)

@MainActor
final class CallbackChainTests: XCTestCase {

    var mockRecognizer: MockSpeechRecognizer!
    var mockRecorder: MockAudioRecorder!
    var mockPermission: MockPermissionChecker!
    var appState: AppState!

    @MainActor
    override func setUp() {
        super.setUp()
        mockRecognizer = MockSpeechRecognizer()
        mockRecorder = MockAudioRecorder()
        mockPermission = MockPermissionChecker()
        appState = AppState(
            speechRecognizer: mockRecognizer,
            audioRecorder: mockRecorder,
            permissionChecker: mockPermission
        )
    }

    @MainActor
    override func tearDown() {
        appState = nil
        mockRecognizer = nil
        mockRecorder = nil
        mockPermission = nil
        super.tearDown()
    }

    // MARK: - #38: Toggle → AppState.startRecording 被调用

    func test38_toggleFromIdle_startsRecording() {
        appState.handleHotkeyToggle()

        XCTAssertEqual(mockRecorder.startCallCount, 1, "startRecording should be called once")
        XCTAssertEqual(appState.state, .recording)
    }

    // MARK: - #39: Toggle → AppState.stopAndRecognize 被调用

    func test39_toggleFromRecording_stopsAndRecognizes() async throws {
        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing

        XCTAssertEqual(mockRecorder.stopCallCount, 1, "stopRecording should be called once")

        try await Task.sleep(nanoseconds: 100_000_000) // wait for async recognition

        XCTAssertEqual(mockRecognizer.recognizeCallCount, 1, "recognize should be called once")
    }

    // MARK: - #40: AudioRecorder.stop → 样本传给 SpeechRecognizer

    func test40_samplesPassedToRecognizer() async throws {
        let testSamples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        mockRecorder.samplesResult = testSamples

        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mockRecognizer.lastReceivedSamples, testSamples, "Recognizer should receive exact samples from recorder")
        XCTAssertEqual(mockRecognizer.lastReceivedSampleRate, 16000, "Sample rate should be 16000")
    }

    // MARK: - #41: SpeechRecognizer 结果 → TextOutputService (lastResult)

    func test41_recognitionResult_setsLastResult() async throws {
        mockRecognizer.recognizeResult = "测试文字"

        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appState.lastResult, "测试文字", "lastResult should be set with recognition result")
    }

    // MARK: - #42: 输出 → RecordingPanel 显示结果 (via Published)

    func test42_recognitionResult_updatesPublishedState() async throws {
        mockRecognizer.recognizeResult = "你好世界"

        var stateChanges: [AppState.State] = []
        let cancellable = appState.$state
            .sink { stateChanges.append($0) }

        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing

        try await Task.sleep(nanoseconds: 200_000_000) // wait for full cycle

        cancellable.cancel()

        // Should have gone through: idle → recording → recognizing → idle
        XCTAssertTrue(stateChanges.contains(.recording), "Should have been in recording state")
        XCTAssertTrue(stateChanges.contains(.recognizing), "Should have been in recognizing state")
        XCTAssertEqual(stateChanges.last, .idle, "Should end in idle state")
        XCTAssertEqual(appState.lastResult, "你好世界")
    }

    // MARK: - #43: 完整链路 Toggle→录音→Toggle→识别→输出→idle

    func test43_fullChain_toggleToIdleComplete() async throws {
        mockRecognizer.recognizeResult = "完整链路测试"
        mockRecorder.samplesResult = Array(repeating: 0.3, count: 16000)

        // Start recording
        appState.handleHotkeyToggle()
        XCTAssertEqual(appState.state, .recording)
        XCTAssertEqual(mockRecorder.startCallCount, 1)

        // Stop and recognize
        appState.handleHotkeyToggle()
        XCTAssertEqual(appState.state, .recognizing)
        XCTAssertEqual(mockRecorder.stopCallCount, 1)

        // Wait for async recognition
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify final state
        XCTAssertEqual(appState.state, .idle, "Should return to idle after full chain")
        XCTAssertEqual(appState.lastResult, "完整链路测试")
        XCTAssertEqual(mockRecognizer.recognizeCallCount, 1)
        XCTAssertEqual(mockRecognizer.lastReceivedSamples.count, 16000)
    }
}
