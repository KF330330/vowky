import SwiftUI
import AppKit
import ServiceManagement
import Sparkle

// MARK: - Settings Window Controller

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private weak var updater: SPUUpdater?
    private weak var updateCoordinator: UpdateReminderCoordinator?

    /// 由 MenuBarView 调用时传入 updater 和 coordinator，让设置里的「自动检查更新」开关与「立即检查更新」按钮可用。
    func showWindow(updater: SPUUpdater? = nil, updateCoordinator: UpdateReminderCoordinator? = nil) {
        if let updater {
            self.updater = updater
        }
        if let updateCoordinator {
            self.updateCoordinator = updateCoordinator
        }
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(updater: self.updater, updateCoordinator: self.updateCoordinator)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "VowKy Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @State private var isAccessibilityGranted = AXIsProcessTrusted()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hotkeyDisplay = HotkeyConfig.current.displayName
    @State private var isHoldMode = HotkeyConfig.current.isHoldMode
    @State private var isRecording = false
    @State private var eventMonitor: Any?
    @State private var pendingModifierKeyCode: Int64?
    @State private var autoCopyToClipboard = UserDefaults.standard.bool(forKey: "autoCopyToClipboard")
    @State private var automaticUpdateChecks: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: VowKyApp.automaticUpdateChecksDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: VowKyApp.automaticUpdateChecksDefaultsKey)
    }()
    @State private var permissionRefreshTimer: Timer?

    // 翻译
    @State private var translationEnabled: Bool
    @State private var translationEngine: TranslationEngineKind
    @State private var translationTargetBCP47: String
    @State private var translationLLMBaseURL: String
    @State private var translationLLMModel: String
    @State private var translationLLMAPIKey: String
    @State private var translationTestResult: String?
    @State private var translationTestInProgress: Bool = false

    private weak var updater: SPUUpdater?
    private weak var updateCoordinator: UpdateReminderCoordinator?
    @ObservedObject private var updateViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater? = nil, updateCoordinator: UpdateReminderCoordinator? = nil) {
        self.updater = updater
        self.updateCoordinator = updateCoordinator
        self.updateViewModel = CheckForUpdatesViewModel(updater: updater)

        let translationConfig = TranslationConfigStore.load()
        _translationEnabled     = State(initialValue: translationConfig.enabled)
        _translationEngine      = State(initialValue: translationConfig.engine)
        _translationTargetBCP47 = State(initialValue: translationConfig.target.bcp47)
        _translationLLMBaseURL  = State(initialValue: translationConfig.llmBaseURL)
        _translationLLMModel    = State(initialValue: translationConfig.llmModel)
        _translationLLMAPIKey   = State(initialValue: translationConfig.llmAPIKey)
    }

    var body: some View {
        Form {
            // Hotkey
            Section("快捷键") {
                HStack {
                    Text("语音输入")
                    Spacer()
                    if isRecording {
                        Text("请按下新快捷键...")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                    } else {
                        Text(hotkeyDisplay)
                            .font(.system(.body, design: .monospaced))
                    }
                    Button(isRecording ? "取消" : "修改") {
                        if isRecording {
                            stopRecordingHotkey()
                        } else {
                            startRecordingHotkey()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Picker("触发方式", selection: $isHoldMode) {
                    Text("按键切换").tag(false)
                    Text("长按说话").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: isHoldMode) { newValue in
                    var config = HotkeyConfig.current
                    config.isHoldMode = newValue
                    config.save()
                }
            }

            // Model
            Section("语音模型") {
                LabeledContent("模型") {
                    Text("SenseVoice (int8)")
                }
                LabeledContent("引擎") {
                    Text("sherpa-onnx (本地)")
                }
            }

            // Permissions
            Section("权限") {
                HStack {
                    Text("辅助功能")
                    Spacer()
                    if isAccessibilityGranted {
                        Text("已授权")
                            .foregroundColor(.green)
                    } else {
                        Text("未授权")
                            .foregroundColor(.red)
                        Button("前往设置") {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            AXIsProcessTrustedWithOptions(options)
                            startPermissionRefresh()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Text("麦克风")
                    Spacer()
                    Text("由系统管理")
                        .foregroundColor(.secondary)
                }
            }

            // General
            Section("通用") {
                Toggle("开机自启", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Revert on failure
                            launchAtLogin = !newValue
                        }
                    }
                Toggle("识别后自动复制到剪贴板", isOn: $autoCopyToClipboard)
                    .onChange(of: autoCopyToClipboard) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "autoCopyToClipboard")
                    }
                Toggle("自动检查更新", isOn: $automaticUpdateChecks)
                    .onChange(of: automaticUpdateChecks) { newValue in
                        UserDefaults.standard.set(newValue, forKey: VowKyApp.automaticUpdateChecksDefaultsKey)
                        updater?.automaticallyChecksForUpdates = newValue
                    }
                HStack {
                    Text("立即检查更新")
                    Spacer()
                    Button("检查") {
                        guard let updater else { return }
                        updateCoordinator?.userInitiatedCheck(updater: updater)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updater == nil || !updateViewModel.canCheckForUpdates)
                }
            }

            // 翻译
            Section("翻译（录音窗口）") {
                Toggle(isOn: $translationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用实时翻译")
                        Text("录音转写时在每段原文下方实时显示译文")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: translationEnabled) { _ in saveTranslationConfig() }

                if translationEnabled {
                    Picker("翻译引擎", selection: $translationEngine) {
                        if #available(macOS 15.0, *) {
                            Text("系统离线翻译").tag(TranslationEngineKind.apple)
                        }
                        Text("LLM API").tag(TranslationEngineKind.llm)
                    }
                    .onChange(of: translationEngine) { _ in saveTranslationConfig() }

                    Picker("目标语言", selection: $translationTargetBCP47) {
                        ForEach(TranslationTarget.presets, id: \.target.bcp47) { preset in
                            Text(preset.name).tag(preset.target.bcp47)
                        }
                    }
                    .onChange(of: translationTargetBCP47) { _ in saveTranslationConfig() }

                    if translationEngine == .apple {
                        Text("完全离线，由 macOS 系统翻译。首次使用某语言时系统会自动下载离线语言包。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Text("快速填入")
                            Spacer()
                            Menu("选择服务商") {
                                ForEach(TranslationLLMPreset.all) { preset in
                                    Button(preset.title) {
                                        translationLLMBaseURL = preset.baseURL
                                        translationLLMModel = preset.model
                                        translationTestResult = nil
                                        saveTranslationConfig()
                                    }
                                }
                            }
                            .fixedSize()
                        }
                        Text("推荐阿里 Qwen-MT：专用翻译模型，速度快、质量高、便宜、国内直连。填入后在下方补上你的 API Key 即可。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField("API 地址", text: $translationLLMBaseURL, prompt: Text("https://api.deepseek.com/v1"))
                            .onChange(of: translationLLMBaseURL) { _ in saveTranslationConfig() }
                        TextField("模型", text: $translationLLMModel, prompt: Text("deepseek-chat"))
                            .onChange(of: translationLLMModel) { _ in saveTranslationConfig() }
                        SecureField("API Key", text: $translationLLMAPIKey)
                            .onChange(of: translationLLMAPIKey) { _ in saveTranslationConfig() }

                        Text("兼容 OpenAI Chat Completions 格式的服务（DeepSeek、Qwen、OpenAI 等）。译文会发送到该服务，请注意隐私。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Button {
                                Task { await testTranslationLLM() }
                            } label: {
                                if translationTestInProgress {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("测试连接")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(translationTestInProgress)
                            Spacer()
                        }

                        if let translationTestResult {
                            Text(translationTestResult)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

        }
        .formStyle(.grouped)
        .frame(width: 420, height: 720)
        .onAppear {
            isAccessibilityGranted = AXIsProcessTrusted()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            hotkeyDisplay = HotkeyConfig.current.displayName
            isHoldMode = HotkeyConfig.current.isHoldMode
        }
        .onDisappear {
            stopRecordingHotkey()
            stopPermissionRefresh()
        }
    }

    // MARK: - Hotkey Recording

    private func startRecordingHotkey() {
        isRecording = true
        pendingModifierKeyCode = nil
        // 同时监听 keyDown 和 flagsChanged，支持单修饰键录入
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                let keyCode = Int64(event.keyCode)
                // 只处理修饰键（含 Fn = 63）
                let modifierKeyCodes: Set<Int64> = [55, 56, 58, 59, 61, 62, 63]
                guard modifierKeyCodes.contains(keyCode) else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                // 修饰键全部释放 → 如果有 pending 修饰键，保存为单修饰键模式
                if flags.isEmpty, let pending = pendingModifierKeyCode {
                    pendingModifierKeyCode = nil
                    let config = HotkeyConfig(
                        keyCode: pending,
                        needsOption: false, needsCommand: false,
                        needsControl: false, needsShift: false,
                        isModifierOnly: true,
                        isHoldMode: HotkeyConfig.current.isHoldMode
                    )
                    config.save()
                    hotkeyDisplay = config.displayName
                    AnalyticsService.shared.trackHotkeyChange()
                    stopRecordingHotkey()
                    return nil
                }

                // 检测是否只有一个修饰键按下 → 记为 pending，等释放后再保存
                let isSingleModifier = flags == .command || flags == .shift
                    || flags == .option || flags == .control || flags == .function

                if isSingleModifier {
                    // 统一左右键：61→58(Option), 62→59(Control)
                    switch keyCode {
                    case 61: pendingModifierKeyCode = 58
                    case 62: pendingModifierKeyCode = 59
                    default: pendingModifierKeyCode = keyCode
                    }
                } else {
                    pendingModifierKeyCode = nil
                }
                return event

            } else {
                // keyDown 事件：清除 pending，走组合键录制逻辑
                pendingModifierKeyCode = nil
                let keyCode = Int64(event.keyCode)

                // Ignore pure modifier keys (in keyDown they shouldn't appear, but be safe)
                if [55, 56, 58, 59, 61, 62].contains(keyCode) { return event }

                // Escape without modifiers = cancel
                if keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    stopRecordingHotkey()
                    return nil
                }

                let config = HotkeyConfig(
                    keyCode: keyCode,
                    needsOption: event.modifierFlags.contains(.option),
                    needsCommand: event.modifierFlags.contains(.command),
                    needsControl: event.modifierFlags.contains(.control),
                    needsShift: event.modifierFlags.contains(.shift),
                    isModifierOnly: false,
                    isHoldMode: HotkeyConfig.current.isHoldMode
                )
                config.save()
                hotkeyDisplay = config.displayName
                AnalyticsService.shared.trackHotkeyChange()
                stopRecordingHotkey()
                return nil
            }
        }
    }

    // MARK: - Permission Refresh

    private func startPermissionRefresh() {
        stopPermissionRefresh()
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            DispatchQueue.main.async {
                let granted = AXIsProcessTrusted()
                if granted {
                    isAccessibilityGranted = true
                    stopPermissionRefresh()
                }
            }
        }
    }

    private func stopPermissionRefresh() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
    }

    private func stopRecordingHotkey() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func saveTranslationConfig() {
        TranslationConfigStore.save(TranslationConfig(
            enabled: translationEnabled,
            engine: translationEngine,
            target: TranslationTarget(bcp47: translationTargetBCP47),
            llmBaseURL: translationLLMBaseURL,
            llmModel: translationLLMModel,
            llmAPIKey: translationLLMAPIKey
        ))
    }

    private func testTranslationLLM() async {
        translationTestInProgress = true
        translationTestResult = nil
        saveTranslationConfig()
        let provider = OpenAICompatibleTranslationProvider(config: TranslationConfigStore.load())
        do {
            let translated = try await provider.translate(
                "Hello, this is a connection test.",
                to: TranslationTarget(bcp47: translationTargetBCP47)
            )
            translationTestResult = "✓ 连接成功：\(translated)"
        } catch {
            let message = (error as? TranslationError)?.errorDescription ?? error.localizedDescription
            translationTestResult = "✗ \(message)"
        }
        translationTestInProgress = false
    }

}
