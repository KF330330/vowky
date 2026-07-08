import XCTest
@testable import VowKy

@MainActor
final class RecordingTranscriptionViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var appState: AppState!
    private var mockRecorder: MockAudioRecorder!
    private var mockFinalRecognizer: MockSpeechRecognizer!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_recording_vm_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        mockRecorder = MockAudioRecorder()
        mockFinalRecognizer = MockSpeechRecognizer()
        appState = AppState(
            speechRecognizer: MockSpeechRecognizer(),
            audioRecorder: mockRecorder,
            permissionChecker: MockPermissionChecker()
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        appState = nil
        mockRecorder = nil
        mockFinalRecognizer = nil
        tempDir = nil
        super.tearDown()
    }

    func testStartStopSavesTextAndAudioAndRecordsHistory() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2, 0.3]]
        mockFinalRecognizer.recognizeResult = "SenseVoice最终"
        var recordedResults: [String] = []

        let viewModel = makeViewModel(
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.start()
        try await waitUntil("recording starts") {
            viewModel.state == .recording
        }
        XCTAssertTrue(appState.isRecordingTranscriptionInProgress)

        viewModel.stop()
        XCTAssertEqual(viewModel.state, .finishing)

        try await waitUntil("recording transcription completes") {
            viewModel.state == .completed
        }

        XCTAssertEqual(viewModel.transcriptText, "SenseVoice最终")
        XCTAssertEqual(recordedResults, ["SenseVoice最终"])
        XCTAssertFalse(appState.isRecordingTranscriptionInProgress)
        let output = try XCTUnwrap(viewModel.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.textURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
        XCTAssertEqual(try String(contentsOf: output.textURL), "SenseVoice最终")
        let samples = try XCTUnwrap(WAVSampleFileWriter.readFloat32Samples(from: output.audioURL))
        XCTAssertEqual(samples, [Float(0.1), Float(0.2), Float(0.3)])
    }

    func testCancelDeletesPartialOutputsAndSkipsHistory() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1]]
        var recordedResults: [String] = []
        let viewModel = makeViewModel(resultRecorder: { recordedResults.append($0) })

        viewModel.start()
        try await waitUntil("recording starts") {
            viewModel.state == .recording
        }

        viewModel.cancel()

        XCTAssertEqual(viewModel.state, .cancelled)
        XCTAssertFalse(appState.isRecordingTranscriptionInProgress)
        XCTAssertNil(viewModel.output)
        XCTAssertEqual(recordedResults, [])
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }

    func testFinalRecognizerNotReadyMarksFailedAndClearsAppGuard() async throws {
        mockFinalRecognizer.isReady = false
        let viewModel = makeViewModel()

        viewModel.start()

        try await waitUntil("model load failure") {
            if case .failed = viewModel.state {
                return true
            }
            return false
        }

        XCTAssertFalse(appState.isRecordingTranscriptionInProgress)
        XCTAssertEqual(mockRecorder.startCallCount, 0)
    }

    func testStopWaitsForSlowSenseVoiceBeforeCompleting() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2]]
        mockFinalRecognizer.recognizeResult = "慢速最终稿"
        mockFinalRecognizer.recognizeDelay = 300_000_000
        let viewModel = makeViewModel()

        viewModel.start()
        try await waitUntil("recording starts") {
            viewModel.state == .recording
        }

        viewModel.stop()
        XCTAssertEqual(viewModel.state, .finishing)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.state, .finishing)

        try await waitUntil("slow final recognition completes", timeout: 1) {
            viewModel.state == .completed
        }
        XCTAssertEqual(viewModel.transcriptText, "慢速最终稿")
    }

    func testEmptySenseVoiceFinalTextFailsAndSkipsHistory() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2]]
        mockFinalRecognizer.recognizeResult = ""
        var recordedResults: [String] = []
        let viewModel = makeViewModel(resultRecorder: { recordedResults.append($0) })

        viewModel.start()
        try await waitUntil("recording starts") {
            viewModel.state == .recording
        }
        viewModel.stop()

        try await waitUntil("empty final recognition fails") {
            if case .failed = viewModel.state {
                return true
            }
            return false
        }

        XCTAssertNil(viewModel.output)
        XCTAssertEqual(recordedResults, [])
        XCTAssertFalse(appState.isRecordingTranscriptionInProgress)
        // 兜底策略：失败时保留 wav（用户没有主动取消），只删除空 txt
        XCTAssertNotNil(viewModel.recoveredAudioURL)
        if let recovered = viewModel.recoveredAudioURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path))
            let txtURL = recovered.deletingPathExtension().appendingPathExtension("txt")
            XCTAssertFalse(FileManager.default.fileExists(atPath: txtURL.path))
        }
    }

    func testCompleteWithoutSubtitleDisplays_writesNoSubtitleLogFile() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2, 0.3]]
        mockFinalRecognizer.recognizeResult = "最终稿"
        let viewModel = makeViewModel()

        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }
        viewModel.stop()
        try await waitUntil("recording transcription completes") { viewModel.state == .completed }

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(
            contents.contains { $0.contains("(\(LL("subtitleLog.export.filenameSuffix")))") },
            "整场没上过字幕不应产出实录文件：\(contents)"
        )
    }

    func testCompleteWithSubtitleRecords_writesSubtitleLogNextToTranscript() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2, 0.3]]
        mockFinalRecognizer.recognizeResult = "最终稿"
        let viewModel = makeViewModel()

        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }
        // 直接注入实录（不走真实 pacer：预览解码要凑样本，脆且慢）。
        // 注入必须在进入 recording 之后——start() 会 reset 记录器。
        viewModel.subtitleDisplayRecorder.record(
            TranscriptParagraph(id: "p-0", text: "第一句字幕。", isPartial: true,
                                translation: .translated("First subtitle.")),
            isNewSentence: true, at: 2.0
        )
        viewModel.subtitleDisplayRecorder.record(
            TranscriptParagraph(id: "p-0", text: "第二句字幕", isPartial: true, translation: .pending),
            isNewSentence: true, at: 5.0
        )
        viewModel.stop()
        try await waitUntil("recording transcription completes") { viewModel.state == .completed }

        let output = try XCTUnwrap(viewModel.output)
        let logURL = SubtitleDisplayRecorder.outputURL(for: output.textURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path), "实录文件应写在原文旁")
        let content = try String(contentsOf: logURL)
        XCTAssertTrue(content.contains("[00:02] 第一句字幕。"), content)
        XCTAssertTrue(content.contains("> First subtitle."), content)
        XCTAssertTrue(content.contains("[00:05] 第二句字幕"), content)
    }

    func testWaveformBandsReflectPCMPositiveAndNegativePeaks() {
        let samples: [Float] = [
            0.00, 0.03, -0.04, 0.01,
            -0.02, 0.05, -0.01, 0.02
        ]

        let bands = RecordingTranscriptionViewModel.displayWaveformBands(from: samples)

        XCTAssertEqual(bands.count, 64)
        XCTAssertTrue(bands.contains { $0.positive > 0.25 })
        XCTAssertTrue(bands.contains { $0.negative > 0.25 })
    }

    func testQuietWaveformBandsStayFlat() {
        let samples = Array(repeating: Float(0.002), count: 256)

        let bands = RecordingTranscriptionViewModel.displayWaveformBands(from: samples)

        XCTAssertEqual(bands.count, 64)
        XCTAssertTrue(bands.allSatisfy { $0.positive == 0 && $0.negative == 0 })
    }

    private func makeViewModel(
        resultRecorder: ((String) -> Void)? = nil
    ) -> RecordingTranscriptionViewModel {
        RecordingTranscriptionViewModel(
            appState: appState,
            audioRecorder: mockRecorder,
            finalRecognizer: mockFinalRecognizer,
            outputStore: RecordingTranscriptionOutputStore(outputDirectory: tempDir),
            resultRecorder: resultRecorder
        )
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
