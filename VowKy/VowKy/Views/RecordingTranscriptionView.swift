import AppKit
import Combine
import SwiftUI

// MARK: - Recording Transcription Window Controller

@MainActor
final class RecordingTranscriptionWindowController {
    static let shared = RecordingTranscriptionWindowController()

    private var window: NSWindow?
    private var viewModel: RecordingTranscriptionViewModel?

    /// 供 AppDelegate.applicationShouldTerminate 检查/驱动当前的录音流程。
    var activeViewModel: RecordingTranscriptionViewModel? { viewModel }

    func showWindow(appState: AppState) {
        NSApp.setActivationPolicy(.regular)

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            viewModel?.start()
            return
        }

        let viewModel = RecordingTranscriptionViewModel(
            appState: appState,
            metadataRecorder: { text, meta in
                HistoryStore.shared.insertWithMetadata(content: text, sourceType: meta.sourceType, metadata: meta)
            }
        )
        let view = RecordingTranscriptionView(viewModel: viewModel)
            .environmentObject(LocalizationManager.shared)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = L("window.recording.title")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 520))
        window.minSize = NSSize(width: 540, height: 420)
        window.backgroundColor = NSColor(
            red: 247.0 / 255.0,
            green: 250.0 / 255.0,
            blue: 240.0 / 255.0,
            alpha: 1
        )
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // 退出流程中由 AppDelegate 驱动 stop()，这里不能 cancel 否则会删除正在保存的文件
                if self?.viewModel?.isFinalizingForQuit != true {
                    self?.viewModel?.cancel()
                }
                self?.viewModel = nil
                self?.window = nil
                NSApp.setActivationPolicy(.prohibited)
            }
        }

        self.viewModel = viewModel
        self.window = window
        viewModel.start()
    }
}

// MARK: - View Model

struct RecordingWaveformBand: Equatable {
    let positive: Float
    let negative: Float
}

@MainActor
final class RecordingTranscriptionViewModel: ObservableObject {
    @Published private(set) var state: RecordingTranscriptionState = .idle
    @Published private(set) var transcriptText = ""
    @Published private(set) var output: RecordingTranscriptionOutput?
    @Published private(set) var statusMessage: String?
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var waveformBands: [RecordingWaveformBand] = RecordingTranscriptionViewModel.silentWaveformBands
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    /// 失败但音频已落盘时的兜底地址，UI 据此显示「在 Finder 中显示音频」按钮。
    @Published private(set) var recoveredAudioURL: URL?
    /// 应用退出流程中：UI 显示遮罩，willClose 跳过 cancel，避免误删保存中的文件。
    @Published private(set) var isFinalizingForQuit: Bool = false
    @Published private(set) var finalizationProgress: RecordingFinalizationProgress?
    @Published private(set) var finalizationElapsedSeconds: TimeInterval = 0

    // MARK: 翻译

    @Published private(set) var translationConfig: TranslationConfig = TranslationConfigStore.load()
    @Published private(set) var translationCoordinator: TranslationCoordinator?
    private(set) var translationProvider: TranslationProviding?
    /// 最近一次流式更新的快照，供录音中途开启翻译时立即补译
    private var lastStreamingUpdate: StreamingRecognitionUpdate?
    /// 翻译终态落盘订阅：全部段落到达终态后把双语对照写到原文旁的「(双语).md」
    private var bilingualSaveCancellable: AnyCancellable?

    // MARK: 字幕浮窗

    @Published private(set) var subtitleEnabled: Bool =
        UserDefaults.standard.object(forKey: SubtitleDefaults.enabled) as? Bool ?? false
    private lazy var subtitleController: SubtitleOverlayController = {
        let controller = SubtitleOverlayController()
        controller.requestDisable = { [weak self] in self?.setSubtitleEnabled(false) }
        return controller
    }()
    private var subtitleCancellable: AnyCancellable?
    /// 字幕节奏调度：排队按序上屏，杜绝一次更新跨多句时跳句
    private lazy var subtitlePacer: SubtitlePacer = {
        let pacer = SubtitlePacer()
        pacer.onDisplay = { [weak self] paragraph in
            Self.debugSubtitleTrace("DISPLAY", paragraph.text)
            self?.subtitleController.update(paragraph: paragraph)
        }
        return pacer
    }()

    /// E2E 自动化验证用追踪（仅 Debug 构建）：字幕上屏与段落流写入 /tmp 日志，
    /// 供脚本断言「零漏句、零重排」。Release 构建为空实现。
    nonisolated static func debugSubtitleTrace(_ kind: String, _ payload: String) {
        #if DEBUG
        let path = "/tmp/vowky_subtitle_trace.log"
        let line = "\(Date().timeIntervalSince1970)\t\(kind)\t"
            + payload.replacingOccurrences(of: "\n", with: "⏎") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
        #endif
    }

    nonisolated private static let waveformBandCount = 64
    nonisolated private static var silentWaveformBands: [RecordingWaveformBand] {
        Array(repeating: RecordingWaveformBand(positive: 0, negative: 0), count: waveformBandCount)
    }

    private let appState: AppState
    private var audioRecorder: AudioRecorderProtocol
    private let finalRecognizer: SpeechRecognizerProtocol
    private let outputStore: RecordingTranscriptionOutputStore
    private let resultRecorder: (String) -> Void
    /// 带元数据写历史库的闭包。仅生产环境（窗口控制器）注入；测试不注入即为 nil，绝不触碰真实 DB。
    private let metadataRecorder: ((String, TranscriptionMetadata) -> Void)?

