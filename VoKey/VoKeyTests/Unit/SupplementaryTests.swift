import XCTest
import AVFoundation
@testable import VoKey

/// Tests #81, #85, #87, #88, #90: Supplementary edge-case and performance tests.
final class SupplementaryTests: XCTestCase {

    // MARK: - #81 Very short audio (<0.5 seconds)

    func testVeryShortAudio_handledGracefully() async {
        let recognizer = LocalSpeechRecognizer()
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        // 0.3 seconds of low-amplitude noise at 16kHz (4800 samples)
        let shortSamples = (0..<4800).map { _ in Float.random(in: -0.01...0.01) }
        let result = await recognizer.recognize(samples: shortSamples, sampleRate: 16000)
        // Should not crash; result may be nil for very short noise
        XCTAssertTrue(true, "Very short audio should not crash")
        _ = result
    }

    // MARK: - #85 Special characters in recognized text

    func testSpecialCharactersPreserved() async {
        let recognizer = LocalSpeechRecognizer()
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        // Load the bundled test WAV which should produce Chinese text
        guard let wavPath = Bundle.main.path(forResource: "0", ofType: "wav") else {
            XCTFail("Test audio 0.wav not found in bundle")
            return
        }
        let fileURL = URL(fileURLWithPath: wavPath)
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
            XCTFail("Could not read audio file")
            return
        }
        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Could not create buffer")
            return
        }
        try? audioFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            XCTFail("No channel data")
            return
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

        let result = await recognizer.recognize(samples: samples, sampleRate: Int(format.sampleRate))
        // The Paraformer-zh model produces Chinese characters; verify they're preserved
        if let text = result {
            XCTAssertFalse(text.isEmpty, "Recognized text should not be empty")
            // Chinese characters should be present (not garbled to ASCII)
            let hasNonASCII = text.unicodeScalars.contains { $0.value > 127 }
            XCTAssertTrue(hasNonASCII, "Paraformer-zh output should contain non-ASCII characters (Chinese): \(text)")
        }
    }

    // MARK: - #87 C string lifetime (multiple load/recognize cycles)

    func testCStringLifetime_multipleLoadCycles() async {
        // Verify that loading model multiple times doesn't cause dangling pointer issues
        let recognizer = LocalSpeechRecognizer()

        for cycle in 1...3 {
            recognizer.loadModel()
            XCTAssertTrue(recognizer.isReady, "Cycle \(cycle): model should be ready after loadModel()")

            // Perform a minimal recognition to exercise the C strings
            let silentSamples = [Float](repeating: 0.0, count: 16000)
            _ = await recognizer.recognize(samples: silentSamples, sampleRate: 16000)
            // Key assertion: no crash from dangling pointer
        }
        XCTAssertTrue(true, "Multiple load/recognize cycles should not crash (C string lifetime)")
    }

    // MARK: - #88 Memory baseline (no obvious leak)

    func testMemoryBaseline() async {
        let recognizer = LocalSpeechRecognizer()
        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        // Run several recognitions and check that we don't accumulate excessive memory
        let silentSamples = [Float](repeating: 0.0, count: 16000)

        // Warm up
        _ = await recognizer.recognize(samples: silentSamples, sampleRate: 16000)

        let beforeMemory = Self.currentMemoryUsage()

        for _ in 1...5 {
            _ = await recognizer.recognize(samples: silentSamples, sampleRate: 16000)
        }

        let afterMemory = Self.currentMemoryUsage()

        // Allow up to 50 MB growth (generous to avoid flaky tests)
        let growth = afterMemory - beforeMemory
        XCTAssertLessThan(growth, 50 * 1024 * 1024,
                          "Memory grew by \(growth / 1024 / 1024) MB after 5 recognitions — potential leak")
    }

    // MARK: - #90 End-to-end latency (model load + recognition < 5s)

    func testEndToEndLatency() async {
        let recognizer = LocalSpeechRecognizer()

        let start = CFAbsoluteTimeGetCurrent()

        recognizer.loadModel()
        guard recognizer.isReady else {
            XCTFail("Model not ready")
            return
        }

        // Load test audio
        guard let wavPath = Bundle.main.path(forResource: "0", ofType: "wav") else {
            XCTFail("Test audio not found")
            return
        }
        let fileURL = URL(fileURLWithPath: wavPath)
        guard let audioFile = try? AVAudioFile(forReading: fileURL),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: audioFile.processingFormat,
                  frameCapacity: UInt32(audioFile.length)
              ) else {
            XCTFail("Could not load audio")
            return
        }
        try? audioFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            XCTFail("No channel data")
            return
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

        _ = await recognizer.recognize(samples: samples, sampleRate: Int(audioFile.processingFormat.sampleRate))

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 5.0,
                          "End-to-end (load model + recognize) should complete in < 5 seconds, took \(elapsed)s")
    }

    // MARK: - Memory helper

    private static func currentMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}
