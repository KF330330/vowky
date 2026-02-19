import Foundation

protocol SpeechRecognizerProtocol {
    func recognize(samples: [Float], sampleRate: Int) async -> String?
    var isReady: Bool { get }
}

protocol AudioRecorderProtocol {
    func startRecording() throws
    func stopRecording() -> [Float]
    var audioLevel: Float { get }
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
