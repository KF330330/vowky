import XCTest
@testable import VowKy

private final class MockMediaAudioDecoder: MediaAudioDecoding {
    var decodedAudio: DecodedAudio
    var decodeCallCount = 0
    var decodeTimeRanges: [MediaAudioTimeRange] = []
    var failingDurations: [TimeInterval] = []
    var failingStartTimes: [TimeInterval] = []

    init(decodedAudio: DecodedAudio) {
        self.decodedAudio = decodedAudio
    }

    func loadInfo(url: URL) async throws -> MediaAudioInfo {
        MediaAudioInfo(duration: decodedAudio.duration)
    }

    func decode(url: URL) async throws -> DecodedAudio {
        decodeCallCount += 1
        return decodedAudio
    }

    func decode(url: URL, timeRange: MediaAudioTimeRange) async throws -> DecodedAudio {
        decodeCallCount += 1
        decodeTimeRanges.append(timeRange)

        if failingDurations.contains(where: { abs($0 - timeRange.duration) < 0.01 }) {
            throw MediaAudioDecoderError.readFailed("mock failure")
        }
        if failingStartTimes.contains(where: { abs($0 - timeRange.start) < 0.01 }) {
            throw MediaAudioDecoderError.readFailed("mock failure")
        }

        let sampleRate = decodedAudio.sampleRate
        let startIndex = max(0, Int(timeRange.start * Double(sampleRate)))
        let requestedCount = max(0, Int(timeRange.duration * Double(sampleRate)))
        let endIndex = min(decodedAudio.samples.count, startIndex + requestedCount)
        guard startIndex < endIndex else {
            return DecodedAudio(samples: [], sampleRate: sampleRate, duration: 0)
        }

        let samples = Array(decodedAudio.samples[startIndex..<endIndex])
        return DecodedAudio(
            samples: samples,
            sampleRate: sampleRate,
            duration: Double(samples.count) / Double(sampleRate)
        )
    }
}

@MainActor
final class FileTranscriptionServiceTests: XCTestCase {
    func testMakeChunksPrefersNearbyLowEnergyBoundary() {
        let sampleRate = 100
        var samples = Array(repeating: Float(0.02), count: 6_500)
        for index in 3_100..<3_220 {
            samples[index] = 0
        }

        let chunks = FileTranscriptionService.makeChunks(
            samples: samples,
            sampleRate: sampleRate,
            targetDuration: 30,
            searchWindow: 2
        )

        XCTAssertEqual(chunks.count, 3)
        XCTAssertGreaterThan(chunks[0].duration, 30.8)
        XCTAssertLessThan(chunks[0].duration, 32.3)
    }

    func testTranscribeSegmentsAddsPunctuationAndReportsProgress() async throws {
        let sampleRate = 100
        let samples = Array(repeating: Float(0.02), count: 6_500)
        let decoder = MockMediaAudioDecoder(decodedAudio: DecodedAudio(
            samples: samples,
            sampleRate: sampleRate,
            duration: 65
        ))
        let recognizer = MockSpeechRecognizer()
        recognizer.queuedRecognizeResults = ["第一段", "第二段", "第三段"]
        let punctuation = MockPunctuationService()
        let service = FileTranscriptionService(
            decoder: decoder,
            speechRecognizer: recognizer,
            punctuationService: punctuation
        )

        var updates: [FileTranscriptionProgress] = []
        let result = try await service.transcribe(url: URL(fileURLWithPath: "/tmp/fake.wav")) { update in
            updates.append(update)
        }

        XCTAssertEqual(result, "第一段。\n第二段。\n第三段。")
        XCTAssertEqual(decoder.decodeCallCount, 3)
        XCTAssertEqual(decoder.decodeTimeRanges.map { Int($0.start.rounded()) }, [0, 30, 60])
        XCTAssertEqual(recognizer.recognizeCallCount, 3)
        XCTAssertEqual(punctuation.addPunctuationCallCount, 3)
        XCTAssertEqual(updates.last?.progress, 1)
        XCTAssertEqual(updates.last?.partialText, result)
    }

    func testMakeChunkFromWindowPrefersNearbyLowEnergyBoundary() {
        let sampleRate = 100
        var samples = Array(repeating: Float(0.02), count: 3_200)
        for index in 2_900..<3_030 {
            samples[index] = 0
        }

        let chunk = FileTranscriptionService.makeChunkFromWindow(
            samples: samples,
            sampleRate: sampleRate,
            startTime: 120,
            targetDuration: 30,
            searchWindow: 2
        )

        XCTAssertGreaterThan(chunk.duration, 28.8)
        XCTAssertLessThan(chunk.duration, 30.5)
        XCTAssertEqual(chunk.startTime, 120, accuracy: 0.001)
    }

