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

    func testEngineReturnsSenseVoiceFinalTextAndWritesWAV() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_engine_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let finalRecognizer = MockSpeechRecognizer()
        finalRecognizer.queuedRecognizeResults = ["第一段", "第二段", "第三段"]

        let writer = try WAVSampleFileWriter(url: audioURL)
        // previewDecodeInterval 取大值：本测试只验证最终稿路径，不触发预览解码
        let engine = RecordingTranscriptionEngine(
            finalRecognizer: finalRecognizer,
            writer: writer,
            sampleRate: 10,
            finalSegmentDuration: 0.2,
            finalBoundarySearchWindow: 0,
            previewDecodeInterval: 100
        )

        let stream = AsyncStream<[Float]> { continuation in
            continuation.yield([0.1, 0.2])
            continuation.yield([0.3, 0.4])
            continuation.yield([0.5])
            continuation.finish()
        }

        let result = try await engine.run(audioChunks: stream) { _ in }

        XCTAssertEqual(result.finalText, "第一段\n第二段\n第三段")
        XCTAssertEqual(finalRecognizer.receivedSamples, [[Float(0.1), Float(0.2)], [Float(0.3), Float(0.4)], [Float(0.5)]])
        let samples = try XCTUnwrap(WAVSampleFileWriter.readFloat32Samples(from: audioURL))
        XCTAssertEqual(samples, [Float(0.1), Float(0.2), Float(0.3), Float(0.4), Float(0.5)])
    }

    func testEngineThrowsWhenSenseVoiceReturnsNoFinalText() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_engine_empty_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let finalRecognizer = MockSpeechRecognizer()
        finalRecognizer.recognizeResult = ""

        let writer = try WAVSampleFileWriter(url: audioURL)
        let engine = RecordingTranscriptionEngine(
            finalRecognizer: finalRecognizer,
            writer: writer,
            sampleRate: 10,
            finalSegmentDuration: 0.2,
            finalBoundarySearchWindow: 0,
            previewDecodeInterval: 100
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

        let finalRecognizer = MockSpeechRecognizer()
        finalRecognizer.queuedRecognizeResults = ["seg1", "seg2", "seg3"]

        let writer = try WAVSampleFileWriter(url: audioURL)
        let engine = RecordingTranscriptionEngine(
            finalRecognizer: finalRecognizer,
            writer: writer,
            sampleRate: 10,
            finalSegmentDuration: 0.2,
            finalBoundarySearchWindow: 0,
            previewDecodeInterval: 100
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

    // MARK: - SenseVoice 伪流式预览

    func testEngineEmitsSenseVoicePreviewUpdatesDuringRecording() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_engine_preview_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let finalRecognizer = MockSpeechRecognizer()
        finalRecognizer.recognizeResult = "プレビュー"

        let writer = try WAVSampleFileWriter(url: audioURL)
        // previewDecodeInterval 0.1s × sampleRate 10 → 每 1 个样本即可触发一次预览解码
        let engine = RecordingTranscriptionEngine(
            finalRecognizer: finalRecognizer,
            writer: writer,
            sampleRate: 10,
            finalSegmentDuration: 10,
            finalBoundarySearchWindow: 0,
            previewDecodeInterval: 0.1
        )

        var continuation: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]> { continuation = $0 }

        var updates: [StreamingRecognitionUpdate] = []
        let runTask = Task { @MainActor in
            try await engine.run(audioChunks: stream) { update in
                updates.append(update)
            }
        }

        continuation.yield([0.1, 0.2])
        try await waitUntil("preview update arrives") {
            !updates.isEmpty
        }
        XCTAssertEqual(updates.last?.displayText, "プレビュー")

        continuation.finish()
        let result = try await runTask.value
        XCTAssertEqual(result.finalText, "プレビュー")
    }

    func testPreviewDecoderFinalTextReplacesStashAfterSegmentCut() async throws {
        let recognizer = MockSpeechRecognizer()
        recognizer.queuedRecognizeResults = ["预览一", "预览二"]
        let gate = SpeechRecognitionGate(recognizer: recognizer)
        var updates: [StreamingRecognitionUpdate] = []
        let decoder = RecordingPreviewDecoder(gate: gate, sampleRate: 10) { update in
            updates.append(update)
        }

        // 第 0 段录音中预览
        await decoder.decodeIfIdle(pending: [0.1], segmentIndex: 0, totalSampleCount: 1)
        try await waitUntil("first preview update") { !updates.isEmpty }
        XCTAssertEqual(updates.last?.displayText, "预览一")

        // 切段：预览文本转为占位，不消失
        await decoder.segmentCut(index: 0)

        // 第 0 段最终稿就绪：替换占位
        await decoder.segmentFinalized(index: 0, text: "最终一")
        try await waitUntil("finalized update") { updates.last?.committedText == "最终一" }
        XCTAssertEqual(updates.last?.displayText, "最终一")

        // 第 1 段继续预览：拼接在最终稿之后
        await decoder.decodeIfIdle(pending: [0.2], segmentIndex: 1, totalSampleCount: 2)
        try await waitUntil("second preview update") { updates.last?.partialText == "预览二" }
        XCTAssertEqual(updates.last?.displayText, "最终一\n预览二")

        let previewText = await decoder.stop()
        XCTAssertEqual(previewText, "最终一\n预览二")
    }

    func testPreviewDecoderSkipsStaleAndBusyTriggers() async throws {
        let recognizer = MockSpeechRecognizer()
        recognizer.recognizeResult = "文本"
        let gate = SpeechRecognitionGate(recognizer: recognizer)
        let decoder = RecordingPreviewDecoder(gate: gate, sampleRate: 10) { _ in }

        await decoder.decodeIfIdle(pending: [0.1], segmentIndex: 0, totalSampleCount: 10)
        XCTAssertEqual(recognizer.recognizeCallCount, 1)

        // 乱序到达的旧触发被丢弃
        await decoder.decodeIfIdle(pending: [0.1], segmentIndex: 0, totalSampleCount: 5)
        XCTAssertEqual(recognizer.recognizeCallCount, 1)

        // busy 时新触发被跳过
        recognizer.recognizeDelay = 200_000_000
        let inFlight = Task {
            await decoder.decodeIfIdle(pending: [0.1, 0.2], segmentIndex: 0, totalSampleCount: 20)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await decoder.decodeIfIdle(pending: [0.1, 0.2, 0.3], segmentIndex: 0, totalSampleCount: 30)
        await inFlight.value
        XCTAssertEqual(recognizer.recognizeCallCount, 2)
    }

    func testPreviewDecoderStopsEmittingAfterStop() async throws {
        let recognizer = MockSpeechRecognizer()
        recognizer.recognizeResult = "文本"
        let gate = SpeechRecognitionGate(recognizer: recognizer)
        let decoder = RecordingPreviewDecoder(gate: gate, sampleRate: 10) { _ in }

        _ = await decoder.stop()
        await decoder.decodeIfIdle(pending: [0.1], segmentIndex: 0, totalSampleCount: 1)
        XCTAssertEqual(recognizer.recognizeCallCount, 0)
    }

    func testPreviewDecoderLateDecodeResultLandsInStash() async throws {
        let recognizer = MockSpeechRecognizer()
        recognizer.recognizeResult = "迟到的预览"
        recognizer.recognizeDelay = 100_000_000
        let gate = SpeechRecognitionGate(recognizer: recognizer)
        let decoder = RecordingPreviewDecoder(gate: gate, sampleRate: 10) { _ in }

        // 解码进行中该段被切走：结果应转入占位而不是当前段
        let inFlight = Task {
            await decoder.decodeIfIdle(pending: [0.1], segmentIndex: 0, totalSampleCount: 1)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        await decoder.segmentCut(index: 0)
        await inFlight.value

        let previewText = await decoder.stop()
        XCTAssertEqual(previewText, "迟到的预览")
    }

    func testPreviewDecoderFreezesPiecesAndSlicesAudio() async throws {
        let recognizer = MockSpeechRecognizer()
        recognizer.queuedDetailedResults = [
            // 「界」(0.6)与「再」(1.8)之间 1.2s 停顿 → 冻结「你好世界」，
            // 切点 = max(0.6+0.25, 1.8-0.5) = 1.3s（13 样本 @10Hz）
            DetailedRecognition(
                text: "你好世界再见",
                tokens: ["你", "好", "世", "界", "再", "见"],
                timestamps: [0.0, 0.2, 0.4, 0.6, 1.8, 2.0]
            ),
            DetailedRecognition(text: "新内容", tokens: ["新", "内", "容"], timestamps: [0.0, 0.2, 0.4]),
        ]
        let gate = SpeechRecognitionGate(recognizer: recognizer)
        var updates: [StreamingRecognitionUpdate] = []
        let decoder = RecordingPreviewDecoder(gate: gate, sampleRate: 10) { update in
            updates.append(update)
        }

        await decoder.decodeIfIdle(pending: Array(repeating: 0.1, count: 40), segmentIndex: 0, totalSampleCount: 40)
        try await waitUntil("freeze update") { updates.last?.partialText == "你好世界\n再见" }
        XCTAssertEqual(recognizer.receivedSamples.last?.count, 40)

        // 第二次：只应解码冻结点之后的音频；冻结句文本保持不变
        await decoder.decodeIfIdle(pending: Array(repeating: 0.1, count: 50), segmentIndex: 0, totalSampleCount: 50)
        try await waitUntil("sliced update") { updates.last?.partialText == "你好世界\n新内容" }
        XCTAssertEqual(recognizer.receivedSamples.last?.count, 37, "冻结点(13 样本)之前的音频不应重解码")
    }

    func testPreviewDecoderSplitsPartialAtPauseBoundaries() async throws {
        let recognizer = MockSpeechRecognizer()
        // 「界」与「再」之间 1.2s 的 token 间隔 = 真实停顿 → partial 应插入换行
        recognizer.detailedResult = DetailedRecognition(
            text: "你好世界再见",
            tokens: ["你", "好", "世", "界", "再", "见"],
            timestamps: [0.0, 0.2, 0.4, 0.6, 1.8, 2.0]
        )
        let gate = SpeechRecognitionGate(recognizer: recognizer)
        var updates: [StreamingRecognitionUpdate] = []
        let decoder = RecordingPreviewDecoder(gate: gate, sampleRate: 10) { update in
            updates.append(update)
        }

        await decoder.decodeIfIdle(pending: [0.1], segmentIndex: 0, totalSampleCount: 1)
        try await waitUntil("pause-split preview update") { !updates.isEmpty }
        XCTAssertEqual(updates.last?.partialText, "你好世界\n再见")
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
