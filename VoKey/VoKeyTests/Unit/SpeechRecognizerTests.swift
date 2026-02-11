import XCTest
import AVFoundation
@testable import VoKey

/// Tests #1-7: SpeechRecognizer unit tests.
/// These tests require real model files (model.int8.onnx, tokens.txt) and test audio (0.wav)
/// bundled in the app's Resources.
final class SpeechRecognizerTests: XCTestCase {

    private var recognizer: LocalSpeechRecognizer!

    override func setUp() {
        super.setUp()
        recognizer = LocalSpeechRecognizer()
    }

    override func tearDown() {
        recognizer = nil
        super.tearDown()
    }

    // MARK: - Helper

    /// Load test WAV file from bundle and return samples at original sample rate.
    private func loadTestWavSamples() -> (samples: [Float], sampleRate: Int)? {
        guard let wavPath = Bundle.main.path(forResource: "0", ofType: "wav") else { return nil }
        let fileURL = URL(fileURLWithPath: wavPath)
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        try? audioFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return (samples, Int(format.sampleRate))
    }

    // MARK: - #1 Model loads successfully (isReady=true)

    func testModelLoadSuccess_isReadyTrue() {
        XCTAssertFalse(recognizer.isReady)
        recognizer.loadModel()
        XCTAssertTrue(recognizer.isReady, "Model should be ready after loadModel() with bundled resources")
    }

    // MARK: - #2 Recognize normal text

    func testRecognizeNormalText() async {
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready - cannot run recognition test")
            return
        }

        guard let wav = loadTestWavSamples() else {
            XCTFail("Test audio 0.wav not found in bundle")
            return
        }

        let result = await recognizer.recognize(samples: wav.samples, sampleRate: wav.sampleRate)
        XCTAssertNotNil(result, "Recognition should return non-nil for valid audio")
        XCTAssertFalse(result!.isEmpty, "Recognition result should not be empty")
    }

    // MARK: - #3 Empty audio returns nil

    func testEmptyAudio_returnsNil() async {
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        let result = await recognizer.recognize(samples: [], sampleRate: 16000)
        XCTAssertNil(result, "Empty audio should return nil")
    }

    // MARK: - #4 Silent audio handling

    func testSilentAudio_handledGracefully() async {
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        // 1 second of silence at 16kHz
        let silentSamples = [Float](repeating: 0.0, count: 16000)
        let result = await recognizer.recognize(samples: silentSamples, sampleRate: 16000)
        // Silent audio may return nil or empty-ish text; should not crash
        // The key assertion is that we get here without crashing
        XCTAssertTrue(true, "Silent audio should not crash")
        if let text = result {
            // If there is a result, it's acceptable
            _ = text
        }
    }

    // MARK: - #5 Recognition performance (<3 seconds)

    func testRecognitionPerformance_under3Seconds() async {
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        guard let wav = loadTestWavSamples() else {
            XCTFail("Test audio not found")
            return
        }

        let start = CFAbsoluteTimeGetCurrent()
        _ = await recognizer.recognize(samples: wav.samples, sampleRate: wav.sampleRate)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 3.0, "Recognition should complete in under 3 seconds, took \(elapsed)s")
    }

    // MARK: - #6 Multiple consecutive recognitions

    func testMultipleConsecutiveRecognitions() async {
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        guard let wav = loadTestWavSamples() else {
            XCTFail("Test audio not found")
            return
        }

        for i in 1...3 {
            let result = await recognizer.recognize(samples: wav.samples, sampleRate: wav.sampleRate)
            XCTAssertNotNil(result, "Recognition #\(i) should return non-nil")
        }
    }

    // MARK: - #7 Large audio file

    func testLargeAudioFile() async {
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        // 10 seconds of random low-amplitude noise at 16kHz
        let largeSamples = (0..<160000).map { _ in Float.random(in: -0.01...0.01) }
        let result = await recognizer.recognize(samples: largeSamples, sampleRate: 16000)
        // Should not crash on large input; result may be nil or empty for noise
        XCTAssertTrue(true, "Large audio should not crash")
        _ = result
    }
}