    func testTranscribeRetriesSmallerDecodeWindowAfterSegmentFailure() async throws {
        let sampleRate = 100
        let samples = Array(repeating: Float(0.02), count: 800)
        let decoder = MockMediaAudioDecoder(decodedAudio: DecodedAudio(
            samples: samples,
            sampleRate: sampleRate,
            duration: 8
        ))
        decoder.failingDurations = [8]
        let recognizer = MockSpeechRecognizer()
        recognizer.queuedRecognizeResults = ["第一段", ""]
        let service = FileTranscriptionService(
            decoder: decoder,
            speechRecognizer: recognizer,
            punctuationService: nil
        )

        let result = try await service.transcribe(url: URL(fileURLWithPath: "/tmp/fake.wav")) { _ in }

        XCTAssertEqual(result, "第一段")
        XCTAssertEqual(decoder.decodeTimeRanges.prefix(2).map { Int($0.duration.rounded()) }, [8, 5])
        XCTAssertEqual(recognizer.recognizeCallCount, 2)
    }

    func testTranscribeReturnsPartialResultWhenTailDecodeFailsAfterRecognizedText() async throws {
        let sampleRate = 100
        let samples = Array(repeating: Float(0.02), count: 10_000)
        let decoder = MockMediaAudioDecoder(decodedAudio: DecodedAudio(
            samples: samples,
            sampleRate: sampleRate,
            duration: 100
        ))
        decoder.failingStartTimes = [96]
        let recognizer = MockSpeechRecognizer()
        recognizer.queuedRecognizeResults = ["第一段", "第二段"]
        let service = FileTranscriptionService(
            decoder: decoder,
            speechRecognizer: recognizer,
            punctuationService: nil,
            targetChunkDuration: 48,
            boundarySearchWindow: 0
        )

        var updates: [FileTranscriptionProgress] = []
        let result = try await service.transcribe(url: URL(fileURLWithPath: "/tmp/fake.wav")) { update in
            updates.append(update)
        }

        XCTAssertEqual(result, "第一段\n第二段")
        XCTAssertEqual(updates.last?.phase, .finishing)
        XCTAssertEqual(updates.last?.progress, 1)
        XCTAssertEqual(updates.last?.partialText, result)
    }

    func testTranscribeSucceedsWhenTailRecognitionIsEmptyAfterRecognizedText() async throws {
        let sampleRate = 100
        let samples = Array(repeating: Float(0.02), count: 6_500)
        let decoder = MockMediaAudioDecoder(decodedAudio: DecodedAudio(
            samples: samples,
            sampleRate: sampleRate,
            duration: 65
        ))
        let recognizer = MockSpeechRecognizer()
        recognizer.queuedRecognizeResults = ["第一段", "第二段", ""]
        let service = FileTranscriptionService(
            decoder: decoder,
            speechRecognizer: recognizer,
            punctuationService: nil
        )

        let result = try await service.transcribe(url: URL(fileURLWithPath: "/tmp/fake.wav")) { _ in }

        XCTAssertEqual(result, "第一段\n第二段")
        XCTAssertEqual(recognizer.recognizeCallCount, 3)
    }

    func testTranscribeFailsWhenInitialDecodeFailsWithoutRecognizedText() async throws {
        let sampleRate = 100
        let samples = Array(repeating: Float(0.02), count: 6_500)
        let decoder = MockMediaAudioDecoder(decodedAudio: DecodedAudio(
            samples: samples,
            sampleRate: sampleRate,
            duration: 65
        ))
        decoder.failingStartTimes = [0]
        let recognizer = MockSpeechRecognizer()
        let service = FileTranscriptionService(
            decoder: decoder,
            speechRecognizer: recognizer,
            punctuationService: nil
        )

        do {
            _ = try await service.transcribe(url: URL(fileURLWithPath: "/tmp/fake.wav")) { _ in }
            XCTFail("Expected initial decode failure")
        } catch let error as FileTranscriptionError {
            XCTAssertEqual(error, .segmentDecodingFailed(startTime: 0, reason: "音频解码失败：mock failure"))
        }
    }

    func testTranscribeCancellationStopsBeforeNextSegment() async throws {
        let sampleRate = 100
        let samples = Array(repeating: Float(0.02), count: 6_500)
        let decoder = MockMediaAudioDecoder(decodedAudio: DecodedAudio(
            samples: samples,
            sampleRate: sampleRate,
            duration: 65
        ))
        let recognizer = MockSpeechRecognizer()
        recognizer.queuedRecognizeResults = ["第一段", "第二段", "第三段"]
        let service = FileTranscriptionService(
            decoder: decoder,
            speechRecognizer: recognizer,
            punctuationService: nil
        )

        var task: Task<String, Error>!
        task = Task {
            try await service.transcribe(url: URL(fileURLWithPath: "/tmp/fake.wav")) { update in
                if update.progress > 0 {
                    task.cancel()
                }
            }
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(recognizer.recognizeCallCount, 1)
        }
    }
}
