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
    @State private var isRecording = false
    @State private var eventMonitor: Any?

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
            }

            // Model
            Section("语音模型") {
                LabeledContent("模型") {
                    Text("Paraformer-zh (int8)")
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
                            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
                            AXIsProcessTrustedWithOptions(options)
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
        .frame(width: 380, height: 380)
        .onAppear {
            isAccessibilityGranted = AXIsProcessTrusted()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            hotkeyDisplay = HotkeyConfig.current.displayName
        }
        .onDisappear {
            stopRecordingHotkey()
        }
    }

    // MARK: - Hotkey Recording

    private func startRecordingHotkey() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let keyCode = Int64(event.keyCode)

            // Ignore pure modifier keys
            if keyCode == 55 || keyCode == 56 || keyCode == 58 || keyCode == 59 || keyCode == 61 || keyCode == 62 {
                return event
            }

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
                needsShift: event.modifierFlags.contains(.shift)
            )
            config.save()
            hotkeyDisplay = config.displayName
            stopRecordingHotkey()
            return nil
        }
    }

    private func stopRecordingHotkey() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
