import AppKit
import Combine
import SwiftUI

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
    /// 波形重绘节流时间戳（主线程访问）
    private var lastWaveformUpdateAt: TimeInterval = 0
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

    // MARK: 说话人分离

    @Published private(set) var diarizationEnabled: Bool = DiarizationConfigStore.isRecordingEnabled()
    /// 说话人数：0 = 自动估计，≥2 = 强制指定（短句多的对话自动估计易过分裂，已知人数时指定更准）。
    @Published private(set) var diarizationSpeakerCount: Int = DiarizationConfigStore.recordingSpeakerCount()
    /// 分离模型是否在 bundle 里（缺失时开关禁用）。
    let diarizationModelsAvailable = DiarizationModelCatalog.availableInBundle()
    /// finishing 期间的分离子阶段文案（statusText 在 .finishing 时优先显示）。
    @Published private(set) var diarizationPhaseText: String?
    /// 分离失败已降级的注记（完成后显示；下次 start 清空）。
    @Published private(set) var diarizationNote: String?
    /// 极速引擎终稿替换失败、已回退本地引擎终稿的注记（完成后显示；下次 start 清空）。
    @Published private(set) var engineNote: String?
    /// 本次完成的分离说话人数（埋点用；单人/未分离为 0）。
    private var lastDiarizationSpeakerCount = 0
    /// 本次完成的终稿同源段落（分离成功=逐段重识别产物；否则=plain 终稿单段）。
    /// complete() 与「完成态中途开翻译」共用同一数据源，保证翻译管线
    /// 永远吃与落盘同源的无标签文本（transcriptText 分离后是 labeled，绝不能直接喂）。
    /// internal 供单测断言同源不变量。
    private(set) var lastFinalSegments: [TranslationCoordinator.FinalSegment] = []

    // MARK: 字幕浮窗

    @Published private(set) var subtitleEnabled: Bool =
        UserDefaults.standard.object(forKey: SubtitleDefaults.enabled) as? Bool ?? false
    private lazy var subtitleController: SubtitleOverlayController = {
        let controller = SubtitleOverlayController()
        controller.requestDisable = { [weak self] in self?.setSubtitleEnabled(false) }
        return controller
    }()
    private var subtitleCancellable: AnyCancellable?
    /// 翻译关路径的切分锚定（翻译开时由 TranslationCoordinator 内部的锚负责，二者互斥使用）
    private let plainSplitter = AnchoredParagraphSplitter()
    /// 字幕节奏调度：排队按序上屏，杜绝一次更新跨多句时跳句
    private lazy var subtitlePacer: SubtitlePacer = {
        let pacer = SubtitlePacer()
        pacer.onDisplay = { [weak self] paragraph, isNewSentence in
            Self.debugSubtitleTrace("DISPLAY", paragraph.text)
            self?.recordSubtitleDisplay(paragraph, isNewSentence: isNewSentence)
            self?.subtitleController.update(paragraph: paragraph)
        }
        return pacer
    }()
    /// 字幕实录：累积真实上屏内容，complete() 写盘。internal 供单测直接注入记录。
    let subtitleDisplayRecorder = SubtitleDisplayRecorder()

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
    /// 说话人分离服务。仅生产环境（窗口控制器）注入；测试显式注入；nil = 不做分离后处理。
    private let diarizer: SpeakerDiarizing?
    /// 分离开关读取（进入 finishing 后处理前读取，允许录音中途改开关）。测试可注入绕过真实 UserDefaults。
    private let diarizationEnabledProvider: () -> Bool
    /// 固定 locale 的极速终稿转写器工厂。默认全自动策略后生产不再注入（恒 nil），
    /// 保留注入缝供单测覆盖「固定引擎终稿替换/回退」契约。
    private let analyzerFinalPassFactory: () -> FileTranscribing?
    /// 本次录音的极速引擎终稿转写器快照（start() 时按当时设置裁决；nil = 本次用 SenseVoice 终稿）。
    private var engineFinalPassTranscriber: FileTranscribing?
    /// auto 模式（语言=「自动」）终稿上下文工厂：与 analyzerFinalPassFactory 互斥
    /// （live 层按 locale 模式保证至多一个非 nil）。测试注入 mock。
    private let analyzerAutoFinalPassProvider: () -> AnalyzerAutoFinalPassContext?
    /// 本次录音的 auto 终稿上下文快照（nil = 非 auto 模式）。
    private var engineAutoFinalPass: AnalyzerAutoFinalPassContext?

    private var activePreparedOutput: PreparedRecordingTranscriptionOutput?
    private var sampleContinuation: AsyncStream<[Float]>.Continuation?
    private var startupTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var timer: Timer?
    private var finalizationTimer: Timer?
    private var finalizationStartedAt: Date?
    private var activeOperationID: UUID?
    private var recordingStartedAt: Date?
    /// 已完成录音段的累计有效时长（不含暂停）；pause()/stop() 时折账
    private var accumulatedRecordingSeconds: TimeInterval = 0
    /// 当前录音段起点；暂停期间为 nil
    private var currentSegmentStartedAt: Date?
    /// 恢复录音时注入的接缝静音（0.4s @16kHz）：让最终段低能量边界搜索与
    /// 停顿切句在暂停接缝自然断句，避免暂停前后两个词被拼成一个
    private static let resumeSilenceSamples = [Float](repeating: 0, count: 6_400)

    /// 有效录音时长 = 已折账累计 + 当前段墙钟差（暂停/结束后当前段为 nil，取 0）
    private var effectiveRecordingSeconds: TimeInterval {
        accumulatedRecordingSeconds + (currentSegmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    init(
        appState: AppState,
        audioRecorder: AudioRecorderProtocol? = nil,
        finalRecognizer: SpeechRecognizerProtocol? = nil,
        outputStore: RecordingTranscriptionOutputStore = RecordingTranscriptionOutputStore(),
        resultRecorder: ((String) -> Void)? = nil,
        metadataRecorder: ((String, TranscriptionMetadata) -> Void)? = nil,
        diarizer: SpeakerDiarizing? = nil,
        diarizationEnabledProvider: (() -> Bool)? = nil,
        analyzerFinalPassFactory: (() -> FileTranscribing?)? = nil,
        analyzerAutoFinalPassProvider: (() -> AnalyzerAutoFinalPassContext?)? = nil
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
        self.diarizer = diarizer
        let diarizationProvider = diarizationEnabledProvider ?? {
            DiarizationConfigStore.isRecordingEnabled()
        }
        self.diarizationEnabledProvider = diarizationProvider
        // 默认惰性（恒 nil = 本地引擎终稿）；此缝现仅单测注入（生产走 auto provider）。
        // 绝不内嵌读真实 UserDefaults 的默认——测试会随用户当前引擎设置漂移。
        self.analyzerFinalPassFactory = analyzerFinalPassFactory ?? { nil }
        // 同上 DI 红线：默认惰性恒 nil；生产端显式注入 liveAnalyzerAutoFinalPassProvider。
        self.analyzerAutoFinalPassProvider = analyzerAutoFinalPassProvider ?? { nil }
    }

    /// 生产用 auto 模式终稿上下文——默认全自动策略下的唯一极速终稿入口
    /// （2026-08-02 用户拍板：无引擎/语言选择 UI；分离开启恒 SenseVoice 的互锁在 autoPolicyActive 内生效）。
    /// 路由输入是本地引擎终稿文本（SA 替换前已在手），检测零成本。
    /// 固定 locale 的 analyzerFinalPassFactory 注入缝仅测试使用，生产不再注入。
    static func liveAnalyzerAutoFinalPassProvider() -> () -> AnalyzerAutoFinalPassContext? {
        {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *),
               SpeechEngineConfigStore.autoPolicyActive(
                   diarizationOn: DiarizationConfigStore.isRecordingEnabled()
               ) {
                return AnalyzerAutoFinalPassContext(
                    transcriberForLocale: { locale in
                        SpeechAnalyzerFileTranscriber(
                            decoder: MediaAudioDecoder(),
                            localeIdentifier: locale
                        )
                    },
                    installedLocales: {
                        await SpeechAnalyzerAssetStatus.installedSubset(
                            of: SpeechEngineConfigStore.autoRoutableLocales
                        )
                    },
                    requestAssetInstall: { locale in
                        Task { @MainActor in SpeechAnalyzerAssetAutoInstaller.requestInstall(locale) }
                    }
                )
            }
            #endif
            return nil
        }
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
        case .loadingModel, .recording, .paused, .finishing:
            return false
        }
    }

    var canStop: Bool {
        state == .recording || state == .paused
    }

    var canPause: Bool {
        state == .recording
    }

    var canResume: Bool {
        state == .paused
    }

    var canCancel: Bool {
        switch state {
        case .loadingModel, .recording, .paused, .finishing:
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

    /// 是否处于「正在录音 / 已暂停 / 加载模型 / 生成最终稿」的状态，退出拦截时据此判断。
    var isActivelyRecording: Bool {
        switch state {
        case .loadingModel, .recording, .paused, .finishing:
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
        case .paused:
            return L("recording.status.paused")
        case .finishing:
            return diarizationPhaseText ?? L("recording.status.finishing")
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
        accumulatedRecordingSeconds = 0
        currentSegmentStartedAt = nil
        audioLevel = 0
        waveformBands = Self.silentWaveformBands
        state = .loadingModel
        lastStreamingUpdate = nil
        plainSplitter.reset()
        subtitleDisplayRecorder.reset()
        bilingualSaveCancellable = nil
        diarizationPhaseText = nil
        diarizationNote = nil
        engineNote = nil
        lastDiarizationSpeakerCount = 0
        lastFinalSegments = []
        // 终稿引擎快照：按 start 瞬间的设置裁决本次录音（与文件转录任务启动快照口径一致）
        engineFinalPassTranscriber = analyzerFinalPassFactory()
        engineAutoFinalPass = analyzerAutoFinalPassProvider()
        refreshTranslationSetup(resetCoordinator: true)

        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.startRecordingPipeline(operationID: operationID)
        }
    }

    func stop() {
        guard state == .recording || state == .paused else { return }
        if state == .recording {
            accumulatedRecordingSeconds = effectiveRecordingSeconds
            currentSegmentStartedAt = nil
        }
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

        if state == .recording || state == .paused || state == .finishing {
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
        subtitleDisplayRecorder.reset()
    }

    func pause() {
        guard canPause else { return }
        accumulatedRecordingSeconds = effectiveRecordingSeconds
        currentSegmentStartedAt = nil
        stopTimer()
        elapsedSeconds = accumulatedRecordingSeconds
        audioRecorder.pauseRecording()
        audioLevel = 0
        waveformBands = Self.silentWaveformBands
        state = .paused
        syncSubtitle()
    }

    func resume() {
        guard canResume else { return }
        // 先注接缝静音再放行采集：真实样本经串行队列异步到达，必然排在静音之后
        sampleContinuation?.yield(Self.resumeSilenceSamples)
        audioRecorder.resumeRecording()
        currentSegmentStartedAt = Date()
        state = .recording
        startTimer()
        syncSubtitle()
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
        if state == .completed, !lastFinalSegments.isEmpty {
            // 完成态用保存的同源段落——transcriptText 分离后是 labeled 文本，
            // 直接喂会让说话人标签进翻译管线（红线）
            coordinator.ingestFinal(segments: lastFinalSegments)
            scheduleBilingualTranscriptSave()
        } else if state == .completed || state == .finishing {
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

    // MARK: - 说话人分离

    func setDiarizationEnabled(_ enabled: Bool) {
        diarizationEnabled = enabled
        DiarizationConfigStore.setRecordingEnabled(enabled)
    }

    func setDiarizationSpeakerCount(_ count: Int) {
        diarizationSpeakerCount = count
        DiarizationConfigStore.setRecordingSpeakerCount(count)
    }

    /// 分离后处理产物：labeled 全文（落盘/历史）+ 同一批逐段重识别结果的显示段落
    /// （窗口双语视图/翻译管线用，text 无标签前缀）。两者同源，窗口显示 ≡ 落盘内容。
    struct DiarizedTranscript {
        let labeledText: String
        let displaySegments: [TranslationCoordinator.FinalSegment]
    }

    /// 录完后的说话人分离后处理。开关关/单说话人/任何失败都返回 nil（= 用无标签原文稿）。
    private func runDiarizationPostPass(
        audioURL: URL,
        sampleCount: Int,
        operationID: UUID
    ) async -> DiarizedTranscript? {
        guard let diarizer, diarizationEnabledProvider(), isActive(operationID) else { return nil }
        let sampleRate = 16_000
        let audioDuration = Double(sampleCount) / Double(sampleRate)
        guard audioDuration > 0 else { return nil }

        diarizationPhaseText = L("diarization.status.separating")
        do {
            let raw = try await diarizer.diarize(
                wavURL: audioURL, audioDuration: audioDuration
            ) { _ in }
            guard isActive(operationID), !raw.isEmpty else { return nil }

            let segments = SpeakerSegmentComposer.renumberByFirstAppearance(
                SpeakerSegmentComposer.padAndClip(raw, totalDuration: audioDuration)
            )
            let speakerCount = SpeakerSegmentComposer.distinctSpeakerCount(segments)
            // 单说话人：无需标签，直接沿用原文稿（跳过逐段重识别，保住已验证的质量与耗时）
            guard speakerCount > 1 else { return nil }

            var labeled: [SpeakerSegmentComposer.LabeledSegment] = []
            for (index, segment) in segments.enumerated() {
                guard isActive(operationID) else { return nil }
                diarizationPhaseText = L("diarization.status.relabeling", index + 1, segments.count)
                let startSample = max(0, Int(segment.start * Double(sampleRate)))
                let endSample = Int(segment.end * Double(sampleRate))
                guard endSample > startSample,
                      let samples = WAVSampleFileWriter.readFloat32Samples(
                        from: audioURL, sampleRange: startSample..<endSample
                      ),
                      !samples.isEmpty else { continue }

                let text: String
                if segment.end - segment.start > 32 {
                    // 超长 speaker 段：复用文件转写的低能量边界二次切块
                    var parts: [String] = []
                    for chunk in FileTranscriptionService.makeChunks(samples: samples, sampleRate: sampleRate) {
                        guard isActive(operationID) else { return nil }
                        if let part = await finalRecognizer.recognize(samples: chunk.samples, sampleRate: sampleRate)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !part.isEmpty {
                            parts.append(part)
                        }
                    }
                    text = parts.joined(separator: "\n")
                } else {
                    text = (await finalRecognizer.recognize(samples: samples, sampleRate: sampleRate) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !text.isEmpty {
                    labeled.append(.init(speaker: segment.speaker, text: text))
                }
            }
            guard isActive(operationID) else { return nil }
            let composed = SpeakerSegmentComposer.compose(labeled) { LL("diarization.speakerLabel", $0) }
            guard !composed.isEmpty else { return nil }
            lastDiarizationSpeakerCount = speakerCount
            // 显示段落与 labeled 全文同源：同一批逐段重识别结果。
            // 标签只在说话人变化处出现（与 compose 的连续同人合并口径一致）。
            var displaySegments: [TranslationCoordinator.FinalSegment] = []
            var previousSpeaker: Int?
            for segment in labeled where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label = segment.speaker != previousSpeaker
                    ? LL("diarization.speakerLabel", segment.speaker)
                    : nil
                displaySegments.append(.init(speakerLabel: label, text: segment.text))
                previousSpeaker = segment.speaker
            }
            return DiarizedTranscript(labeledText: composed, displaySegments: displaySegments)
        } catch {
            NSLog("[VowKy][Recording] 分离后处理失败，使用无标签文稿: \(error.localizedDescription)")
            if isActive(operationID) {
                diarizationNote = L("diarization.note.fallback")
            }
            return nil
        }
    }

    // MARK: - 极速引擎终稿替换

    /// 录完后的极速引擎（SpeechAnalyzer）终稿后处理：对已落盘 wav 整体转写，
    /// 成功则替换 SenseVoice 终稿（照 runDiarizationPostPass 的后处理模式）。
    /// 任何失败返回 nil → complete 回退 SenseVoice 终稿并注记，绝不丢文稿。
    /// 分离场景恒 SenseVoice：分离开启（含录音中途打开）时直接跳过。
    /// auto 模式：按本地终稿文本路由语言——单语言按该 locale 替换；
    /// 混说/粤语保留本地终稿并注记（本地引擎本就是混说唯一能识别的引擎）；其余 keep 静默保留。
    private func runAnalyzerFinalPass(audioURL: URL, senseVoiceText: String, operationID: UUID) async -> String? {
        guard isActive(operationID) else { return nil }
        guard !(diarizer != nil && diarizationEnabledProvider()) else { return nil }

        let transcriber: FileTranscribing?
        if let auto = engineAutoFinalPass {
            let installed = await auto.installedLocales()
            switch AnalyzerLocaleRouter.route(text: senseVoiceText, installedLocales: installed) {
            case .analyzer(let locale):
                transcriber = auto.transcriberForLocale(locale)
            case .keepSenseVoice(.mixed), .keepSenseVoice(.likelyCantonese):
                if isActive(operationID) {
                    engineNote = L("recording.note.autoMixedKeptLocal")
                }
                return nil
            case .keepSenseVoice(.notInstalled(let locale)):
                // 本次保留本地终稿；后台按需下载，装好后下次录音自动用极速
                auto.requestAssetInstall?(locale)
                return nil
            case .keepSenseVoice:
                return nil
            }
        } else {
            transcriber = engineFinalPassTranscriber
        }
        guard let transcriber, isActive(operationID) else { return nil }

        diarizationPhaseText = L("recording.status.analyzerPass")
        do {
            let text = try await transcriber.transcribe(url: audioURL) { _ in }
            guard isActive(operationID) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            NSLog("[VowKy][Recording] 极速引擎终稿失败，回退本地引擎终稿: \(error.localizedDescription)")
            if isActive(operationID) {
                engineNote = L("recording.note.analyzerFallback")
            }
            return nil
        }
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
            let update = lastStreamingUpdate
                ?? StreamingRecognitionUpdate(committedText: "", partialText: transcriptText, isFinal: false)
            subtitlePacer.ingest(Self.subtitleWorthy(plainParagraphs(of: update)))
        }
    }

    /// 字幕只播有实际内容的句子：纯标点/数字（静音噪声）一律过滤。
    private static func subtitleWorthy(_ paragraphs: [TranscriptParagraph]) -> [TranscriptParagraph] {
        paragraphs.filter { !TranslationCoordinator.isTrivialText($0.text) }
    }

    /// 字幕实录挂钩：每次真实上屏渲染时记一笔（时间基准与 elapsedSeconds 一致，不含暂停时长）。
    private func recordSubtitleDisplay(_ paragraph: TranscriptParagraph, isNewSentence: Bool) {
        subtitleDisplayRecorder.record(paragraph, isNewSentence: isNewSentence, at: effectiveRecordingSeconds)
    }

    /// 字幕实录落盘：整场没上过屏（未开字幕/零内容）不产文件；
    /// 非关键产物，写失败只记日志，绝不影响 complete 主流程。
    private func writeSubtitleLogIfNeeded(textURL: URL) {
        guard !subtitleDisplayRecorder.isEmpty else { return }
        let markdown = SubtitleDisplayRecorder.compose(
            records: subtitleDisplayRecorder.records,
            startedAt: recordingStartedAt,
            translation: translationConfig
        )
        do {
            try outputStore.writeTranscript(markdown, to: SubtitleDisplayRecorder.outputURL(for: textURL))
        } catch {
            NSLog("[VowKy][SubtitleLog] 字幕实录写入失败: \(error.localizedDescription)")
        }
    }

    /// 翻译关时的字幕数据源：锚定切分全文（已显示短句不因标点漂移合并回改），
    /// 标记为跳过翻译（字幕不渲染译文行）。
    private func plainParagraphs(of update: StreamingRecognitionUpdate) -> [TranscriptParagraph] {
        let split = plainSplitter.split(committed: update.committedText, partial: update.partialText)
        return (split.committed + split.partial).enumerated().map { index, piece in
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
        if !finalRecognizer.isReady {
            // helper 可能刚崩溃/被回收：先预热（respawn + handshake，阻塞到模型加载完）再判定
            await finalRecognizer.warmUp()
            guard isActive(operationID) else { return }
        }
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
                    guard let self else { return }
                    // 波形重绘节流到 ~12fps：识别流不受影响（yield 在上面无条件执行）
                    let now = Date().timeIntervalSinceReferenceDate
                    guard now - self.lastWaveformUpdateAt >= 0.08 else { return }
                    self.lastWaveformUpdateAt = now
                    self.waveformBands = waveformBands
                }
            }
            try audioRecorder.startRecording()

            guard isActive(operationID) else {
                writer.finalize()
                deletePreparedOutput(preparedOutput)
                return
            }

            recordingStartedAt = preparedOutput.startedAt
            currentSegmentStartedAt = recordingStartedAt
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
                    // 说话人分离后处理（用户拍板：录完后一次性处理，不动录制中字幕冻结架构）。
                    // 任何失败返回 nil → complete 使用无标签原文稿，绝不丢文稿。
                    let diarized = await self?.runDiarizationPostPass(
                        audioURL: preparedOutput.audioURL,
                        sampleCount: writer.sampleCount,
                        operationID: operationID
                    )
                    // 极速引擎终稿替换（引擎快照为 SpeechAnalyzer 且无分离产出时）。
                    // wav 已由 engine.run 的 defer finalize，可整体转写。
                    var analyzerText: String?
                    if diarized == nil {
                        analyzerText = await self?.runAnalyzerFinalPass(
                            audioURL: preparedOutput.audioURL,
                            senseVoiceText: result.finalText,
                            operationID: operationID
                        )
                    }
                    await self?.complete(
                        result: result,
                        diarized: diarized,
                        analyzerText: analyzerText,
                        operationID: operationID
                    )
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
            let paragraphs = Self.subtitleWorthy(plainParagraphs(of: update))
            Self.debugSubtitleTrace("PARAS", paragraphs.map(\.text).joined(separator: "|"))
            subtitlePacer.ingest(paragraphs)
        }
    }

    private func applyFinalization(progress: RecordingFinalizationProgress, operationID: UUID) {
        guard isActive(operationID) else { return }
        finalizationProgress = progress
    }

    private func complete(
        result: RecordingTranscriptionResult,
        diarized: DiarizedTranscript? = nil,
        analyzerText: String? = nil,
        operationID: UUID
    ) {
        guard isActive(operationID), let preparedOutput = activePreparedOutput else { return }

        stopTimer()
        resetFinalizationState()
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation = nil
        subtitleController.hide()
        subtitleCancellable = nil
        subtitlePacer.reset()

        // 主文稿用带标签版本（分离成功时）；翻译管线只吃无标签文本
        // （AnchoredParagraphSplitter/字幕/双语对照均不容说话人前缀——这里是唯一分流闸门）。
        // 分离成功时窗口/翻译用同源 displaySegments（与落盘 .md 同一批识别结果），
        // 不再用整段长解码的 result.finalText——两者可能质量悬殊（2026-08-02 P0）。
        // 终稿优先级：labeled（分离） > analyzerText（极速引擎替换） > SenseVoice plain。
        let plainText = analyzerText?.isEmpty == false
            ? analyzerText!
            : result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let labeled = diarized?.labeledText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = (labeled?.isEmpty == false) ? labeled! : plainText

        do {
            try outputStore.writeTranscript(finalText, to: preparedOutput.textURL)
            transcriptText = finalText

            // 有效录音时长（不含暂停、不含最终稿生成耗时）
            let duration = effectiveRecordingSeconds
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
            var doneData: [String: Any] = [
                "duration_s": Int(duration),
                "char_count": finalText.count,
                "diar": (diarizer != nil && diarizationEnabledProvider()) ? 1 : 0,
                "speakers": lastDiarizationSpeakerCount,
                "engine": analyzerText?.isEmpty == false ? "sa" : "sv",
            ]
            if diarizationNote != nil {
                doneData["diar_fallback"] = 1
            }
            if engineNote != nil {
                doneData["sa_fallback"] = 1
            }
            AnalyticsService.shared.track("rec_transcribe_done", data: doneData)

            writeSubtitleLogIfNeeded(textURL: preparedOutput.textURL)

            // 最终稿整稿重新送译，得到双语终态。分离成功=同源段落（带显示标签）；
            // 否则=plain 终稿单段。lastFinalSegments 同时供「完成态中途开翻译」复用。
            if diarized != nil, labeled?.isEmpty == false {
                lastFinalSegments = diarized!.displaySegments
            } else if !plainText.isEmpty {
                lastFinalSegments = [.init(speakerLabel: nil, text: plainText)]
            } else {
                lastFinalSegments = []
            }
            if !lastFinalSegments.isEmpty {
                translationCoordinator?.ingestFinal(segments: lastFinalSegments)
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
        if state == .recording || state == .paused || state == .finishing {
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
        AnalyticsService.shared.track("rec_transcribe_fail")
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
                self.elapsedSeconds = self.effectiveRecordingSeconds
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
        diarizationPhaseText = nil
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

