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

/// 串行化对共享 SpeechRecognizer 的访问：伪流式预览解码与最终段解码共用同一个
/// SenseVoice 识别器实例，通过任务串联保证同一时刻只有一路 recognize 在跑。
actor SpeechRecognitionGate {
    private let recognizer: SpeechRecognizerProtocol
    private var lastTask: Task<DetailedRecognition?, Never>?

    init(recognizer: SpeechRecognizerProtocol) {
        self.recognizer = recognizer
    }

    func recognize(samples: [Float], sampleRate: Int) async -> String? {
        await recognizeDetailed(samples: samples, sampleRate: sampleRate)?.text
    }

    func recognizeDetailed(samples: [Float], sampleRate: Int) async -> DetailedRecognition? {
        let previous = lastTask
        let recognizer = self.recognizer
        let task = Task<DetailedRecognition?, Never> {
            _ = await previous?.value
            return await recognizer.recognizeDetailed(samples: samples, sampleRate: sampleRate)
        }
        lastTask = task
        return await task.value
    }
}

/// SenseVoice 伪流式预览解码器：录音中每隔约 previewDecodeInterval 把当前未提交的
/// 音频段整段重解码一次作为实时预览（多语言，与最终稿同源，日语等语言不再乱码）。
/// 同时负责预览文本拼接：已定稿段 + 已切段但最终稿未就绪的预览占位 + 当前段最新预览。
actor RecordingPreviewDecoder {
    private let gate: SpeechRecognitionGate
    private let sampleRate: Int
    private let onUpdate: @MainActor (StreamingRecognitionUpdate) -> Void

    /// 已定稿段文本（key = 段号），来自最终段解码结果。
    private var committedSegments: [Int: String] = [:]
    /// 已切段但最终稿未就绪的段，用最后一次预览解码占位，防止切段瞬间文字消失。
    private var stashedSegments: [Int: String] = [:]
    private var finalizedIndices: Set<Int> = []
    private var currentSegmentIndex = 0
    private var currentPartial = ""
    /// 当前段内已按停顿冻结的句子——永不再变（对应音频不再重解码），
    /// 保证段落列表只追加不回改：录音窗不重排、字幕调度不丢句。
    private var frozenPieces: [String] = []
    /// 已冻结音频的绝对样本位置（相对 session 起点），其后的音频才参与预览解码。
    private var frozenAbsoluteSamples = 0
    /// 纯标点/数字（静音解码噪声，如单个「。」）不进预览，避免污染字幕与转写。
    private static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
    private var isDecoding = false
    private var lastTriggerSampleCount = 0
    private var stopped = false
    /// 串联 onUpdate 回调，保证 UI 收到的更新顺序与产生顺序一致。
    private var emitChain: Task<Void, Never>?

    init(
        gate: SpeechRecognitionGate,
        sampleRate: Int,
        onUpdate: @escaping @MainActor (StreamingRecognitionUpdate) -> Void
    ) {
        self.gate = gate
        self.sampleRate = sampleRate
        self.onUpdate = onUpdate
    }

    /// 预览解码（skip-if-busy：上一次还没解完则丢弃本次触发，等下一次触发自然合并）。
    /// - Parameters:
    ///   - pending: 当前未提交音频段的快照
    ///   - segmentIndex: 快照所属的段号
    ///   - totalSampleCount: 快照时刻的累计样本数，用于丢弃乱序到达的旧触发
    func decodeIfIdle(pending: [Float], segmentIndex: Int, totalSampleCount: Int) async {
        guard !stopped, !isDecoding, !pending.isEmpty else { return }
        guard totalSampleCount > lastTriggerSampleCount else { return }
        lastTriggerSampleCount = totalSampleCount
        isDecoding = true
        defer { isDecoding = false }

        // 冻结音频不再重解码：只解码上次停顿冻结点之后的切片。
        // 冻结文本物理上不可能再变，解码量也从整段缩到上次停顿以来的几秒。
        let pendingStartAbs = totalSampleCount - pending.count
        let sliceStart = min(max(0, frozenAbsoluteSamples - pendingStartAbs), pending.count)
        let slice = sliceStart == 0 ? pending : Array(pending[sliceStart...])
        guard !slice.isEmpty else { return }

        let detailed = await gate.recognizeDetailed(samples: slice, sampleRate: sampleRate)
        let text = detailed?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stopped else { return }

        if segmentIndex < currentSegmentIndex {
            // 解码期间该段已被切走：segmentCut 已把冻结句+旧 partial 移入占位，
            // 占位为空时才用迟到结果补上，避免覆盖掉冻结句。
            if !finalizedIndices.contains(segmentIndex), !text.isEmpty,
               stashedSegments[segmentIndex] == nil {
                stashedSegments[segmentIndex] = text
            }
        } else if let detailed, !detailed.timestamps.isEmpty {
            let result = PauseSegmenter.segmentWithCut(
                text: text, tokens: detailed.tokens, timestamps: detailed.timestamps
            )
            if result.pieces.count > 1, let cutTime = result.cutTime {
                // 最后一片之前的句子全部冻结（纯标点噪声丢弃），冻结点之前的音频退出预览解码。
                // 切点夹在停顿区间内：距前 token ≥0.25s（清掉上句尾音）、距后 token ≤0.5s（保住下句起音）。
                frozenPieces.append(contentsOf: result.pieces.dropLast().filter(Self.isMeaningful))
                let lastPiece = result.pieces.last ?? ""
                currentPartial = Self.isMeaningful(lastPiece) ? lastPiece : ""
                let cutSeconds = max((result.gapStart ?? 0) + 0.25, cutTime - 0.5)
                frozenAbsoluteSamples = max(
                    frozenAbsoluteSamples,
                    pendingStartAbs + sliceStart + Int(cutSeconds * Float(sampleRate))
                )
            } else {
                let piece = result.pieces.first ?? text
                currentPartial = Self.isMeaningful(piece) ? piece : ""
            }
            NSLog("[VowKy][Preview] slice=\(slice.count) pieces=\(result.pieces.count) frozen=\(frozenPieces.count)")
        } else {
            currentPartial = Self.isMeaningful(text) ? text : ""
        }
        emit()
    }

    /// 主循环切出第 index 段时调用：当前预览文本（冻结句+进行中句）转为该段占位，
    /// 防止凭空消失。frozenAbsoluteSamples 是绝对样本位，跨段天然兼容。
    func segmentCut(index: Int) {
        let composed = (frozenPieces + [currentPartial])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !composed.isEmpty, !finalizedIndices.contains(index) {
            stashedSegments[index] = composed
        }
        frozenPieces = []
        currentPartial = ""
        currentSegmentIndex = index + 1
    }

    /// 第 index 段最终稿解码完成：高质量文本替换预览占位。
    func segmentFinalized(index: Int, text: String) {
        finalizedIndices.insert(index)
        stashedSegments[index] = nil
        if !text.isEmpty {
            committedSegments[index] = text
        }
        guard !stopped else { return }
        emit()
    }

    /// 进入 finishing 阶段：停止预览（in-flight 解码完成后不再回调），返回当前预览全文。
    func stop() -> String {
        stopped = true
        return currentUpdate().displayText
    }

    private func emit() {
        let update = currentUpdate()
        let previous = emitChain
        let callback = onUpdate
        emitChain = Task { @MainActor in
            await previous?.value
            callback(update)
        }
    }

    private func currentUpdate() -> StreamingRecognitionUpdate {
        let committed = committedSegments.keys.sorted()
            .compactMap { committedSegments[$0] }
            .joined(separator: "\n")
        let stashed = stashedSegments.keys.sorted().compactMap { stashedSegments[$0] }
        let partial = (stashed + frozenPieces + [currentPartial])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return StreamingRecognitionUpdate(
            committedText: committed,
            partialText: partial,
            isFinal: false
        )
    }
}

