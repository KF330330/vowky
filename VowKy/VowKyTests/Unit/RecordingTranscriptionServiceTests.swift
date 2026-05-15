import XCTest
@testable import VowKy

@MainActor
final class RecordingTranscriptionServiceTests: XCTestCase {
    func testOutputStoreCreatesDirectoryAndAvoidsDuplicateNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_recording_output_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RecordingTranscriptionOutputStore(outputDirectory: directory)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try store.prepareOutput(startedAt: date)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try "existing".write(to: first.textURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: first.audioURL.path, contents: Data())

        let second = try store.prepareOutput(startedAt: date)
        XCTAssertNotEqual(first.textURL.lastPathComponent, second.textURL.lastPathComponent)
        XCTAssertTrue(second.textURL.lastPathComponent.hasSuffix("-2.md"))
        XCTAssertTrue(second.audioURL.lastPathComponent.hasSuffix("-2.wav"))
    }

    func testEnginePublishesParaformerPreviewAndReturnsSenseVoiceFinalText() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_engine_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let previewRecognizer = MockStreamingSpeechRecognizer()
        previewRecognizer.queuedAcceptUpdates = [
            StreamingRecognitionUpdate(committedText: "", partialText: "实时", isFinal: false),
            StreamingRecognitionUpdate(committedText: "实时文本", partialText: "", isFinal: false)
        ]
        previewRecognizer.finishUpdate = StreamingRecognitionUpdate(
            committedText: "实时文本\nParaformer最终",
            partialText: "",
            isFinal: true
        )
        let finalRecognizer = MockSpeechRecognizer()
        finalRecognizer.queuedRecognizeResults = ["第一段", "第二段", "第三段"]

        let writer = try WAVSampleFileWriter(url: audioURL)
        let engine = RecordingTranscriptionEngine(
            previewRecognizer: previewRecognizer,
            finalRecognizer: finalRecognizer,
            writer: writer,
            sampleRate: 10,
            finalSegmentDuration: 0.2,
            finalBoundarySearchWindow: 0
        )

        let stream = AsyncStream<[Float]> { continuation in
            continuation.yield([0.1, 0.2])
            continuation.yield([0.3, 0.4])
            continuation.yield([0.5])
            continuation.finish()
        }

        var updates: [StreamingRecognitionUpdate] = []
        let result = try await engine.run(audioChunks: stream) { update in
            updates.append(update)
        }

        XCTAssertEqual(result.previewText, "实时文本\nParaformer最终")
        XCTAssertEqual(result.finalText, "第一段\n第二段\n第三段")
        XCTAssertEqual(updates.map(\.displayText), ["实时", "实时文本", "实时文本\nParaformer最终"])
        XCTAssertEqual(previewRecognizer.acceptCallCount, 3)
        XCTAssertEqual(previewRecognizer.finishCallCount, 1)
        XCTAssertEqual(finalRecognizer.receivedSamples, [[Float(0.1), Float(0.2)], [Float(0.3), Float(0.4)], [Float(0.5)]])
        let samples = try XCTUnwrap(WAVSampleFileWriter.readFloat32Samples(from: audioURL))
        XCTAssertEqual(samples, [Float(0.1), Float(0.2), Float(0.3), Float(0.4), Float(0.5)])
    }

    func testEngineThrowsWhenSenseVoiceReturnsNoFinalText() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_engine_empty_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let previewRecognizer = MockStreamingSpeechRecognizer()
        let finalRecognizer = MockSpeechRecognizer()
        finalRecognizer.recognizeResult = ""

        let writer = try WAVSampleFileWriter(url: audioURL)
        let engine = RecordingTranscriptionEngine(
            previewRecognizer: previewRecognizer,
            finalRecognizer: finalRecognizer,
            writer: writer,
            sampleRate: 10,
            finalSegmentDuration: 0.2,
            finalBoundarySearchWindow: 0
        )

        let stream = AsyncStream<[Float]> { continuation in
            continuation.yield([0.1, 0.2])
            continuation.finish()
        }

        do {
            _ = try await engine.run(audioChunks: stream) { _ in }
            XCTFail("Expected no final recognition text error")
        } catch let error as RecordingTranscriptionError {
            XCTAssertEqual(error, .noFinalRecognitionText)
        }
    }

    func testEngineEmitsFinalizationProgress() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_engine_progress_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let previewRecognizer = MockStreamingSpeechRecognizer()
        previewRecognizer.finishUpdate = StreamingRecognitionUpdate(
            committedText: "preview",
            partialText: "",
            isFinal: true
        )
        let finalRecognizer = MockSpeechRecognizer()
        finalRecognizer.queuedRecognizeResults = ["seg1", "seg2", "seg3"]

        let writer = try WAVSampleFileWriter(url: audioURL)
        let engine = RecordingTranscriptionEngine(
            previewRecognizer: previewRecognizer,
            finalRecognizer: finalRecognizer,
            writer: writer,
            sampleRate: 10,
            finalSegmentDuration: 0.2,
            finalBoundarySearchWindow: 0
        )

        let stream = AsyncStream<[Float]> { continuation in
            continuation.yield([0.1, 0.2])
            continuation.yield([0.3, 0.4])
            continuation.yield([0.5])
            continuation.finish()
        }

        var progressEvents: [RecordingFinalizationProgress] = []
        let result = try await engine.run(audioChunks: stream) { _ in
        } finalizationProgress: { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(result.finalText, "seg1\nseg2\nseg3")
        XCTAssertFalse(progressEvents.isEmpty)
        XCTAssertEqual(progressEvents.last?.total, 3)
        XCTAssertEqual(progressEvents.last?.completed, 3)
        XCTAssertEqual(progressEvents.last?.inputClosed, true)

        XCTAssertTrue(progressEvents.contains { $0.inputClosed }, "Expected at least one inputClosed event")

        var lastCompleted = -1
        var lastTotal = -1
        for event in progressEvents {
            XCTAssertGreaterThanOrEqual(event.completed, lastCompleted)
            XCTAssertGreaterThanOrEqual(event.total, lastTotal)
            XCTAssertLessThanOrEqual(event.completed, event.total)
            lastCompleted = event.completed
            lastTotal = event.total
        }
    }
}