    private var activePreparedOutput: PreparedRecordingTranscriptionOutput?
    private var sampleContinuation: AsyncStream<[Float]>.Continuation?
    private var startupTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var timer: Timer?
    private var finalizationTimer: Timer?
    private var finalizationStartedAt: Date?
    private var activeOperationID: UUID?
    private var recordingStartedAt: Date?

    init(
        appState: AppState,
        audioRecorder: AudioRecorderProtocol? = nil,
        finalRecognizer: SpeechRecognizerProtocol? = nil,
        outputStore: RecordingTranscriptionOutputStore = RecordingTranscriptionOutputStore(),
        resultRecorder: ((String) -> Void)? = nil,
        metadataRecorder: ((String, TranscriptionMetadata) -> Void)? = nil
    ) {
        self.appState = appState
        self.audioRecorder = audioRecorder ?? appState.audioRecorder
        self.finalRecognizer = finalRecognizer ?? appState.finalSpeechRecognizerForRecordingTranscription()
        self.outputStore = outputStore
        self.resultRecorder = resultRecorder ?? { text in
            // 只更新菜单栏最近结果；历史库由 metadataRecorder 带元数据写入，避免重复插入。
            appState.recordRecognitionResult(text: text, sourceType: "recording", persistToHistory: false)
        }
        self.metadataRecorder = metadataRecorder
    }

    /// 为录音转录结果构造历史元数据（标题=录音文件名，路径=落盘的 .md 与 .wav）。
    private static func makeRecordingMetadata(audioURL: URL, markdownURL: URL, duration: TimeInterval) -> TranscriptionMetadata {
        TranscriptionMetadata(
            id: UUID(),
            title: audioURL.deletingPathExtension().lastPathComponent,
            summary: "",
            audioPath: audioURL.path,
            markdownPath: markdownURL.path,
            generatedAt: Date(),
            durationSeconds: duration,
            provider: "local",
            sourceType: "recording",
            aiEnhancementSucceeded: false,
            warnings: []
        )
    }

    var canStart: Bool {
        switch state {
        case .idle, .completed, .cancelled, .failed:
            return startupTask == nil && workerTask == nil
        case .loadingModel, .recording, .finishing:
            return false
        }
    }

    var canStop: Bool {
        state == .recording
    }