struct RecordingTranscriptionEngine {
    let finalRecognizer: SpeechRecognizerProtocol
    let writer: WAVSampleFileWriter
    let sampleRate: Int
    let finalSegmentDuration: TimeInterval
    let finalBoundarySearchWindow: TimeInterval
    let previewDecodeInterval: TimeInterval

    init(
        finalRecognizer: SpeechRecognizerProtocol,
        writer: WAVSampleFileWriter,
        sampleRate: Int,
        finalSegmentDuration: TimeInterval = 30,
        finalBoundarySearchWindow: TimeInterval = 2,
        previewDecodeInterval: TimeInterval = 1.5
    ) {
        self.finalRecognizer = finalRecognizer
        self.writer = writer
        self.sampleRate = sampleRate
        self.finalSegmentDuration = finalSegmentDuration
        self.finalBoundarySearchWindow = finalBoundarySearchWindow
        self.previewDecodeInterval = previewDecodeInterval
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
        let rate = sampleRate
        let gate = SpeechRecognitionGate(recognizer: finalRecognizer)
        let previewDecoder = RecordingPreviewDecoder(
            gate: gate,
            sampleRate: rate,
            onUpdate: progress
        )
        let finalTask = Task.detached(priority: .userInitiated) {
            try await Self.transcribeFinalSegments(
                from: finalStream,
                gate: gate,
                sampleRate: rate,
                counter: counter,
                onProgress: finalizationProgress,
                onSegmentFinalized: { index, text in
                    await previewDecoder.segmentFinalized(index: index, text: text)
                }
            )
        }

        defer {
            finalContinuation?.finish()
            if Task.isCancelled {
                finalTask.cancel()
            }
            writer.finalize()
        }

        var pendingFinalSamples: [Float] = []
        var finalSegmentStartTime: TimeInterval = 0
        var enqueuedSegmentCount = 0
        var totalSampleCount = 0
        var samplesSinceLastPreviewTrigger = 0
        let previewTriggerThreshold = max(1, Int(previewDecodeInterval * Double(rate)))

        for await samples in audioChunks {
            try Task.checkCancellation()
            writer.appendSamples(samples)
            pendingFinalSamples.append(contentsOf: samples)
            totalSampleCount += samples.count
            samplesSinceLastPreviewTrigger += samples.count
            let enqueued = enqueueReadyFinalSegments(
                pendingSamples: &pendingFinalSamples,
                segmentStartTime: &finalSegmentStartTime,
                continuation: finalContinuation
            )
            for _ in 0..<enqueued {
                await previewDecoder.segmentCut(index: enqueuedSegmentCount)
                enqueuedSegmentCount += 1
                let snapshot = await counter.incTotal()
                await finalizationProgress(snapshot)
            }

            if samplesSinceLastPreviewTrigger >= previewTriggerThreshold {
                samplesSinceLastPreviewTrigger = 0
                // 快照 + 非阻塞触发：解码再慢也不会卡住主循环，busy 时该次触发被跳过
                let pendingSnapshot = pendingFinalSamples
                let segmentIndex = enqueuedSegmentCount
                let sampleCount = totalSampleCount
                Task {
                    await previewDecoder.decodeIfIdle(
                        pending: pendingSnapshot,
                        segmentIndex: segmentIndex,
                        totalSampleCount: sampleCount
                    )
                }
            }
        }

        try Task.checkCancellation()
        // finishing 阶段：停止预览解码，让最终稿独占识别器
        let previewText = await previewDecoder.stop()

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
            previewText: previewText,
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
        gate: SpeechRecognitionGate,
        sampleRate: Int,
        counter: FinalizationCounter,
        onProgress: @escaping @MainActor (RecordingFinalizationProgress) -> Void,
        onSegmentFinalized: @escaping (Int, String) async -> Void
    ) async throws -> [String] {
        var finalSegments: [String] = []
        var segmentIndex = 0
        for await chunk in stream {
            try Task.checkCancellation()
            let text = await gate.recognize(samples: chunk.samples, sampleRate: sampleRate)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                finalSegments.append(text)
            }
            await onSegmentFinalized(segmentIndex, text)
            segmentIndex += 1
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
