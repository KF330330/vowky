import Foundation
import AVFoundation
// 多 target 复用:测试 bundle 里 Protocols/CrashLogger 在 host 模块,需 @testable import;
// 在 tool target(helper/transcribe)里这些类型同模块,不可 import。
#if VOWKY_TEST_HOST
@testable import VowKy
#endif

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

    func recognizeDetailed(samples: [Float], sampleRate: Int) async -> DetailedRecognition? {
        guard let rec = recognizer, !samples.isEmpty else { return nil }
        guard let result = rec.decode(samples: samples, sampleRate: sampleRate) else {
            CrashLogger.log("[SpeechRecognizer] decode() returned nil")
            return nil
        }
        let text = result.text
        guard !text.isEmpty else { return nil }
        return DetailedRecognition(text: text, tokens: result.tokens, timestamps: result.timestamps)
    }

}
