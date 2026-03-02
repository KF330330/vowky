import SwiftUI
import AppKit

// MARK: - Keyable Window (fixes TextField focus in LSUIElement apps)

private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - History Window Controller

final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    func showWindow() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let historyView = HistoryView()
        let hostingController = NSHostingController(rootView: historyView)

        let window = KeyableWindow(contentViewController: hostingController)
        window.title = "VowKy 识别历史"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 620))
        window.minSize = NSSize(width: 420, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

// MARK: - Brand Colors

private enum Brand {
    static let main = Color(red: 0.722, green: 0.831, blue: 0.345)       // #B8D458
    static let bright = Color(red: 0.831, green: 0.910, blue: 0.486)     // #D4E87C
    static let deep = Color(red: 0.541, green: 0.682, blue: 0.227)       // #8AAE3A
    static let bg = Color(red: 0.969, green: 0.980, blue: 0.941)         // #F7FAF0
    static let bgSecondary = Color(red: 0.941, green: 0.961, blue: 0.894) // #F0F5E4
    static let textPrimary = Color(red: 0.102, green: 0.133, blue: 0.063) // #1A2210
    static let textSecondary = Color(red: 0.306, green: 0.361, blue: 0.227) // #4E5C3A
    static let textMuted = Color(red: 0.541, green: 0.596, blue: 0.447)  // #8A9872
    static let border = Color(red: 0.863, green: 0.902, blue: 0.784)     // #DCE6C8
}

// MARK: - History View

struct HistoryView: View {
    @State private var records: [HistoryRecord] = []
    @State private var searchText = ""
    @State private var totalCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Brand.deep)
                    .font(.system(size: 13, weight: .medium))
                TextField("搜索历史记录...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onChange(of: searchText) { _ in
                        if !searchText.isEmpty {
                            AnalyticsService.shared.trackHistorySearch()
                        }
                        loadRecords()
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
                    Text(searchText.isEmpty ? "还没有输入记录" : "未找到相关记录")
                        .font(.system(size: 14))
                        .foregroundColor(Brand.textMuted)
                    if searchText.isEmpty {
                        Text("按下快捷键开始语音输入")
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
                Text("共 \(totalCount) 条记录")
                    .font(.system(size: 11))
                    .foregroundColor(Brand.textMuted)
                Spacer()
                Button {
                    exportHistory()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text("导出")
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
        }
    }

    private func loadRecords() {
        let query = searchText.isEmpty ? nil : searchText
        records = HistoryStore.shared.fetchAll(query: query)
        totalCount = searchText.isEmpty ? HistoryStore.shared.count() : records.count
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.title = "导出识别历史"
        panel.nameFieldStringValue = "VowKy历史记录"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsOtherFileTypes = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content: String
        if url.pathExtension.lowercased() == "csv" {
            content = HistoryStore.shared.exportAsCSV()
        } else {
            content = HistoryStore.shared.exportAsText()
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[VowKy][HistoryView] Export failed: \(error)")
        }
    }
}

// MARK: - History Row

struct HistoryRowView: View {
    let record: HistoryRecord
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
                    .help("复制")

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                }
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
            return "今天 " + formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return "昨天 " + formatter.string(from: date)
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }
}
