import XCTest
@testable import VoKey

// MARK: - T4: CGEvent Simulation Tests (#76-77)

@MainActor
final class CGEventSimulationTests: XCTestCase {

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

    // MARK: - #76: 静默 toggle（不说话）→ 不卡死

    func test76_silentToggle_noHang() async throws {
        // Simulate: user presses toggle, doesn't speak, presses toggle again
        mockRecognizer.recognizeResult = nil // simulate no speech detected
        mockRecorder.samplesResult = Array(repeating: 0.0, count: 4800) // 0.3s of silence

        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording)

        // Wait 0.3s (simulating hold time with no speech)
        try await Task.sleep(nanoseconds: 300_000_000)

        appState.handleHotkeyToggle() // recording → recognizing
        XCTAssertEqual(appState.state, .recognizing)

        // Wait for recognition to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        // Should return to idle without error, no output
        XCTAssertEqual(appState.state, .idle, "Should return to idle after silent toggle")
        XCTAssertNil(appState.lastResult, "Should have no result for silent input")
        XCTAssertNil(appState.errorMessage, "Should have no error message")
    }

    // MARK: - #77: 连续快按 3 轮 → 状态正确

    func test77_rapidToggles_stateCorrect() async throws {
        mockRecognizer.recognizeResult = "快按测试"
        mockRecorder.samplesResult = Array(repeating: 0.1, count: 8000) // 0.5s audio

        // Round 1
        appState.handleHotkeyToggle() // idle → recording
        XCTAssertEqual(appState.state, .recording, "Round 1: should be recording")

        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        appState.handleHotkeyToggle() // recording → recognizing
        XCTAssertEqual(appState.state, .recognizing, "Round 1: should be recognizing")

        try await Task.sleep(nanoseconds: 200_000_000) // wait for recognition
        XCTAssertEqual(appState.state, .idle, "Round 1: should return to idle")

        // Round 2
        appState.handleHotkeyToggle()
        XCTAssertEqual(appState.state, .recording, "Round 2: should be recording")

        try await Task.sleep(nanoseconds: 100_000_000)

        appState.handleHotkeyToggle()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(appState.state, .idle, "Round 2: should return to idle")

        // Round 3
        appState.handleHotkeyToggle()
        XCTAssertEqual(appState.state, .recording, "Round 3: should be recording")

        try await Task.sleep(nanoseconds: 100_000_000)

        appState.handleHotkeyToggle()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(appState.state, .idle, "Round 3: should return to idle")

        // Verify counts
        XCTAssertEqual(mockRecorder.startCallCount, 3, "Should have started recording 3 times")
        XCTAssertEqual(mockRecorder.stopCallCount, 3, "Should have stopped recording 3 times")
        XCTAssertEqual(mockRecognizer.recognizeCallCount, 3, "Should have recognized 3 times")
    }
}