    var canCancel: Bool {
        switch state {
        case .loadingModel, .recording, .finishing:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }

    var canCopyResult: Bool {
        !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canOpenOutputFolder: Bool {
        output != nil || recoveredAudioURL != nil
    }

    /// 是否处于「正在录音 / 加载模型 / 生成最终稿」的状态，退出拦截时据此判断。
    var isActivelyRecording: Bool {
        switch state {
        case .loadingModel, .recording, .finishing:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }

    var durationText: String {
        let totalSeconds = max(0, Int(elapsedSeconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var statusText: String {
        if let statusMessage {
            return statusMessage
        }

        switch state {
        case .idle:
            return L("recording.status.idle")
        case .loadingModel:
            return L("recording.status.loadingModel")
        case .recording:
            return L("recording.status.recording")
        case .finishing:
            return L("recording.status.finishing")
        case .completed:
            return L("recording.status.completed")
        case .cancelled:
            return L("recording.status.cancelled")
        case .failed(let message):
            return message
        }
    }

    func start() {
        guard canStart else { return }

        if let reason = appState.beginRecordingTranscription() {
            statusMessage = reason
            return
        }

        let operationID = UUID()
        activeOperationID = operationID
        statusMessage = nil
        transcriptText = ""
        output = nil
        recoveredAudioURL = nil
        elapsedSeconds = 0
        audioLevel = 0
        waveformBands = Self.silentWaveformBands
        state = .loadingModel
        lastStreamingUpdate = nil
        bilingualSaveCancellable = nil
        refreshTranslationSetup(resetCoordinator: true)

        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.startRecordingPipeline(operationID: operationID)
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        subtitleController.hide()
        subtitleCancellable = nil
        subtitlePacer.reset()
        stopTimer()
        startFinalizationTimer()
        _ = audioRecorder.stopRecording()
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
    }

    func cancel() {
        guard canCancel else { return }

        recoveredAudioURL = nil
        let preparedOutput = activePreparedOutput
        activeOperationID = nil
        startupTask?.cancel()
        workerTask?.cancel()
        startupTask = nil
        workerTask = nil

        if state == .recording || state == .finishing {
            _ = audioRecorder.stopRecording()
        }
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
        stopTimer()
        resetFinalizationState()
        deletePreparedOutput(preparedOutput)
        activePreparedOutput = nil

        appState.endRecordingTranscription()
        state = .cancelled
        statusMessage = nil
        audioLevel = 0
        waveformBands = Self.silentWaveformBands
        translationCoordinator?.shutdown()
        translationCoordinator = nil
        lastStreamingUpdate = nil
        bilingualSaveCancellable = nil
        subtitleController.close()
        subtitleCancellable = nil
        subtitlePacer.reset()
    }

    func copyResult() {
        guard canCopyResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
        AnalyticsService.shared.trackHistoryCopy()
    }

    func openOutputFolder() {
        if let output {
            NSWorkspace.shared.activateFileViewerSelecting([output.textURL, output.audioURL])
            return
        }
        if let recoveredAudioURL {
            NSWorkspace.shared.activateFileViewerSelecting([recoveredAudioURL])
        }
    }

    /// 由 AppDelegate.applicationShouldTerminate 调用，告知 ViewModel 当前正走退出流程。
    /// View 据此显示遮罩；窗口的 willClose 据此跳过 cancel，避免误删保存中的文件。
    func markFinalizingForQuit() {
        isFinalizingForQuit = true
        subtitleController.hide()
        subtitleCancellable = nil
        subtitlePacer.reset()
    }

    // MARK: - 翻译

    /// 双语对照视图是否生效
    var bilingualViewActive: Bool {
        translationConfig.enabled && translationCoordinator != nil
    }

    func setTranslationEnabled(_ enabled: Bool) {
        var config = TranslationConfigStore.load()
        config.enabled = enabled
        TranslationConfigStore.save(config)
        refreshTranslationSetup(resetCoordinator: false)
        // coordinator 可能已重建/销毁，字幕订阅需重新绑定到新数据源
        if subtitleEnabled, state == .recording {
            syncSubtitle()
        }
        guard enabled, let coordinator = translationCoordinator else { return }
        // 中途开启：把已有文字立即补译
        if state == .completed || state == .finishing {
            let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { coordinator.ingestFinal(text: text) }
            // finishing 阶段不挂订阅：complete() 送终稿时会重新调度，避免把预览稿写盘
            if state == .completed { scheduleBilingualTranscriptSave() }
        } else if let lastStreamingUpdate {
            coordinator.ingest(update: lastStreamingUpdate)
        }
    }

    func setTranslationTarget(_ target: TranslationTarget) {
        guard target != translationConfig.target else { return }
        var config = translationConfig
        config.target = target
        translationConfig = config
        TranslationConfigStore.save(config)
        translationCoordinator?.setTarget(target)
    }

    /// 从 UserDefaults 重载翻译配置，按需重建 provider/coordinator。
    /// - Parameter resetCoordinator: true 时（每次开始录音）强制换新 coordinator，清掉上一轮状态。
    private func refreshTranslationSetup(resetCoordinator: Bool) {
        let newConfig = TranslationConfigStore.load()
        let configChanged = newConfig != translationConfig
        translationConfig = newConfig

        guard newConfig.enabled else {
            translationCoordinator?.shutdown()
            translationCoordinator = nil
            translationProvider = nil
            bilingualSaveCancellable = nil
            return
        }

        if translationProvider == nil || configChanged {
            translationProvider = Self.makeTranslationProvider(config: newConfig)
        }
        if resetCoordinator || translationCoordinator == nil || configChanged {
            translationCoordinator?.shutdown()
            if let provider = translationProvider {
                translationCoordinator = TranslationCoordinator(provider: provider, target: newConfig.target)
            }
        }
    }

    /// 完成后订阅段落流：全部段落到达终态（无 pending）即把双语对照写到原文旁。
    /// 之后重试/换目标语言引发的再翻译会触发原子覆写，文件始终反映最新终态。
    /// 全部同语言跳过或全部失败时不产出文件。
    private func scheduleBilingualTranscriptSave() {
        bilingualSaveCancellable = nil
        guard let coordinator = translationCoordinator,
              let textURL = (activePreparedOutput ?? lastPreparedFromOutput())?.textURL else { return }
        let bilingualURL = BilingualTranscriptComposer.outputURL(for: textURL)
        let store = outputStore
        bilingualSaveCancellable = coordinator.$paragraphs
            .removeDuplicates()
            .filter { BilingualTranscriptComposer.isReadyToWrite($0) }
            .sink { paragraphs in
                do {
                    try store.writeTranscript(
                        BilingualTranscriptComposer.compose(paragraphs: paragraphs),
                        to: bilingualURL
                    )
                } catch {
                    NSLog("[VowKy][Translation] 双语文件写入失败: \(error.localizedDescription)")
                }
            }
    }

    private static func makeTranslationProvider(config: TranslationConfig) -> TranslationProviding {
        #if canImport(Translation)
        if config.engine == .apple, #available(macOS 15.0, *) {
            return AppleTranslationProvider()
        }
        #endif
        return OpenAICompatibleTranslationProvider(config: config)
    }

    // MARK: - 字幕浮窗

    func setSubtitleEnabled(_ enabled: Bool) {
        subtitleEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SubtitleDefaults.enabled)
        syncSubtitle()
    }

    /// 开关 + 状态 + 最新段三因素合一：决定字幕显示/隐藏/更新。
    private func syncSubtitle() {
        let shouldShow = subtitleEnabled && state == .recording
        if shouldShow {
            pushSubtitleContent()
            subtitleController.show()
            bindSubtitleStream()
        } else {
            subtitleController.hide()
            subtitleCancellable = nil
            subtitlePacer.reset()
        }
    }

    /// 翻译开 → 订阅 coordinator 全部段落，交给 pacer 调度上屏（含译文状态刷新）。
    private func bindSubtitleStream() {
        subtitleCancellable = translationCoordinator?.$paragraphs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paragraphs in
                let worthy = Self.subtitleWorthy(paragraphs)
                Self.debugSubtitleTrace("PARAS", worthy.map(\.text).joined(separator: "|"))
                self?.subtitlePacer.ingest(worthy)
            }
    }

    /// 翻译开 → 喂 coordinator 段落；翻译关 → 把转写全文合成「只显原文」段落喂 pacer。
    private func pushSubtitleContent() {
        if let coordinator = translationCoordinator {
            subtitlePacer.ingest(Self.subtitleWorthy(coordinator.paragraphs))
        } else {
            subtitlePacer.ingest(Self.subtitleWorthy(
                Self.plainParagraphs(of: lastStreamingUpdate?.displayText ?? transcriptText)
            ))
        }
    }

    /// 字幕只播有实际内容的句子：纯标点/数字（静音噪声）一律过滤。
    private static func subtitleWorthy(_ paragraphs: [TranscriptParagraph]) -> [TranscriptParagraph] {
        paragraphs.filter { !TranslationCoordinator.isTrivialText($0.text) }
    }

    /// 翻译关时的字幕数据源：按句拆分全文，标记为跳过翻译（字幕不渲染译文行）。
    private static func plainParagraphs(of text: String) -> [TranscriptParagraph] {
        TranslationCoordinator.splitParagraphs(text).enumerated().map { index, piece in
            TranscriptParagraph(
                id: "plain-\(index)",
                text: piece,
                isPartial: true,
                translation: .skippedSameLanguage
            )
        }
    }

    private func startRecordingPipeline(operationID: UUID) async {
        guard isActive(operationID) else { return }
        guard finalRecognizer.isReady else {
            fail(operationID: operationID, message: L("recording.error.modelNotReady"))
            return
        }

        do {
            let preparedOutput = try outputStore.prepareOutput(startedAt: Date())
            let writer = try WAVSampleFileWriter(url: preparedOutput.audioURL)

            var continuation: AsyncStream<[Float]>.Continuation!
            let audioStream = AsyncStream<[Float]> { streamContinuation in
                continuation = streamContinuation
            }
            sampleContinuation = continuation
            activePreparedOutput = preparedOutput

            audioRecorder.onSamplesCaptured = { [weak self] samples in
                continuation.yield(samples)
                let waveformBands = Self.displayWaveformBands(from: samples)
                Task { @MainActor in
                    self?.waveformBands = waveformBands
                }
            }
            try audioRecorder.startRecording()

            guard isActive(operationID) else {
                writer.finalize()
                deletePreparedOutput(preparedOutput)
                return
            }

            recordingStartedAt = preparedOutput.startedAt
            state = .recording
            startTimer()
            syncSubtitle()

            let engine = RecordingTranscriptionEngine(
                finalRecognizer: finalRecognizer,
                writer: writer,
                sampleRate: 16_000
            )

            workerTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let result = try await engine.run(audioChunks: audioStream) { update in
                        self?.apply(update: update, operationID: operationID)
                    } finalizationProgress: { progress in
                        self?.applyFinalization(progress: progress, operationID: operationID)
                    }
                    await self?.complete(result: result, operationID: operationID)
                } catch is CancellationError {
                    await self?.completeCancellation(operationID: operationID)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await self?.fail(operationID: operationID, message: message)
                }
            }

            startupTask = nil
        } catch {
            fail(operationID: operationID, message: error.localizedDescription)
        }
    }

    private func apply(update: StreamingRecognitionUpdate, operationID: UUID) {
        guard isActive(operationID) else { return }
        transcriptText = update.displayText
        lastStreamingUpdate = update
        translationCoordinator?.ingest(update: update)
        // 翻译关时无 coordinator 订阅驱动字幕，这里把按句拆分的全文喂给 pacer 调度
        if subtitleEnabled, state == .recording, translationCoordinator == nil {
            let paragraphs = Self.subtitleWorthy(Self.plainParagraphs(of: update.displayText))
            Self.debugSubtitleTrace("PARAS", paragraphs.map(\.text).joined(separator: "|"))
            subtitlePacer.ingest(paragraphs)
        }
    }

    private func applyFinalization(progress: RecordingFinalizationProgress, operationID: UUID) {
        guard isActive(operationID) else { return }
        finalizationProgress = progress
    }

    private func complete(result: RecordingTranscriptionResult, operationID: UUID) {
        guard isActive(operationID), let preparedOutput = activePreparedOutput else { return }

        stopTimer()
        resetFinalizationState()
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation = nil
        subtitleController.hide()
        subtitleCancellable = nil
        subtitlePacer.reset()

        let finalText = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try outputStore.writeTranscript(finalText, to: preparedOutput.textURL)
            transcriptText = finalText

            let duration = Date().timeIntervalSince(recordingStartedAt ?? preparedOutput.startedAt)
            output = RecordingTranscriptionOutput(
                textURL: preparedOutput.textURL,
                audioURL: preparedOutput.audioURL,
                startedAt: preparedOutput.startedAt,
                duration: duration,
                characterCount: finalText.count
            )
            if !finalText.isEmpty {
                resultRecorder(finalText)
                metadataRecorder?(
                    finalText,
                    Self.makeRecordingMetadata(
                        audioURL: preparedOutput.audioURL,
                        markdownURL: preparedOutput.textURL,
                        duration: duration
                    )
                )
            }

            state = .completed
            statusMessage = nil

            // 最终稿（加标点后文本变化）整稿重新送译，得到双语终态
            if !finalText.isEmpty {
                translationCoordinator?.ingestFinal(text: finalText)
                scheduleBilingualTranscriptSave()
            }
        } catch {
            state = .failed(L("recording.error.saveFailed", error.localizedDescription))
        }

        clearActiveOperation(operationID: operationID)
    }

