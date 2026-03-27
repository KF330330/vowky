import Foundation
import AVFoundation

final class LocalSpeechRecognizer: SpeechRecognizerProtocol {

    private var recognizer: SherpaOnnxOfflineRecognizer?

    // Keep path strings alive to avoid C dangling pointers
    private var modelPathString: String = ""
    private var tokensPathString: String = ""

    var isReady: Bool { recognizer != nil }

    /// Load the model from the specified paths.
    /// If paths are nil, defaults to Bundle.main resources.
    func loadModel(modelPath: String? = nil, tokensPath: String? = nil) {
        let model = modelPath ?? Bundle.main.path(forResource: "model.int8", ofType: "onnx") ?? ""
        let tokens = tokensPath ?? Bundle.main.path(forResource: "tokens", ofType: "txt") ?? ""

        NSLog("[VowKy][SpeechRecognizer] loadModel() called")
        NSLog("[VowKy][SpeechRecognizer] model path: \(model)")
        NSLog("[VowKy][SpeechRecognizer] tokens path: \(tokens)")

        guard !model.isEmpty, !tokens.isEmpty,
              FileManager.default.fileExists(atPath: model),
              FileManager.default.fileExists(atPath: tokens) else {
            NSLog("[VowKy][SpeechRecognizer] ERROR: Model or tokens file not found!")
            return
        }

        // Store as instance properties to keep C strings alive
        self.modelPathString = model
        self.tokensPathString = tokens

        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: self.modelPathString,
            language: "auto",
            useInverseTextNormalization: true
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: self.tokensPathString,
            debug: 0,
            modelType: "sense_voice",
            senseVoice: senseVoiceConfig
        )

        let featConfig = sherpaOnnxFeatureConfig(
            sampleRate: 16000,
            featureDim: 80
        )

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig
        )

        self.recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        NSLog("[VowKy][SpeechRecognizer] Model loaded: \(self.recognizer != nil ? "SUCCESS" : "FAILED")")
    }

    func recognize(samples: [Float], sampleRate: Int) async -> String? {
        guard let rec = recognizer else {
            NSLog("[VowKy][SpeechRecognizer] recognize() called but recognizer is nil!")
            return nil
        }
        guard !samples.isEmpty else {
            NSLog("[VowKy][SpeechRecognizer] recognize() called with empty samples")
            return nil
        }

        // 诊断：保存识别前的音频为 WAV 文件
        let diagDir = NSHomeDirectory() + "/Library/Application Support/VowKy"
        let diagPath = diagDir + "/diag_audio.wav"
        saveSamplesAsWAV(samples: samples, sampleRate: sampleRate, to: diagPath)
        NSLog("[VowKy][SpeechRecognizer] Saved diagnostic audio to: \(diagPath)")

        // 诊断：记录音频振幅统计
        let maxAmp = samples.map { abs($0) }.max() ?? 0
        let avgAmp = samples.reduce(Float(0)) { $0 + abs($1) } / Float(samples.count)
        CrashLogger.log("[Diag] samples=\(samples.count) maxAmp=\(String(format: "%.4f", maxAmp)) avgAmp=\(String(format: "%.6f", avgAmp))")

        NSLog("[VowKy][SpeechRecognizer] recognize() start: \(samples.count) samples at \(sampleRate)Hz")
        guard let result = rec.decode(samples: samples, sampleRate: sampleRate) else {
            CrashLogger.log("[SpeechRecognizer] decode() returned nil")
            NSLog("[VowKy][SpeechRecognizer] decode() returned nil")
            return nil
        }
        let text = result.text
        NSLog("[VowKy][SpeechRecognizer] Raw recognition result: '\(text)'")
        return text.isEmpty ? nil : text
    }

    // MARK: - 诊断工具（临时）

    private func saveSamplesAsWAV(samples: [Float], sampleRate: Int, to path: String) {
        let url = URL(fileURLWithPath: path)
        let dataSize = samples.count * 2
        let fileSize = 36 + dataSize

        var data = Data()
        // RIFF header
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        var fileSizeLE = UInt32(fileSize).littleEndian
        data.append(Data(bytes: &fileSizeLE, count: 4))
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        // fmt chunk
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        data.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var channels = UInt16(1).littleEndian
        data.append(Data(bytes: &channels, count: 2))
        var sr = UInt32(sampleRate).littleEndian
        data.append(Data(bytes: &sr, count: 4))
        var byteRate = UInt32(sampleRate * 2).littleEndian
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(2).littleEndian
        data.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian
        data.append(Data(bytes: &bitsPerSample, count: 2))
        // data chunk
        data.append(contentsOf: [UInt8]("data".utf8))
        var dataSizeLE = UInt32(dataSize).littleEndian
        data.append(Data(bytes: &dataSizeLE, count: 4))
        // samples
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767).littleEndian
            data.append(Data(bytes: &int16, count: 2))
        }
        try? data.write(to: url)
    }
}
