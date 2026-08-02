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
    /// willClose 观察者 token：窗口关闭时移除，避免每次开→关累积一个僵尸注册
    private var closeObserver: NSObjectProtocol?
    private weak var updater: SPUUpdater?
    private weak var updateCoordinator: UpdateReminderCoordinator?
    private weak var appState: AppState?

    /// 由 MenuBarView 调用时传入 updater + coordinator，让设置页的「自动检查更新」开关与「检查更新」按钮可用；
    /// appState 供「重新打开新手引导」按钮使用。
    func showWindow(updater: SPUUpdater? = nil, updateCoordinator: UpdateReminderCoordinator? = nil, appState: AppState? = nil) {
        if let updater { self.updater = updater }
        if let updateCoordinator { self.updateCoordinator = updateCoordinator }
        if let appState { self.appState = appState }
        // 防御：若激活策略被降到 .prohibited，窗口将无法前置，先恢复为 .accessory。
        if NSApp.activationPolicy() == .prohibited {
            NSApp.setActivationPolicy(.accessory)
        }
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(updater: self.updater, updateCoordinator: self.updateCoordinator, appState: self.appState)
            .environmentObject(LocalizationManager.shared)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = L("window.settings.title")
        window.styleMask = [.titled, .closable]
        // 关窗时 AppKit 默认会 release 窗口，与本类的强引用不平衡 → 二次打开悬挂崩溃，必须关掉。
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.closeObserver = nil
                }
                self.titleObserver = nil
                self.window = nil
            }
        }

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
    @State private var urlSubtitlePriority: String = UserDefaults.standard.string(forKey: FileTranscriptionViewModel.subtitlePriorityDefaultsKey) ?? "all"
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
    private weak var appState: AppState?
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

    // 识别引擎（SpeechAnalyzer 极速引擎，三场景全局生效；分离/录音预览恒本地，见 SpeechEngineConfig）
    @State private var speechEngine: SpeechEngineKind
    @State private var analyzerLocale: String
    /// 切到极速引擎前的取舍确认弹窗（用户硬性要求：切换时必须提示「极快但效果可能略差」）
    @State private var pendingEngineSwitch = false
    @State private var analyzerAssetStatus: AnalyzerAssetUIStatus = .idle

    private enum AnalyzerAssetUIStatus: Equatable {
        case idle, checking, ready, downloading, unsupported
        case failed(String)
    }

    init(updater: SPUUpdater? = nil, updateCoordinator: UpdateReminderCoordinator? = nil, appState: AppState? = nil) {
        self.updater = updater
        self.updateCoordinator = updateCoordinator
        self.appState = appState
        self.updateViewModel = CheckForUpdatesViewModel(updater: updater)

        let translationConfig = TranslationConfigStore.load()
        _translationEnabled     = State(initialValue: translationConfig.enabled)
        _translationEngine      = State(initialValue: translationConfig.engine)
        _translationTargetBCP47 = State(initialValue: translationConfig.target.bcp47)
        _translationLLMBaseURL  = State(initialValue: translationConfig.llmBaseURL)
        _translationLLMModel    = State(initialValue: translationConfig.llmModel)
        _translationLLMAPIKey   = State(initialValue: translationConfig.llmAPIKey)

        let speechEngineConfig = SpeechEngineConfigStore.load()
        _speechEngine  = State(initialValue: speechEngineConfig.engine)
        _analyzerLocale = State(initialValue: speechEngineConfig.analyzerLocale)
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
                    Text(speechEngine == .speechAnalyzer
                        ? loc.string("settings.model.label.speechAnalyzer")
                        : "SenseVoice (int8)")
                }

                Picker(loc.string("settings.model.engine"), selection: Binding(
                    get: { speechEngine },
                    set: { newValue in
                        if newValue == .speechAnalyzer, speechEngine != .speechAnalyzer {
                            // 不立即保存：先弹取舍确认，确认才生效（取消时 Picker 自动弹回）
                            pendingEngineSwitch = true
                        } else if newValue != speechEngine {
                            speechEngine = newValue
                            saveSpeechEngineConfig()
                        }
                    }
                )) {
                    Text(loc.string("settings.model.engine.value")).tag(SpeechEngineKind.senseVoice)
                    if speechAnalyzerSelectable {
                        Text(loc.string("settings.model.engine.speechAnalyzer")).tag(SpeechEngineKind.speechAnalyzer)
                    }
                }

                if !speechAnalyzerSelectable {
                    Text(loc.string("settings.model.engine.requiresOS26"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if speechEngine == .speechAnalyzer {
                    // 常驻取舍说明（alert 只见一次，caption 才是长期知情）
                    Text(loc.string("settings.model.engine.speedNote"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(loc.string("settings.model.analyzerLocale"), selection: $analyzerLocale) {
                        ForEach(SpeechEngineConfigStore.analyzerLocaleChoices, id: \.bcp47) { choice in
                            Text(loc.string(choice.displayKey)).tag(choice.bcp47)
                        }
                    }
                    .onChange(of: analyzerLocale) { _ in
                        saveSpeechEngineConfig()
                        refreshAnalyzerAssets()
                    }

                    analyzerAssetStatusRow
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
                            AnalyticsService.shared.track("launch_login_toggle", data: ["on": newValue])
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
                        AnalyticsService.shared.track("update_check_manual")
                        updateCoordinator?.userInitiatedCheck(updater: updater)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updater == nil || !updateViewModel.canCheckForUpdates)
                }
                HStack {
                    Text(loc.string("settings.general.onboardingLabel"))
                    Spacer()
                    Button(loc.string("settings.general.onboardingButton")) {
                        guard let appState else { return }
                        OnboardingWindowController.shared.showWindow(appState: appState)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState == nil)
                }
            }

            // URL 下载（链接转文字的 Cookie 来源）
            Section(loc.string("settings.section.urlDownload")) {
                Picker(loc.string("settings.urlDownload.subtitlePriority"), selection: $urlSubtitlePriority) {
                    Text(loc.string("settings.urlDownload.subtitlePriority.all")).tag("all")
                    Text(loc.string("settings.urlDownload.subtitlePriority.manualOnly")).tag("manualOnly")
                    Text(loc.string("settings.urlDownload.subtitlePriority.never")).tag("never")
                }
                .onChange(of: urlSubtitlePriority) { newValue in
                    UserDefaults.standard.set(newValue, forKey: FileTranscriptionViewModel.subtitlePriorityDefaultsKey)
                }
                Text(loc.string("settings.urlDownload.subtitlePriorityHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)

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

                    if #unavailable(macOS 15.0) {
                        Text(loc.string("settings.translation.apple.requiresOS15"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
            refreshAnalyzerAssets()
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
                    // fire-and-forget：relaunch 前发出，偶发丢失可接受
                    AnalyticsService.shared.track("app_lang_switch", data: ["to": lang.rawValue])
                    LocalizationManager.shared.applyLanguageAndRestart(lang)
                }
            }
            Button(loc.string("common.cancel"), role: .cancel) {
                pendingLanguage = nil
            }
        } message: {
            Text(loc.string("settings.language.restartMessage"))
        }
        .alert(
            loc.string("settings.model.engine.switchAlert.title"),
            isPresented: $pendingEngineSwitch
        ) {
            Button(loc.string("settings.model.engine.switchAlert.confirm")) {
                speechEngine = .speechAnalyzer
                saveSpeechEngineConfig()
                AnalyticsService.shared.track("speech_engine_switch", data: ["to": "speechanalyzer"])
                refreshAnalyzerAssets()
            }
            Button(loc.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc.string("settings.model.engine.switchAlert.message"))
        }
    }

    // MARK: - 识别引擎（需求 C）

    private var speechAnalyzerSelectable: Bool {
        SpeechEngineConfigStore.speechAnalyzerRuntimeAvailable
    }

    @ViewBuilder
    private var analyzerAssetStatusRow: some View {
        switch analyzerAssetStatus {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(loc.string("settings.model.assets.checking"))
                    .font(.caption).foregroundColor(.secondary)
            }
        case .ready:
            Text(loc.string("settings.model.assets.ready"))
                .font(.caption).foregroundColor(.green)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(loc.string("settings.model.assets.downloading"))
                    .font(.caption).foregroundColor(.secondary)
            }
        case .unsupported:
            Text(loc.string("settings.model.assets.unsupported"))
                .font(.caption).foregroundColor(.orange)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button(loc.string("settings.model.assets.retry")) {
                    refreshAnalyzerAssets()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func saveSpeechEngineConfig() {
        var config = SpeechEngineConfigStore.load()
        config.engine = speechEngine
        config.analyzerLocale = analyzerLocale
        SpeechEngineConfigStore.save(config)
    }

    /// 检查/下载当前 locale 的系统语音资产（仅极速引擎选中时）。
    private func refreshAnalyzerAssets() {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *), speechEngine == .speechAnalyzer else {
            analyzerAssetStatus = .idle
            return
        }
        let locale = analyzerLocale
        analyzerAssetStatus = .checking
        Task { @MainActor in
            guard await SpeechAnalyzerAssetStatus.isSupported(locale) else {
                analyzerAssetStatus = .unsupported
                return
            }
            if await SpeechAnalyzerAssetStatus.isInstalled(locale) {
                analyzerAssetStatus = .ready
                return
            }
            analyzerAssetStatus = .downloading
            do {
                try await SpeechAnalyzerAssetStatus.ensureInstalled(locale)
                analyzerAssetStatus = await SpeechAnalyzerAssetStatus.isInstalled(locale)
                    ? .ready
                    : .failed(loc.string("settings.model.assets.failed"))
            } catch {
                analyzerAssetStatus = .failed(loc.string("settings.model.assets.failed"))
            }
        }
        #else
        analyzerAssetStatus = .idle
        #endif
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
