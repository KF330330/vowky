import SwiftUI
import AppKit
import ServiceManagement
import Combine
import Sparkle

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var titleObserver: AnyCancellable?
    private weak var updater: SPUUpdater?
    private weak var updateCoordinator: UpdateReminderCoordinator?

    /// 由 MenuBarView 调用时传入 updater + coordinator，让设置页的「自动检查更新」开关与「检查更新」按钮可用。
    func showWindow(updater: SPUUpdater? = nil, updateCoordinator: UpdateReminderCoordinator? = nil) {
        if let updater { self.updater = updater }
        if let updateCoordinator { self.updateCoordinator = updateCoordinator }
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(updater: self.updater, updateCoordinator: self.updateCoordinator)
            .environmentObject(LocalizationManager.shared)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = L("window.settings.title")
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // SwiftUI 内容随语言切换自动刷新；AppKit 标题栏不在 SwiftUI graph 内，需手动跟随。
        titleObserver = LocalizationManager.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak window] _ in window?.title = L("window.settings.title") }

        self.window = window
    }
}

// MARK: - Hotkey Recorder

/// 录制快捷键的状态机。必须是引用类型（class + ObservableObject）：
/// NSEvent 本地监听是逃逸闭包，若用 SettingsView(struct) 的 @State，闭包会按值捕获快照，
/// 之后写入既不刷新活动视图、暂存值也无法跨回调保存 —— 这正是「点修改后按什么都没反应」的根因。
/// 与已验证可用的 OnboardingViewModel 同款写法：用 [weak self] 捕获同一对象，@Published 可靠刷新 UI。
final class HotkeyRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var displayName = HotkeyConfig.current.displayName

    private var pendingModifierKeyCode: Int64?
    private var eventMonitor: Any?

    /// 窗口出现时从 UserDefaults 重新同步当前热键显示
    func refreshDisplay() {
        displayName = HotkeyConfig.current.displayName
    }

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        isRecording = true
        pendingModifierKeyCode = nil
        // 同时监听 keyDown 和 flagsChanged，支持单修饰键录入
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .flagsChanged {
                let keyCode = Int64(event.keyCode)
                // 只处理修饰键（含 Fn = 63）
                let modifierKeyCodes: Set<Int64> = [55, 56, 58, 59, 61, 62, 63]
                guard modifierKeyCodes.contains(keyCode) else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                // 修饰键全部释放 → 如果有 pending 修饰键，保存为单修饰键模式
                if flags.isEmpty, let pending = self.pendingModifierKeyCode {
                    self.pendingModifierKeyCode = nil
                    let config = HotkeyConfig(
                        keyCode: pending,
                        needsOption: false, needsCommand: false,
                        needsControl: false, needsShift: false,
                        isModifierOnly: true,
                        isHoldMode: HotkeyConfig.current.isHoldMode
                    )
                    config.save()
                    self.displayName = config.displayName
                    AnalyticsService.shared.trackHotkeyChange()
                    self.stop()
                    return nil
                }

                // 检测是否只有一个修饰键按下 → 记为 pending，等释放后再保存
                let isSingleModifier = flags == .command || flags == .shift
                    || flags == .option || flags == .control || flags == .function

                if isSingleModifier {
                    // 统一左右键：61→58(Option), 62→59(Control)
                    switch keyCode {
                    case 61: self.pendingModifierKeyCode = 58
                    case 62: self.pendingModifierKeyCode = 59
                    default: self.pendingModifierKeyCode = keyCode
                    }
                } else {
                    self.pendingModifierKeyCode = nil
                }
                return event

            } else {
                // keyDown 事件：清除 pending，走组合键录制逻辑
                self.pendingModifierKeyCode = nil
                let keyCode = Int64(event.keyCode)

                // Ignore pure modifier keys (in keyDown they shouldn't appear, but be safe)
                if [55, 56, 58, 59, 61, 62].contains(keyCode) { return event }

                // Escape without modifiers = cancel
                if keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.stop()
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
                self.displayName = config.displayName
                AnalyticsService.shared.trackHotkeyChange()
                self.stop()
                return nil
            }
        }
    }

    func stop() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @State private var isAccessibilityGranted = AXIsProcessTrusted()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isHoldMode = HotkeyConfig.current.isHoldMode
    @StateObject private var hotkeyRecorder = HotkeyRecorder()
    @State private var autoCopyToClipboard = UserDefaults.standard.bool(forKey: "autoCopyToClipboard")
    @State private var urlCookieSource: String = UserDefaults.standard.string(forKey: FileTranscriptionViewModel.cookieSourceDefaultsKey) ?? "none"
    @State private var automaticUpdateChecks: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: VowKyApp.automaticUpdateChecksDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: VowKyApp.automaticUpdateChecksDefaultsKey)
    }()
    @State private var permissionRefreshTimer: Timer?
    /// 待确认切换的目标语言（非 nil 时弹「需重启」确认框）。
    @State private var pendingLanguage: AppLanguage?

    private weak var updater: SPUUpdater?
    private weak var updateCoordinator: UpdateReminderCoordinator?
    @ObservedObject private var updateViewModel: CheckForUpdatesViewModel

    // 翻译
    @State private var translationEnabled: Bool
    @State private var translationEngine: TranslationEngineKind
    @State private var translationTargetBCP47: String
    @State private var translationLLMBaseURL: String
    @State private var translationLLMModel: String
    @State private var translationLLMAPIKey: String
    @State private var translationTestResult: String?
    @State private var translationTestInProgress: Bool = false

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
            Section(loc.string("settings.section.hotkey")) {
                HStack {
                    Text(loc.string("settings.hotkey.voiceInput"))
                    Spacer()
                    if hotkeyRecorder.isRecording {
                        Text(loc.string("settings.hotkey.recording"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                    } else {
                        Text(hotkeyRecorder.displayName)
                            .font(.system(.body, design: .monospaced))
                    }
                    Button(hotkeyRecorder.isRecording ? loc.string("common.cancel") : loc.string("settings.hotkey.modify")) {
                        hotkeyRecorder.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Picker(loc.string("settings.hotkey.trigger"), selection: $isHoldMode) {
                    Text(loc.string("settings.hotkey.trigger.toggle")).tag(false)
                    Text(loc.string("settings.hotkey.trigger.hold")).tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: isHoldMode) { newValue in
                    var config = HotkeyConfig.current
                    config.isHoldMode = newValue
                    config.save()
                }
            }

            // Model
            Section(loc.string("settings.section.model")) {
                LabeledContent(loc.string("settings.model.label")) {
                    Text("SenseVoice (int8)")
                }
                LabeledContent(loc.string("settings.model.engine")) {
                    Text(loc.string("settings.model.engine.value"))
                }
            }

            // Permissions
            Section(loc.string("settings.section.permissions")) {
                HStack {
                    Text(loc.string("settings.permission.accessibility"))
                    Spacer()
                    if isAccessibilityGranted {
                        Text(loc.string("settings.permission.granted"))
                            .foregroundColor(.green)
                    } else {
                        Text(loc.string("settings.permission.denied"))
                            .foregroundColor(.red)
                        Button(loc.string("settings.permission.openSettings")) {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            AXIsProcessTrustedWithOptions(options)
                            startPermissionRefresh()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Text(loc.string("settings.permission.microphone"))
                    Spacer()
                    Text(loc.string("settings.permission.systemManaged"))
                        .foregroundColor(.secondary)
                }
            }

            // General
            Section(loc.string("settings.section.general")) {
                Toggle(loc.string("settings.general.launchAtLogin"), isOn: $launchAtLogin)
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
                Toggle(loc.string("settings.general.autoCopy"), isOn: $autoCopyToClipboard)
                    .onChange(of: autoCopyToClipboard) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "autoCopyToClipboard")
                    }
                Toggle(loc.string("settings.update.autoCheck"), isOn: $automaticUpdateChecks)
                    .onChange(of: automaticUpdateChecks) { newValue in
                        UserDefaults.standard.set(newValue, forKey: VowKyApp.automaticUpdateChecksDefaultsKey)
                        updater?.automaticallyChecksForUpdates = newValue
                    }
                HStack {
                    Text(loc.string("settings.update.checkNowLabel"))
                    Spacer()
                    Button(loc.string("settings.update.checkButton")) {
                        guard let updater else { return }
                        updateCoordinator?.userInitiatedCheck(updater: updater)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updater == nil || !updateViewModel.canCheckForUpdates)
                }
            }

            // URL 下载（链接转文字的 Cookie 来源）
            Section(loc.string("settings.section.urlDownload")) {
                Picker(loc.string("settings.urlDownload.cookieSource"), selection: $urlCookieSource) {
                    Text(loc.string("settings.urlDownload.cookie.none")).tag("none")
                    Text(loc.string("settings.urlDownload.cookie.safari")).tag("safari")
                    Text(loc.string("settings.urlDownload.cookie.chrome")).tag("chrome")
                    Text(loc.string("settings.urlDownload.cookie.firefox")).tag("firefox")
                }
                .onChange(of: urlCookieSource) { newValue in
                    UserDefaults.standard.set(newValue, forKey: FileTranscriptionViewModel.cookieSourceDefaultsKey)
                }
                Text(loc.string("settings.urlDownload.cookieHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Language
            Section(loc.string("settings.section.language")) {
                Picker(loc.string("settings.language.picker"), selection: Binding(
                    get: { loc.language },
                    set: { newLang in
                        // 不立即切换：先弹确认，确认后写偏好并重启（见 onChange/alert 处理）。
                        if newLang != loc.language { pendingLanguage = newLang }
                    }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }

            // 翻译
            Section(loc.string("settings.section.translation")) {
                Toggle(isOn: $translationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.string("settings.translation.enable"))
                        Text(loc.string("settings.translation.enable.subtitle"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: translationEnabled) { _ in saveTranslationConfig() }

                if translationEnabled {
                    Picker(loc.string("settings.translation.engine"), selection: $translationEngine) {
                        if #available(macOS 15.0, *) {
                            Text(loc.string("settings.translation.engine.apple")).tag(TranslationEngineKind.apple)
                        }
                        Text("LLM API").tag(TranslationEngineKind.llm)
                    }
                    .onChange(of: translationEngine) { _ in saveTranslationConfig() }

                    Picker(loc.string("settings.translation.targetLang"), selection: $translationTargetBCP47) {
                        ForEach(TranslationTarget.presets, id: \.target.bcp47) { preset in
                            Text(preset.name).tag(preset.target.bcp47)
                        }
                    }
                    .onChange(of: translationTargetBCP47) { _ in saveTranslationConfig() }

                    if translationEngine == .apple {
                        Text(loc.string("settings.translation.apple.note"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Text(loc.string("settings.translation.quickFill"))
                            Spacer()
                            Menu(loc.string("settings.translation.selectProvider")) {
                                ForEach(TranslationLLMPreset.all) { preset in
                                    Button(loc.string(preset.titleKey)) {
                                        translationLLMBaseURL = preset.baseURL
                                        translationLLMModel = preset.model
                                        translationTestResult = nil
                                        saveTranslationConfig()
                                    }
                                }
                            }
                            .fixedSize()
                        }
                        Text(loc.string("settings.translation.llm.recommend"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField(loc.string("settings.translation.llm.baseURL"), text: $translationLLMBaseURL, prompt: Text("https://api.deepseek.com/v1"))
                            .onChange(of: translationLLMBaseURL) { _ in saveTranslationConfig() }
                        TextField(loc.string("settings.translation.llm.model"), text: $translationLLMModel, prompt: Text("deepseek-chat"))
                            .onChange(of: translationLLMModel) { _ in saveTranslationConfig() }
                        SecureField(loc.string("settings.translation.llm.apiKey"), text: $translationLLMAPIKey)
                            .onChange(of: translationLLMAPIKey) { _ in saveTranslationConfig() }

                        Text(loc.string("settings.translation.llm.note"))
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
                                    Text(loc.string("settings.translation.llm.test"))
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
            hotkeyRecorder.refreshDisplay()
            isHoldMode = HotkeyConfig.current.isHoldMode
        }
        .onDisappear {
            hotkeyRecorder.stop()
            stopPermissionRefresh()
        }
        .alert(
            loc.string("settings.language.restartTitle"),
            isPresented: Binding(
                get: { pendingLanguage != nil },
                set: { if !$0 { pendingLanguage = nil } }
            )
        ) {
            Button(loc.string("settings.language.restartConfirm")) {
                if let lang = pendingLanguage {
                    LocalizationManager.shared.applyLanguageAndRestart(lang)
                }
            }
            Button(loc.string("common.cancel"), role: .cancel) {
                pendingLanguage = nil
            }
        } message: {
            Text(loc.string("settings.language.restartMessage"))
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

    @MainActor
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
            translationTestResult = loc.string("settings.translation.llm.testSuccess", translated)
        } catch {
            let message = (error as? TranslationError)?.errorDescription ?? error.localizedDescription
            translationTestResult = loc.string("settings.translation.llm.testFail", message)
        }
        translationTestInProgress = false
    }

}
