import Foundation

final class PunctuationService: PunctuationServiceProtocol {

    private var wrapper: SherpaOnnxOfflinePunctuationWrapper?

    // Keep path string alive to avoid C dangling pointers
    private var modelPathString: String = ""

    var isReady: Bool { wrapper?.ptr != nil }

    /// Load the punctuation model.
    /// If modelPath is nil, defaults to Bundle.main resource.
    func loadModel(modelPath: String? = nil) {
        let path = modelPath ?? Bundle.main.path(forResource: "punct-model", ofType: "onnx") ?? ""

        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            NSLog("[VowKy][Punctuation] Model not found at: \(path)")
            return
        }

        self.modelPathString = path

        let modelConfig = sherpaOnnxOfflinePunctuationModelConfig(
            ctTransformer: self.modelPathString
        )
        var config = sherpaOnnxOfflinePunctuationConfig(model: modelConfig)

        let w = SherpaOnnxOfflinePunctuationWrapper(config: &config)

        if w.ptr != nil {
            wrapper = w
            NSLog("[VowKy][Punctuation] Model loaded successfully")
        } else {
            wrapper = nil
            NSLog("[VowKy][Punctuation] Failed to create punctuation wrapper")
        }
    }

    func addPunctuation(to text: String) -> String {
        guard let wrapper = wrapper else { return text }
        let result = wrapper.addPunct(text: text)
        NSLog("[VowKy][Punctuation] '\(text)' → '\(result)'")
        return result
    }
}
