import SwiftUI
import AppKit

// MARK: - History Window Controller

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSPanel?
    /// willClose 观察者 token：窗口关闭时移除，避免每次开→关累积一个僵尸注册
    private var closeObserver: NSObjectProtocol?

    func showWindow() {
        NSApp.setActivationPolicy(.regular)

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let historyView = HistoryView()
            .environmentObject(LocalizationManager.shared)
        let hostingController = NSHostingController(rootView: historyView)

        let panel = NSPanel(contentViewController: hostingController)
        panel.title = L("history.window.title")
        panel.styleMask = [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel]
        panel.styleMask.remove(.nonactivatingPanel)
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.setContentSize(NSSize(width: 520, height: 620))
        panel.minSize = NSSize(width: 420, height: 400)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Force first responder to content view for keyboard input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            panel.makeFirstResponder(hostingController.view)
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.closeObserver = nil
                }
                self.window = nil
                NSApp.setActivationPolicy(.accessory)
            }
        }

        self.window = panel
    }
}

// MARK: - Brand Colors（别名到共享 TranscriptionTheme，色值唯一来源）

private enum Brand {
    static let main = TranscriptionTheme.accentMain
    static let bright = TranscriptionTheme.accentBright
    static let deep = TranscriptionTheme.accentDeep
    static let bg = TranscriptionTheme.background
    static let bgSecondary = TranscriptionTheme.secondaryBackground
    static let textPrimary = TranscriptionTheme.textPrimary
    static let textSecondary = TranscriptionTheme.textSecondary
    static let textMuted = TranscriptionTheme.textMuted
    static let border = TranscriptionTheme.border
}

// MARK: - History View

struct HistoryView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @State private var records: [HistoryRecord] = []
    @State private var searchText = ""
    @State private var totalCount = 0
    @FocusState private var isSearchFocused: Bool
    /// 搜索防抖：逐字符敲击不再每键都查库
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Brand.deep)
                    .font(.system(size: 13, weight: .medium))
                TextField(loc.string("history.search.placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isSearchFocused)
                    .onChange(of: searchText) { _ in
                        searchDebounceTask?.cancel()
                        searchDebounceTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard !Task.isCancelled else { return }
                            if !searchText.isEmpty {
                                AnalyticsService.shared.trackHistorySearch()
                            }
                            loadRecords()
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Brand.textMuted)
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
                            .stroke(Brand.border, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Records list
            if records.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "leaf")
                        .font(.system(size: 36))
                        .foregroundColor(Brand.main)
                    Text(searchText.isEmpty ? loc.string("history.empty.noRecords") : loc.string("history.empty.noResults"))
                        .font(.system(size: 14))
                        .foregroundColor(Brand.textMuted)
                    if searchText.isEmpty {
                        Text(loc.string("history.empty.hint"))
                            .font(.system(size: 12))
                            .foregroundColor(Brand.textMuted.opacity(0.7))
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(records) { record in
                            HistoryRowView(record: record, onDelete: {
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

            // Bottom bar
            HStack {
                Text(loc.string("history.count", totalCount))
                    .font(.system(size: 11))
                    .foregroundColor(Brand.textMuted)
                Spacer()
                Button {
                    exportHistory()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text(loc.string("history.export"))
                            .font(.system(size: 11))
                    }
                    .foregroundColor(Brand.deep)
                }
                .buttonStyle(.plain)
                .disabled(records.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Brand.bgSecondary.opacity(0.5))
        }
        .background(Brand.bg)
        .frame(minWidth: 420, minHeight: 400)
        .onAppear {
            loadRecords()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
    }

    private func loadRecords() {
        let query = searchText.isEmpty ? nil : searchText
        let wasEmptyQuery = searchText.isEmpty
        // 后台查询、主线程更新，避免历史量大时卡 UI
        HistoryStore.shared.fetchAllAsync(query: query) { fetched in
            records = fetched
            totalCount = wasEmptyQuery ? HistoryStore.shared.count() : fetched.count
        }
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.title = loc.string("history.export.panelTitle")
        panel.nameFieldStringValue = loc.string("history.export.defaultFilename")
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsOtherFileTypes = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 全表拉取 + 大字符串拼接在后台完成，主线程只做落盘
        let writeToDisk: (String) -> Void = { content in
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[VowKy][HistoryView] Export failed: \(error)")
            }
        }
        if url.pathExtension.lowercased() == "csv" {
            HistoryStore.shared.exportAsCSVAsync(completion: writeToDisk)
        } else {
            HistoryStore.shared.exportAsTextAsync(completion: writeToDisk)
        }
    }
}

// MARK: - History Row

struct HistoryRowView: View {
    @EnvironmentObject private var loc: LocalizationManager
    let record: HistoryRecord
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.content)
                .font(.system(size: 13))
                .foregroundColor(Brand.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatDate(record.createdAt))
                .font(.system(size: 11))
                .foregroundColor(Brand.textMuted)
        }
        .overlay(alignment: .topTrailing) {
            if isHovered {
                HStack(spacing: 6) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.content, forType: .string)
                        AnalyticsService.shared.trackHistoryCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(Brand.deep)
                    }
                    .buttonStyle(.plain)
                    .help(loc.string("history.copy"))

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help(loc.string("history.delete"))
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Brand.bgSecondary)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Brand.bgSecondary : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? Brand.main.opacity(0.3) : Brand.border.opacity(0.5), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
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
