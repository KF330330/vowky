import XCTest
@testable import VowKy

// Mock classes are in Mocks/TestMocks.swift

// MARK: - AppState Tests (Toggle Mode)

@MainActor
final class AppStateTests: XCTestCase {

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

    // MARK: - #26: 初始状态 = idle

    func test01_initialStateIsIdle() {
        XCTAssertEqual(appState.state, .idle)
        XCTAssertNil(appState.errorMessage)
        XCTAssertNil(appState.lastResult)
    }

    // MARK: - #27: idle → recording (toggle once)

    func test02_idleToRecording() {
        appState.handleHotkeyToggle()

        XCTAssertEqual(appState.state, .recording)
        XCTAssertEqual(mockRecorder.startCallCount, 1)
    }

    // MARK: - #28: recording → recognizing (toggle twice)

    func test03_recordingToRecognizing() {
        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording)

        appState.handleHotkeyToggle() // recording → recognizing
        XCTAssertEqual(appState.state, .recognizing)
        XCTAssertEqual(mockRecorder.stopCallCount, 1)
    }

    // MARK: - #29: recognizing 中 toggle → 忽略

    func test04_toggleDuringRecognizingIsIgnored() {
        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing
        XCTAssertEqual(appState.state, .recognizing)

        appState.handleHotkeyToggle() // should be ignored
        XCTAssertEqual(appState.state, .recognizing)
        XCTAssertEqual(mockRecorder.startCallCount, 1)
        XCTAssertEqual(mockRecorder.stopCallCount, 1)
    }

    // MARK: - #30: 快速连按 toggle → 状态不混乱

    func test05_rapidTogglesDoNotCorruptState() {
        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording)

        appState.handleHotkeyToggle() // recording → recognizing
        XCTAssertEqual(appState.state, .recognizing)

        // While recognizing, additional toggles should be ignored
        appState.handleHotkeyToggle()
        XCTAssertEqual(appState.state, .recognizing)

        appState.handleHotkeyToggle()
        XCTAssertEqual(appState.state, .recognizing)

        // Only 1 start and 1 stop should have been called
        XCTAssertEqual(mockRecorder.startCallCount, 1)
        XCTAssertEqual(mockRecorder.stopCallCount, 1)
    }

    // MARK: - #33: 识别返回 nil → 不粘贴，回 idle

    func test06_recognizeReturnsNilGoesBackToIdle() async throws {
        mockRecognizer.recognizeResult = nil

        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing
        XCTAssertEqual(appState.state, .recognizing)

        // Wait for async recognition to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        XCTAssertEqual(appState.state, .idle)
        XCTAssertNil(appState.lastResult)
    }

    // MARK: - #34: 识别返回空字符串 → 不粘贴，回 idle

    func test07_recognizeReturnsEmptyStringGoesBackToIdle() async throws {
        mockRecognizer.recognizeResult = ""

        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing
        XCTAssertEqual(appState.state, .recognizing)

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        XCTAssertEqual(appState.state, .idle)
        XCTAssertNil(appState.lastResult)
    }

    // MARK: - #35: 录音启动失败 → 回 idle + 显示错误

    func test08_recordingStartFailureGoesBackToIdleWithError() {
        mockRecorder.shouldThrowOnStart = true

        appState.handleHotkeyToggle()

        XCTAssertEqual(appState.state, .idle)
        XCTAssertNotNil(appState.errorMessage)
    }

    // MARK: - #36: 识别异常 → 回 idle

    func test09_recognitionFailureGoesBackToIdle() async throws {
        // Simulate recognition returning nil (as if an error occurred)
        mockRecognizer.recognizeResult = nil

        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        XCTAssertEqual(appState.state, .idle)
    }

    // MARK: - #37: 连续错误后仍可用

    func test10_usableAfterConsecutiveErrors() async throws {
        // First attempt: recording fails
        mockRecorder.shouldThrowOnStart = true
        appState.handleHotkeyToggle()
        XCTAssertEqual(appState.state, .idle)
        XCTAssertNotNil(appState.errorMessage)

        // Second attempt: recording fails again
        appState.handleHotkeyToggle()
        XCTAssertEqual(appState.state, .idle)

        // Third attempt: recording succeeds, recognition returns nil
        mockRecorder.shouldThrowOnStart = false
        mockRecognizer.recognizeResult = nil
        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording)

        appState.handleHotkeyToggle() // recording → recognizing
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertEqual(appState.state, .idle)

        // Fourth attempt: full success
        mockRecognizer.recognizeResult = "成功"
        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording)

        appState.handleHotkeyToggle() // recording → recognizing
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(appState.lastResult, "成功")
    }

    // MARK: - #83: 模型加载中按快捷键 → 显示"语音模型加载中..."

    func test11_hotkeyDuringModelLoadingShowsMessage() {
        mockRecognizer.isReady = false
        appState.state = .loading

        appState.handleHotkeyToggle()

        XCTAssertEqual(appState.state, .loading) // state unchanged
        XCTAssertEqual(appState.errorMessage, "语音模型加载中...")
        XCTAssertEqual(mockRecorder.startCallCount, 0) // no recording started
    }

    // MARK: - #84: outputting 中按快捷键 → 忽略

    func test12_hotkeyDuringOutputtingIsIgnored() {
        appState.state = .outputting

        appState.handleHotkeyToggle()

        XCTAssertEqual(appState.state, .outputting) // state unchanged
        XCTAssertEqual(mockRecorder.startCallCount, 0)
    }

    // MARK: - #82: 麦克风被占用 → 回 idle + 错误提示

    func test13_microphoneBusyGoesBackToIdleWithError() {
        mockRecorder.shouldThrowOnStart = true
        mockRecorder.startError = NSError(
            domain: "MockAudioRecorder",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "麦克风被其他应用占用"]
        )

        appState.handleHotkeyToggle()

        XCTAssertEqual(appState.state, .idle)
        XCTAssertNotNil(appState.errorMessage)
    }

    // MARK: - #91: 辅助功能权限被拒 → 显示引导 UI、不崩溃、不录音

    func test14_accessibilityDeniedShowsGuidanceAndDoesNotRecord() {
        mockPermission.accessibilityGranted = false

        appState.handleHotkeyToggle()

        XCTAssertEqual(appState.state, .idle) // stays idle
        XCTAssertNotNil(appState.errorMessage) // shows guidance
        XCTAssertEqual(mockRecorder.startCallCount, 0) // no recording started
    }

    // MARK: - Full cycle: idle → recording → recognizing → idle

    func test15_fullCycleReturnsToIdle() async throws {
        mockRecognizer.recognizeResult = "你好世界"

        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording)

        appState.handleHotkeyToggle() // recording → recognizing
        XCTAssertEqual(appState.state, .recognizing)

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(appState.lastResult, "你好世界")
    }

    // MARK: - Two consecutive full cycles

    func test16_twoConsecutiveFullCycles() async throws {
        // First cycle
        mockRecognizer.recognizeResult = "第一次"
        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(appState.lastResult, "第一次")

        // Second cycle
        mockRecognizer.recognizeResult = "第二次"
        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording)
        appState.handleHotkeyToggle() // recording → recognizing
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(appState.lastResult, "第二次")

        XCTAssertEqual(mockRecorder.startCallCount, 2)
        XCTAssertEqual(mockRecorder.stopCallCount, 2)
    }
}
