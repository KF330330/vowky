import SwiftUI
import AppKit
import ServiceManagement
import Sparkle

// MARK: - Settings Window Controller

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private weak var updater: SPUUpdater?

    /// 由 MenuBarView 调用时传入 updater，让设置里的「自动检查更新」开关可以实时生效。
    func showWindow(updater: SPUUpdater? = nil) {
        if let updater {
            self.updater = updater
        }
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(updater: self.updater)
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

private struct SkillStatusKey: Hashable {
    let platform: AISkillPlatform
    let kind: AISkillKind
}

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
    @State private var skillStatuses: [SkillStatusKey: AISkillPlatformStatus] = [:]
    @State private var skillStatusMessage: String?

    // AI 助手
    @State private var aiEnabled: Bool
    @State private var aiAutoTrigger: Bool
    @State private var providerEntries: [ProviderPriorityEntry]
    @State private var selectedProviderIndex: Int = 0
    @State private var codexBinaryPath: String
    @State private var claudeBinaryPath: String
    @State private var aiTimeoutSeconds: Int
    @State private var aiTestResult: String?
    @State private var aiTestInProgress: Bool = false

    private let skillInstaller = AISkillInstallerService()
    private weak var updater: SPUUpdater?

    init(updater: SPUUpdater? = nil) {
        self.updater = updater
        let config = AIProviderFactory.load()
        _aiEnabled        = State(initialValue: config.enabled)
        _aiAutoTrigger    = State(initialValue: config.autoTrigger)
        _providerEntries  = State(initialValue: config.providers)
        _codexBinaryPath  = State(initialValue: config.codex.binaryPath)
        _claudeBinaryPath = State(initialValue: config.claude.binaryPath)
        _aiTimeoutSeconds = State(initialValue: config.timeoutSeconds)
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
            }

            Section("AI 助手") {
                Text("用本机 Claude Code / Codex CLI 给转写稿自动生成标题、摘要和分段。需先装 CLI 并安装对应 skill。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("启用 AI 后处理", isOn: $aiEnabled)
                    .onChange(of: aiEnabled) { _ in saveAIConfig() }

                if aiEnabled {
                    Toggle("转写完成后自动触发", isOn: $aiAutoTrigger)
                        .onChange(of: aiAutoTrigger) { _ in saveAIConfig() }

                    Text("Provider 优先级（前面的不可用时自动尝试后面的）")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(spacing: 4) {
                        ForEach(providerEntries.indices, id: \.self) { idx in
                            providerPriorityRow(index: idx)
                        }
                    }

                    if let kind = currentSelectedProviderKind, let platform = skillPlatform(for: kind) {
                        Divider()
                        providerDetailPanel(for: kind, platform: platform)
                    }

                    Stepper("调用超时：\(aiTimeoutSeconds) 秒", value: $aiTimeoutSeconds, in: 30...300, step: 10)
                        .onChange(of: aiTimeoutSeconds) { _ in saveAIConfig() }

                    HStack {
                        Button {
                            Task { await testAIProvider() }
                        } label: {
                            if aiTestInProgress {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("测试连接")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(aiTestInProgress)
                        Spacer()
                    }

                    if let aiTestResult {
                        Text(aiTestResult)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
            refreshSkillStatuses()
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

    // MARK: - AI Skills helpers

    private func refreshSkillStatuses() {
        skillStatuses = Dictionary(
            uniqueKeysWithValues: skillInstaller.statuses().map {
                (SkillStatusKey(platform: $0.platform, kind: $0.kind), $0)
            }
        )
    }

    /// Provider kind → 对应平台。
    private func skillPlatform(for kind: AIProviderKind) -> AISkillPlatform? {
        switch kind {
        case .codex:      return .codex
        case .claudeCode: return .claudeCode
        }
    }

    private func installSkill(for platform: AISkillPlatform) {
        do {
            _ = try skillInstaller.install(platforms: [platform])
            refreshSkillStatuses()
            skillStatusMessage = "已安装/更新 \(platform.displayName) 平台 skill"
        } catch {
            refreshSkillStatuses()
            skillStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func uninstallSkill(for platform: AISkillPlatform) {
        do {
            let result = try skillInstaller.uninstall(platforms: [platform])
            refreshSkillStatuses()
            if result.removedCompletedJobCaches > 0 {
                skillStatusMessage = "已卸载 \(platform.displayName) 平台 skill，已清理 \(result.removedCompletedJobCaches) 个已完成任务缓存"
            } else {
                skillStatusMessage = "已卸载 \(platform.displayName) 平台 skill"
            }
        } catch {
            refreshSkillStatuses()
            skillStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func skillStatusText(for platform: AISkillPlatform, kind: AISkillKind) -> String {
        guard let status = skillStatuses[SkillStatusKey(platform: platform, kind: kind)] else {
            return "检查中"
        }
        switch status.state {
        case .notInstalled:
            return "未安装"
        case .installed(let version):
            return version.map { "已安装 \($0)" } ?? "已安装"
        case .blockedByUnmanagedSkill:
            return "存在同名 skill"
        }
    }

    private func skillStatusColor(for platform: AISkillPlatform, kind: AISkillKind) -> Color {
        guard let status = skillStatuses[SkillStatusKey(platform: platform, kind: kind)] else {
            return .secondary
        }
        switch status.state {
        case .notInstalled:
            return .secondary
        case .installed:
            return .green
        case .blockedByUnmanagedSkill:
            return .orange
        }
    }

    // MARK: - AI 后处理

    private var currentSelectedProviderKind: AIProviderKind? {
        guard providerEntries.indices.contains(selectedProviderIndex) else { return nil }
        return providerEntries[selectedProviderIndex].kind
    }

    private func buildAIConfig() -> AIProviderConfig {
        AIProviderConfig(
            enabled: aiEnabled,
            autoTrigger: aiAutoTrigger,
            providers: providerEntries,
            codex: CLIConfig(binaryPath: codexBinaryPath),
            claude: CLIConfig(binaryPath: claudeBinaryPath),
            timeoutSeconds: aiTimeoutSeconds
        )
    }

    private func saveAIConfig() {
        AIProviderFactory.save(buildAIConfig())
    }

    private func moveProvider(at idx: Int, delta: Int) {
        let newIdx = idx + delta
        guard providerEntries.indices.contains(idx),
              providerEntries.indices.contains(newIdx) else { return }
        providerEntries.swapAt(idx, newIdx)
        if selectedProviderIndex == idx {
            selectedProviderIndex = newIdx
        } else if selectedProviderIndex == newIdx {
            selectedProviderIndex = idx
        }
        aiTestResult = nil
        saveAIConfig()
    }

    @ViewBuilder
    private func providerPriorityRow(index idx: Int) -> some View {
        let entry = providerEntries[idx]
        let isSelected = idx == selectedProviderIndex
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { providerEntries[idx].enabled },
                set: { newValue in
                    providerEntries[idx].enabled = newValue
                    saveAIConfig()
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text("\(idx + 1).")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Text(entry.kind.displayName)
                .foregroundColor(entry.enabled ? .primary : .secondary)
            Spacer()
            Button {
                moveProvider(at: idx, delta: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(idx == 0)

            Button {
                moveProvider(at: idx, delta: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(idx == providerEntries.count - 1)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedProviderIndex = idx
            aiTestResult = nil
        }
    }

    @ViewBuilder
    private func providerDetailPanel(for kind: AIProviderKind, platform: AISkillPlatform) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // CLI 路径
            switch kind {
            case .codex:
                TextField("codex 绝对路径（留空自动探测）", text: $codexBinaryPath)
                    .onChange(of: codexBinaryPath) { _ in saveAIConfig() }
                Text("自动探测会扫 Homebrew、nvm、fnm、volta 等常见位置。装 codex：`npm i -g @openai/codex` 或 `brew install codex`。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .claudeCode:
                TextField("claude 绝对路径（留空自动探测）", text: $claudeBinaryPath)
                    .onChange(of: claudeBinaryPath) { _ in saveAIConfig() }
                Text("自动探测会扫 Homebrew、nvm、fnm 等常见位置。装 claude：`npm i -g @anthropic-ai/claude-code`。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Skill 状态
            Text("\(platform.displayName) 平台 Skill 状态")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                Text("vowky-transcribe:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(skillStatusText(for: platform, kind: .transcribe))
                    .font(.caption)
                    .foregroundColor(skillStatusColor(for: platform, kind: .transcribe))
            }
            HStack(spacing: 6) {
                Text("transcript-enhance:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(skillStatusText(for: platform, kind: .enhance))
                    .font(.caption)
                    .foregroundColor(skillStatusColor(for: platform, kind: .enhance))
            }

            HStack(spacing: 8) {
                Button("安装/更新 skill") {
                    installSkill(for: platform)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("卸载") {
                    uninstallSkill(for: platform)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    skillStatuses[SkillStatusKey(platform: platform, kind: .transcribe)]?.state == .notInstalled &&
                    skillStatuses[SkillStatusKey(platform: platform, kind: .enhance)]?.state == .notInstalled
                )
            }

            if let skillStatusMessage {
                Text(skillStatusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func testAIProvider() async {
        aiTestInProgress = true
        aiTestResult = nil
        defer { aiTestInProgress = false }

        let config = buildAIConfig()
        let checker = ProviderUsabilityChecker()

        var lines: [String] = []
        for entry in config.providers where entry.enabled {
            if let reason = checker.unusableReason(for: entry.kind, config: config) {
                lines.append("✗ \(entry.kind.displayName)：\(reason.errorDescription ?? "不可用")")
                continue
            }
            let provider = AIProviderFactory.makeProvider(kind: entry.kind, config: config)
            do {
                let probeStarted = Date()
                let reply = try await provider.probe()
                let elapsedMs = Int(Date().timeIntervalSince(probeStarted) * 1000)
                let preview = reply.prefix(40)
                lines.append("✓ \(entry.kind.displayName)（\(elapsedMs) ms）：\(preview)")
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lines.append("✗ \(entry.kind.displayName)：\(msg)")
            }
        }

        if config.providers.allSatisfy({ !$0.enabled }) {
            lines.append("未启用任何 provider")
        }

        aiTestResult = lines.joined(separator: "\n")
    }
}
