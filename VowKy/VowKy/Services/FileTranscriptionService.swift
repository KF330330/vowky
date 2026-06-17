import Foundation

struct DecodedAudioChunk {
    let samples: [Float]
    let startTime: TimeInterval
    let duration: TimeInterval
}

struct FileTranscriptionProgress {
    enum Phase: Equatable {
        case reading
        case transcribing
        case finishing
    }

    let phase: Phase
    let progress: Double
    let currentSegment: Int
    let totalSegments: Int
    let partialText: String
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
    private let punctuationService: PunctuationServiceProtocol?
    private let targetChunkDuration: TimeInterval
    private let boundarySearchWindow: TimeInterval
    /// 礼让闸：每个分块前调用。实时语音输入活动时挂起，让出共用 helper；为 nil 时不礼让（CLI/测试）。
    private let yieldToVoiceInput: (() async -> Void)?

    init(
        decoder: MediaAudioDecoding = MediaAudioDecoder(),
        speechRecognizer: SpeechRecognizerProtocol,
        punctuationService: PunctuationServiceProtocol?,
        targetChunkDuration: TimeInterval = 30,
        boundarySearchWindow: TimeInterval = 2,
        yieldToVoiceInput: (() async -> Void)? = nil
    ) {
        self.decoder = decoder
        self.speechRecognizer = speechRecognizer
        self.punctuationService = punctuationService
        self.targetChunkDuration = targetChunkDuration
        self.boundarySearchWindow = boundarySearchWindow
        self.yieldToVoiceInput = yieldToVoiceInput
    }

    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        await progress(FileTranscriptionProgress(
            phase: .reading,
            progress: 0,
            currentSegment: 0,
            totalSegments: 0,
            partialText: ""
        ))

        let info = try await decoder.loadInfo(url: url)
        try Task.checkCancellation()

        let totalDuration = max(0, info.duration)
        let totalSegments = max(1, Int(ceil(totalDuration / targetChunkDuration)))
        var recognizedSegments: [String] = []
        var currentStart: TimeInterval = 0
        var segmentIndex = 0

        while currentStart < totalDuration || (totalDuration == 0 && segmentIndex == 0) {
            // 实时语音输入活动时在此挂起（解码前完全礼让），语音结束后继续。取消会立即唤醒。
            await yieldToVoiceInput?()
            try Task.checkCancellation()
            let partialText = recognizedSegments.joined(separator: "\n")
            await progress(FileTranscriptionProgress(
                phase: .transcribing,
                progress: totalDuration > 0 ? min(0.99, currentStart / totalDuration) : 0,
                currentSegment: segmentIndex + 1,
                totalSegments: max(totalSegments, segmentIndex + 1),
                partialText: partialText
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

            let finalText = punctuationService?.addPunctuation(to: rawText) ?? rawText
            recognizedSegments.append(finalText)
            currentStart += max(chunk.duration, 0.01)
            segmentIndex += 1

            await progress(FileTranscriptionProgress(
                phase: .transcribing,
                progress: totalDuration > 0 ? min(0.99, currentStart / totalDuration) : 0.99,
                currentSegment: segmentIndex,
                totalSegments: max(totalSegments, segmentIndex),
                partialText: recognizedSegments.joined(separator: "\n")
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
            partialText: result
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
