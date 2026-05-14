import AppKit
import SwiftUI

// MARK: - Recording Transcription Window Controller

@MainActor
final class RecordingTranscriptionWindowController {
    static let shared = RecordingTranscriptionWindowController()

    private var window: NSWindow?
    private var viewModel: RecordingTranscriptionViewModel?

    func showWindow(appState: AppState) {
        NSApp.setActivationPolicy(.regular)

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            viewModel?.start()
            return
        }

        let viewModel = RecordingTranscriptionViewModel(appState: appState)
        let view = RecordingTranscriptionView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "VowKy 录音"
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
                self?.viewModel?.cancel()
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

    // AI 后处理
    @Published private(set) var enhancementInFlight: Bool = false
    @Published private(set) var enhancementResult: EnhancementResult?
    @Published private(set) var titleStatus: AIBadgeStatus = .idle
    @Published private(set) var summaryStatus: AIBadgeStatus = .idle
    @Published private(set) var outlineStatus: AIBadgeStatus = .idle
    @Published private(set) var formattedMarkdown: String?

    nonisolated private static let waveformBandCount = 64
    nonisolated private static var silentWaveformBands: [RecordingWaveformBand] {
        Array(repeating: RecordingWaveformBand(positive: 0, negative: 0), count: waveformBandCount)
    }

    private let appState: AppState
    private var audioRecorder: AudioRecorderProtocol
    private let recognizerFactory: () -> StreamingSpeechRecognizerProtocol
    private let finalRecognizer: SpeechRecognizerProtocol
    private let punctuationService: PunctuationServiceProtocol?
    private let outputStore: RecordingTranscriptionOutputStore
    private let resultRecorder: (String) -> Void
    private let enhancementService: TranscriptionEnhancing
    private let aiConfigLoader: () -> AIProviderConfig

    private var activeRecognizer: StreamingSpeechRecognizerProtocol?
    private var activePreparedOutput: PreparedRecordingTranscriptionOutput?
    private var sampleContinuation: AsyncStream<[Float]>.Continuation?
    private var startupTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var enhancementTask: Task<Void, Never>?
    private var timer: Timer?
    private var activeOperationID: UUID?
    private var recordingStartedAt: Date?

    init(
        appState: AppState,
        audioRecorder: AudioRecorderProtocol? = nil,
        recognizerFactory: (() -> StreamingSpeechRecognizerProtocol)? = nil,
        finalRecognizer: SpeechRecognizerProtocol? = nil,
        punctuationService: PunctuationServiceProtocol? = nil,
        outputStore: RecordingTranscriptionOutputStore = RecordingTranscriptionOutputStore(),
        resultRecorder: ((String) -> Void)? = nil,
        enhancementService: TranscriptionEnhancing = EnhancementRouter(),
        aiConfigLoader: @escaping () -> AIProviderConfig = { AIProviderFactory.load() }
    ) {
        self.appState = appState
        self.audioRecorder = audioRecorder ?? appState.audioRecorder
        self.recognizerFactory = recognizerFactory ?? {
            appState.makeRecordingStreamingRecognizer()
        }
        self.finalRecognizer = finalRecognizer ?? appState.finalSpeechRecognizerForRecordingTranscription()
        self.punctuationService = punctuationService ?? appState.punctuationServiceForRecordingTranscription()
        self.outputStore = outputStore
        self.resultRecorder = resultRecorder ?? { text in
            appState.recordRecognitionResult(text: text, sourceType: "recording")
        }
        self.enhancementService = enhancementService
        self.aiConfigLoader = aiConfigLoader
    }

