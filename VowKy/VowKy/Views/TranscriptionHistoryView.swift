import SwiftUI
import AppKit

// MARK: - Filter

/// 转录历史的两个独立视角：文件/链接转录、录音。各窗口只看自己那一类。
enum TranscriptionHistoryFilter {
    case file
    case recording

    /// 对应 HistoryStore 里的 source_type 值。
    var sourceTypes: [String] {
        switch self {
        case .file: return ["file"]
        case .recording: return ["recording"]
        }
    }

    var windowTitleKey: String {
        switch self {
        case .file: return "transcriptionHistory.file.windowTitle"
        case .recording: return "transcriptionHistory.recording.windowTitle"
        }
    }

    var typeLabelKey: String {
        switch self {
        case .file: return "transcriptionHistory.type.file"
        case .recording: return "transcriptionHistory.type.recording"
        }
    }

    var iconName: String {
        switch self {
        case .file: return "doc.text"
        case .recording: return "waveform"
        }
    }
}

// MARK: - Window Controller

@MainActor
final class TranscriptionHistoryWindowController {
    static let shared = TranscriptionHistoryWindowController()

    private var fileWindow: NSPanel?
    private var recordingWindow: NSPanel?

    func showWindow(filter: TranscriptionHistoryFilter) {
        NSApp.setActivationPolicy(.regular)

        if let existing = window(for: filter) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = TranscriptionHistoryView(filter: filter)
            .environmentObject(LocalizationManager.shared)
        let hostingController = NSHostingController(rootView: view)

        let panel = NSPanel(contentViewController: hostingController)
        panel.title = L(filter.windowTitleKey)
        panel.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.setContentSize(NSSize(width: 560, height: 640))
        panel.minSize = NSSize(width: 460, height: 420)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 强制把第一响应者切到内容视图，让搜索框能立即接收键盘输入。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            panel.makeFirstResponder(hostingController.view)
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.setWindow(nil, for: filter)
            // 两个历史窗口都关了才隐藏 Dock 图标，避免父窗口（转录/录音）仍开着时被连带隐藏。
            if self?.fileWindow == nil && self?.recordingWindow == nil {
                NSApp.setActivationPolicy(.prohibited)
            }
        }

        setWindow(panel, for: filter)
    }

    private func window(for filter: TranscriptionHistoryFilter) -> NSPanel? {
        switch filter {
        case .file: return fileWindow
        case .recording: return recordingWindow
        }
    }

    private func setWindow(_ panel: NSPanel?, for filter: TranscriptionHistoryFilter) {
        switch filter {
        case .file: fileWindow = panel
        case .recording: recordingWindow = panel
        }
    }
}

// MARK: - Brand Colors (与 HistoryView 一致的米绿配色)

private enum THBrand {
    static let main = Color(red: 0.722, green: 0.831, blue: 0.345)
    static let bright = Color(red: 0.831, green: 0.910, blue: 0.486)
    static let deep = Color(red: 0.541, green: 0.682, blue: 0.227)
    static let bg = Color(red: 0.969, green: 0.980, blue: 0.941)
    static let bgSecondary = Color(red: 0.941, green: 0.961, blue: 0.894)
    static let textPrimary = Color(red: 0.102, green: 0.133, blue: 0.063)
    static let textSecondary = Color(red: 0.306, green: 0.361, blue: 0.227)
    static let textMuted = Color(red: 0.541, green: 0.596, blue: 0.447)
    static let border = Color(red: 0.863, green: 0.902, blue: 0.784)
}

// MARK: - Transcription History View

struct TranscriptionHistoryView: View {
    let filter: TranscriptionHistoryFilter

