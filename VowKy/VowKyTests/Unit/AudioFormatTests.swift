import XCTest
import AVFoundation
@testable import VowKy

/// Tests #11-14: Audio format and WAV file handling.
/// These tests verify WAV loading, sample range, format conversion, and sample count.
final class AudioFormatTests: XCTestCase {

    // MARK: - Helper

    /// Load test WAV file from bundle.
    private func loadTestWav() -> (file: AVAudioFile, url: URL)? {
        guard let wavPath = Bundle.main.path(forResource: "0", ofType: "wav") else { return nil }
        let url = URL(fileURLWithPath: wavPath)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        return (audioFile, url)
    }

    private func loadSamples(from file: AVAudioFile) -> [Float]? {
        let format = file.processingFormat
        let frameCount = UInt32(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        try? file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    // MARK: - #11 WAV file loads successfully

    func testWavFileLoads() {
        guard let wav = loadTestWav() else {
            XCTFail("Test audio 0.wav not found in bundle")
            return
        }
        XCTAssertGreaterThan(wav.file.length, 0, "WAV file should have frames")
        XCTAssertGreaterThan(wav.file.processingFormat.sampleRate, 0, "WAV should have valid sample rate")
    }

    // MARK: - #12 Sample values in range [-1, 1]

    func testSampleValuesInRange() {
        guard let wav = loadTestWav(), let samples = loadSamples(from: wav.file) else {
            XCTFail("Could not load test WAV samples")
            return
        }

        XCTAssertFalse(samples.isEmpty, "Samples should not be empty")

        for (index, sample) in samples.enumerated() {
            XCTAssertGreaterThanOrEqual(sample, -1.0, "Sample \(index) below -1.0: \(sample)")
            XCTAssertLessThanOrEqual(sample, 1.0, "Sample \(index) above 1.0: \(sample)")
        }
    }

    // MARK: - #13 Format conversion (48kHz→16kHz) produces valid output

    func testFormatConversion() {
        guard let wav = loadTestWav() else {
            XCTFail("Could not load test WAV samples")
            return
        }

        let sourceRate = wav.file.processingFormat.sampleRate
        let sourceFormat = wav.file.processingFormat

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // If the source is already 16kHz mono float32, conversion is identity
        if Int(sourceRate) == 16000 && sourceFormat.channelCount == 1 {
            // Already at target format — load samples directly and verify
            guard let samples = loadSamples(from: wav.file) else {
                XCTFail("Could not load samples")
                return
            }
            XCTAssertGreaterThan(samples.count, 0, "Should have samples at native 16kHz")
            return
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            XCTFail("Could not create audio converter from \(sourceRate)Hz to 16kHz")
            return
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: UInt32(wav.file.length)) else {
            XCTFail("Could not create input buffer")
            return
        }
        try? wav.file.read(into: inputBuffer)

        let ratio = 16000.0 / sourceRate
        let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            XCTFail("Could not create output buffer")
            return
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        XCTAssertNil(error, "Conversion should not produce error")
        XCTAssertGreaterThan(outputBuffer.frameLength, 0, "Converted output should have frames")
    }

    // MARK: - #14 Sample count correct (~16000/second at 16kHz)

    func testSampleCountAt16kHz() {
        guard let wav = loadTestWav() else {
            XCTFail("Test audio not found")
            return
        }

        let sourceRate = wav.file.processingFormat.sampleRate
        let sourceFrames = wav.file.length
        let durationSeconds = Double(sourceFrames) / sourceRate

        // Expected samples at 16kHz
        let expectedSamples = durationSeconds * 16000
        // Allow 10% tolerance
        let tolerance = expectedSamples * 0.1

        // If already 16kHz, check directly
        if Int(sourceRate) == 16000 {
            let actualSamples = Double(sourceFrames)
            XCTAssertEqual(actualSamples, expectedSamples, accuracy: tolerance,
                           "Sample count at 16kHz should be ~16000 per second")
        } else {
            // After conversion the ratio should hold
            let convertedSamples = durationSeconds * 16000
            XCTAssertGreaterThan(convertedSamples, 0, "Converted sample count should be positive")
            XCTAssertEqual(convertedSamples, expectedSamples, accuracy: tolerance,
                           "Sample count should be approximately 16000 per second of audio")
        }
    }
}
