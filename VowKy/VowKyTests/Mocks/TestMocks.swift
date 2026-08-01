import Foundation
@testable import VowKy

// MARK: - Shared Mock Implementations for T2/T3/T4 Tests

final class MockSpeechRecognizer: SpeechRecognizerProtocol {
    var isReady: Bool = true
    var warmUpCallCount = 0
    var recognizeResult: String? = "测试结果"
    var queuedRecognizeResults: [String?] = []
    /// 按输入样本编程返回（优先级最高）：识别调用次数不确定（如录音预览解码）时,
    /// 用样本特征（如 count）区分各路调用,比队列出队稳定。
    var recognizeResultProvider: (([Float]) -> String?)?
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
        if let recognizeResultProvider {
            return recognizeResultProvider(samples)
        }
        if !queuedRecognizeResults.isEmpty {
            return queuedRecognizeResults.removeFirst()
        }
        return recognizeResult
    }

    func warmUp() async { warmUpCallCount += 1 }

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

final class MockDiarizer: SpeakerDiarizing {
    /// 编程返回的分离段;error 非 nil 时抛出它。
    var segmentsToReturn: [SpeakerSegment] = []
    var errorToThrow: Error?
    /// 模拟的进度序列(diarize 时依次回调)。
    var progressToEmit: [Double] = []
    var diarizeCallCount = 0
    var lastWavURL: URL?
    var lastAudioDuration: TimeInterval = 0

    func diarize(
        wavURL: URL,
        audioDuration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerSegment] {
        diarizeCallCount += 1
        lastWavURL = wavURL
        lastAudioDuration = audioDuration
        for value in progressToEmit {
            onProgress(value)
        }
        if let errorToThrow {
            throw errorToThrow
        }
        return segmentsToReturn
    }
}

final class MockAudioRecorder: AudioRecorderProtocol {
    var audioLevel: Float = 0.5
    var onSamplesCaptured: (([Float]) -> Void)?
    var shouldThrowOnStart = false
    var startError: Error = NSError(domain: "MockAudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音启动失败"])
    var startCallCount = 0
    var stopCallCount = 0
    var pauseCallCount = 0
    var resumeCallCount = 0
    var isPaused = false
    var samplesResult: [Float] = Array(repeating: 0.1, count: 16000)
    var samplesToEmitOnStart: [[Float]] = []

    func startRecording() throws {
        startCallCount += 1
        isPaused = false
        if shouldThrowOnStart {
            throw startError
        }
        for samples in samplesToEmitOnStart {
            onSamplesCaptured?(samples)
        }
    }

    func stopRecording() -> [Float] {
        stopCallCount += 1
        isPaused = false
        return samplesResult
    }

    func pauseRecording() {
        pauseCallCount += 1
        isPaused = true
        audioLevel = 0
    }

    func resumeRecording() {
        resumeCallCount += 1
        isPaused = false
    }
}

final class MockPermissionChecker: PermissionCheckerProtocol {
    var accessibilityGranted = true

    func isAccessibilityGranted() -> Bool {
        return accessibilityGranted
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

    var preserveBackupCallCount = 0
    var lastPreserveDirectory: URL?
    var lastPreserveBaseName: String?
    var preserveBackupResult: URL? = URL(fileURLWithPath: "/tmp/mock-preserved.wav")

    func preserveBackup(to directory: URL, baseName: String) -> URL? {
        preserveBackupCallCount += 1
        lastPreserveDirectory = directory
        lastPreserveBaseName = baseName
        return preserveBackupResult
    }
}
