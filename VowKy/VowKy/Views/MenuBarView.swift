import SwiftUI
import AppKit
import Sparkle

struct MenuBarView: View {
    @EnvironmentObject private var loc: LocalizationManager
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
                Text(loc.string("menu.recentResults"))
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
                        .help(loc.string("menu.copyToClipboard"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }

                Button {
                    HistoryWindowController.shared.showWindow()
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(loc.string("menu.viewAllHistory"))
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
                        Text(loc.string("menu.returnToRecording"))
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
                        Text(loc.string("menu.record"))
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
                    Text(loc.string("menu.transcribeFile"))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .disabled(appState.state != .idle || appState.isFileTranscriptionInProgress || appState.isRecordingTranscriptionInProgress)

            // Settings（更新控件已移入设置页：自动检查更新开关 + 检查更新按钮）
            Button {
                SettingsWindowController.shared.showWindow(updater: updater, updateCoordinator: updateCoordinator)
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text(loc.string("menu.settings"))
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
                    Text(loc.string("menu.quit"))
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
            return loc.string("menu.status.recording")
        }
        if appState.isFileTranscriptionInProgress {
            return loc.string("menu.status.transcribingFile")
        }
        switch appState.state {
        case .loading:
            return loc.string("menu.status.loadingModel")
        case .idle:
            if let hm = appState.hotkeyManager, !hm.isRunning {
                return loc.string("menu.status.needAccessibility")
            }
            return loc.string("menu.status.ready")
        case .recording:
            return loc.string("menu.status.recording")
        case .recognizing:
            return loc.string("menu.status.recognizing")
        case .outputting:
            return loc.string("menu.status.outputting")
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
