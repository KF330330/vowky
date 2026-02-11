import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var appState: AppState

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

            // Settings
            Button {
                SettingsWindowController.shared.showWindow()
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
                    Text("Quit VoKey")
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
        switch appState.state {
        case .loading:
            return "Loading model..."
        case .idle:
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
        switch appState.state {
        case .loading:
            return .orange
        case .idle:
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
