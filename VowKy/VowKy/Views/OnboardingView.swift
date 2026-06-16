import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - Onboarding Step

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions = 1
    case hotkey = 2
    case tryIt = 3
    case menuBar = 4
}

// MARK: - Onboarding Window Controller

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var viewModel: OnboardingViewModel?
    private var closeObserver: Any?

    func showWindow(appState: AppState) {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = OnboardingViewModel()
        vm.appState = appState
        vm.onComplete = { [weak self] in
            self?.closeWindow()
        }
        self.viewModel = vm

        let onboardingView = OnboardingView(viewModel: vm)
        let hostingController = NSHostingController(rootView: onboardingView.environmentObject(LocalizationManager.shared))

        let window = NSWindow(contentViewController: hostingController)
        window.title = L("window.onboarding.title")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Observe window close (user clicks X button)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowClosed()
        }

        self.window = window
    }

    func closeWindow() {
        viewModel?.cleanup()
        removeCloseObserver()
        window?.close()
        window = nil
        viewModel = nil
    }

    private func handleWindowClosed() {
        // User clicked X — cleanup but don't mark completed, show again next launch
        viewModel?.cleanup()
        removeCloseObserver()
        window = nil
        viewModel = nil
    }

    private func removeCloseObserver() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
    }
}

// MARK: - Onboarding ViewModel

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var isAccessibilityGranted: Bool = false
    @Published var hotkeyDisplay: String = HotkeyConfig.current.displayName
    @Published var isRecordingHotkey: Bool = false
    @Published var hasConflict: Bool = false
    @Published var conflictMessage: String = ""

    // Try It step
    @Published var tryItState: TryItState = .ready
    @Published var recognizedText: String = ""

    enum TryItState {
        case ready
        case recording
        case recognizing
        case success
        case failed
    }

    weak var appState: AppState?
    var onComplete: (() -> Void)?

    private var permissionTimer: Timer?
    private var eventMonitor: Any?
    private var pendingModifierKeyCode: Int64?
    private var stateCancellable: AnyCancellable?
    private var resultCancellable: AnyCancellable?

    // MARK: - Navigation

    func goNext() {
        guard let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else {
            completeOnboarding()
            return
        }
        // 进入 Try It 前启动热键，让用户可以测试
        if next == .tryIt {
            appState?.startHotkey()
        }
        currentStep = next
    }

    func goPrevious() {
        guard let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    func completeOnboarding() {
        cleanup()
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        // startHotkey() 已在进入 Try It 步骤时调用，内部有 guard 防重复
        appState?.startHotkey()
        // 默认开启开机自启
        try? SMAppService.mainApp.register()
        onComplete?()
    }

    func cleanup() {
        stopPermissionPolling()
        stopRecordingHotkey()
        stopTryItObserving()
    }

    // MARK: - Permission Check

    func refreshPermissionState() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    // MARK: - Permission Polling

    func startPermissionPolling() {
        refreshPermissionState()
        guard !isAccessibilityGranted else { return }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.isAccessibilityGranted = true
                    self.stopPermissionPolling()
                    // 不自动跳转，让用户看到绿色勾后手动点下一步
                }
            }
        }
    }

    func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPermissionPolling()
    }

    /// 是否正在等待用户授权（已点过按钮，轮询中）
    var isPollingPermission: Bool {
        permissionTimer != nil
    }

    // MARK: - Hotkey Recording

    func startRecordingHotkey() {
        isRecordingHotkey = true
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
                    self.hotkeyDisplay = config.displayName
                    self.stopRecordingHotkey()
                    self.checkHotkeyConflict()

                    if let hotkeyMgr = self.appState?.hotkeyManager {
                        hotkeyMgr.stop()
                        _ = hotkeyMgr.start()
                    }
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

                // Ignore pure modifier keys
                if [55, 56, 58, 59, 61, 62].contains(keyCode) { return event }

                // Escape without modifiers = cancel
                if keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.stopRecordingHotkey()
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
                self.hotkeyDisplay = config.displayName
                self.stopRecordingHotkey()
                self.checkHotkeyConflict()

                if let hotkeyMgr = self.appState?.hotkeyManager {
                    hotkeyMgr.stop()
                    _ = hotkeyMgr.start()
                }
                return nil
            }
        }
    }

    func stopRecordingHotkey() {
        isRecordingHotkey = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Conflict Detection

    func checkHotkeyConflict() {
        hasConflict = false
        conflictMessage = ""

        let config = HotkeyConfig.current
        // Only check if current hotkey could conflict with input source switching
        guard config.keyCode == 49, // Space
              config.needsOption,
              !config.needsCommand,
              !config.needsControl,
              !config.needsShift else { return }

        guard let hotkeys = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let items = hotkeys["AppleSymbolicHotKeys"] as? [String: Any],
              let item61 = items["61"] as? [String: Any],
              let enabled = item61["enabled"] as? Bool, enabled,
              let value = item61["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int] else { return }

        if parameters.count >= 3 {
            let keyCode = parameters[1]
            let modifiers = parameters[2]
            let isSpace = (keyCode == 49)
            let hasOption = (modifiers & 0x80000) != 0
            let hasCommand = (modifiers & 0x100000) != 0
            let hasControl = (modifiers & 0x40000) != 0

            if isSpace && hasOption && !hasCommand && !hasControl {
                hasConflict = true
                conflictMessage = L("onboarding.hotkey.conflictMessage")
            }
        }
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Try It (observe AppState via Combine)

    func startTryItObserving() {
        guard let appState else { return }
        tryItState = .ready
        recognizedText = ""

        stateCancellable = appState.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (state: AppState.State) in
                guard let self else { return }
                switch state {
                case .recording:
                    self.tryItState = .recording
                case .recognizing:
                    self.tryItState = .recognizing
                case .idle:
                    if self.tryItState == .recognizing && self.recognizedText.isEmpty {
                        self.tryItState = .failed
                    }
                default:
                    break
                }
            }

        resultCancellable = appState.$lastResult
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] (text: String) in
                guard let self else { return }
                self.recognizedText = text
                self.tryItState = .success
            }
    }

    func stopTryItObserving() {
        stateCancellable?.cancel()
        resultCancellable?.cancel()
        stateCancellable = nil
        resultCancellable = nil
    }

    func resetTryIt() {
        tryItState = .ready
        recognizedText = ""
    }
}

