import AppKit
import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: - State Enum

    enum State: Equatable {
        case loading
        case idle
        case recording
        case recognizing
        case outputting
    }

    // MARK: - Published Properties

    @Published var state: State = .idle
    @Published var errorMessage: String?
    @Published var lastResult: String?
    @Published var recentResults: [String] = [] // 最近 3 次识别结果
    @Published var isFileTranscriptionInProgress = false
    @Published var isRecordingTranscriptionInProgress = false

    // MARK: - Dependencies

    private let speechRecognizer: SpeechRecognizerProtocol
    let audioRecorder: AudioRecorderProtocol
    private let permissionChecker: PermissionCheckerProtocol
    private let punctuationService: PunctuationServiceProtocol?
    private let backupService: AudioBackupProtocol?

    /// Optional services wired during setup()
    var hotkeyManager: HotkeyManager?
    var textOutputService: TextOutputService?
    var recordingPanel: RecordingPanel?

    /// Timestamp when recording started (for duration tracking)
    private var recordingStartTime: Date?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var lastTextInsertionTarget: NSRunningApplication?

    // MARK: - Init

    init(
        speechRecognizer: SpeechRecognizerProtocol,
        audioRecorder: AudioRecorderProtocol,
        permissionChecker: PermissionCheckerProtocol,
        punctuationService: PunctuationServiceProtocol? = nil,
        backupService: AudioBackupProtocol? = nil
    ) {
        self.speechRecognizer = speechRecognizer
        self.audioRecorder = audioRecorder
        self.permissionChecker = permissionChecker
        self.punctuationService = punctuationService
        self.backupService = backupService
    }

    // MARK: - Setup (called once at app launch)

    /// - Parameter skipHotkey: 新手引导期间跳过热键创建，避免触发系统辅助功能对话框
    func setup(skipHotkey: Bool = false) {
        CrashLogger.log("[AppState] setup() start, skipHotkey: \(skipHotkey)")

        // 0. Open history database
        HistoryStore.shared.open()
        CrashLogger.log("[AppState] HistoryStore opened")
        startApplicationFocusTracking()

        // 1. Load speech model + punctuation model in background
        state = .loading
        CrashLogger.log("[AppState] Loading speech model...")
        if let recognizer = speechRecognizer as? LocalSpeechRecognizer {
            let punctService = punctuationService as? PunctuationService
            Task.detached(priority: .userInitiated) {
                recognizer.loadModel()
                CrashLogger.log("[AppState] Speech model loaded")
                punctService?.loadModel()
                CrashLogger.log("[AppState] Punctuation model loaded")
                await MainActor.run {
                    self.state = .idle
                    self.checkForRecovery()
                }
            }
        } else {
            state = .idle
            checkForRecovery()
        }

        // 2. Wire backup service to audio recorder
        if let recorder = audioRecorder as? AudioRecorder {
            recorder.backupService = backupService
        }

        // 3. Create recording panel
        recordingPanel = RecordingPanel(appState: self)

        // 4. Create text output service
        textOutputService = TextOutputService()

        // 5. Wire hotkey manager (skip during onboarding to avoid system dialog)
        if !skipHotkey {
            startHotkey()
        }
        CrashLogger.log("[AppState] setup() complete")
        print("[VowKy][AppState] setup() complete, skipHotkey: \(skipHotkey)")
    }

    /// 创建并启动热键管理器（新手引导完成后调用）
    func startHotkey() {
        guard hotkeyManager == nil else {
            CrashLogger.log("[AppState] startHotkey() skipped, already initialized")
            print("[VowKy][AppState] startHotkey() skipped, already initialized")
            return
        }
        let config = HotkeyConfig.current
        CrashLogger.log("[AppState] startHotkey() config: \(config.displayName) (keyCode=\(config.keyCode))")
        let hotkeyMgr = HotkeyManager()
        hotkeyMgr.onHotkeyPressed = { [weak self] in
            self?.handleHotkeyToggle()
        }
        hotkeyMgr.onHotkeyReleased = { [weak self] in
            self?.handleHotkeyRelease()
        }
        hotkeyMgr.onCancelPressed = { [weak self] in
            self?.cancelRecording()
        }
        hotkeyMgr.shouldInterceptCancel = { [weak self] in
            self?.state == .recording
        }
        let started = hotkeyMgr.start()
        self.hotkeyManager = hotkeyMgr

        if !started {
            CrashLogger.log("[AppState] startHotkey() failed, starting permission polling")
            startPermissionPolling()
        }
        CrashLogger.log("[AppState] startHotkey() complete, hotkey active: \(started)")
        print("[VowKy][AppState] startHotkey() complete, hotkey active: \(started)")
    }

    // MARK: - Permission Polling

    private var permissionPollTimer: Timer?

    /// 轮询辅助功能权限，授权后自动启动快捷键
    private func startPermissionPolling() {
        print("[VowKy][AppState] Starting permission polling...")
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRetryHotkey()
            }
        }
    }

    private func checkAndRetryHotkey() {
        guard let hotkeyMgr = hotkeyManager, !hotkeyMgr.isRunning else {
            stopPermissionPolling()
            return
        }

        guard permissionChecker.isAccessibilityGranted() else { return }

        // 权限已授予，重试启动快捷键
        let started = hotkeyMgr.start()
        if started {
            stopPermissionPolling()
            print("[VowKy][AppState] Permission granted, hotkey now active!")
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        print("[VowKy][AppState] Permission polling stopped")
    }

    // MARK: - Hotkey Handler (Toggle Mode)

    func handleHotkeyToggle() {
        CrashLogger.log("[Hotkey] handleHotkeyToggle() state=\(state)")
        print("[VowKy][AppState] handleHotkeyToggle() called, current state: \(state)")

        // Clear previous error
        errorMessage = nil

        if isFileTranscriptionInProgress {
            errorMessage = "文件转录中，请稍后或取消转录"
            CrashLogger.log("[Hotkey] Ignored while file transcription is running")
            return
        }
        if isRecordingTranscriptionInProgress {
            errorMessage = "录音中，请稍后或完成录音"
            CrashLogger.log("[Hotkey] Ignored while recording transcription is running")
            return
        }

        switch state {
        case .idle:
            startRecordingFromIdle()

        case .recording:
            if !HotkeyConfig.current.isHoldMode {
                stopRecordingAndRecognize()
            }
            // 长按模式：录音中收到 keyDown 忽略，等松手再停止

        case .loading:
            if !speechRecognizer.isReady {
                errorMessage = "语音模型加载中..."
                CrashLogger.log("[Hotkey] Model still loading, ignored")
                print("[VowKy][AppState] Model still loading, ignoring toggle")
            }

        case .recognizing, .outputting:
            CrashLogger.log("[Hotkey] Ignored in state: \(state)")
            print("[VowKy][AppState] Ignoring toggle in state: \(state)")
        }
    }

    private func startRecordingFromIdle() {
        // Check accessibility permission
        guard permissionChecker.isAccessibilityGranted() else {
            errorMessage = "请在系统设置中授予辅助功能权限"
            CrashLogger.log("[Recording] Accessibility not granted")
            print("[VowKy][AppState] Accessibility not granted")
            return
        }

        // Try to start recording
        do {
            try audioRecorder.startRecording()
            try? backupService?.startBackup()
            state = .recording
            recordingStartTime = Date()
            AnalyticsService.shared.trackVoiceStart()
            CrashLogger.log("[Recording] Started")
            print("[VowKy][AppState] Recording started → state = .recording")
        } catch {
            state = .idle
            errorMessage = error.localizedDescription
            CrashLogger.log("[Recording] Failed: \(error.localizedDescription)")
            print("[VowKy][AppState] Recording failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Hold Mode Release

    func handleHotkeyRelease() {
        CrashLogger.log("[Hotkey] handleHotkeyRelease() state=\(state)")
        print("[VowKy][AppState] handleHotkeyRelease() called, current state: \(state)")
        guard state == .recording else { return }
        stopRecordingAndRecognize()
    }

    // MARK: - Cancel Recording

    func cancelRecording() {
        guard state == .recording else {
            print("[VowKy][AppState] cancelRecording() ignored, state: \(state)")
            return
        }
        _ = audioRecorder.stopRecording()
        backupService?.deleteBackup()
        AnalyticsService.shared.trackVoiceCancel()
        state = .idle
        print("[VowKy][AppState] Recording cancelled → state = .idle")
    }

    private func stopRecordingAndRecognize() {
        let samples = audioRecorder.stopRecording()
        CrashLogger.log("[Recognize] Stopped recording, \(samples.count) samples")
        print("[VowKy][AppState] Recording stopped, samples count: \(samples.count)")

        // 静音检测：录音波形几乎为 0 时直接给出明确提示，避免把垃圾喂给识别引擎产生乱码
        let maxAmp = samples.map { abs($0) }.max() ?? 0
        if !samples.isEmpty && maxAmp < 0.0001 {
            CrashLogger.log("[Recognize] Audio is silent (maxAmp=\(maxAmp)), aborting recognition")
            backupService?.deleteBackup()
            errorMessage = "未检测到声音，请检查麦克风权限或系统输入设备设置"
            state = .idle
            return
        }

        state = .recognizing

        Task { @MainActor in
            CrashLogger.log("[Recognize] Starting speech recognition...")
            print("[VowKy][AppState] Starting recognition...")
            let result = await speechRecognizer.recognize(samples: samples, sampleRate: 16000)
            CrashLogger.log("[Recognize] Result: \(result ?? "nil")")
            print("[VowKy][AppState] Recognition result: \(result ?? "nil")")

            // If result is nil or empty, go back to idle without outputting
            guard let text = result, !text.isEmpty else {
                backupService?.deleteBackup()
                AnalyticsService.shared.trackVoiceFailure()
                state = .idle
                print("[VowKy][AppState] Empty result → state = .idle")
                return
            }

            // Add punctuation if available
            CrashLogger.log("[Recognize] Adding punctuation to: \(text)")
            let finalText = punctuationService?.addPunctuation(to: text) ?? text
            CrashLogger.log("[Recognize] Punctuation done: \(finalText)")
            print("[VowKy][AppState] Final text: \(finalText)")

            // Valid result: insert text and return to idle
            recordRecognitionResult(text: finalText, sourceType: "voice")
            let autoCopy = UserDefaults.standard.bool(forKey: "autoCopyToClipboard")
            CrashLogger.log("[Recognize] Inserting text, autoCopyToClipboard=\(autoCopy)")
            textOutputService?.insertText(finalText, copyToClipboard: autoCopy)
            backupService?.finalizeAndDelete()
            AnalyticsService.shared.trackRecognition()
            let durationMs = Int((Date().timeIntervalSince(self.recordingStartTime ?? Date())) * 1000)
            AnalyticsService.shared.trackVoiceComplete(durationMs: durationMs, charCount: finalText.count)
            state = .idle
            CrashLogger.log("[Recognize] Complete → idle")
            print("[VowKy][AppState] Text inserted → state = .idle")
        }
    }

    // MARK: - Recent Results

    func recordRecognitionResult(text: String, sourceType: String = "voice") {
        lastResult = text
        addToRecentResults(text, sourceType: sourceType)
    }

    private func addToRecentResults(_ text: String, sourceType: String) {
        recentResults.insert(text, at: 0)
        if recentResults.count > 3 {
            recentResults.removeLast()
        }
        HistoryStore.shared.insert(content: text, sourceType: sourceType)
    }

    // MARK: - File Transcription

    func beginFileTranscription() -> String? {
        if isFileTranscriptionInProgress {
            return "已有文件转录任务正在进行"
        }
        if isRecordingTranscriptionInProgress {
            return "录音中，请稍后或完成录音"
        }
        if state == .loading || !speechRecognizer.isReady {
            return "语音模型加载中..."
        }
        guard state == .idle else {
            return "语音输入正在进行中，请稍后再试"
        }
        isFileTranscriptionInProgress = true
        return nil
    }

    func endFileTranscription() {
        isFileTranscriptionInProgress = false
    }

    func makeFileTranscriptionService() -> FileTranscriptionService {
        FileTranscriptionService(
            speechRecognizer: speechRecognizer,
            punctuationService: punctuationService
        )
    }

    // MARK: - Recording Transcription

    func beginRecordingTranscription() -> String? {
        if isRecordingTranscriptionInProgress {
            return "已有录音任务正在进行"
        }
        if isFileTranscriptionInProgress {
            return "文件转录中，请稍后或取消转录"
        }
        if state == .loading {
            return "语音模型加载中..."
        }
        guard state == .idle else {
            return "语音输入正在进行中，请稍后再试"
        }
        isRecordingTranscriptionInProgress = true
        return nil
    }

    func endRecordingTranscription() {
        isRecordingTranscriptionInProgress = false
    }

    func makeRecordingStreamingRecognizer() -> StreamingSpeechRecognizerProtocol {
        LocalStreamingSpeechRecognizer()
    }

    func finalSpeechRecognizerForRecordingTranscription() -> SpeechRecognizerProtocol {
        speechRecognizer
    }

    func punctuationServiceForRecordingTranscription() -> PunctuationServiceProtocol? {
        punctuationService
    }

    var hasTextInsertionTarget: Bool {
        guard let app = lastTextInsertionTarget else { return false }
        return !app.isTerminated
    }

    func captureCurrentTextInsertionTarget() {
        rememberTextInsertionTarget(NSWorkspace.shared.frontmostApplication)
    }

    func activateTextInsertionTarget() -> Bool {
        guard hasTextInsertionTarget, let app = lastTextInsertionTarget else {
            return false
        }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    private func startApplicationFocusTracking() {
        captureCurrentTextInsertionTarget()
        guard workspaceActivationObserver == nil else { return }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.rememberTextInsertionTarget(app)
            }
        }
    }

    private func rememberTextInsertionTarget(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastTextInsertionTarget = app
    }

    // MARK: - Recovery

    private func checkForRecovery() {
        CrashLogger.log("[Recovery] checkForRecovery() start, hasBackup: \(backupService?.hasBackup ?? false)")
        guard let backup = backupService, backup.hasBackup else { return }
        print("[VowKy][AppState] Found backup recording, attempting recovery...")

        guard let samples = backup.recoverSamples(), !samples.isEmpty else {
            backup.deleteBackup()
            CrashLogger.log("[Recovery] Backup empty or corrupt, deleted")
            print("[VowKy][AppState] Backup empty or corrupt, deleted")
            return
        }
        CrashLogger.log("[Recovery] Recovered \(samples.count) samples, starting recognition")

        // Recognize the recovered audio
        state = .recognizing
        Task { @MainActor in
            let result = await speechRecognizer.recognize(samples: samples, sampleRate: 16000)
            CrashLogger.log("[Recovery] Recognition result: \(result ?? "nil")")
            guard let text = result, !text.isEmpty else {
                backup.deleteBackup()
                state = .idle
                print("[VowKy][AppState] Recovery: empty result, deleted backup")
                return
            }

            CrashLogger.log("[Recovery] Adding punctuation to: \(text)")
            let finalText = punctuationService?.addPunctuation(to: text) ?? text
            CrashLogger.log("[Recovery] Punctuation done: \(finalText)")
            recordRecognitionResult(text: finalText, sourceType: "voice")
            let autoCopy = UserDefaults.standard.bool(forKey: "autoCopyToClipboard")
            textOutputService?.insertText(finalText, copyToClipboard: autoCopy)
            backup.deleteBackup()
            AnalyticsService.shared.trackRecovery()
            state = .idle
            CrashLogger.log("[Recovery] Complete: \(finalText)")
            print("[VowKy][AppState] Recovery complete: \(finalText)")
        }
    }
}
