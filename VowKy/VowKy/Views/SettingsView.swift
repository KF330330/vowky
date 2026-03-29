import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Settings Window Controller

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func showWindow() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
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
    @State private var permissionRefreshTimer: Timer?

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
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
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
}
