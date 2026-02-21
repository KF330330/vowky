import SwiftUI
import AppKit
import Combine

// MARK: - Onboarding Step

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions = 1
    case hotkey = 2
    case tryIt = 3
}

// MARK: - Onboarding Window Controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var viewModel: OnboardingViewModel?

    func showWindow(appState: AppState) {
        if let window = window {
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
        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "VowKy 设置向导"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func closeWindow() {
        viewModel?.cleanup()
        window?.close()
        window = nil
        viewModel = nil
    }

    // NSWindowDelegate — user clicked X button
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        viewModel?.cleanup()
        window = nil
        viewModel = nil
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
    private var stateCancellable: AnyCancellable?
    private var resultCancellable: AnyCancellable?

    // MARK: - Navigation

    func goNext() {
        guard let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else {
            completeOnboarding()
            return
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
        onComplete?()
    }

    func cleanup() {
        stopPermissionPolling()
        stopRecordingHotkey()
        stopTryItObserving()
    }

    // MARK: - Permission Polling

    func startPermissionPolling() {
        isAccessibilityGranted = AXIsProcessTrusted()
        guard !isAccessibilityGranted else { return }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let granted = AXIsProcessTrusted()
                if granted {
                    self.isAccessibilityGranted = true
                    self.stopPermissionPolling()
                    // Auto-advance after brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        if self.currentStep == .permissions {
                            self.goNext()
                        }
                    }
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

    // MARK: - Hotkey Recording

    func startRecordingHotkey() {
        isRecordingHotkey = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
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
                needsShift: event.modifierFlags.contains(.shift)
            )
            config.save()
            self.hotkeyDisplay = config.displayName
            self.stopRecordingHotkey()
            self.checkHotkeyConflict()

            // Notify AppState to reload hotkey
            if let hotkeyMgr = self.appState?.hotkeyManager {
                hotkeyMgr.stop()
                _ = hotkeyMgr.start()
            }

            return nil
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
                conflictMessage = "系统的「选择上一个输入法」快捷键也使用了 Option+Space，会与 VowKy 冲突。\n请前往「系统设置 > 键盘 > 键盘快捷键 > 输入法」中修改或关闭。"
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
                    Button("上一步") {
                        viewModel.goPrevious()
                    }
                }

                if viewModel.currentStep == .tryIt {
                    Button("完成") {
                        viewModel.completeOnboarding()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("下一步") {
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
        if viewModel.currentStep == .permissions {
            return !viewModel.isAccessibilityGranted
        }
        return false
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("欢迎使用 VowKy")
                .font(.title)
                .bold()

            Text("macOS 菜单栏语音输入工具\n按下快捷键说话，文字即刻出现在光标位置")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "wifi.slash", text: "完全离线，无需联网")
                FeatureRow(icon: "lock.shield", text: "隐私优先，语音不出设备")
                FeatureRow(icon: "globe", text: "支持中文语音识别")
                FeatureRow(icon: "cursorarrow.click.badge.clock", text: "全局快捷键，任意应用可用")
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
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.circle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("授权辅助功能")
                .font(.title2)
                .bold()

            Text("VowKy 需要辅助功能权限来注册全局快捷键和输入文字。\n\n点击下方按钮后，在系统设置中找到 VowKy 并开启开关。")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isAccessibilityGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                    Text("辅助功能权限已授予")
                        .foregroundColor(.green)
                        .font(.headline)
                }
                .padding(.top, 8)
            } else {
                Button("打开系统设置") {
                    viewModel.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("等待授权中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            viewModel.isAccessibilityGranted = AXIsProcessTrusted()
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
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("设置快捷键")
                .font(.title2)
                .bold()

            Text("当前语音输入快捷键：")
                .foregroundColor(.secondary)

            if viewModel.isRecordingHotkey {
                Text("请按下新快捷键...")
                    .font(.system(size: 24, design: .monospaced))
                    .foregroundColor(.orange)
                    .padding(.vertical, 8)
            } else {
                Text(viewModel.hotkeyDisplay)
                    .font(.system(size: 24, design: .monospaced))
                    .padding(.vertical, 8)
            }

            Button(viewModel.isRecordingHotkey ? "取消" : "修改快捷键") {
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
                        Text("快捷键冲突")
                            .foregroundColor(.orange)
                            .bold()
                    }
                    Text(viewModel.conflictMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("打开键盘设置") {
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
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            switch viewModel.tryItState {
            case .ready:
                Image(systemName: "waveform.circle")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("试一试")
                    .font(.title2)
                    .bold()

                if let appState = viewModel.appState, appState.state == .loading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("语音模型加载中，请稍候...")
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("按下 \(viewModel.hotkeyDisplay) 开始说话")
                            .font(.headline)
                        Text("说完后再按一次 \(viewModel.hotkeyDisplay) 停止")
                            .foregroundColor(.secondary)
                    }
                }

            case .recording:
                PulsingMicIcon()
                Text("正在聆听...")
                    .font(.headline)
                    .foregroundColor(.red)
                Text("说完后按 \(viewModel.hotkeyDisplay) 停止")
                    .foregroundColor(.secondary)

            case .recognizing:
                ProgressView()
                    .controlSize(.regular)
                Text("识别中...")
                    .font(.headline)

            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)
                Text("识别成功!")
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
                Button("再试一次") {
                    viewModel.resetTryIt()
                }
                .buttonStyle(.bordered)

            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)
                Text("未识别到语音")
                    .font(.headline)
                Text("请确保麦克风正常工作，然后再试一次")
                    .foregroundColor(.secondary)
                Button("重试") {
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