    @EnvironmentObject private var loc: LocalizationManager
    @State private var records: [HistoryRecord] = []
    @State private var searchText = ""
    @State private var totalCount = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(THBrand.deep)
                    .font(.system(size: 13, weight: .medium))
                TextField(loc.string("transcriptionHistory.search.placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isSearchFocused)
                    .onChange(of: searchText) { _ in loadRecords() }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(THBrand.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(THBrand.border, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // 列表
            if records.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: filter.iconName)
                        .font(.system(size: 36))
                        .foregroundColor(THBrand.main)
                    Text(searchText.isEmpty
                         ? loc.string("transcriptionHistory.empty.title")
                         : loc.string("transcriptionHistory.empty.noResults"))
                        .font(.system(size: 14))
                        .foregroundColor(THBrand.textMuted)
                    if searchText.isEmpty {
                        Text(loc.string("transcriptionHistory.empty.hint"))
                            .font(.system(size: 12))
                            .foregroundColor(THBrand.textMuted.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(records) { record in
                            TranscriptionHistoryRowView(record: record, filter: filter, onDelete: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    HistoryStore.shared.delete(id: record.id)
                                    loadRecords()
                                }
                            })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }

            // 底部计数
            HStack {
                Text(loc.string("transcriptionHistory.count", totalCount))
                    .font(.system(size: 11))
                    .foregroundColor(THBrand.textMuted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(THBrand.bgSecondary.opacity(0.5))
        }
        .background(THBrand.bg)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            loadRecords()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
    }

    private func loadRecords() {
        let query = searchText.isEmpty ? nil : searchText
        records = HistoryStore.shared.fetchAll(query: query, sourceTypes: filter.sourceTypes)
        totalCount = searchText.isEmpty
            ? HistoryStore.shared.count(sourceTypes: filter.sourceTypes)
            : records.count
    }
}

// MARK: - Row

struct TranscriptionHistoryRowView: View {
    @EnvironmentObject private var loc: LocalizationManager
    let record: HistoryRecord
    let filter: TranscriptionHistoryFilter
    let onDelete: () -> Void

    @State private var isHovered = false

    /// 标题：优先元数据标题 → 落盘文件名 → 正文首行 → 占位。
    private var displayTitle: String {
        if let title = record.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let md = record.markdownPath {
            return (md as NSString).lastPathComponent
        }
        if let audio = record.audioPath {
            return (audio as NSString).lastPathComponent
        }
        let firstLine = record.content.split(separator: "\n").first.map(String.init) ?? record.content
        if !firstLine.isEmpty { return firstLine }
        return loc.string("transcriptionHistory.untitled")
    }

    /// 「在访达中显示」的目标：录音定位音频(.wav)，文件转录定位转录稿(.md)。
    private var revealPath: String? {
        switch filter {
        case .recording: return record.audioPath ?? record.markdownPath
        case .file: return record.markdownPath
        }
    }

    private var canOpenMarkdown: Bool { fileExists(record.markdownPath) }
    private var canReveal: Bool { fileExists(revealPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: filter.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(THBrand.deep)
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(THBrand.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(loc.string(filter.typeLabelKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(THBrand.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(THBrand.bgSecondary))
            }

            if !record.content.isEmpty {
                Text(record.content)
                    .font(.system(size: 12))
                    .foregroundColor(THBrand.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 14) {
                Text(formatDate(record.createdAt))
                    .font(.system(size: 11))
                    .foregroundColor(THBrand.textMuted)

                Spacer(minLength: 8)

                if canOpenMarkdown {
                    actionButton("doc.text.magnifyingglass", "transcriptionHistory.action.open") {
                        openFile(record.markdownPath)
                    }
                }
                if canReveal {
                    actionButton("folder", "transcriptionHistory.action.reveal") {
                        revealFile(revealPath)
                    }
                }
                actionButton("doc.on.doc", "history.copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.content, forType: .string)
                    AnalyticsService.shared.trackHistoryCopy()
                }
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(loc.string("history.delete"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? THBrand.bgSecondary : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? THBrand.main.opacity(0.3) : THBrand.border.opacity(0.5), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private func actionButton(_ icon: String, _ helpKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(THBrand.deep)
        }
        .buttonStyle(.plain)
        .help(loc.string(helpKey))
    }

    private func fileExists(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func openFile(_ path: String?) {
        guard fileExists(path), let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealFile(_ path: String?) {
        guard fileExists(path), let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return loc.string("history.date.today", formatter.string(from: date))
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return loc.string("history.date.yesterday", formatter.string(from: date))
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }
}
