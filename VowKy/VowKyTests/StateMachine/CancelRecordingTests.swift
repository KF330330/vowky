import XCTest
@testable import VowKy

@MainActor
final class CancelRecordingTests: XCTestCase {

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

    // 录音中取消 → 回到 idle
    func testCancelDuringRecording_returnsToIdle() {
        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording)

        appState.cancelRecording()
        XCTAssertEqual(appState.state, .idle, "Should return to idle after cancel")
        XCTAssertEqual(mockRecorder.stopCallCount, 1, "Should have stopped recording")
    }

    // idle 状态取消 → 无效果
    func testCancelWhenIdle_isIgnored() {
        XCTAssertEqual(appState.state, .idle)
        appState.cancelRecording()
        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(mockRecorder.stopCallCount, 0, "Should not call stop when not recording")
    }

    // recognizing 状态取消 → 无效果
    func testCancelWhenRecognizing_isIgnored() {
        mockRecognizer.recognizeDelay = 1_000_000_000 // 1s delay
        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing

        XCTAssertEqual(appState.state, .recognizing)
        appState.cancelRecording()
        XCTAssertEqual(appState.state, .recognizing, "Should not cancel during recognition")
    }

    // 取消后可以正常开始新录音
    func testCancelThenNewRecording_works() {
        appState.handleHotkeyToggle() // idle → recording
        appState.cancelRecording()     // recording → idle
        XCTAssertEqual(appState.state, .idle)

        appState.handleHotkeyToggle() // idle → recording again
        XCTAssertEqual(appState.state, .recording, "Should be able to record again after cancel")
        XCTAssertEqual(mockRecorder.startCallCount, 2)
    }

    // 取消不设置 lastResult
    func testCancel_doesNotSetLastResult() {
        appState.handleHotkeyToggle() // idle → recording
        appState.cancelRecording()
        XCTAssertNil(appState.lastResult, "Cancel should not produce any result")
    }

    // 取消不设置 errorMessage
    func testCancel_doesNotSetError() {
        appState.handleHotkeyToggle() // idle → recording
        appState.cancelRecording()
        XCTAssertNil(appState.errorMessage, "Cancel should not produce any error")
    }
}