    /// `activePreparedOutput` 在 `clearActiveOperation` 中会被清空；用 `output` 重建一个供完成后的双语落盘使用。
    private func lastPreparedFromOutput() -> PreparedRecordingTranscriptionOutput? {
        guard let output else { return nil }
        return PreparedRecordingTranscriptionOutput(
            textURL: output.textURL,
            audioURL: output.audioURL,
            startedAt: output.startedAt
        )
    }

    private func completeCancellation(operationID: UUID) {
        guard isActive(operationID) else { return }
        resetFinalizationState()
        deletePreparedOutput(activePreparedOutput)
        state = .cancelled
        clearActiveOperation(operationID: operationID)
    }

    private func fail(operationID: UUID, message: String) {
        guard isActive(operationID) else { return }
        stopTimer()
        resetFinalizationState()
        if state == .recording || state == .finishing {
            _ = audioRecorder.stopRecording()
        }
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
        // 失败时保留音频，仅清理空的 txt；引擎的 defer 已经 finalize 过 wav header。
        let prepared = activePreparedOutput
        if let prepared {
            try? FileManager.default.removeItem(at: prepared.textURL)
            if let size = (try? FileManager.default.attributesOfItem(atPath: prepared.audioURL.path))?[.size] as? Int,
               size > 44 {
                recoveredAudioURL = prepared.audioURL
            } else {
                // 没有有效音频，wav 文件也清掉
                try? FileManager.default.removeItem(at: prepared.audioURL)
            }
        }
        state = .failed(message)
        statusMessage = nil
        clearActiveOperation(operationID: operationID)
    }

