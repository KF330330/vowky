import AVFoundation
import XCTest
@testable import VowKy

final class MediaAudioDecoderTests: XCTestCase {
    func testDecodeGeneratedWavOutputs16kMonoFloatSamples() async throws {
        let url = temporaryURL(extension: "wav")
        try writeToneAudio(to: url, formatID: kAudioFormatLinearPCM)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try await MediaAudioDecoder().decode(url: url)

        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertGreaterThan(decoded.samples.count, 10_000)
        XCTAssertLessThanOrEqual(decoded.samples.map { abs($0) }.max() ?? 0, 1)
    }

    func testDecodeGeneratedM4AOutputs16kMonoFloatSamples() async throws {
        let url = temporaryURL(extension: "m4a")
        try writeToneAudio(to: url, formatID: kAudioFormatMPEG4AAC)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try await MediaAudioDecoder().decode(url: url)

        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertGreaterThan(decoded.samples.count, 10_000)
        XCTAssertLessThanOrEqual(decoded.samples.map { abs($0) }.max() ?? 0, 1)
    }

    func testDecodeGenerated16kWavUsesCompatibleOutputPath() async throws {
        let url = temporaryURL(extension: "wav")
        try writeToneAudio(to: url, formatID: kAudioFormatLinearPCM, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try await MediaAudioDecoder().decode(
            url: url,
            timeRange: MediaAudioTimeRange(start: 0, duration: 0.5)
        )

        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertGreaterThan(decoded.samples.count, 7_000)
        XCTAssertLessThanOrEqual(decoded.samples.map { abs($0) }.max() ?? 0, 1)
    }

    func testDecodeGeneratedM4ATimeRangeOutputsSamples() async throws {
        let url = temporaryURL(extension: "m4a")
        try writeToneAudio(to: url, formatID: kAudioFormatMPEG4AAC)
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try await MediaAudioDecoder().loadInfo(url: url)
        let decoded = try await MediaAudioDecoder().decode(
            url: url,
            timeRange: MediaAudioTimeRange(start: 0.25, duration: 0.4)
        )

        XCTAssertGreaterThan(info.duration, 0.8)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertGreaterThan(decoded.samples.count, 2_000)
        XCTAssertLessThanOrEqual(decoded.duration, 0.6)
    }

    func testDecodeLocalMP4RegressionFileWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["VOWKY_TEST_MEDIA_FILE"],
              !path.isEmpty else {
            throw XCTSkip("Set VOWKY_TEST_MEDIA_FILE to a local MP4/MOV file to run this regression test")
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Configured regression media file does not exist")
        }

        let decoded = try await MediaAudioDecoder().decode(
            url: url,
            timeRange: MediaAudioTimeRange(start: 0, duration: 30)
        )

        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertGreaterThan(decoded.samples.count, 10_000)
        XCTAssertLessThanOrEqual(decoded.samples.map { abs($0) }.max() ?? 0, 1)
        XCTAssertLessThanOrEqual(decoded.duration, 30)
    }

    func testDecodeEmptyFileReturnsClearError() async throws {
        let url = temporaryURL(extension: "mp3")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await MediaAudioDecoder().decode(url: url)
            XCTFail("Expected decoder to reject empty file")
        } catch {
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    func testDecodeUnsupportedExtensionReturnsError() async {
        let url = temporaryURL(extension: "txt")

        do {
            _ = try await MediaAudioDecoder().decode(url: url)
            XCTFail("Expected unsupported extension error")
        } catch let error as MediaAudioDecoderError {
            XCTAssertEqual(error, .unsupportedFileType("txt"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    private func writeToneAudio(
        to url: URL,
        formatID: AudioFormatID,
        sampleRate: Double = 44_100
    ) throws {
        let frameCount = AVAudioFrameCount(sampleRate)
        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]

        if formatID == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        } else {
            settings[AVEncoderBitRateKey] = 64_000
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Could not create audio buffer")
            return
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else {
            XCTFail("Could not access float channel data")
            return
        }

        for index in 0..<Int(frameCount) {
            let phase = 2.0 * Double.pi * 440.0 * Double(index) / sampleRate
            channelData[0][index] = Float(sin(phase) * 0.3)
        }

        try file.write(from: buffer)
    }
}
