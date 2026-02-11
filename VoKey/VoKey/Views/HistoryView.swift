import SwiftUI
import AppKit

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

        let window = NSWindow(contentViewController: hostingController)
        window.title = "VoKey 识别历史"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 500, height: 600))
        window.minSize = NSSize(width: 400, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

// MARK: - History View

struct HistoryView: View {
    @State private var records: [HistoryRecord] = []
    @State private var searchText = ""
    @State private var totalCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索历史记录...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) { _ in
                        loadRecords()
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Records list
            if records.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "还没有输入记录" : "未找到相关记录")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(records) { record in
                        HistoryRowView(record: record, onDelete: {
                            HistoryStore.shared.delete(id: record.id)
                            loadRecords()
                        })
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // Status bar
            HStack {
                Text("共 \(totalCount) 条记录")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if !records.isEmpty {
                    Button("清空全部") {
                        HistoryStore.shared.deleteAll()
                        loadRecords()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 400, minHeight: 400)
        .onAppear {
            loadRecords()
        }
    }

    private func loadRecords() {
        let query = searchText.isEmpty ? nil : searchText
        records = HistoryStore.shared.fetchAll(query: query)
        totalCount = searchText.isEmpty ? HistoryStore.shared.count() : records.count
    }
}

// MARK: - History Row

struct HistoryRowView: View {
    let record: HistoryRecord
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.content)
                    .font(.system(size: 13))
                    .lineLimit(3)
                Text(formatDate(record.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                HStack(spacing: 4) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("复制")

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
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
