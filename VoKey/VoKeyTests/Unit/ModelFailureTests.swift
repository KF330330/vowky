import XCTest
@testable import VoKey

/// Tests #8-10: Model failure scenarios.
/// These tests verify graceful handling when model files are missing or invalid.
final class ModelFailureTests: XCTestCase {

    // MARK: - #8 Model file missing → isReady=false

    func testModelFileMissing_isReadyFalse() {
        let recognizer = LocalSpeechRecognizer()
        recognizer.loadModel(
            modelPath: "/nonexistent/path/model.int8.onnx",
            tokensPath: Bundle.main.path(forResource: "tokens", ofType: "txt")
        )
        XCTAssertFalse(recognizer.isReady, "Should not be ready when model file is missing")
    }

    // MARK: - #9 Tokens file missing

    func testTokensFileMissing_isReadyFalse() {
        let recognizer = LocalSpeechRecognizer()
        recognizer.loadModel(
            modelPath: Bundle.main.path(forResource: "model.int8", ofType: "onnx"),
            tokensPath: "/nonexistent/path/tokens.txt"
        )
        XCTAssertFalse(recognizer.isReady, "Should not be ready when tokens file is missing")
    }

    // MARK: - #10 Empty path

    func testEmptyPath_isReadyFalse() {
        let recognizer = LocalSpeechRecognizer()
        recognizer.loadModel(modelPath: "", tokensPath: "")
        XCTAssertFalse(recognizer.isReady, "Should not be ready with empty paths")
    }
}