    private func clearActiveOperation(operationID: UUID) {
        guard activeOperationID == operationID else { return }
        startupTask = nil
        workerTask = nil
        activeOperationID = nil
        activePreparedOutput = nil
        audioLevel = 0
        subtitleController.hide()
        subtitleCancellable = nil
        subtitlePacer.reset()
        appState.endRecordingTranscription()
    }

    private func isActive(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let recordingStartedAt = self.recordingStartedAt {
                    self.elapsedSeconds = Date().timeIntervalSince(recordingStartedAt)
                }
                self.audioLevel = self.audioRecorder.audioLevel
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startFinalizationTimer() {
        stopFinalizationTimer()
        finalizationStartedAt = Date()
        finalizationElapsedSeconds = 0
        finalizationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.finalizationStartedAt else { return }
                self.finalizationElapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopFinalizationTimer() {
        finalizationTimer?.invalidate()
        finalizationTimer = nil
    }

    private func resetFinalizationState() {
        stopFinalizationTimer()
        finalizationStartedAt = nil
        finalizationElapsedSeconds = 0
        finalizationProgress = nil
    }

    var finalizationFraction: Double? {
        guard let p = finalizationProgress, p.total > 0 else { return nil }
        return min(1, Double(p.completed) / Double(p.total))
    }

    var finalizationETAText: String? {
        guard let p = finalizationProgress else { return nil }
        guard p.inputClosed, p.completed >= 2, p.total > p.completed,
              finalizationElapsedSeconds > 0 else {
            return L("recording.eta.estimating")
        }
        let perSegment = finalizationElapsedSeconds / Double(p.completed)
        let remaining = Int((Double(p.total - p.completed) * perSegment).rounded())
        if remaining < 1 { return L("recording.eta.almostDone") }
        if remaining < 60 { return L("recording.eta.seconds", remaining) }
        let mins = remaining / 60
        let secs = remaining % 60
        return secs == 0 ? L("recording.eta.minutes", mins) : L("recording.eta.minutesSeconds", mins, secs)
    }

    var finalizationDurationText: String {
        let totalSeconds = max(0, Int(finalizationElapsedSeconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var finalizationSegmentText: String? {
        guard let p = finalizationProgress else { return nil }
        if p.total == 0 {
            return L("recording.segment.preparing")
        }
        return L("recording.segment.progress", p.completed, p.total)
    }

    nonisolated static func displayWaveformBands(from samples: [Float]) -> [RecordingWaveformBand] {
        guard !samples.isEmpty else { return silentWaveformBands }

        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        guard peak >= 0.01 else {
            return silentWaveformBands
        }

        let gain = min(24, max(6, 0.78 / peak))
        let bucketSize = max(1, Int(ceil(Double(samples.count) / Double(waveformBandCount))))

        return (0..<waveformBandCount).map { bucketIndex in
            let start = bucketIndex * bucketSize
            let end = min(samples.count, start + bucketSize)
            guard start < end else {
                return RecordingWaveformBand(positive: 0, negative: 0)
            }

            var positivePeak: Float = 0
            var negativePeak: Float = 0
            for sample in samples[start..<end] {
                let scaled = sample * gain
                if scaled >= 0 {
                    positivePeak = max(positivePeak, scaled)
                } else {
                    negativePeak = max(negativePeak, abs(scaled))
                }
            }

            return RecordingWaveformBand(
                positive: min(1, positivePeak),
                negative: min(1, negativePeak)
            )
        }
    }

    private func deletePreparedOutput(_ preparedOutput: PreparedRecordingTranscriptionOutput?) {
        guard let preparedOutput else { return }
        try? FileManager.default.removeItem(at: preparedOutput.textURL)
        try? FileManager.default.removeItem(at: preparedOutput.audioURL)
    }
}

// MARK: - View

struct RecordingTranscriptionView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @ObservedObject var viewModel: RecordingTranscriptionViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                header
                recordingCard
                transcriptCard
                footer
            }
            .padding(12)
            .frame(minWidth: 540, minHeight: 420)
            .background(
                LinearGradient(
                    colors: [
                        RecordingTheme.background,
                        RecordingTheme.secondaryBackground,
                        RecordingTheme.elevatedBackground
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            if viewModel.isFinalizingForQuit {
                finalizingForQuitOverlay
            }
        }
        .background(translationHost)
    }

    /// Apple 翻译引擎的 session 宿主（不可见）。LLM 引擎或翻译关闭时为空。
    @ViewBuilder
    private var translationHost: some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *),
           viewModel.translationConfig.enabled,
           viewModel.translationConfig.engine == .apple,
           let provider = viewModel.translationProvider as? AppleTranslationProvider,
           let coordinator = viewModel.translationCoordinator {
            AppleTranslationHostView(
                provider: provider,
                coordinator: coordinator,
                target: viewModel.translationConfig.target
            )
        }
        #endif
    }

    private var translationControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.translationConfig.enabled },
                set: { viewModel.setTranslationEnabled($0) }
            )) {
                Text(loc.string("recording.translation.toggle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(RecordingTheme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()

            if viewModel.translationConfig.enabled {
                Menu {
                    ForEach(TranslationTarget.presets, id: \.target) { preset in
                        Button {
                            viewModel.setTranslationTarget(preset.target)
                        } label: {
                            if preset.target == viewModel.translationConfig.target {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10, weight: .semibold))
                        Text(viewModel.translationConfig.target.displayName)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(RecordingTheme.accentDark)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Toggle(isOn: Binding(
                get: { viewModel.subtitleEnabled },
                set: { viewModel.setSubtitleEnabled($0) }
            )) {
                Text(loc.string("recording.subtitle.toggle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(RecordingTheme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            .help(loc.string("recording.subtitle.help"))
        }
    }

    private var finalizingForQuitOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(loc.string("recording.quitOverlay.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(loc.string("recording.quitOverlay.subtitle"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.55))
            )
        }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(RecordingTheme.accentDark)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(RecordingTheme.accentBright.opacity(0.35))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(loc.string("recording.header.title"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(RecordingTheme.textPrimary)
                Text(loc.string("recording.header.subtitle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(RecordingTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                TranscriptionHistoryWindowController.shared.showWindow(filter: .recording)
            } label: {
                Label(loc.string("recording.action.history"), systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(RecordingGhostButtonStyle())
            .help(loc.string("recording.action.history"))

            statusPill
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 42)
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(statusDotColor.opacity(isLiveState ? 0.28 : 0), lineWidth: isLiveState ? 5 : 0)
                )
            Text(statusBadgeText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(RecordingTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(RecordingTheme.cardBackground.opacity(0.82))
                .overlay(
                    Capsule()
                        .stroke(RecordingTheme.borderLight, lineWidth: 1)
                )
        )
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                RecordingPulseIcon(
                    state: viewModel.state,
                    level: viewModel.audioLevel,
                    reduceMotion: reduceMotion
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(cardTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(RecordingTheme.textPrimary)
                        .lineLimit(1)

                    Text(headerSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(RecordingTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(headerDurationText)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundColor(RecordingTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(durationCaption)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(RecordingTheme.textMuted)
                }
            }

            RecordingWaveformView(
                bands: viewModel.waveformBands,
                isActive: viewModel.state == .recording,
                isProcessing: viewModel.state == .loadingModel || viewModel.state == .finishing
            )
            .frame(height: 36)

            if viewModel.state == .finishing {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = viewModel.finalizationFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(RecordingTheme.accentDeep)
                            .frame(height: 8)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(RecordingTheme.accentDeep)
                            .frame(height: 8)
                    }
                    Text(loc.string("recording.finishing.hint"))
                        .font(.system(size: 11))
                        .foregroundColor(RecordingTheme.textMuted)
                        .lineLimit(2)
                }
            } else if viewModel.state == .loadingModel {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(RecordingTheme.accentDeep)
                    .frame(height: 4)
            }
        }
        .padding(14)
        .frame(minHeight: 104)
        .recordingCardStyle()
    }

    private var headerSubtitle: String {
        if viewModel.state == .finishing {
            let segment = viewModel.finalizationSegmentText ?? loc.string("recording.segment.preparing")
            if let eta = viewModel.finalizationETAText {
                return loc.string("recording.headerSubtitle.segmentETA", segment, eta)
            }
            return segment
        }
        return viewModel.statusText
    }

    private var headerDurationText: String {
        viewModel.state == .finishing ? viewModel.finalizationDurationText : viewModel.durationText
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: transcriptIconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(RecordingTheme.accentDark)

                Text(loc.string("recording.transcript.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(RecordingTheme.textPrimary)

                Text(transcriptBadgeText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(RecordingTheme.accentDarkest)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(RecordingTheme.accentBright.opacity(0.32))
                    )

                if viewModel.state == .loadingModel || viewModel.state == .finishing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(RecordingTheme.accentDeep)
                }

                Spacer()

                translationControls

                if !viewModel.transcriptText.isEmpty {
                    Text(loc.string("recording.transcript.charCount", viewModel.transcriptText.count))
                        .font(.system(size: 11))
                        .foregroundColor(RecordingTheme.textMuted)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(RecordingTheme.secondaryBackground.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(RecordingTheme.borderLight, lineWidth: 1)
                    )

                if let coordinator = viewModel.translationCoordinator, viewModel.bilingualViewActive {
                    BilingualTranscriptView(
                        coordinator: coordinator,
                        emptyText: emptyTranscriptText
                    )
                } else {
                    if viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(emptyTranscriptText)
                            .font(.system(size: 14))
                            .foregroundColor(RecordingTheme.textMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                    }

                    TextEditor(text: Binding(
                        get: { viewModel.transcriptText },
                        set: { _ in }
                    ))
                    .font(.system(size: 14))
                    .foregroundColor(RecordingTheme.textPrimary)
                    .lineSpacing(4)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
            .frame(minHeight: 128, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RecordingTheme.accentDark)
                Text(outputPathText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(RecordingTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .frame(height: 18)
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .recordingCardStyle()
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if viewModel.canCancel {
                Button {
                    viewModel.cancel()
                } label: {
                    Label(loc.string("recording.button.cancel"), systemImage: "xmark")
                }
                .buttonStyle(RecordingGhostButtonStyle())
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    viewModel.start()
                } label: {
                    Label(loc.string("recording.button.reRecord"), systemImage: "record.circle")
                }
                .buttonStyle(RecordingPrimaryButtonStyle())
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.return, modifiers: [])
            }

            if viewModel.canStop {
                Button {
                    viewModel.stop()
                } label: {
                    Label(loc.string("recording.button.finish"), systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(RecordingPrimaryButtonStyle())
            }

            Spacer()

            Button {
                viewModel.copyResult()
            } label: {
                Label(loc.string("recording.button.copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(RecordingSecondaryButtonStyle())
            .disabled(!viewModel.canCopyResult)

            Button {
                viewModel.openOutputFolder()
            } label: {
                Label(loc.string("recording.button.openFolder"), systemImage: "folder")
            }
            .buttonStyle(RecordingSecondaryButtonStyle())
            .disabled(!viewModel.canOpenOutputFolder)
        }
        .controlSize(.small)
        .frame(height: 34)
    }

    private var isLiveState: Bool {
        viewModel.state == .recording || viewModel.state == .loadingModel || viewModel.state == .finishing
    }

    private var statusBadgeText: String {
        switch viewModel.state {
        case .idle:
            return loc.string("recording.badge.ready")
        case .loadingModel:
            return loc.string("recording.badge.loading")
        case .recording:
            return loc.string("recording.badge.live")
        case .finishing:
            return loc.string("recording.badge.finalizing")
        case .completed:
            return loc.string("recording.badge.saved")
        case .cancelled:
            return loc.string("recording.badge.cancelled")
        case .failed:
            return loc.string("recording.badge.failed")
        }
    }

    private var cardTitle: String {
        switch viewModel.state {
        case .idle:
            return loc.string("recording.cardTitle.idle")
        case .loadingModel:
            return loc.string("recording.cardTitle.loadingModel")
        case .recording:
            return loc.string("recording.cardTitle.recording")
        case .finishing:
            return loc.string("recording.cardTitle.finishing")
        case .completed:
            return loc.string("recording.cardTitle.completed")
        case .cancelled:
            return loc.string("recording.cardTitle.cancelled")
        case .failed:
            return loc.string("recording.cardTitle.failed")
        }
    }

    private var durationCaption: String {
        switch viewModel.state {
        case .completed:
            return loc.string("recording.durationCaption.total")
        case .finishing:
            return loc.string("recording.durationCaption.processing")
        default:
            return loc.string("recording.durationCaption.current")
        }
    }

    private var transcriptBadgeText: String {
        switch viewModel.state {
        case .completed:
            return loc.string("recording.transcriptBadge.completed")
        case .finishing:
            return loc.string("recording.transcriptBadge.finishing")
        case .recording:
            return loc.string("recording.transcriptBadge.recording")
        case .failed:
            return loc.string("recording.transcriptBadge.failed")
        default:
            return loc.string("recording.transcriptBadge.waiting")
        }
    }

    private var transcriptIconName: String {
        switch viewModel.state {
        case .completed:
            return "checkmark.seal.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return "text.quote"
        }
    }

    private var emptyTranscriptText: String {
        switch viewModel.state {
        case .loadingModel:
            return loc.string("recording.empty.loadingModel")
        case .recording:
            return loc.string("recording.empty.recording")
        case .finishing:
            return loc.string("recording.empty.finishing")
        case .completed:
            return loc.string("recording.empty.completed")
        case .failed:
            return viewModel.recoveredAudioURL == nil
                ? loc.string("recording.empty.failedNoAudio")
                : loc.string("recording.empty.failedWithAudio")
        case .cancelled:
            return loc.string("recording.empty.cancelled")
        case .idle:
            return loc.string("recording.empty.idle")
        }
    }

    private var outputPathText: String {
        if let output = viewModel.output {
            return output.textURL.deletingLastPathComponent().path
        }
        if let recovered = viewModel.recoveredAudioURL {
            return recovered.deletingLastPathComponent().path
        }
        return loc.string("recording.outputPath.default")
    }

    private var statusDotColor: Color {
        switch viewModel.state {
        case .idle, .completed:
            return RecordingTheme.accentDeep
        case .loadingModel, .finishing:
            return RecordingTheme.accentMain
        case .recording:
            return RecordingTheme.recordingRed
        case .cancelled:
            return RecordingTheme.warning
        case .failed:
            return RecordingTheme.recordingRed
        }
    }
}

// MARK: - Recording Visual Components

private struct RecordingPulseIcon: View {
    let state: RecordingTranscriptionState
    let level: Float
    let reduceMotion: Bool

    private var normalizedLevel: CGFloat {
        CGFloat(min(max(level, 0), 1))
    }

    var body: some View {
        ZStack {
            if state == .recording && !reduceMotion {
                Circle()
                    .fill(RecordingTheme.recordingRed.opacity(0.12))
                    .frame(width: 68, height: 68)
                    .scaleEffect(1 + normalizedLevel * 0.35)
                    .animation(.easeOut(duration: 0.16), value: normalizedLevel)
            }

            Circle()
                .fill(
                    LinearGradient(
                        colors: [RecordingTheme.accentBright, RecordingTheme.accentMain],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 52, height: 52)
                .shadow(color: RecordingTheme.accentMain.opacity(0.24), radius: 12, x: 0, y: 6)

            stateIcon
        }
        .frame(width: 70, height: 70)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(RecordingTheme.accentDarkest)
        case .cancelled:
            Image(systemName: "xmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(RecordingTheme.accentDarkest)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(RecordingTheme.accentDarkest)
        default:
            Image(nsImage: Self.butterflyLargeImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .foregroundColor(RecordingTheme.accentDarkest)
        }
    }

    private static let butterflyLargeImage: NSImage = {
        let img = NSImage(named: "ButterflyLarge") ?? NSImage()
        img.isTemplate = true
        return img
    }()
}

private struct RecordingWaveformView: View {
    let bands: [RecordingWaveformBand]
    let isActive: Bool
    let isProcessing: Bool

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: midY))
            centerLine.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(
                centerLine,
                with: .color(RecordingTheme.border.opacity(isActive ? 0.72 : 0.45)),
                lineWidth: 1
            )

            guard !bands.isEmpty else { return }

            let usableHeight = max(8, size.height - 8)
            let halfHeight = usableHeight / 2
            let step = bands.count > 1
                ? size.width / CGFloat(bands.count - 1)
                : size.width
            let barWidth = max(2, min(4.5, step * 0.44))
            let style = StrokeStyle(lineWidth: barWidth, lineCap: .round)
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [RecordingTheme.accentDeep, RecordingTheme.accentBright]),
                startPoint: CGPoint(x: 0, y: size.height),
                endPoint: CGPoint(x: 0, y: 0)
            )

            for (index, band) in bands.enumerated() {
                let positive = CGFloat(min(max(band.positive, 0), 1))
                let negative = CGFloat(min(max(band.negative, 0), 1))
                let x = CGFloat(index) * step
                let top = midY - max(0.75, positive * halfHeight)
                let bottom = midY + max(0.75, negative * halfHeight)

                var bar = Path()
                bar.move(to: CGPoint(x: x, y: top))
                bar.addLine(to: CGPoint(x: x, y: bottom))
                context.opacity = opacity(for: band)
                context.stroke(bar, with: gradient, style: style)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(RecordingTheme.secondaryBackground.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(RecordingTheme.borderLight, lineWidth: 1)
                )
        )
    }

    private func opacity(for band: RecordingWaveformBand) -> Double {
        if isActive { return 0.95 }
        if isProcessing { return 0.58 }
        return (band.positive > 0 || band.negative > 0) ? 0.46 : 0.30
    }
}

private struct RecordingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(RecordingTheme.accentDarkest)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [RecordingTheme.accentBright, RecordingTheme.accentMain]
                                : [RecordingTheme.borderLight, RecordingTheme.border],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(
                        color: isEnabled ? RecordingTheme.accentMain.opacity(configuration.isPressed ? 0.10 : 0.24) : .clear,
                        radius: configuration.isPressed ? 3 : 8,
                        x: 0,
                        y: configuration.isPressed ? 1 : 3
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct RecordingSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(RecordingTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(RecordingTheme.cardBackground.opacity(isEnabled ? 0.92 : 0.54))
                    .overlay(
                        Capsule()
                            .stroke(RecordingTheme.border, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.52)
    }
}

private struct RecordingGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(RecordingTheme.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? RecordingTheme.borderLight.opacity(0.6) : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct RecordingCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(RecordingTheme.cardBackground.opacity(0.96))
                    .shadow(color: RecordingTheme.shadow, radius: 18, x: 0, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(RecordingTheme.borderLight, lineWidth: 1)
            )
    }
}

private extension View {
    func recordingCardStyle() -> some View {
        modifier(RecordingCardModifier())
    }
}

enum RecordingTheme {
    static let background = color(0xF7FAF0)
    static let secondaryBackground = color(0xF0F5E4)
    static let cardBackground = color(0xFFFFFF)
    static let elevatedBackground = color(0xE8EED8)
    static let textPrimary = color(0x1A2210)
    static let textSecondary = color(0x4E5C3A)
    static let textMuted = color(0x8A9872)
    static let accentBright = color(0xD4E87C)
    static let accentMain = color(0xB8D458)
    static let accentDeep = color(0x8AAE3A)
    static let accentDark = color(0x5A6B2A)
    static let accentDarkest = color(0x4A5A22)
    static let border = color(0xDCE6C8)
    static let borderLight = color(0xE8EED8)
    static let recordingRed = color(0xEF6159)
    static let warning = color(0xC88A2A)
    static let shadow = color(0x4A5A22, opacity: 0.10)

    private static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
