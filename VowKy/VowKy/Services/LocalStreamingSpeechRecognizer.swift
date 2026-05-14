import Foundation

final class LocalStreamingSpeechRecognizer: StreamingSpeechRecognizerProtocol {
    private var recognizer: SherpaOnnxRecognizer?
    private var committedSegments: [String] = []

    private var encoderPathString = ""
    private var decoderPathString = ""
    private var tokensPathString = ""

    var isReady: Bool { recognizer != nil }

    func loadModel() {
        guard recognizer == nil else { return }

        let modelDirectory = "StreamingModels/paraformer-bilingual-zh-en"
        let encoder = Self.resourcePath(name: "encoder.int8", type: "onnx", inDirectory: modelDirectory)
        let decoder = Self.resourcePath(name: "decoder.int8", type: "onnx", inDirectory: modelDirectory)
        let tokens = Self.resourcePath(name: "streaming-tokens", type: "txt", inDirectory: modelDirectory)

        NSLog("[VowKy][StreamingRecognizer] loadModel() called")
        NSLog("[VowKy][StreamingRecognizer] encoder path: \(encoder)")
        NSLog("[VowKy][StreamingRecognizer] decoder path: \(decoder)")
        NSLog("[VowKy][StreamingRecognizer] tokens path: \(tokens)")

        guard !encoder.isEmpty, !decoder.isEmpty, !tokens.isEmpty,
              FileManager.default.fileExists(atPath: encoder),
              FileManager.default.fileExists(atPath: decoder),
              FileManager.default.fileExists(atPath: tokens) else {
            NSLog("[VowKy][StreamingRecognizer] ERROR: Streaming model files not found")
            return
        }

        encoderPathString = encoder
        decoderPathString = decoder
        tokensPathString = tokens

        let paraformerConfig = sherpaOnnxOnlineParaformerModelConfig(
            encoder: encoderPathString,
            decoder: decoderPathString
        )
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: tokensPathString,
            paraformer: paraformerConfig,
            numThreads: 2,
            modelType: "paraformer"
        )
        let featConfig = sherpaOnnxFeatureConfig(
            sampleRate: 16_000,
            featureDim: 80
        )
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: true,
            rule1MinTrailingSilence: 2.4,
            rule2MinTrailingSilence: 1.2,
            rule3MinUtteranceLength: 30
        )

        recognizer = SherpaOnnxRecognizer(config: &config)
        NSLog("[VowKy][StreamingRecognizer] Model loaded: \(recognizer != nil ? "SUCCESS" : "FAILED")")
    }

    func startSession() {
        committedSegments = []
        recognizer?.reset()
    }

    func accept(samples: [Float], sampleRate: Int) -> StreamingRecognitionUpdate? {
        guard let recognizer, !samples.isEmpty else { return nil }

        recognizer.acceptWaveform(samples: samples, sampleRate: sampleRate)

        var latestText = ""
        var decodedAnything = false
        while recognizer.isReady() {
            recognizer.decode()
            latestText = recognizer.getResult().text
            decodedAnything = true
        }

        if recognizer.isEndpoint() {
            let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                committedSegments.append(text)
            }
            recognizer.reset()
            return makeUpdate(partialText: "", isFinal: false)
        }

        guard decodedAnything else { return nil }
        return makeUpdate(partialText: latestText, isFinal: false)
    }

    func finish() -> StreamingRecognitionUpdate? {
        guard let recognizer else { return nil }

        recognizer.inputFinished()
        while recognizer.isReady() {
            recognizer.decode()
        }

        let finalText = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            committedSegments.append(finalText)
        }
        return makeUpdate(partialText: "", isFinal: true)
    }

    func reset() {
        committedSegments = []
        recognizer?.reset()
    }

    private func makeUpdate(partialText: String, isFinal: Bool) -> StreamingRecognitionUpdate {
        StreamingRecognitionUpdate(
            committedText: committedSegments.joined(separator: "\n"),
            partialText: partialText.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: isFinal
        )
    }

    private static func resourcePath(name: String, type: String, inDirectory directory: String) -> String {
        Bundle.main.path(forResource: name, ofType: type, inDirectory: directory)
            ?? Bundle.main.path(forResource: name, ofType: type)
            ?? ""
    }
}
