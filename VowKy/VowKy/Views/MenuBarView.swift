import SwiftUI
import AppKit
import Sparkle

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    private let updater: SPUUpdater
    private let updateCoordinator: UpdateReminderCoordinator

    init(appState: AppState, updater: SPUUpdater, updateCoordinator: UpdateReminderCoordinator) {
        self.appState = appState
        self.updater = updater
        self.updateCoordinator = updateCoordinator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Recent results
            if !appState.recentResults.isEmpty {
                Divider()
                Text("识别历史")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                ForEach(appState.recentResults.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text(appState.recentResults[index])
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.recentResults[index], forType: .string)
                            AnalyticsService.shared.trackHistoryCopy()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("复制到剪贴板")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }

                Button {
                    HistoryWindowController.shared.showWindow()
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("查看全部历史")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }

            // Error message
            if let error = appState.errorMessage {
                Divider()
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            Divider()

            // Recording / Return to recording window
            // 录音中：显示突出的"返回录音窗口"入口（始终可点），避免窗口失焦或被关后用户找不到回路。
            // 空闲：显示原"录音"按钮，逻辑同前。
            if appState.isRecordingTranscriptionInProgress {
                Button {
                    RecordingTranscriptionWindowController.shared.showWindow(appState: appState)
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                        Text("返回录音窗口")
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            } else {
                Button {
                    RecordingTranscriptionWindowController.shared.showWindow(appState: appState)
                } label: {
                    HStack {
                        Image(systemName: "record.circle")
                        Text("录音")
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .disabled(appState.state != .idle || appState.isFileTranscriptionInProgress)
            }

            // File transcription
            Button {
                FileTranscriptionWindowController.shared.showWindow(appState: appState)
            } label: {
                HStack {
                    Image(systemName: "waveform")
                    Text("转录文件...")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .disabled(appState.state != .idle || appState.isFileTranscriptionInProgress || appState.isRecordingTranscriptionInProgress)

            // Check for Updates（用户主动检查，不计入自动提醒次数）
            Button {
                updateCoordinator.userInitiatedCheck(updater: updater)
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("检查更新")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Settings
            Button {
                SettingsWindowController.shared.showWindow(updater: updater, updateCoordinator: updateCoordinator)
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit VowKy")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .padding(.bottom, 8)
        }
        .frame(width: 220)
    }

    // MARK: - Computed Properties

    private var statusText: String {
        if appState.isRecordingTranscriptionInProgress {
            return "Recording..."
        }
        if appState.isFileTranscriptionInProgress {
            return "Transcribing file..."
        }
        switch appState.state {
        case .loading:
            return "Loading model..."
        case .idle:
            if let hm = appState.hotkeyManager, !hm.isRunning {
                return "需要辅助功能权限"
            }
            return "Ready (Option+Space)"
        case .recording:
            return "Recording..."
        case .recognizing:
            return "Recognizing..."
        case .outputting:
            return "Outputting..."
        }
    }

    private var statusColor: Color {
        if appState.isRecordingTranscriptionInProgress {
            return .red
        }
        if appState.isFileTranscriptionInProgress {
            return .yellow
        }
        switch appState.state {
        case .loading:
            return .orange
        case .idle:
            if let hm = appState.hotkeyManager, !hm.isRunning {
                return .orange
            }
            return .green
        case .recording:
            return .red
        case .recognizing:
            return .yellow
        case .outputting:
            return .blue
        }
    }
}