// MARK: - Main Onboarding View

struct OnboardingView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch viewModel.currentStep {
                case .welcome:
                    WelcomeStepView()
                case .permissions:
                    PermissionsStepView(viewModel: viewModel)
                case .hotkey:
                    HotkeyStepView(viewModel: viewModel)
                case .tryIt:
                    TryItStepView(viewModel: viewModel)
                case .menuBar:
                    MenuBarStepView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            Divider()

            // Bottom bar
            HStack {
                // Step dots
                HStack(spacing: 8) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                        Circle()
                            .fill(step == viewModel.currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if viewModel.currentStep != .welcome {
                    Button(loc.string("onboarding.nav.previous")) {
                        viewModel.goPrevious()
                    }
                }

                if viewModel.currentStep == .menuBar {
                    Button(loc.string("onboarding.nav.finish")) {
                        viewModel.completeOnboarding()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(loc.string("onboarding.nav.next")) {
                        viewModel.goNext()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isNextDisabled)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 420)
    }

    private var isNextDisabled: Bool {
        return false
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    @EnvironmentObject private var loc: LocalizationManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text(loc.string("onboarding.welcome.title"))
                .font(.title)
                .bold()

            Text(loc.string("onboarding.welcome.subtitle"))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "wifi.slash", text: loc.string("onboarding.welcome.featureOffline"))
                FeatureRow(icon: "lock.shield", text: loc.string("onboarding.welcome.featurePrivacy"))
                FeatureRow(icon: "globe", text: loc.string("onboarding.welcome.featureChinese"))
                FeatureRow(icon: "cursorarrow.click.badge.clock", text: loc.string("onboarding.welcome.featureGlobal"))
            }
            .padding(.top, 8)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            Text(text)
        }
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStepView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.circle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text(loc.string("onboarding.permission.title"))
                .font(.title2)
                .bold()

