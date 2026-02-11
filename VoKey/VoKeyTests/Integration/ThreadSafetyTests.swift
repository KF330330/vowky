import XCTest
@testable import VoKey

// MARK: - T3: Thread Safety Tests (#44-46)

@MainActor
final class ThreadSafetyTests: XCTestCase {

    // MARK: - #44: 识别回调 UI 更新在主线程

    func test44_recognitionCallback_UIUpdateOnMainThread() async throws {
        let mockRecognizer = MockSpeechRecognizer()
        mockRecognizer.recognizeResult = "线程测试"
        // Add a small delay to simulate real async work
        mockRecognizer.recognizeDelay = 50_000_000 // 50ms

        let mockRecorder = MockAudioRecorder()
        let mockPermission = MockPermissionChecker()
        let appState = AppState(
            speechRecognizer: mockRecognizer,
            audioRecorder: mockRecorder,
            permissionChecker: mockPermission
        )

        // AppState is @MainActor, so all state updates are on main thread
        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing

        try await Task.sleep(nanoseconds: 200_000_000) // wait for recognition

        // If we get here without crash, MainActor enforcement is working
        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(appState.lastResult, "线程测试")

        // Verify the recognizer was called (it runs on a non-main thread via Task)
        XCTAssertEqual(mockRecognizer.recognizeCallCount, 1)
    }

    // MARK: - #45: 音频缓冲区线程安全

    func test45_audioBufferThreadSafety() {
        // Create a real AudioRecorder and test concurrent stop calls
        let recorder = AudioRecorder()

        let expectation = XCTestExpectation(description: "Concurrent stops complete")
        expectation.expectedFulfillmentCount = 10

        // Multiple concurrent stop calls should not crash
        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            _ = recorder.stopRecording()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        // If we reach here without crash, the test passes
    }

    // MARK: - #46: 并发 toggle 调用

    func test46_concurrentToggle_onlyOneEffective() async throws {
        let mockRecognizer = MockSpeechRecognizer()
        let mockRecorder = MockAudioRecorder()
        let mockPermission = MockPermissionChecker()
        let appState = AppState(
            speechRecognizer: mockRecognizer,
            audioRecorder: mockRecorder,
            permissionChecker: mockPermission
        )

        // Since AppState is @MainActor, concurrent calls are serialized
        // Dispatch multiple toggles rapidly on main thread
        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing
        appState.handleHotkeyToggle() // recognizing → ignored
        appState.handleHotkeyToggle() // recognizing → ignored

        // Only 1 start and 1 stop should have been called
        XCTAssertEqual(mockRecorder.startCallCount, 1, "Only one recording session should start")
        XCTAssertEqual(mockRecorder.stopCallCount, 1, "Only one stop should be called")

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(appState.state, .idle)
    }
}
