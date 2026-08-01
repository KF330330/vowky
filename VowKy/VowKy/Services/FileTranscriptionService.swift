import Foundation

struct DecodedAudioChunk {
    let samples: [Float]
    let startTime: TimeInterval
    let duration: TimeInterval
}

struct FileTranscriptionProgress {
    enum Phase: Equatable {
        case reading
        case separating
        case transcribing
        case finishing
    }

    let phase: Phase
    let progress: Double
    let currentSegment: Int
    let totalSegments: Int
    let partialText: String
    /// 分离路径失败、已自动降级为无标签转写(降级后的第一条进度起置 true)。
    var diarizationFellBack: Bool = false
    /// 分离路径检出的说话人数(仅 .finishing 时有值,其余为 0)。
    var speakerCount: Int = 0
}

enum FileTranscriptionError: LocalizedError, Equatable {
    case noRecognizedText
    case segmentDecodingFailed(startTime: TimeInterval, reason: String)

    var errorDescription: String? {
        switch self {
        case .noRecognizedText:
            return "没有识别到文字"
        case .segmentDecodingFailed(let startTime, let reason):
            let timeText = Self.formatTime(startTime)
            return reason.isEmpty
                ? "约 \(timeText) 处音频解码失败"
                : "约 \(timeText) 处音频解码失败：\(reason)"
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

protocol FileTranscribing {
    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String
}

final class FileTranscriptionService: FileTranscribing {
    private let decoder: MediaAudioDecoding
    private let speechRecognizer: SpeechRecognizerProtocol
    private let targetChunkDuration: TimeInterval
    private let boundarySearchWindow: TimeInterval
    /// 礼让闸：每个分块前调用。实时语音输入活动时挂起，让出共用 helper；为 nil 时不礼让（CLI/测试）。
    private let yieldToVoiceInput: (() async -> Void)?
    /// 说话人分离服务。nil = 分离关闭,走原有 30s 切块路径(零变化)。
    private let diarizer: SpeakerDiarizing?
    /// 说话人标签(如「说话人 1：」),按重编号后的 1..N 取。nil 时用引擎原始风格兜底。
    private let speakerLabel: ((Int) -> String)?

    init(
        decoder: MediaAudioDecoding = MediaAudioDecoder(),
        speechRecognizer: SpeechRecognizerProtocol,
        targetChunkDuration: TimeInterval = 30,
        boundarySearchWindow: TimeInterval = 2,
        yieldToVoiceInput: (() async -> Void)? = nil,
        diarizer: SpeakerDiarizing? = nil,
        speakerLabel: ((Int) -> String)? = nil
    ) {
        self.decoder = decoder
        self.speechRecognizer = speechRecognizer
        self.targetChunkDuration = targetChunkDuration
        self.boundarySearchWindow = boundarySearchWindow
        self.yieldToVoiceInput = yieldToVoiceInput
        self.diarizer = diarizer
        self.speakerLabel = speakerLabel
    }

    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String {
        guard let diarizer else {
            return try await transcribePlain(url: url, progress: progress)
        }
        // 分离失败绝不丢文稿:除取消与两条路径共有的领域错误外,一律降级为无标签转写。
        do {
            return try await transcribeWithDiarization(url: url, diarizer: diarizer, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeakerDiarizationError where error == .cancelled {
            throw CancellationError()
        } catch let error as FileTranscriptionError {
            throw error
        } catch {
            NSLog("[VowKy][FileTranscription] 分离失败,降级无标签转写: \(error.localizedDescription)")
            return try await transcribePlain(url: url, progress: progress, diarizationFellBack: true)
        }
    }

    // MARK: - 说话人分离路径

    private func transcribeWithDiarization(
        url: URL,
        diarizer: SpeakerDiarizing,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        await progress(FileTranscriptionProgress(
            phase: .reading, progress: 0, currentSegment: 0, totalSegments: 0, partialText: ""
        ))

        let info = try await decoder.loadInfo(url: url)
        try Task.checkCancellation()
        let totalDuration = max(0, info.duration)
        guard totalDuration > 0 else {
            // 时长未知无法整体分离,交给原路径的 0 时长特殊处理
            throw SpeakerDiarizationError.processFailed("unknown duration")
        }

        // 1) 全音频分窗解码,写临时 canonical WAV(分离子进程输入;逐段识别也从它 seek 读样本)
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("VowKy-Diarization", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        var writer: WAVSampleFileWriter?
        var sampleRate = 0
        var decodedSeconds: TimeInterval = 0
        while decodedSeconds < totalDuration {
            await yieldToVoiceInput?()
            try Task.checkCancellation()
            let requestDuration = min(targetChunkDuration, totalDuration - decodedSeconds)
            guard requestDuration > 0.05 else { break }
            let decoded = try await decodeWindowWithRetry(
                url: url, startTime: decodedSeconds, duration: requestDuration
            )
            if writer == nil {
                sampleRate = decoded.sampleRate
                writer = try WAVSampleFileWriter(url: tempWAV, sampleRate: sampleRate)
            }
            guard decoded.sampleRate == sampleRate else {
                throw SpeakerDiarizationError.processFailed("inconsistent sample rate")
            }
            let decodedDuration = Double(decoded.samples.count) / Double(max(1, decoded.sampleRate))
            guard decodedDuration > 0.01 else { break }
            writer?.appendSamples(decoded.samples)
            decodedSeconds += decodedDuration
            await progress(FileTranscriptionProgress(
                phase: .reading,
                progress: 0.15 * min(1, decodedSeconds / totalDuration),
                currentSegment: 0, totalSegments: 0, partialText: ""
            ))
        }
        writer?.finalize()
        guard let writer, writer.sampleCount > 0, sampleRate > 0 else {
            throw FileTranscriptionError.noRecognizedText
        }
        let writtenDuration = Double(writer.sampleCount) / Double(sampleRate)

        // 2) 分离(一次性子进程,不占听写管道,无需礼让)
        await progress(FileTranscriptionProgress(
            phase: .separating, progress: 0.15, currentSegment: 0, totalSegments: 0, partialText: ""
        ))
        let rawSegments = try await diarizer.diarize(
            wavURL: tempWAV, audioDuration: writtenDuration
        ) { fraction in
            Task { @MainActor in
                progress(FileTranscriptionProgress(
                    phase: .separating,
                    progress: 0.15 + 0.4 * min(1, max(0, fraction)),
                    currentSegment: 0, totalSegments: 0, partialText: ""
                ))
            }
        }
        try Task.checkCancellation()
        guard !rawSegments.isEmpty else {
            throw SpeakerDiarizationError.processFailed("no speech segments")
        }

        // 3) 段后处理:±0.25s padding + 边界裁剪 + 首次出现重编号
        let segments = SpeakerSegmentComposer.renumberByFirstAppearance(
            SpeakerSegmentComposer.padAndClip(rawSegments, totalDuration: writtenDuration)
        )
        let speakerCount = SpeakerSegmentComposer.distinctSpeakerCount(segments)
        let label = speakerLabel ?? { "speaker_\($0)：" }

        // 4) 逐段识别(共用听写 helper,每段前礼让)
        var labeled: [SpeakerSegmentComposer.LabeledSegment] = []
        func composeCurrent() -> String {
            speakerCount <= 1
                ? labeled.map(\.text).joined(separator: "\n")
                : SpeakerSegmentComposer.compose(labeled, labelProvider: label)
        }
        for (index, segment) in segments.enumerated() {
            await yieldToVoiceInput?()
            try Task.checkCancellation()
            let startSample = max(0, Int(segment.start * Double(sampleRate)))
            let endSample = Int(segment.end * Double(sampleRate))
            guard endSample > startSample,
                  let samples = WAVSampleFileWriter.readFloat32Samples(
                    from: tempWAV, sampleRange: startSample..<endSample
                  ),
                  !samples.isEmpty else { continue }

            let text: String
            if segment.end - segment.start > targetChunkDuration + boundarySearchWindow {
                // 超长 speaker 段:复用低能量边界二次切块,子块文本换行后归属同段
                var parts: [String] = []
                for chunk in Self.makeChunks(
                    samples: samples, sampleRate: sampleRate,
                    targetDuration: targetChunkDuration, searchWindow: boundarySearchWindow
                ) {
                    await yieldToVoiceInput?()
                    try Task.checkCancellation()
                    if let part = await speechRecognizer.recognize(samples: chunk.samples, sampleRate: sampleRate)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !part.isEmpty {
                        parts.append(part)
                    }
                }
                text = parts.joined(separator: "\n")
            } else {
                text = (await speechRecognizer.recognize(samples: samples, sampleRate: sampleRate) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !text.isEmpty {
                labeled.append(.init(speaker: segment.speaker, text: text))
            }
            await progress(FileTranscriptionProgress(
                phase: .transcribing,
                progress: 0.55 + 0.43 * Double(index + 1) / Double(segments.count),
                currentSegment: index + 1,
                totalSegments: segments.count,
                partialText: composeCurrent()
            ))
        }

        try Task.checkCancellation()
        let result = composeCurrent()
        guard !result.isEmpty else {
            throw FileTranscriptionError.noRecognizedText
        }
        await progress(FileTranscriptionProgress(
            phase: .finishing, progress: 1,
            currentSegment: segments.count, totalSegments: segments.count,
            partialText: result, speakerCount: speakerCount
        ))
        return result
    }

    // MARK: - 原有 30s 切块路径

    private func transcribePlain(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void,
        diarizationFellBack: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        await progress(FileTranscriptionProgress(
            phase: .reading,
            progress: 0,
            currentSegment: 0,
            totalSegments: 0,
            partialText: "",
            diarizationFellBack: diarizationFellBack
        ))

        let info = try await decoder.loadInfo(url: url)
        try Task.checkCancellation()

        let totalDuration = max(0, info.duration)
        let totalSegments = max(1, Int(ceil(totalDuration / targetChunkDuration)))
        var recognizedSegments: [String] = []
        /// 增量维护的 partialText：避免每段都 joined 整篇（段数多时 O(n²)）
        var accumulatedText = ""
        var currentStart: TimeInterval = 0
        var segmentIndex = 0

        while currentStart < totalDuration || (totalDuration == 0 && segmentIndex == 0) {
            // 实时语音输入活动时在此挂起（解码前完全礼让），语音结束后继续。取消会立即唤醒。
            await yieldToVoiceInput?()
            try Task.checkCancellation()
            await progress(FileTranscriptionProgress(
                phase: .transcribing,
                progress: totalDuration > 0 ? min(0.99, currentStart / totalDuration) : 0,
                currentSegment: segmentIndex + 1,
                totalSegments: max(totalSegments, segmentIndex + 1),
                partialText: accumulatedText,
                diarizationFellBack: diarizationFellBack
            ))

            let remainingDuration = totalDuration > 0 ? max(0, totalDuration - currentStart) : targetChunkDuration
            let requestedDuration = totalDuration > 0
                ? min(targetChunkDuration + boundarySearchWindow, remainingDuration)
                : targetChunkDuration
            let decoded: DecodedAudio
            do {
                decoded = try await decodeWindowWithRetry(
                    url: url,
                    startTime: currentStart,
                    duration: requestedDuration
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if shouldUsePartialResultAfterTailDecodeFailure(
                    currentStart: currentStart,
                    totalDuration: totalDuration,
                    recognizedSegments: recognizedSegments
                ) {
                    break
                }
                throw error
            }
            try Task.checkCancellation()

            let chunk = Self.makeChunkFromWindow(
                samples: decoded.samples,
                sampleRate: decoded.sampleRate,
                startTime: currentStart,
                targetDuration: targetChunkDuration,
                searchWindow: boundarySearchWindow
            )
            guard !chunk.samples.isEmpty else { break }

            let recognizedText = await speechRecognizer.recognize(
                samples: chunk.samples,
                sampleRate: decoded.sampleRate
            )
            guard let rawText = recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawText.isEmpty else {
                currentStart += max(chunk.duration, 0.01)
                segmentIndex += 1
                if totalDuration == 0 { break }
                continue
            }

            recognizedSegments.append(rawText)
            if accumulatedText.isEmpty {
                accumulatedText = rawText
            } else {
                accumulatedText += "\n" + rawText
            }
            currentStart += max(chunk.duration, 0.01)
            segmentIndex += 1

            await progress(FileTranscriptionProgress(
                phase: .transcribing,
                progress: totalDuration > 0 ? min(0.99, currentStart / totalDuration) : 0.99,
                currentSegment: segmentIndex,
                totalSegments: max(totalSegments, segmentIndex),
                partialText: accumulatedText,
                diarizationFellBack: diarizationFellBack
            ))

            if totalDuration == 0 { break }
        }

        try Task.checkCancellation()
        let result = recognizedSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !result.isEmpty else {
            throw FileTranscriptionError.noRecognizedText
        }

        await progress(FileTranscriptionProgress(
            phase: .finishing,
            progress: 1,
            currentSegment: max(segmentIndex, totalSegments),
            totalSegments: max(segmentIndex, totalSegments),
            partialText: result,
            diarizationFellBack: diarizationFellBack
        ))

        return result
    }

    private func decodeWindowWithRetry(
        url: URL,
        startTime: TimeInterval,
        duration: TimeInterval
    ) async throws -> DecodedAudio {
        let attempts = [
            duration,
            min(duration, 15),
            min(duration, 5)
        ]
        .filter { $0 > 0.05 }
        .reduce(into: [TimeInterval]()) { result, value in
            if !result.contains(where: { abs($0 - value) < 0.01 }) {
                result.append(value)
            }
        }

        var lastError: Error?
        for attemptDuration in attempts {
            do {
                return try await decoder.decode(
                    url: url,
                    timeRange: MediaAudioTimeRange(
                        start: startTime,
                        duration: attemptDuration
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        let reason = (lastError as? LocalizedError)?.errorDescription
            ?? lastError?.localizedDescription
            ?? ""
        throw FileTranscriptionError.segmentDecodingFailed(
            startTime: startTime,
            reason: reason
        )
    }

    private func shouldUsePartialResultAfterTailDecodeFailure(
        currentStart: TimeInterval,
        totalDuration: TimeInterval,
        recognizedSegments: [String]
    ) -> Bool {
        guard !recognizedSegments.isEmpty, totalDuration > 0 else { return false }
        let remainingDuration = max(0, totalDuration - currentStart)
        let progress = currentStart / totalDuration
        return remainingDuration <= targetChunkDuration + boundarySearchWindow
            || progress >= 0.95
    }

    static func makeChunks(
        samples: [Float],
        sampleRate: Int,
        targetDuration: TimeInterval = 30,
        searchWindow: TimeInterval = 2
    ) -> [DecodedAudioChunk] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }

        let targetSamples = max(1, Int(targetDuration * Double(sampleRate)))
        let searchSamples = max(0, Int(searchWindow * Double(sampleRate)))
        let windowSamples = max(1, Int(0.25 * Double(sampleRate)))
        let stepSamples = max(1, Int(0.10 * Double(sampleRate)))
        let minimumChunkSamples = min(samples.count, max(1, Int(5.0 * Double(sampleRate))))
        let lowEnergyThreshold: Float = 0.003

        var chunks: [DecodedAudioChunk] = []
        var start = 0

        while start < samples.count {
            let remaining = samples.count - start
            if remaining <= targetSamples {
                chunks.append(chunk(samples: samples, start: start, end: samples.count, sampleRate: sampleRate))
                break
            }

            let targetEnd = min(samples.count, start + targetSamples)
            let minEnd = min(samples.count, max(start + minimumChunkSamples, targetEnd - searchSamples))
            let maxEnd = min(samples.count, targetEnd + searchSamples)

            let chosenEnd = bestLowEnergyBoundary(
                samples: samples,
                fallback: targetEnd,
                minEnd: minEnd,
                maxEnd: maxEnd,
                windowSamples: windowSamples,
                stepSamples: stepSamples,
                threshold: lowEnergyThreshold
            )

            let end = max(start + 1, min(chosenEnd, samples.count))
            chunks.append(chunk(samples: samples, start: start, end: end, sampleRate: sampleRate))
            start = end
        }

        return chunks
    }

    static func makeChunkFromWindow(
        samples: [Float],
        sampleRate: Int,
        startTime: TimeInterval,
        targetDuration: TimeInterval = 30,
        searchWindow: TimeInterval = 2
    ) -> DecodedAudioChunk {
        guard !samples.isEmpty, sampleRate > 0 else {
            return DecodedAudioChunk(samples: [], startTime: startTime, duration: 0)
        }

        let targetSamples = max(1, Int(targetDuration * Double(sampleRate)))
        let searchSamples = max(0, Int(searchWindow * Double(sampleRate)))

        if samples.count <= targetSamples {
            return chunk(samples: samples, start: 0, end: samples.count, sampleRate: sampleRate, startTime: startTime)
        }

        let windowSamples = max(1, Int(0.25 * Double(sampleRate)))
        let stepSamples = max(1, Int(0.10 * Double(sampleRate)))
        let minimumChunkSamples = min(samples.count, max(1, Int(5.0 * Double(sampleRate))))
        let minEnd = min(samples.count, max(minimumChunkSamples, targetSamples - searchSamples))
        let maxEnd = min(samples.count, targetSamples + searchSamples)
        let lowEnergyThreshold: Float = 0.003

        let chosenEnd = bestLowEnergyBoundary(
            samples: samples,
            fallback: min(targetSamples, samples.count),
            minEnd: minEnd,
            maxEnd: maxEnd,
            windowSamples: windowSamples,
            stepSamples: stepSamples,
            threshold: lowEnergyThreshold
        )
        let end = max(1, min(chosenEnd, samples.count))
        return chunk(samples: samples, start: 0, end: end, sampleRate: sampleRate, startTime: startTime)
    }

    private static func bestLowEnergyBoundary(
        samples: [Float],
        fallback: Int,
        minEnd: Int,
        maxEnd: Int,
        windowSamples: Int,
        stepSamples: Int,
        threshold: Float
    ) -> Int {
        var bestIndex = fallback
        var bestEnergy = Float.greatestFiniteMagnitude

        guard minEnd < maxEnd else { return fallback }

        var index = minEnd
        while index < maxEnd {
            let end = min(samples.count, index + windowSamples)
            guard end > index else { break }
            let energy = meanAbsoluteEnergy(samples, start: index, end: end)
            if energy < bestEnergy {
                bestEnergy = energy
                bestIndex = index
            }
            index += stepSamples
        }

        return bestEnergy <= threshold ? bestIndex : fallback
    }

    private static func meanAbsoluteEnergy(_ samples: [Float], start: Int, end: Int) -> Float {
        let count = max(1, end - start)
        var total: Float = 0
        for index in start..<end {
            total += abs(samples[index])
        }
        return total / Float(count)
    }

    private static func chunk(
        samples: [Float],
        start: Int,
        end: Int,
        sampleRate: Int
    ) -> DecodedAudioChunk {
        let range = start..<end
        return DecodedAudioChunk(
            samples: Array(samples[range]),
            startTime: Double(start) / Double(sampleRate),
            duration: Double(end - start) / Double(sampleRate)
        )
    }

    private static func chunk(
        samples: [Float],
        start: Int,
        end: Int,
        sampleRate: Int,
        startTime: TimeInterval
    ) -> DecodedAudioChunk {
        let range = start..<end
        return DecodedAudioChunk(
            samples: Array(samples[range]),
            startTime: startTime + Double(start) / Double(sampleRate),
            duration: Double(end - start) / Double(sampleRate)
        )
    }
}
