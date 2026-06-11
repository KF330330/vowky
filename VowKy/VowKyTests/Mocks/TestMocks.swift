import Foundation
@testable import VowKy

// MARK: - Shared Mock Implementations for T2/T3/T4 Tests

final class MockSpeechRecognizer: SpeechRecognizerProtocol {
    var isReady: Bool = true
    var recognizeResult: String? = "测试结果"
    var queuedRecognizeResults: [String?] = []
    var recognizeDelay: UInt64 = 0 // nanoseconds
    var recognizeCallCount = 0
    var lastReceivedSamples: [Float] = []
    var lastReceivedSampleRate: Int = 0
    var receivedSamples: [[Float]] = []
    var receivedSampleRates: [Int] = []
    var recognizeCalledOnThread: Thread?

    func recognize(samples: [Float], sampleRate: Int) async -> String? {
        recognizeCallCount += 1
        lastReceivedSamples = samples
        lastReceivedSampleRate = sampleRate
        receivedSamples.append(samples)
        receivedSampleRates.append(sampleRate)
        recognizeCalledOnThread = Thread.current
        if recognizeDelay > 0 {
            try? await Task.sleep(nanoseconds: recognizeDelay)
        }
        if !queuedRecognizeResults.isEmpty {
            return queuedRecognizeResults.removeFirst()
        }
        return recognizeResult
    }

    /// 非空时 recognizeDetailed 依次出队（含 token 时间戳）。
    var queuedDetailedResults: [DetailedRecognition] = []
    /// 非 nil 时 recognizeDetailed 返回它（含 token 时间戳）；否则退化为包装 recognize()。
    var detailedResult: DetailedRecognition?

    func recognizeDetailed(samples: [Float], sampleRate: Int) async -> DetailedRecognition? {
        if !queuedDetailedResults.isEmpty || detailedResult != nil {
            recognizeCallCount += 1
            lastReceivedSamples = samples
            receivedSamples.append(samples)
            if recognizeDelay > 0 {
                try? await Task.sleep(nanoseconds: recognizeDelay)
            }
            if !queuedDetailedResults.isEmpty {
                return queuedDetailedResults.removeFirst()
            }
            return detailedResult
        }
        guard let text = await recognize(samples: samples, sampleRate: sampleRate) else { return nil }
        return DetailedRecognition(text: text, tokens: [], timestamps: [])
    }
}

final class MockAudioRecorder: AudioRecorderProtocol {
    var audioLevel: Float = 0.5
    var onSamplesCaptured: (([Float]) -> Void)?
    var shouldThrowOnStart = false
    var startError: Error = NSError(domain: "MockAudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音启动失败"])
    var startCallCount = 0
    var stopCallCount = 0
    var samplesResult: [Float] = Array(repeating: 0.1, count: 16000)
    var samplesToEmitOnStart: [[Float]] = []

    func startRecording() throws {
        startCallCount += 1
        if shouldThrowOnStart {
            throw startError
        }
        for samples in samplesToEmitOnStart {
            onSamplesCaptured?(samples)
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

final class MockStreamingSpeechRecognizer: StreamingSpeechRecognizerProtocol {
    var isReady: Bool = true
    var loadModelCallCount = 0
    var startSessionCallCount = 0
    var acceptCallCount = 0
    var finishCallCount = 0
    var resetCallCount = 0
    var queuedAcceptUpdates: [StreamingRecognitionUpdate?] = []
    var finishUpdate: StreamingRecognitionUpdate? = StreamingRecognitionUpdate(
        committedText: "最终文本",
        partialText: "",
        isFinal: true
    )
    var receivedSamples: [[Float]] = []

    func loadModel() {
        loadModelCallCount += 1
    }

    func startSession() {
        startSessionCallCount += 1
    }

    func accept(samples: [Float], sampleRate: Int) -> StreamingRecognitionUpdate? {
        acceptCallCount += 1
        receivedSamples.append(samples)
        if !queuedAcceptUpdates.isEmpty {
            return queuedAcceptUpdates.removeFirst()
        }
        return nil
    }

    func finish() -> StreamingRecognitionUpdate? {
        finishCallCount += 1
        return finishUpdate
    }

    func reset() {
        resetCallCount += 1
    }
}

final class MockTranslationProvider: TranslationProviding, @unchecked Sendable {
    /// 模拟引擎是否要求源≠目标（Apple = true，LLM = false）
    var requiresDistinctSourceLanguage: Bool = false
    /// 固定结果映射（key = 原文）；没命中时返回 "译:<原文>"
    var results: [String: String] = [:]
    /// 指定原文抛错
    var errors: [String: TranslationError] = [:]
    /// 模拟延迟（纳秒）
    var delayNanoseconds: UInt64 = 0

    private let lock = NSLock()
    private var _requestedTexts: [String] = []
    var requestedTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requestedTexts
    }

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        lock.lock()
        _requestedTexts.append(text)
        lock.unlock()
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        if let error = errors[text] { throw error }
        return results[text] ?? "译:\(text)"
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
