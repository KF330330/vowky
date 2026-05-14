import Foundation

protocol SpeechRecognizerProtocol {
    func recognize(samples: [Float], sampleRate: Int) async -> String?
    var isReady: Bool { get }
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
