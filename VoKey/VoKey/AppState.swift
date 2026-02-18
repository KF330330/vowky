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

    func setup() {
        // 0. Open history database
        HistoryStore.shared.open()

        // 1. Load speech model + punctuation model in background
        state = .loading
        if let recognizer = speechRecognizer as? LocalSpeechRecognizer {
            let punctService = punctuationService as? PunctuationService
            Task.detached(priority: .userInitiated) {
                recognizer.loadModel()
                punctService?.loadModel()
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

        // 5. Wire hotkey manager callbacks (toggle mode)
        let hotkeyMgr = HotkeyManager()
        hotkeyMgr.onHotkeyPressed = { [weak self] in
            self?.handleHotkeyToggle()
        }
        hotkeyMgr.onCancelPressed = { [weak self] in
            self?.cancelRecording()
        }
        hotkeyMgr.shouldInterceptCancel = { [weak self] in
            self?.state == .recording
        }
        hotkeyMgr.start()
        self.hotkeyManager = hotkeyMgr
        print("[VowKy][AppState] setup() complete")
    }

    // MARK: - Hotkey Handler (Toggle Mode)

    func handleHotkeyToggle() {
        print("[VowKy][AppState] handleHotkeyToggle() called, current state: \(state)")

        // Clear previous error
        errorMessage = nil

        switch state {
        case .idle:
            startRecordingFromIdle()

        case .recording:
            stopRecordingAndRecognize()

        case .loading:
            if !speechRecognizer.isReady {
                errorMessage = "语音模型加载中..."
                print("[VowKy][AppState] Model still loading, ignoring toggle")
            }

        case .recognizing, .outputting:
            print("[VowKy][AppState] Ignoring toggle in state: \(state)")
        }
    }

    private func startRecordingFromIdle() {
        // Check accessibility permission
        guard permissionChecker.isAccessibilityGranted() else {
            errorMessage = "请在系统设置中授予辅助功能权限"
            print("[VowKy][AppState] Accessibility not granted")
            return
        }

        // Try to start recording
        do {
            try audioRecorder.startRecording()
            try? backupService?.startBackup()
            state = .recording
            print("[VowKy][AppState] Recording started → state = .recording")
        } catch {
            state = .idle
            errorMessage = error.localizedDescription
            print("[VowKy][AppState] Recording failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancel Recording

    func cancelRecording() {
        guard state == .recording else {
            print("[VowKy][AppState] cancelRecording() ignored, state: \(state)")
            return
        }
        _ = audioRecorder.stopRecording()
        backupService?.deleteBackup()
        state = .idle
        print("[VowKy][AppState] Recording cancelled → state = .idle")
    }

    private func stopRecordingAndRecognize() {
        let samples = audioRecorder.stopRecording()
        print("[VowKy][AppState] Recording stopped, samples count: \(samples.count)")
        state = .recognizing

        Task { @MainActor in
            print("[VowKy][AppState] Starting recognition...")
            let result = await speechRecognizer.recognize(samples: samples, sampleRate: 16000)
            print("[VowKy][AppState] Recognition result: \(result ?? "nil")")

            // If result is nil or empty, go back to idle without outputting
            guard let text = result, !text.isEmpty else {
                backupService?.deleteBackup()
                state = .idle
                print("[VowKy][AppState] Empty result → state = .idle")
                return
            }

            // Add punctuation if available
            let finalText = punctuationService?.addPunctuation(to: text) ?? text
            print("[VowKy][AppState] Final text: \(finalText)")

            // Valid result: insert text and return to idle
            lastResult = finalText
            addToRecentResults(finalText)
            textOutputService?.insertText(finalText)
            backupService?.finalizeAndDelete()
            state = .idle
            print("[VowKy][AppState] Text inserted → state = .idle")
        }
    }

    // MARK: - Recent Results

    private func addToRecentResults(_ text: String) {
        recentResults.insert(text, at: 0)
        if recentResults.count > 3 {
            recentResults.removeLast()
        }
        HistoryStore.shared.insert(content: text)
    }

    // MARK: - Recovery

    private func checkForRecovery() {
        guard let backup = backupService, backup.hasBackup else { return }
        print("[VowKy][AppState] Found backup recording, attempting recovery...")

        guard let samples = backup.recoverSamples(), !samples.isEmpty else {
            backup.deleteBackup()
            print("[VowKy][AppState] Backup empty or corrupt, deleted")
            return
        }

        // Recognize the recovered audio
        state = .recognizing
        Task { @MainActor in
            let result = await speechRecognizer.recognize(samples: samples, sampleRate: 16000)
            guard let text = result, !text.isEmpty else {
                backup.deleteBackup()
                state = .idle
                print("[VowKy][AppState] Recovery: empty result, deleted backup")
                return
            }

            let finalText = punctuationService?.addPunctuation(to: text) ?? text
            lastResult = finalText
            addToRecentResults(finalText)
            textOutputService?.insertText(finalText)
            backup.deleteBackup()
            state = .idle
            print("[VowKy][AppState] Recovery complete: \(finalText)")
        }
    }
}
