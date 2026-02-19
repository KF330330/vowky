import XCTest
@testable import VowKy

// MARK: - T4: Audio Capture Tests (#57-60)
// Requires: Microphone permission

final class AudioCaptureTests: XCTestCase {

    // MARK: - #57: AVAudioEngine 启动成功

    func test57_engineStart_noThrow() throws {
        let recorder = AudioRecorder()

        do {
            try recorder.startRecording()
        } catch {
            throw XCTSkip("Microphone not available: \(error.localizedDescription)")
        }

        // If we get here, engine started successfully
        _ = recorder.stopRecording()
    }

    // MARK: - #58: 录音 1 秒获得 ~16000 样本

    func test58_recording1Second_getSamples() throws {
        let recorder = AudioRecorder()

        do {
            try recorder.startRecording()
        } catch {
            throw XCTSkip("Microphone not available: \(error.localizedDescription)")
        }

        // Record for 1 second
        let expectation = XCTestExpectation(description: "Recording for 1 second")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)

        let samples = recorder.stopRecording()

        // At 16kHz, 1 second should produce ~16000 samples (±2000 tolerance)
        XCTAssertGreaterThan(samples.count, 14000,
                             "Should have at least 14000 samples for 1 second, got \(samples.count)")
        XCTAssertLessThan(samples.count, 18000,
                           "Should have at most 18000 samples for 1 second, got \(samples.count)")
    }

    // MARK: - #59: 样本非全零

    func test59_samples_notAllZero() throws {
        let recorder = AudioRecorder()

        do {
            try recorder.startRecording()
        } catch {
            throw XCTSkip("Microphone not available: \(error.localizedDescription)")
        }

        // Record for 0.5 seconds
        let expectation = XCTestExpectation(description: "Recording for 0.5 seconds")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let samples = recorder.stopRecording()

        // At least some samples should be non-zero (ambient noise)
        let hasNonZero = samples.contains { $0 != 0 }
        XCTAssertTrue(hasNonZero, "Samples should contain non-zero values from ambient noise")
    }

    // MARK: - #60: 停止后 engine 状态正确

    func test60_engineStop_cleanState() throws {
        let recorder = AudioRecorder()

        do {
            try recorder.startRecording()
        } catch {
            throw XCTSkip("Microphone not available: \(error.localizedDescription)")
        }

        _ = recorder.stopRecording()

        // Should be able to start again after stop
        do {
            try recorder.startRecording()
            _ = recorder.stopRecording()
        } catch {
            XCTFail("Should be able to restart after stop: \(error.localizedDescription)")
        }
    }
}
