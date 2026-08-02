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

    // MARK: - 暂停/继续

    func testPauseFromRecordingEntersPausedAndPausesRecorder() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2]]
        let viewModel = makeViewModel()

        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }

        viewModel.pause()

        XCTAssertEqual(viewModel.state, .paused)
        XCTAssertEqual(mockRecorder.pauseCallCount, 1)
        XCTAssertTrue(mockRecorder.isPaused)
        XCTAssertEqual(viewModel.audioLevel, 0)
        XCTAssertTrue(viewModel.canStop, "暂停态应可直接完成")
        XCTAssertTrue(viewModel.canCancel)
        XCTAssertTrue(viewModel.canResume)
        XCTAssertFalse(viewModel.canStart)
        XCTAssertFalse(viewModel.canPause)
        XCTAssertTrue(viewModel.isActivelyRecording, "退出拦截必须覆盖暂停态")
    }

    func testResumeInjectsSeamSilenceAndPipelineContinues() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2]]
        mockFinalRecognizer.recognizeResult = "跨暂停最终稿"
        let viewModel = makeViewModel()

        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }

        viewModel.pause()
        viewModel.resume()
        XCTAssertEqual(viewModel.state, .recording)
        XCTAssertEqual(mockRecorder.resumeCallCount, 1)
        mockRecorder.onSamplesCaptured?([0.3, 0.4])

        viewModel.stop()
        try await waitUntil("recording transcription completes") { viewModel.state == .completed }

        XCTAssertEqual(viewModel.transcriptText, "跨暂停最终稿")
        let output = try XCTUnwrap(viewModel.output)
        let samples = try XCTUnwrap(WAVSampleFileWriter.readFloat32Samples(from: output.audioURL))
        // 接缝静音 0.4s@16kHz = 6400 个零样本，且必须落在暂停前后样本之间
        let expected = [Float(0.1), Float(0.2)]
            + Array(repeating: Float(0), count: 6_400)
            + [Float(0.3), Float(0.4)]
        XCTAssertEqual(samples, expected)
    }

    func testStopWhilePausedGeneratesFinalTranscript() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2]]
        mockFinalRecognizer.recognizeResult = "暂停中直接完成"
        let viewModel = makeViewModel()

        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }

        viewModel.pause()
        viewModel.stop()
        XCTAssertEqual(viewModel.state, .finishing)

        try await waitUntil("recording transcription completes") { viewModel.state == .completed }

        let output = try XCTUnwrap(viewModel.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.textURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
        XCTAssertEqual(viewModel.transcriptText, "暂停中直接完成")
        // 暂停中完成不注接缝静音
        let samples = try XCTUnwrap(WAVSampleFileWriter.readFloat32Samples(from: output.audioURL))
        XCTAssertEqual(samples, [Float(0.1), Float(0.2)])
    }

    func testCancelWhilePausedStopsEngineAndDeletesOutputs() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1]]
        let viewModel = makeViewModel()

        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }

        viewModel.pause()
        viewModel.cancel()

        XCTAssertEqual(viewModel.state, .cancelled)
        XCTAssertEqual(mockRecorder.stopCallCount, 1, "暂停中取消必须关闭引擎，否则麦克风泄漏")
        XCTAssertFalse(appState.isRecordingTranscriptionInProgress)
        XCTAssertNil(viewModel.output)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }

    func testElapsedSecondsFreezesWhilePausedAndDurationExcludesPause() async throws {
        mockRecorder.samplesToEmitOnStart = [[0.1, 0.2]]
        mockFinalRecognizer.recognizeResult = "时长口径"
        let viewModel = makeViewModel()

        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }
        try await Task.sleep(nanoseconds: 200_000_000)

        viewModel.pause()
        let frozenElapsed = viewModel.elapsedSeconds
        XCTAssertGreaterThan(frozenElapsed, 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(viewModel.elapsedSeconds, frozenElapsed, "暂停期间计时必须冻结")

        viewModel.resume()
        viewModel.stop()
        try await waitUntil("recording transcription completes") { viewModel.state == .completed }

        let output = try XCTUnwrap(viewModel.output)
        // 总墙钟 ≥ 0.7s，其中暂停 0.5s；有效时长应只计录音段
        XCTAssertLessThan(output.duration, 0.5, "duration 不应包含暂停时长")
        XCTAssertGreaterThanOrEqual(output.duration, frozenElapsed)
    }

    func testPauseResumeAreNoOpsWhenNotInMatchingState() async throws {
        let viewModel = makeViewModel()

        viewModel.pause()
        viewModel.resume()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(mockRecorder.pauseCallCount, 0)
        XCTAssertEqual(mockRecorder.resumeCallCount, 0)
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

    // MARK: - 说话人分离后处理

    /// 录 2 秒(32000 样本@16k)→停止→等完成。返回 (viewModel, 收到的 metadata 文本)。
    /// 识别 mock 按样本数编程:引擎的预览/最终识别都是整段 32000 样本,
    /// 后处理的逐段识别是 padding 后的段大小——识别调用次数不确定也能稳定区分。
    private func runRecordingToCompletion(
        diarizer: SpeakerDiarizing?,
        diarizationEnabled: Bool,
        recognizer: @escaping ([Float]) -> String?
    ) async throws -> (RecordingTranscriptionViewModel, [String]) {
        mockRecorder.samplesToEmitOnStart = [Array(repeating: Float(0.1), count: 32_000)]
        mockFinalRecognizer.recognizeResultProvider = recognizer
        var metadataTexts: [String] = []
        let viewModel = makeViewModel(
            metadataRecorder: { text, _ in metadataTexts.append(text) },
            diarizer: diarizer,
            diarizationEnabled: diarizationEnabled
        )
        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }
        viewModel.stop()
        try await waitUntil("recording completes") { viewModel.state == .completed }
        return (viewModel, metadataTexts)
    }

    func testDiarizationPostPassLabelsTranscriptAndMetadata() async throws {
        let diarizer = MockDiarizer()
        diarizer.segmentsToReturn = [
            SpeakerSegment(start: 0, end: 0.8, speaker: 0),
            SpeakerSegment(start: 1.0, end: 1.8, speaker: 4),
        ]
        // padding 后:段1 (0,1.0)=16000 样本、段2 (0.8,2.0)=19200 样本;引擎整段调用为 32000
        let (viewModel, metadataTexts) = try await runRecordingToCompletion(
            diarizer: diarizer, diarizationEnabled: true,
            recognizer: { samples in
                switch samples.count {
                case 16_000: return "甲的话"
                case 19_200: return "乙的话"
                default: return "原文全部"
                }
            }
        )

        // 期望文本用同一组装函数生成,与生产标签文案解耦
        let expected = SpeakerSegmentComposer.compose([
            .init(speaker: 1, text: "甲的话"),
            .init(speaker: 2, text: "乙的话"),
        ]) { LL("diarization.speakerLabel", $0) }
        XCTAssertEqual(viewModel.transcriptText, expected)
        XCTAssertEqual(metadataTexts, [expected])
        XCTAssertEqual(diarizer.diarizeCallCount, 1)
        XCTAssertEqual(diarizer.lastAudioDuration, 2.0, accuracy: 0.01)
        XCTAssertNil(viewModel.diarizationNote)
        let output = try XCTUnwrap(viewModel.output)
        XCTAssertEqual(try String(contentsOf: output.textURL), expected)
    }

    func testDiarizationPostPassFailureFallsBackToPlainTranscript() async throws {
        let diarizer = MockDiarizer()
        diarizer.errorToThrow = SpeakerDiarizationError.processFailed("mock failure")
        let (viewModel, metadataTexts) = try await runRecordingToCompletion(
            diarizer: diarizer, diarizationEnabled: true,
            recognizer: { _ in "原文全部" }
        )

        XCTAssertEqual(viewModel.transcriptText, "原文全部")
        XCTAssertEqual(metadataTexts, ["原文全部"])
        XCTAssertNotNil(viewModel.diarizationNote)
    }

    func testDiarizationPostPassSingleSpeakerSkipsRelabeling() async throws {
        let diarizer = MockDiarizer()
        diarizer.segmentsToReturn = [
            SpeakerSegment(start: 0, end: 0.8, speaker: 2),
            SpeakerSegment(start: 1.0, end: 1.8, speaker: 2),
        ]
        let (viewModel, _) = try await runRecordingToCompletion(
            diarizer: diarizer, diarizationEnabled: true,
            recognizer: { _ in "原文全部" }
        )

        XCTAssertEqual(viewModel.transcriptText, "原文全部")
        XCTAssertEqual(diarizer.diarizeCallCount, 1)
        // 单说话人跳过逐段重识别:识别只见过整段音频,从未收到 padding 段大小的输入
        XCTAssertTrue(mockFinalRecognizer.receivedSamples.allSatisfy { $0.count == 32_000 })
        XCTAssertNil(viewModel.diarizationNote)
    }

    func testDiarizationSuccessFinalSegmentsSameSourceAsDisk() async throws {
        // P0 回归（2026-08-02）：分离成功时窗口/翻译数据源必须与落盘同源
        // （同一批逐段重识别结果），不得再用整段长解码的 result.finalText。
        let diarizer = MockDiarizer()
        // 边界值全部取二进制可精确表示的 0.25 倍数，避免 Double 截断使样本数偏 1
        diarizer.segmentsToReturn = [
            SpeakerSegment(start: 0, end: 0.5, speaker: 0),
            SpeakerSegment(start: 1.0, end: 1.5, speaker: 4),
            SpeakerSegment(start: 1.75, end: 2.0, speaker: 4),
        ]
        // padding 后:段1 (0,0.75)=12000、段2 (0.75,1.75)=16000、段3 (1.5,2.0)=8000;引擎整段 32000
        let (viewModel, _) = try await runRecordingToCompletion(
            diarizer: diarizer, diarizationEnabled: true,
            recognizer: { samples in
                switch samples.count {
                case 12_000: return "甲的第一句"
                case 16_000: return "乙的第一句"
                case 8_000: return "乙的第二句"
                default: return "整段长解码产物"
                }
            }
        )

        // 落盘 = labeled 全文（连续同人合并）
        let expectedDisk = SpeakerSegmentComposer.compose([
            .init(speaker: 1, text: "甲的第一句"),
            .init(speaker: 2, text: "乙的第一句"),
            .init(speaker: 2, text: "乙的第二句"),
        ]) { LL("diarization.speakerLabel", $0) }
        XCTAssertEqual(viewModel.transcriptText, expectedDisk)

        // 窗口/翻译数据源 = 同一批段落：text 无标签、标签只在说话人变化处
        XCTAssertEqual(
            viewModel.lastFinalSegments.map(\.text),
            ["甲的第一句", "乙的第一句", "乙的第二句"]
        )
        XCTAssertEqual(
            viewModel.lastFinalSegments.map(\.speakerLabel),
            [LL("diarization.speakerLabel", 1), LL("diarization.speakerLabel", 2), nil]
        )
        // 整段长解码产物绝不进窗口/翻译数据源
        XCTAssertFalse(viewModel.lastFinalSegments.contains { $0.text.contains("整段长解码产物") })
    }

    func testNoDiarizationFinalSegmentsUsePlainTranscript() async throws {
        let (viewModel, _) = try await runRecordingToCompletion(
            diarizer: nil, diarizationEnabled: false,
            recognizer: { _ in "原文全部" }
        )

        XCTAssertEqual(
            viewModel.lastFinalSegments,
            [TranslationCoordinator.FinalSegment(speakerLabel: nil, text: "原文全部")]
        )
    }

    // MARK: - 极速引擎终稿替换（引擎切换全局化，2026-08-02）

    /// 录 2 秒到完成，注入极速引擎终稿转写器 mock。
    private func runRecordingToCompletion(
        analyzerPass: MockAnalyzerFinalPassTranscribing,
        diarizer: SpeakerDiarizing? = nil,
        diarizationEnabled: Bool = false,
        recognizer: @escaping ([Float]) -> String? = { _ in "本地终稿" }
    ) async throws -> RecordingTranscriptionViewModel {
        mockRecorder.samplesToEmitOnStart = [Array(repeating: Float(0.1), count: 32_000)]
        mockFinalRecognizer.recognizeResultProvider = recognizer
        let viewModel = makeViewModel(
            diarizer: diarizer,
            diarizationEnabled: diarizationEnabled,
            analyzerFinalPassFactory: { analyzerPass }
        )
        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }
        viewModel.stop()
        try await waitUntil("recording completes") { viewModel.state == .completed }
        return viewModel
    }

    func testAnalyzerFinalPassReplacesTranscript() async throws {
        let analyzerPass = MockAnalyzerFinalPassTranscribing(.success("极速引擎终稿"))
        let viewModel = try await runRecordingToCompletion(analyzerPass: analyzerPass)

        XCTAssertEqual(viewModel.transcriptText, "极速引擎终稿")
        XCTAssertEqual(analyzerPass.transcribeCallCount, 1)
        XCTAssertNil(viewModel.engineNote)
        // 翻译/窗口数据源同步用极速引擎终稿（无标签单段）
        XCTAssertEqual(
            viewModel.lastFinalSegments,
            [TranslationCoordinator.FinalSegment(speakerLabel: nil, text: "极速引擎终稿")]
        )
        let output = try XCTUnwrap(viewModel.output)
        XCTAssertEqual(try String(contentsOf: output.textURL), "极速引擎终稿")
    }

    func testAnalyzerFinalPassFailureFallsBackToSenseVoiceWithNote() async throws {
        let analyzerPass = MockAnalyzerFinalPassTranscribing(.failure)
        let viewModel = try await runRecordingToCompletion(analyzerPass: analyzerPass)

        XCTAssertEqual(viewModel.transcriptText, "本地终稿", "SA 失败必须回退本地引擎终稿，绝不丢文稿")
        XCTAssertEqual(analyzerPass.transcribeCallCount, 1)
        XCTAssertNotNil(viewModel.engineNote)
    }

    func testAnalyzerFinalPassSkippedWhenDiarizationProducesLabels() async throws {
        let analyzerPass = MockAnalyzerFinalPassTranscribing(.success("不应出现"))
        let diarizer = MockDiarizer()
        diarizer.segmentsToReturn = [
            SpeakerSegment(start: 0, end: 0.8, speaker: 0),
            SpeakerSegment(start: 1.0, end: 1.8, speaker: 4),
        ]
        let viewModel = try await runRecordingToCompletion(
            analyzerPass: analyzerPass,
            diarizer: diarizer,
            diarizationEnabled: true,
            recognizer: { samples in
                switch samples.count {
                case 16_000: return "甲的话"
                case 19_200: return "乙的话"
                default: return "本地终稿"
                }
            }
        )

        XCTAssertEqual(analyzerPass.transcribeCallCount, 0, "分离场景恒本地引擎")
        XCTAssertTrue(viewModel.transcriptText.contains("甲的话"))
    }

    func testAnalyzerFinalPassSkippedWhenDiarizationAttemptedButFailed() async throws {
        let analyzerPass = MockAnalyzerFinalPassTranscribing(.success("不应出现"))
        let diarizer = MockDiarizer()
        diarizer.errorToThrow = SpeakerDiarizationError.processFailed("mock failure")
        let viewModel = try await runRecordingToCompletion(
            analyzerPass: analyzerPass,
            diarizer: diarizer,
            diarizationEnabled: true
        )

        XCTAssertEqual(analyzerPass.transcribeCallCount, 0, "分离开启（即使失败）也恒本地引擎")
        XCTAssertEqual(viewModel.transcriptText, "本地终稿")
    }

    // MARK: - auto 模式终稿路由（语言=「自动」，2026-08-02）

    /// auto 模式录到完成：注入 auto 终稿上下文（transcriberForLocale 记录收到的 locale）。
    private func runAutoRecordingToCompletion(
        transcriber: MockAnalyzerFinalPassTranscribing?,
        installed: Set<String> = ["zh-CN", "en-US", "ja-JP", "ko-KR"],
        recognizer: @escaping ([Float]) -> String? = { _ in "本地终稿" },
        onLocaleRequested: ((String) -> Void)? = nil,
        onInstallRequested: ((String) -> Void)? = nil
    ) async throws -> RecordingTranscriptionViewModel {
        mockRecorder.samplesToEmitOnStart = [Array(repeating: Float(0.1), count: 32_000)]
        mockFinalRecognizer.recognizeResultProvider = recognizer
        let viewModel = makeViewModel(
            analyzerAutoFinalPassProvider: {
                AnalyzerAutoFinalPassContext(
                    transcriberForLocale: { locale in
                        onLocaleRequested?(locale)
                        return transcriber
                    },
                    installedLocales: { installed },
                    requestAssetInstall: onInstallRequested
                )
            }
        )
        viewModel.start()
        try await waitUntil("recording starts") { viewModel.state == .recording }
        viewModel.stop()
        try await waitUntil("recording completes") { viewModel.state == .completed }
        return viewModel
    }

    func testAutoFinalPass_singleLanguage_routesLocaleAndReplacesTranscript() async throws {
        let analyzerPass = MockAnalyzerFinalPassTranscribing(.success("极速引擎终稿"))
        var requestedLocales: [String] = []
        let viewModel = try await runAutoRecordingToCompletion(
            transcriber: analyzerPass,
            onLocaleRequested: { requestedLocales.append($0) }
        )

        XCTAssertEqual(requestedLocales, ["zh-CN"], "本地终稿为中文 → 路由 zh-CN")
        XCTAssertEqual(viewModel.transcriptText, "极速引擎终稿")
        XCTAssertEqual(analyzerPass.transcribeCallCount, 1)
        XCTAssertNil(viewModel.engineNote)
    }

    func testAutoFinalPass_mixedSpeech_keepsLocalTranscriptWithNote() async throws {
        let analyzerPass = MockAnalyzerFinalPassTranscribing(.success("不应出现"))
        let mixed = "我们今天讨论了三个重要问题都解决了ありがとうございます"
        let viewModel = try await runAutoRecordingToCompletion(
            transcriber: analyzerPass,
            recognizer: { _ in mixed }
        )

        XCTAssertEqual(analyzerPass.transcribeCallCount, 0, "混说恒本地引擎")
        XCTAssertEqual(viewModel.transcriptText, mixed)
        XCTAssertNotNil(viewModel.engineNote, "混说保留本地终稿需注记")
    }

    func testAutoFinalPass_transcriberThrows_fallsBackWithNote() async throws {
        let analyzerPass = MockAnalyzerFinalPassTranscribing(.failure)
        let viewModel = try await runAutoRecordingToCompletion(transcriber: analyzerPass)

        XCTAssertEqual(viewModel.transcriptText, "本地终稿", "SA 失败必须回退本地终稿，绝不丢文稿")
        XCTAssertEqual(analyzerPass.transcribeCallCount, 1)
        XCTAssertNotNil(viewModel.engineNote)
    }

    func testAutoFinalPass_targetNotInstalled_keepsLocalSilently_andRequestsInstall() async throws {
        let analyzerPass = MockAnalyzerFinalPassTranscribing(.success("不应出现"))
        var installRequests: [String] = []
        let viewModel = try await runAutoRecordingToCompletion(
            transcriber: analyzerPass,
            installed: ["en-US"], // zh-CN 未安装
            onInstallRequested: { installRequests.append($0) }
        )

        XCTAssertEqual(analyzerPass.transcribeCallCount, 0)
        XCTAssertEqual(viewModel.transcriptText, "本地终稿")
        XCTAssertNil(viewModel.engineNote, "未安装静默保留本地，不打扰")
        XCTAssertEqual(installRequests, ["zh-CN"], "缺失语言按需触发后台下载")
    }

    func testDiarizationDisabledNeverInvokesDiarizer() async throws {
        let diarizer = MockDiarizer()
        diarizer.segmentsToReturn = [SpeakerSegment(start: 0, end: 1, speaker: 0)]
        let (viewModel, _) = try await runRecordingToCompletion(
            diarizer: diarizer, diarizationEnabled: false,
            recognizer: { _ in "原文全部" }
        )

        XCTAssertEqual(viewModel.transcriptText, "原文全部")
        XCTAssertEqual(diarizer.diarizeCallCount, 0)
    }

    private func makeViewModel(
        resultRecorder: ((String) -> Void)? = nil,
        metadataRecorder: ((String, TranscriptionMetadata) -> Void)? = nil,
        diarizer: SpeakerDiarizing? = nil,
        diarizationEnabled: Bool = false,
        analyzerFinalPassFactory: (() -> FileTranscribing?)? = nil,
        analyzerAutoFinalPassProvider: (() -> AnalyzerAutoFinalPassContext?)? = nil
    ) -> RecordingTranscriptionViewModel {
        RecordingTranscriptionViewModel(
            appState: appState,
            audioRecorder: mockRecorder,
            finalRecognizer: mockFinalRecognizer,
            outputStore: RecordingTranscriptionOutputStore(outputDirectory: tempDir),
            resultRecorder: resultRecorder,
            metadataRecorder: metadataRecorder,
            diarizer: diarizer,
            // 注入固定值绕过真实 UserDefaults，测试绝不读写用户偏好
            diarizationEnabledProvider: { diarizationEnabled },
            // 终稿引擎默认钉死本地：默认工厂会读真实 UserDefaults 的引擎设置，测试绝不依赖
            analyzerFinalPassFactory: analyzerFinalPassFactory ?? { nil },
            analyzerAutoFinalPassProvider: analyzerAutoFinalPassProvider ?? { nil }
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

/// 极速引擎终稿转写器 mock（runAnalyzerFinalPass 注入用）。
private final class MockAnalyzerFinalPassTranscribing: FileTranscribing {
    enum Outcome {
        case success(String)
        case failure
    }

    private let outcome: Outcome
    private(set) var transcribeCallCount = 0
    private(set) var lastURL: URL?

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String {
        transcribeCallCount += 1
        lastURL = url
        switch outcome {
        case .success(let text):
            return text
        case .failure:
            throw FileTranscriptionError.noRecognizedText
        }
    }
}
