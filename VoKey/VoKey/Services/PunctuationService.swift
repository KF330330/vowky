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
            print("[VoKey][Punctuation] Model not found at: \(path)")
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
            print("[VoKey][Punctuation] Model loaded successfully")
        } else {
            wrapper = nil
            print("[VoKey][Punctuation] Failed to create punctuation wrapper")
        }
    }

    func addPunctuation(to text: String) -> String {
        guard let wrapper = wrapper else { return text }
        let result = wrapper.addPunct(text: text)
        print("[VoKey][Punctuation] '\(text)' → '\(result)'")
        return result
    }
}
