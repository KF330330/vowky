import Foundation

enum RecordingTranscriptionState: Equatable {
    case idle
    case loadingModel
    case recording
    case finishing
    case completed
    case cancelled
    case failed(String)
}

struct RecordingTranscriptionOutput: Equatable {
    let textURL: URL
    let audioURL: URL
    let startedAt: Date
    let duration: TimeInterval
    let characterCount: Int
}

struct PreparedRecordingTranscriptionOutput: Equatable {
    let textURL: URL
    let audioURL: URL
    let startedAt: Date
}

struct RecordingTranscriptionResult: Equatable {
    let previewText: String
    let finalText: String
}

struct RecordingFinalizationProgress: Equatable {
    let completed: Int
    let total: Int
    let inputClosed: Bool
}

enum RecordingTranscriptionError: LocalizedError, Equatable {
    case noFinalRecognitionText

    var errorDescription: String? {
        switch self {
        case .noFinalRecognitionText:
            return "没有识别到文字"
        }
    }
}

struct RecordingTranscriptionOutputStore {
    let outputDirectory: URL
    private let fileManager: FileManager

    init(
        outputDirectory: URL = Self.defaultOutputDirectory(),
        fileManager: FileManager = .default
    ) {
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
    }

    func prepareOutput(startedAt: Date = Date()) throws -> PreparedRecordingTranscriptionOutput {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let baseName = uniqueBaseName(for: startedAt)
        return PreparedRecordingTranscriptionOutput(
            textURL: outputDirectory.appendingPathComponent("\(baseName).md"),
            audioURL: outputDirectory.appendingPathComponent("\(baseName).wav"),
            startedAt: startedAt
        )
    }

    func writeTranscript(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func defaultOutputDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VowKy Recordings", isDirectory: true)
    }

    private func uniqueBaseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"

