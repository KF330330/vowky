import XCTest
@testable import VowKy

@MainActor
final class RecordingTranscriptionViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var appState: AppState!
    private var mockRecorder: MockAudioRecorder!
    private var mockRecognizer: MockStreamingSpeechRecognizer!
    private var mockFinalRecognizer: MockSpeechRecognizer!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_recording_vm_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        mockRecorder = MockAudioRecorder()
        mockRecognizer = MockStreamingSpeechRecognizer()
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
        mockRecognizer = nil
        mockFinalRecognizer = nil
        tempDir = nil
        super.tearDown()
    }

    func testStartStopSavesTextAndAudioAndRecordsHistory() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2, 0.3]]
        mockRecognizer.queuedAcceptUpdates = [
            StreamingRecognitionUpdate(committedText: "", partialText: "实时文本", isFinal: false)
        ]
        mockRecognizer.finishUpdate = StreamingRecognitionUpdate(
            committedText: "Paraformer最终",
            partialText: "",
            isFinal: true
        )
        mockFinalRecognizer.recognizeResult = "SenseVoice最终"
        let punctuation = MockPunctuationService()
        var recordedResults: [String] = []

        let viewModel = makeViewModel(
            punctuationService: punctuation,
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.start()
        try await waitUntil("recording starts") {
            viewModel.state == .recording
        }
        XCTAssertTrue(appState.isRecordingTranscriptionInProgress)
        XCTAssertEqual(viewModel.transcriptText, "实时文本")

        viewModel.stop()
        XCTAssertEqual(viewModel.state, .finishing)

        try await waitUntil("recording transcription completes") {
            viewModel.state == .completed
        }

        XCTAssertEqual(viewModel.transcriptText, "SenseVoice最终。")
        XCTAssertEqual(recordedResults, ["SenseVoice最终。"])
        XCTAssertFalse(appState.isRecordingTranscriptionInProgress)
        let output = try XCTUnwrap(viewModel.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.textURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
        XCTAssertEqual(try String(contentsOf: output.textURL), "SenseVoice最终。")
        let samples = try XCTUnwrap(WAVSampleFileWriter.readFloat32Samples(from: output.audioURL))
        XCTAssertEqual(samples, [Float(0.1), Float(0.2), Float(0.3)])
    }

    func testCancelDeletesPartialOutputsAndSkipsHistory() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1]]
        mockRecognizer.finishUpdate = StreamingRecognitionUpdate(
            committedText: "不应保存",
            partialText: "",
            isFinal: true
        )
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

    func testModelLoadFailureMarksFailedAndClearsAppGuard() async throws {
        mockRecognizer.isReady = false
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
        mockRecognizer.queuedAcceptUpdates = [
            StreamingRecognitionUpdate(committedText: "", partialText: "实时预览", isFinal: false)
        ]
        mockFinalRecognizer.recognizeResult = "慢速最终稿"
        mockFinalRecognizer.recognizeDelay = 300_000_000
        let viewModel = makeViewModel(punctuationService: MockPunctuationService())

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
        XCTAssertEqual(viewModel.transcriptText, "慢速最终稿。")
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
        punctuationService: PunctuationServiceProtocol? = nil,
        resultRecorder: ((String) -> Void)? = nil
    ) -> RecordingTranscriptionViewModel {
        RecordingTranscriptionViewModel(
            appState: appState,
            audioRecorder: mockRecorder,
            recognizerFactory: { self.mockRecognizer },
            finalRecognizer: mockFinalRecognizer,
            punctuationService: punctuationService,
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