            Text(loc.string("onboarding.permission.description"))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isAccessibilityGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                    Text(loc.string("onboarding.permission.granted"))
                        .foregroundColor(.green)
                        .font(.headline)
                }
                .padding(.top, 8)
            } else {
                Button(loc.string("onboarding.permission.openSettings")) {
                    viewModel.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)

                if viewModel.isPollingPermission {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(loc.string("onboarding.permission.waiting"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text(loc.string("onboarding.permission.skipHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            viewModel.refreshPermissionState()
            if !viewModel.isAccessibilityGranted {
                viewModel.startPermissionPolling()
            }
        }
        .onDisappear {
            viewModel.stopPermissionPolling()
        }
    }
}

// MARK: - Step 3: Hotkey

private struct HotkeyStepView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 14) {
            Text(loc.string("onboarding.hotkey.title"))
                .font(.title2)
                .bold()

            Text(loc.string("onboarding.hotkey.currentLabel"))
                .foregroundColor(.secondary)

            if viewModel.isRecordingHotkey {
                Text(loc.string("onboarding.hotkey.pressNew"))
                    .font(.system(size: 24, design: .monospaced))
                    .foregroundColor(.orange)
            } else {
                Text(viewModel.hotkeyDisplay)
                    .font(.system(size: 24, design: .monospaced))
            }

            if let image = NSImage(contentsOfFile: Bundle.main.path(forResource: "onboarding-hotkey", ofType: "jpg") ?? "") {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 2)
            }

            Button(viewModel.isRecordingHotkey ? loc.string("onboarding.hotkey.cancelRecord") : loc.string("onboarding.hotkey.changeButton")) {
                if viewModel.isRecordingHotkey {
                    viewModel.stopRecordingHotkey()
                } else {
                    viewModel.startRecordingHotkey()
                }
            }
            .buttonStyle(.bordered)

            if viewModel.hasConflict {
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(loc.string("onboarding.hotkey.conflictTitle"))
                            .foregroundColor(.orange)
                            .bold()
                    }
                    Text(viewModel.conflictMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button(loc.string("onboarding.hotkey.openKeyboardSettings")) {
                        viewModel.openKeyboardSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                )
            }
        }
        .onAppear {
            viewModel.hotkeyDisplay = HotkeyConfig.current.displayName
            viewModel.checkHotkeyConflict()
        }
        .onDisappear {
            viewModel.stopRecordingHotkey()
        }
    }
}

// MARK: - Step 4: Try It

private struct TryItStepView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            switch viewModel.tryItState {
            case .ready:
                Image(systemName: "waveform.circle")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text(loc.string("onboarding.tryIt.title"))
                    .font(.title2)
                    .bold()

                if let appState = viewModel.appState, appState.state == .loading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(loc.string("onboarding.tryIt.modelLoading"))
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text(loc.string("onboarding.tryIt.pressToStart", viewModel.hotkeyDisplay))
                            .font(.headline)
                        Text(loc.string("onboarding.tryIt.pressToStop", viewModel.hotkeyDisplay))
                            .foregroundColor(.secondary)
                    }
                }

            case .recording:
                PulsingMicIcon()
                Text(loc.string("onboarding.tryIt.listening"))
                    .font(.headline)
                    .foregroundColor(.red)
                Text(loc.string("onboarding.tryIt.pressToStopShort", viewModel.hotkeyDisplay))
                    .foregroundColor(.secondary)

            case .recognizing:
                ProgressView()
                    .controlSize(.regular)
                Text(loc.string("onboarding.tryIt.recognizing"))
                    .font(.headline)

            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)
                Text(loc.string("onboarding.tryIt.success"))
                    .font(.headline)
                    .foregroundColor(.green)
                Text(viewModel.recognizedText)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                Button(loc.string("onboarding.tryIt.tryAgain")) {
                    viewModel.resetTryIt()
                }
                .buttonStyle(.bordered)

            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)
                Text(loc.string("onboarding.tryIt.noVoice"))
                    .font(.headline)
                Text(loc.string("onboarding.tryIt.noVoiceHint"))
                    .foregroundColor(.secondary)
                Button(loc.string("onboarding.tryIt.retry")) {
                    viewModel.resetTryIt()
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            viewModel.startTryItObserving()
        }
        .onDisappear {
            viewModel.stopTryItObserving()
        }
    }
}

// MARK: - Step 5: Menu Bar

private struct MenuBarStepView: View {
    @EnvironmentObject private var loc: LocalizationManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text(loc.string("onboarding.menuBar.title"))
                .font(.title2)
                .bold()

            Text(loc.string("onboarding.menuBar.description"))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if let image = NSImage(contentsOfFile: Bundle.main.path(forResource: "onboarding-menubar", ofType: "jpg") ?? "") {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)
            }
        }
    }
}
