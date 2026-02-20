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

        print("[VowKy][SpeechRecognizer] loadModel() called")
        print("[VowKy][SpeechRecognizer] model path: \(model)")
        print("[VowKy][SpeechRecognizer] tokens path: \(tokens)")

        guard !model.isEmpty, !tokens.isEmpty,
              FileManager.default.fileExists(atPath: model),
              FileManager.default.fileExists(atPath: tokens) else {
            print("[VowKy][SpeechRecognizer] ERROR: Model or tokens file not found!")
            return
        }

        // Store as instance properties to keep C strings alive
        self.modelPathString = model
        self.tokensPathString = tokens

        let paraformerConfig = sherpaOnnxOfflineParaformerModelConfig(
            model: self.modelPathString
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: self.tokensPathString,
            paraformer: paraformerConfig,
            debug: 0,
            modelType: "paraformer"
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
        print("[VowKy][SpeechRecognizer] Model loaded: \(self.recognizer != nil ? "SUCCESS" : "FAILED")")
    }

    func recognize(samples: [Float], sampleRate: Int) async -> String? {
        guard let rec = recognizer else {
            print("[VowKy][SpeechRecognizer] recognize() called but recognizer is nil!")
            return nil
        }
        guard !samples.isEmpty else {
            print("[VowKy][SpeechRecognizer] recognize() called with empty samples")
            return nil
        }

        print("[VowKy][SpeechRecognizer] recognize() start: \(samples.count) samples at \(sampleRate)Hz")
        let result = rec.decode(samples: samples, sampleRate: sampleRate)
        let text = result.text
        print("[VowKy][SpeechRecognizer] Raw recognition result: '\(text)'")
        return text.isEmpty ? nil : text
    }
}