    enum AIBadgeStatus: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
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
        output != nil
    }

    /// 是否可以手动触发 AI 美化：AI 已启用 + 转写已完成 + 当前没有进行中的增强 + 还没拿到结果。
    var canRunEnhancement: Bool {
        guard state == .completed, !transcriptText.isEmpty else { return false }
        let cfg = aiConfigLoader()
        guard cfg.enabled else { return false }
        return !enhancementInFlight && enhancementResult == nil
    }

    /// 是否在 UI 中显示 AI 三任务徽章（已启用就显示）。
    var aiBadgesVisible: Bool {
        aiConfigLoader().enabled
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
            return "准备录音"
        case .loadingModel:
            return "正在加载录音模型..."
        case .recording:
            return "正在录音并实时预览"
        case .finishing:
            return "录音已完成，正在生成高质量转录稿..."
        case .completed:
            return "已保存文字和音频"
        case .cancelled:
            return "已取消"
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
        elapsedSeconds = 0
        audioLevel = 0
        waveformBands = Self.silentWaveformBands
        state = .loadingModel
        resetEnhancementState()
        enhancementTask?.cancel()
        enhancementTask = nil

        let recognizer = recognizerFactory()
        activeRecognizer = recognizer

        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.loadModelAndStartRecording(recognizer: recognizer, operationID: operationID)
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        stopTimer()
        _ = audioRecorder.stopRecording()
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
    }

    func cancel() {
        guard canCancel else { return }

        let preparedOutput = activePreparedOutput
        activeOperationID = nil
        startupTask?.cancel()
        workerTask?.cancel()
        enhancementTask?.cancel()
        startupTask = nil
        workerTask = nil
        enhancementTask = nil

        if state == .recording || state == .finishing {
            _ = audioRecorder.stopRecording()
        }
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
        activeRecognizer?.reset()
        activeRecognizer = nil
        stopTimer()
        deletePreparedOutput(preparedOutput)
        activePreparedOutput = nil

        appState.endRecordingTranscription()
        state = .cancelled
        statusMessage = nil
        audioLevel = 0
        waveformBands = Self.silentWaveformBands
        resetEnhancementState()
    }

    /// 手动触发 AI 美化（Settings 关闭自动触发时使用）。
    func runEnhancement() {
        guard canRunEnhancement else { return }
        triggerEnhancement(rawText: transcriptText)
    }

    /// 复制 Markdown 文档（带 frontmatter）到剪贴板；若没有 AI 结果则复制原文。
    func copyMarkdown() {
        let toCopy = formattedMarkdown ?? transcriptText
        guard !toCopy.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(toCopy, forType: .string)
        AnalyticsService.shared.trackHistoryCopy()
    }

    func copyResult() {
        guard canCopyResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
        AnalyticsService.shared.trackHistoryCopy()
    }

    func openOutputFolder() {
        guard let output else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output.textURL, output.audioURL])
    }

    private func loadModelAndStartRecording(
        recognizer: StreamingSpeechRecognizerProtocol,
        operationID: UUID
    ) async {
        await Task.detached(priority: .userInitiated) {
            recognizer.loadModel()
        }.value

        guard isActive(operationID) else { return }
        guard recognizer.isReady else {
            fail(operationID: operationID, message: "流式语音模型未找到或加载失败")
            return
        }
        guard finalRecognizer.isReady else {
            fail(operationID: operationID, message: "语音模型未加载，无法生成最终转录稿")
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

            recognizer.startSession()
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

            let engine = RecordingTranscriptionEngine(
                previewRecognizer: recognizer,
                finalRecognizer: finalRecognizer,
                writer: writer,
                sampleRate: 16_000
            )

            workerTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let result = try await engine.run(audioChunks: audioStream) { update in
                        self?.apply(update: update, operationID: operationID)
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
    }

    private func complete(result: RecordingTranscriptionResult, operationID: UUID) {
        guard isActive(operationID), let preparedOutput = activePreparedOutput else { return }

        stopTimer()
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation = nil

        let trimmedText = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = trimmedText.isEmpty
            ? ""
            : (punctuationService?.addPunctuation(to: trimmedText) ?? trimmedText)

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
            }

            state = .completed
            statusMessage = nil

            // AI 后处理：仅在 enabled + autoTrigger 且有有效文本时自动触发
            let cfg = aiConfigLoader()
            if cfg.enabled && cfg.autoTrigger && !finalText.isEmpty {
                triggerEnhancement(rawText: finalText)
            }
        } catch {
            state = .failed("保存失败：\(error.localizedDescription)")
        }

        clearActiveOperation(operationID: operationID)
    }

    private func resetEnhancementState() {
        enhancementInFlight = false
        enhancementResult = nil
        titleStatus = .idle
        summaryStatus = .idle
        outlineStatus = .idle
        formattedMarkdown = nil
    }

    private func triggerEnhancement(rawText: String) {
        guard let preparedOutput = activePreparedOutput ?? lastPreparedFromOutput() else { return }

        enhancementInFlight = true
        titleStatus = .running
        summaryStatus = .running
        outlineStatus = .running
        enhancementResult = nil

        let input = EnhancementInput(
            rawText: rawText,
            audioURL: preparedOutput.audioURL,
            startedAt: preparedOutput.startedAt,
            durationSeconds: output?.duration,
            sourceType: "recording"
        )
        let markdownPath = preparedOutput.textURL.path
        let textURL = preparedOutput.textURL
        // 同目录写 .ai-log.txt，方便排查 AI prompt / response
        let logURL = preparedOutput.textURL
            .deletingPathExtension()
            .appendingPathExtension("ai-log.txt")
        let service = enhancementService

        enhancementTask = Task { @MainActor [weak self] in
            let result = await service.enhance(
                input: input,
                markdownPath: markdownPath,
                logFilePath: logURL.path
            ) { progress in
                Task { @MainActor in
                    self?.apply(enhancementProgress: progress)
                }
            }
            // 任务可能在 cancel 中已取消
            guard let self else { return }
            if Task.isCancelled { return }

            self.enhancementInFlight = false
            self.enhancementResult = result
            self.formattedMarkdown = result.fullMarkdownDocument

            // 覆盖写入带 frontmatter 的完整 markdown
            try? result.fullMarkdownDocument.write(to: textURL, atomically: true, encoding: .utf8)
        }
    }

    private func apply(enhancementProgress progress: EnhancementProgress) {
        let status: AIBadgeStatus
        switch progress.status {
        case .running:   status = .running
        case .succeeded: status = .succeeded
        case .failed(let msg): status = .failed(msg)
        }
        switch progress.task {
        case .title:   titleStatus = status
        case .summary: summaryStatus = status
        case .outline: outlineStatus = status
        }
    }

    /// `activePreparedOutput` 在 `clearActiveOperation` 中会被清空；用 `output` 重建一个用于增强阶段。
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
        deletePreparedOutput(activePreparedOutput)
        state = .cancelled
        clearActiveOperation(operationID: operationID)
    }

    private func fail(operationID: UUID, message: String) {
        guard isActive(operationID) else { return }
        stopTimer()
        if state == .recording || state == .finishing {
            _ = audioRecorder.stopRecording()
        }
        audioRecorder.onSamplesCaptured = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
        deletePreparedOutput(activePreparedOutput)
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
        activeRecognizer?.reset()
        activeRecognizer = nil
        audioLevel = 0
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
    @ObservedObject var viewModel: RecordingTranscriptionViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
                Text("录音")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(RecordingTheme.textPrimary)
                Text("实时预览，高质量最终稿自动保存")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(RecordingTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

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

                    Text(viewModel.statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(RecordingTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(viewModel.durationText)
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

            if viewModel.state == .loadingModel || viewModel.state == .finishing {
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

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: transcriptIconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(RecordingTheme.accentDark)

                Text("转写内容")
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

                if viewModel.aiBadgesVisible && viewModel.state == .completed {
                    AIBadgesView(
                        title: viewModel.titleStatus,
                        summary: viewModel.summaryStatus,
                        outline: viewModel.outlineStatus
                    )
                }

                Spacer()

                if !viewModel.transcriptText.isEmpty {
                    Text("\(viewModel.transcriptText.count) 字")
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

                if viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(emptyTranscriptText)
                        .font(.system(size: 14))
                        .foregroundColor(RecordingTheme.textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                }

                TextEditor(text: Binding(
                    get: { viewModel.formattedMarkdown ?? viewModel.transcriptText },
                    set: { _ in }
                ))
                .font(.system(size: 14))
                .foregroundColor(RecordingTheme.textPrimary)
                .lineSpacing(4)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
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
                    Label("取消", systemImage: "xmark")
                }
                .buttonStyle(RecordingGhostButtonStyle())
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    viewModel.start()
                } label: {
                    Label("重新录音", systemImage: "record.circle")
                }
                .buttonStyle(RecordingPrimaryButtonStyle())
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.return, modifiers: [])
            }

            if viewModel.canStop {
                Button {
                    viewModel.stop()
                } label: {
                    Label("完成并生成最终稿", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(RecordingPrimaryButtonStyle())
            }

            Spacer()

            if viewModel.canRunEnhancement {
                Button {
                    viewModel.runEnhancement()
                } label: {
                    Label("AI 美化", systemImage: "wand.and.stars")
                }
                .buttonStyle(RecordingSecondaryButtonStyle())
            }

            if viewModel.enhancementInFlight {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("AI 处理中…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(RecordingTheme.textMuted)
                }
            }

            Button {
                viewModel.copyResult()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(RecordingSecondaryButtonStyle())
            .disabled(!viewModel.canCopyResult)

            if viewModel.enhancementResult != nil {
                Button {
                    viewModel.copyMarkdown()
                } label: {
                    Label("复制 Markdown", systemImage: "doc.richtext")
                }
                .buttonStyle(RecordingSecondaryButtonStyle())
            }

            Button {
                viewModel.openOutputFolder()
            } label: {
                Label("打开文件夹", systemImage: "folder")
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
            return "READY"
        case .loadingModel:
            return "LOADING"
        case .recording:
            return "LIVE"
        case .finishing:
            return "FINALIZING"
        case .completed:
            return "SAVED"
        case .cancelled:
            return "CANCELLED"
        case .failed:
            return "FAILED"
        }
    }

    private var cardTitle: String {
        switch viewModel.state {
        case .idle:
            return "准备开始"
        case .loadingModel:
            return "正在准备模型"
        case .recording:
            return "正在聆听"
        case .finishing:
            return "生成最终稿"
        case .completed:
            return "录音已保存"
        case .cancelled:
            return "录音已取消"
        case .failed:
            return "录音失败"
        }
    }

    private var durationCaption: String {
        switch viewModel.state {
        case .completed:
            return "总时长"
        case .finishing:
            return "录音时长"
        default:
            return "当前时长"
        }
    }

    private var transcriptBadgeText: String {
        switch viewModel.state {
        case .completed:
            return "SenseVoice 最终稿"
        case .finishing:
            return "高质量转录中"
        case .recording:
            return "Paraformer 实时预览"
        case .failed:
            return "未保存"
        default:
            return "等待内容"
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
            return "正在准备离线模型，准备好后会自动开始录音。"
        case .recording:
            return "开始说话后，这里会显示实时预览。完成后会替换为高质量最终稿。"
        case .finishing:
            return "正在等待 SenseVoice 完成最终转录。"
        case .completed:
            return "最终稿为空。"
        case .failed:
            return "没有生成可保存的转写内容。"
        case .cancelled:
            return "本次录音已取消。"
        case .idle:
            return "点击菜单中的录音后会自动开始。"
        }
    }

    private var outputPathText: String {
        if let output = viewModel.output {
            return output.textURL.deletingLastPathComponent().path
        }
        return "完成后自动保存到 文稿/VowKy Recordings"
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

            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(RecordingTheme.accentDarkest)
        }
        .frame(width: 70, height: 70)
    }

    private var iconName: String {
        switch state {
        case .loadingModel, .finishing:
            return "waveform"
        case .completed:
            return "checkmark"
        case .cancelled:
            return "xmark"
        case .failed:
            return "exclamationmark"
        default:
            return "mic.fill"
        }
    }
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

private enum RecordingTheme {
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

// MARK: - AI 三任务徽章

struct AIBadgesView: View {
    let title: RecordingTranscriptionViewModel.AIBadgeStatus
    let summary: RecordingTranscriptionViewModel.AIBadgeStatus
    let outline: RecordingTranscriptionViewModel.AIBadgeStatus

    var body: some View {
        HStack(spacing: 4) {
            badge(label: "标题", status: title)
            badge(label: "摘要", status: summary)
            badge(label: "结构", status: outline)
        }
    }

    @ViewBuilder
    private func badge(label: String, status: RecordingTranscriptionViewModel.AIBadgeStatus) -> some View {
        let (symbol, color, tooltip): (String, Color, String?) = {
            switch status {
            case .idle:        return ("circle.dashed", .gray, nil)
            case .running:     return ("ellipsis.circle", .orange, nil)
            case .succeeded:   return ("checkmark.circle.fill", .green, nil)
            case .failed(let msg): return ("xmark.octagon.fill", .red, msg)
            }
        }()
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
        .help(tooltip ?? label)
    }
}
