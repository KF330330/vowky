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
        CrashLogger.log("[Audio] Input: rate=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) bits=\(inputFormat.streamDescription.pointee.mBitsPerChannel)")

        guard let targetFmt = targetFormat else {
            throw AudioRecorderError.formatCreationFailed
        }

        // 手动 downmix 多声道到单声道，再交给 AVAudioConverter 重采样。
        // 原因：某些虚拟音频驱动（腾讯会议 / Omi / Loopback / BlackHole 等）会把默认麦克风的
        // 声道数改成 3 或更多。AVAudioConverter 对这种非标准声道布局的自动 downmix 会输出全 0，
        // 导致录音静音、识别出乱码。先手动求平均到 mono，转换器只做 mono→mono 重采样最稳定。
        guard let monoInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatCreationFailed
        }

        guard let conv = AVAudioConverter(from: monoInputFormat, to: targetFmt) else {
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
            self?.processBuffer(buffer, converter: conv, monoInputFormat: monoInputFormat, targetFormat: targetFmt)
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
        CrashLogger.log("[Audio] samples=\(samples.count) duration=\(String(format: "%.1f", duration))s maxAmp=\(String(format: "%.4f", maxVal)) avgAmp=\(String(format: "%.6f", avgVal))")
        return samples
    }

    // MARK: - Private

    private func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        monoInputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) {
        // Step 1: 手动 downmix 多声道到 mono（求所有声道平均值）
        guard let inputData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        guard let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: monoInputFormat,
            frameCapacity: AVAudioFrameCount(frameLength)
        ) else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frameLength)
        guard let monoOut = monoBuffer.floatChannelData else { return }

        if channelCount == 1 {
            memcpy(monoOut[0], inputData[0], frameLength * MemoryLayout<Float>.size)
        } else {
            let invChannels = 1.0 / Float(channelCount)
            for i in 0..<frameLength {
                var sum: Float = 0
                for c in 0..<channelCount {
                    sum += inputData[c][i]
                }
                monoOut[0][i] = sum * invChannels
            }
        }

        // Step 2: 走 converter 做单声道→16kHz 单声道重采样
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = UInt32(Double(frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var error: NSError?
        var hasProvided = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvided = true
            outStatus.pointee = .haveData
            return monoBuffer
        }

        if let error = error {
            NSLog("[VowKy][Audio] Converter error: \(error)")
            return
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