        let baseName = "VowKy Recording \(formatter.string(from: date))"
        var candidate = baseName
        var suffix = 2
        // 同时检测 .md（新格式）和 .txt（老格式，向后兼容用户已有的转写文件）
        while fileManager.fileExists(atPath: outputDirectory.appendingPathComponent("\(candidate).md").path)
            || fileManager.fileExists(atPath: outputDirectory.appendingPathComponent("\(candidate).txt").path)
            || fileManager.fileExists(atPath: outputDirectory.appendingPathComponent("\(candidate).wav").path) {
            candidate = "\(baseName)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

struct RecordingTranscriptionEngine {
    let previewRecognizer: StreamingSpeechRecognizerProtocol
    let finalRecognizer: SpeechRecognizerProtocol
    let writer: WAVSampleFileWriter
    let sampleRate: Int
    let finalSegmentDuration: TimeInterval
    let finalBoundarySearchWindow: TimeInterval

    init(
        previewRecognizer: StreamingSpeechRecognizerProtocol,
        finalRecognizer: SpeechRecognizerProtocol,
        writer: WAVSampleFileWriter,
        sampleRate: Int,
        finalSegmentDuration: TimeInterval = 30,
        finalBoundarySearchWindow: TimeInterval = 2
    ) {
        self.previewRecognizer = previewRecognizer
        self.finalRecognizer = finalRecognizer
        self.writer = writer
        self.sampleRate = sampleRate
        self.finalSegmentDuration = finalSegmentDuration
        self.finalBoundarySearchWindow = finalBoundarySearchWindow
    }

    func run(
        audioChunks: AsyncStream<[Float]>,
        progress: @escaping @MainActor (StreamingRecognitionUpdate) -> Void,
        finalizationProgress: @escaping @MainActor (RecordingFinalizationProgress) -> Void = { _ in }
    ) async throws -> RecordingTranscriptionResult {
        var finalContinuation: AsyncStream<DecodedAudioChunk>.Continuation?
        let finalStream = AsyncStream<DecodedAudioChunk> { continuation in
            finalContinuation = continuation
        }
        let counter = FinalizationCounter()
        let recognizer = finalRecognizer
        let rate = sampleRate
        let finalTask = Task.detached(priority: .userInitiated) {
            try await Self.transcribeFinalSegments(
                from: finalStream,
                recognizer: recognizer,
                sampleRate: rate,
                counter: counter,
                onProgress: finalizationProgress
            )
        }

        defer {
            finalContinuation?.finish()
            if Task.isCancelled {
                finalTask.cancel()
            }
            writer.finalize()
        }

        var latestUpdate = StreamingRecognitionUpdate(
            committedText: "",
            partialText: "",
            isFinal: false
        )
        var pendingFinalSamples: [Float] = []
        var finalSegmentStartTime: TimeInterval = 0

        for await samples in audioChunks {
            try Task.checkCancellation()
            writer.appendSamples(samples)
            pendingFinalSamples.append(contentsOf: samples)
            let enqueued = enqueueReadyFinalSegments(
                pendingSamples: &pendingFinalSamples,
                segmentStartTime: &finalSegmentStartTime,
                continuation: finalContinuation
            )
            for _ in 0..<enqueued {
                let snapshot = await counter.incTotal()
                await finalizationProgress(snapshot)
            }

            if let update = previewRecognizer.accept(samples: samples, sampleRate: sampleRate) {
                latestUpdate = update
                await progress(update)
            }
        }

        try Task.checkCancellation()
        if let finalUpdate = previewRecognizer.finish() {
            latestUpdate = finalUpdate
            await progress(finalUpdate)
        }

        if !pendingFinalSamples.isEmpty {
            finalContinuation?.yield(DecodedAudioChunk(
                samples: pendingFinalSamples,
                startTime: finalSegmentStartTime,
                duration: Double(pendingFinalSamples.count) / Double(sampleRate)
            ))
            pendingFinalSamples.removeAll(keepingCapacity: false)
            let snapshot = await counter.incTotal()
            await finalizationProgress(snapshot)
        }
        finalContinuation?.finish()
        let closedSnapshot = await counter.markClosed()
        await finalizationProgress(closedSnapshot)

        let finalSegments = try await finalTask.value
        let finalText = finalSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !finalText.isEmpty else {
            throw RecordingTranscriptionError.noFinalRecognitionText
        }

        return RecordingTranscriptionResult(
            previewText: latestUpdate.displayText,
            finalText: finalText
        )
    }

    private func enqueueReadyFinalSegments(
        pendingSamples: inout [Float],
        segmentStartTime: inout TimeInterval,
        continuation: AsyncStream<DecodedAudioChunk>.Continuation?
    ) -> Int {
        let minimumReadySamples = max(1, Int((finalSegmentDuration + finalBoundarySearchWindow) * Double(sampleRate)))
        var enqueued = 0

        while pendingSamples.count >= minimumReadySamples {
            let chunk = FileTranscriptionService.makeChunkFromWindow(
                samples: pendingSamples,
                sampleRate: sampleRate,
                startTime: segmentStartTime,
                targetDuration: finalSegmentDuration,
                searchWindow: finalBoundarySearchWindow
            )
            guard !chunk.samples.isEmpty else { break }

            continuation?.yield(chunk)
            enqueued += 1
            let consumedCount = min(chunk.samples.count, pendingSamples.count)
            pendingSamples = Array(pendingSamples.dropFirst(consumedCount))
            segmentStartTime += chunk.duration
        }
        return enqueued
    }

    private static func transcribeFinalSegments(
        from stream: AsyncStream<DecodedAudioChunk>,
        recognizer: SpeechRecognizerProtocol,
        sampleRate: Int,
        counter: FinalizationCounter,
        onProgress: @escaping @MainActor (RecordingFinalizationProgress) -> Void
    ) async throws -> [String] {
        var finalSegments: [String] = []
        for await chunk in stream {
            try Task.checkCancellation()
            let text = await recognizer.recognize(samples: chunk.samples, sampleRate: sampleRate)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                finalSegments.append(text)
            }
            let snapshot = await counter.incCompleted()
            await onProgress(snapshot)
        }
        return finalSegments
    }
}

private actor FinalizationCounter {
    private var total = 0
    private var completed = 0
    private var inputClosed = false

    func incTotal() -> RecordingFinalizationProgress {
        total += 1
        return snapshot()
    }

    func incCompleted() -> RecordingFinalizationProgress {
        completed += 1
        return snapshot()
    }

    func markClosed() -> RecordingFinalizationProgress {
        inputClosed = true
        return snapshot()
    }

    private func snapshot() -> RecordingFinalizationProgress {
        RecordingFinalizationProgress(completed: completed, total: total, inputClosed: inputClosed)
    }
}
