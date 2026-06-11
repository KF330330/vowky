import Foundation

/// 带 token 级时间戳的识别结果。tokens/timestamps 等长、一一对应;
/// 模型不支持时间戳时两者为空（消费方据此优雅退化为纯文本逻辑）。
struct DetailedRecognition {
    let text: String
    let tokens: [String]
    let timestamps: [Float]
}

protocol SpeechRecognizerProtocol {
    func recognize(samples: [Float], sampleRate: Int) async -> String?
    func recognizeDetailed(samples: [Float], sampleRate: Int) async -> DetailedRecognition?
    var isReady: Bool { get }
}

extension SpeechRecognizerProtocol {
    /// 默认实现：仅文本、无时间戳。实现方可覆盖以提供停顿检测信号。
    func recognizeDetailed(samples: [Float], sampleRate: Int) async -> DetailedRecognition? {
        guard let text = await recognize(samples: samples, sampleRate: sampleRate) else { return nil }
        return DetailedRecognition(text: text, tokens: [], timestamps: [])
    }
}

protocol AudioRecorderProtocol {
    func startRecording() throws
    func stopRecording() -> [Float]
    var audioLevel: Float { get }
    var onSamplesCaptured: (([Float]) -> Void)? { get set }
}

struct StreamingRecognitionUpdate: Equatable {
    let committedText: String
    let partialText: String
    let isFinal: Bool

    var displayText: String {
        [committedText, partialText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

protocol StreamingSpeechRecognizerProtocol: AnyObject {
    var isReady: Bool { get }
    func loadModel()
    func startSession()
    func accept(samples: [Float], sampleRate: Int) -> StreamingRecognitionUpdate?
    func finish() -> StreamingRecognitionUpdate?
    func reset()
}

protocol PermissionCheckerProtocol {
    func isAccessibilityGranted() -> Bool
}

protocol PunctuationServiceProtocol {
    var isReady: Bool { get }
    func addPunctuation(to text: String) -> String
}

protocol AudioBackupProtocol {
    var hasBackup: Bool { get }
    func startBackup() throws
    func appendSamples(_ samples: [Float])
    func finalizeAndDelete()
    func recoverSamples() -> [Float]?
    func deleteBackup()
}

protocol UsageTrackerProtocol {
    func trackVoiceStart()
    func trackVoiceComplete(durationMs: Int, charCount: Int)
    func trackVoiceCancel()
    func trackVoiceFailure()
    func trackRecovery()
    func trackHotkeyChange()
    func trackHistorySearch()
    func trackHistoryCopy()
}
