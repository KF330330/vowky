import Foundation
@testable import VoKey

// MARK: - Shared Mock Implementations for T2/T3/T4 Tests

final class MockSpeechRecognizer: SpeechRecognizerProtocol {
    var isReady: Bool = true
    var recognizeResult: String? = "测试结果"
    var recognizeDelay: UInt64 = 0 // nanoseconds
    var recognizeCallCount = 0
    var lastReceivedSamples: [Float] = []
    var lastReceivedSampleRate: Int = 0
    var recognizeCalledOnThread: Thread?

    func recognize(samples: [Float], sampleRate: Int) async -> String? {
        recognizeCallCount += 1
        lastReceivedSamples = samples
        lastReceivedSampleRate = sampleRate
        recognizeCalledOnThread = Thread.current
        if recognizeDelay > 0 {
            try? await Task.sleep(nanoseconds: recognizeDelay)
        }
        return recognizeResult
    }
}

final class MockAudioRecorder: AudioRecorderProtocol {
    var audioLevel: Float = 0.5
    var shouldThrowOnStart = false
    var startError: Error = NSError(domain: "MockAudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音启动失败"])
    var startCallCount = 0
    var stopCallCount = 0
    var samplesResult: [Float] = Array(repeating: 0.1, count: 16000)

    func startRecording() throws {
        startCallCount += 1
        if shouldThrowOnStart {
            throw startError
        }
    }

    func stopRecording() -> [Float] {
        stopCallCount += 1
        return samplesResult
    }
}

final class MockPermissionChecker: PermissionCheckerProtocol {
    var accessibilityGranted = true

    func isAccessibilityGranted() -> Bool {
        return accessibilityGranted
    }
}

final class MockPunctuationService: PunctuationServiceProtocol {
    var isReady: Bool = true
    var addPunctuationCallCount = 0
    var punctuationSuffix = "。"

    func addPunctuation(to text: String) -> String {
        addPunctuationCallCount += 1
        return text + punctuationSuffix
    }
}

final class MockAudioBackupService: AudioBackupProtocol {
    var hasBackup: Bool = false
    var startBackupCallCount = 0
    var appendSamplesCallCount = 0
    var lastAppendedSamples: [Float] = []
    var finalizeAndDeleteCallCount = 0
    var deleteBackupCallCount = 0
    var recoverSamplesResult: [Float]?

    func startBackup() throws { startBackupCallCount += 1 }
    func appendSamples(_ samples: [Float]) {
        appendSamplesCallCount += 1
        lastAppendedSamples = samples
    }
    func finalizeAndDelete() { finalizeAndDeleteCallCount += 1 }
    func recoverSamples() -> [Float]? { return recoverSamplesResult }
    func deleteBackup() { deleteBackupCallCount += 1 }
}
