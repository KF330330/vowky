import Foundation
import AVFoundation

final class AudioRecorder: AudioRecorderProtocol {

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var recordedSamples: [Float] = []
    private let lock = NSLock()

    /// Optional backup service for content protection
    var backupService: AudioBackupProtocol?

    private(set) var audioLevel: Float = 0

    private let targetSampleRate: Double = 16000

    private lazy var targetFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
    }()

    func startRecording() throws {
        NSLog("[VowKy][Audio] startRecording() called")
        // Support VOWKY_TEST_AUDIO env var for testing
        if let testAudioDir = ProcessInfo.processInfo.environment["VOWKY_TEST_AUDIO"] {
            try startFromTestAudio(directory: testAudioDir)
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        NSLog("[VowKy][Audio] Input format: sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) bitsPerChannel=\(inputFormat.streamDescription.pointee.mBitsPerChannel)")
        NSLog("[VowKy][Audio] Target format: sampleRate=\(targetSampleRate) channels=1 Float32")

        guard let targetFmt = targetFormat else {
            throw AudioRecorderError.formatCreationFailed
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFmt) else {
            throw AudioRecorderError.converterCreationFailed(
                sourceSampleRate: inputFormat.sampleRate,
                sourceChannels: inputFormat.channelCount
            )
        }

        self.converter = conv

        lock.lock()
        recordedSamples = []
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer, converter: conv, targetFormat: targetFmt)
        }

        do {
            try engine.start()
        } catch {
            throw AudioRecorderError.engineStartFailed(error)
        }

        self.engine = engine
    }

    func stopRecording() -> [Float] {
        NSLog("[VowKy][Audio] stopRecording() called")
        guard let engine = self.engine else {
            NSLog("[VowKy][Audio] No engine — returning empty samples")
            return []
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.converter = nil

        lock.lock()
        let samples = recordedSamples
        recordedSamples = []
        lock.unlock()

        audioLevel = 0
        // 统计音频采样信息，帮助诊断是否录到有效音频
        let maxVal = samples.map { abs($0) }.max() ?? 0
        let avgVal = samples.isEmpty ? 0 : samples.map { abs($0) }.reduce(0, +) / Float(samples.count)
        let duration = Double(samples.count) / targetSampleRate
        NSLog("[VowKy][Audio] Returning \(samples.count) samples (duration=\(String(format: "%.1f", duration))s, maxAmp=\(String(format: "%.4f", maxVal)), avgAmp=\(String(format: "%.6f", avgVal)))")
        return samples
    }

    // MARK: - Private

    private func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = UInt32(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard let data = outputBuffer.floatChannelData else { return }

        let samples = Array(UnsafeBufferPointer(
            start: data[0],
            count: Int(outputBuffer.frameLength)
        ))

        // Compute RMS audio level
        let rms = computeRMS(samples)

        lock.lock()
        recordedSamples.append(contentsOf: samples)
        lock.unlock()

        // Write to backup file for content protection
        backupService?.appendSamples(samples)

        audioLevel = rms
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    /// Load test audio from a directory (for VOWKY_TEST_AUDIO env var support)
    private func startFromTestAudio(directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        let wavFiles = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "wav" } ?? []

        guard let firstWav = wavFiles.first else {
            throw AudioRecorderError.testAudioNotFound(directory)
        }

        guard let audioFile = try? AVAudioFile(forReading: firstWav) else {
            throw AudioRecorderError.testAudioNotFound(directory)
        }

        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioRecorderError.formatCreationFailed
        }

        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw AudioRecorderError.formatCreationFailed
        }

        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))

        lock.lock()
        recordedSamples = samples
        lock.unlock()
    }
}

enum AudioRecorderError: Error {
    case formatCreationFailed
    case converterCreationFailed(sourceSampleRate: Double, sourceChannels: UInt32)
    case engineStartFailed(Error)
    case testAudioNotFound(String)
}
