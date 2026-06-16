import Foundation
import SQLite3

struct HistoryRecord: Identifiable {
    let id: Int64
    let content: String
    let sourceType: String
    let createdAt: Date
    let title: String?
    let summary: String?
    let audioPath: String?
    let markdownPath: String?
    let aiProvider: String?
}

final class HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?

    // MARK: - Open / Close

    /// 打开数据库。`customPath` 仅供单测使用；生产环境一律走 Application Support。
    func open(at customPath: URL? = nil) {
        guard db == nil else { return }

        let dbPath: String
        if let custom = customPath {
            try? FileManager.default.createDirectory(
                at: custom.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            dbPath = custom.path
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("VowKy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dbPath = dir.appendingPathComponent("history.db").path
        }

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("[VowKy][HistoryStore] Failed to open database at \(dbPath)")
            return
        }

        let createTable = """
        CREATE TABLE IF NOT EXISTS input_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            source_type TEXT NOT NULL DEFAULT 'voice',
            created_at REAL NOT NULL
        );
        """
        sqlite3_exec(db, createTable, nil, nil, nil)

        // 向后兼容老数据库：5 条 ALTER TABLE 对已存在列报错被忽略
        for sql in [
            "ALTER TABLE input_history ADD COLUMN title TEXT;",
            "ALTER TABLE input_history ADD COLUMN summary TEXT;",
            "ALTER TABLE input_history ADD COLUMN audio_path TEXT;",
            "ALTER TABLE input_history ADD COLUMN markdown_path TEXT;",
            "ALTER TABLE input_history ADD COLUMN ai_provider TEXT;",
        ] {
            sqlite3_exec(db, sql, nil, nil, nil)
        }

        print("[VowKy][HistoryStore] Database opened at \(dbPath)")
    }

    /// 关闭并清除连接（仅供单测使用）。
    func closeForTesting() {
        if let db = db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Insert

    func insert(content: String, sourceType: String = "voice") {
        insertWithMetadata(content: content, sourceType: sourceType, metadata: nil)
    }

    @discardableResult
    func insertWithMetadata(
        content: String,
        sourceType: String,
        metadata: TranscriptionMetadata?
    ) -> Int64 {
        guard let db = db else { return -1 }

        let sql = """
        INSERT INTO input_history
            (content, source_type, created_at, title, summary, audio_path, markdown_path, ai_provider)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT (-1) tells SQLite to make its own copy; the NSString bridge can
        // outlive Swift's autorelease scope when used through sqlite3_bind_text(... nil).
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_text(stmt, 1, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, sourceType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)

        if let m = metadata {
            sqlite3_bind_text(stmt, 4, m.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, m.summary, -1, SQLITE_TRANSIENT)
            if let audio = m.audioPath {
                sqlite3_bind_text(stmt, 6, audio, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_text(stmt, 7, m.markdownPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, m.provider, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
            sqlite3_bind_null(stmt, 5)
            sqlite3_bind_null(stmt, 6)
            sqlite3_bind_null(stmt, 7)
            sqlite3_bind_null(stmt, 8)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Fetch

    func fetchAll(query: String? = nil, limit: Int = 500) -> [HistoryRecord] {
        guard let db = db else { return [] }

        var records: [HistoryRecord] = []
        var stmt: OpaquePointer?

        let baseColumns = "id, content, source_type, created_at, title, summary, audio_path, markdown_path, ai_provider"
        let sql: String
        if let query = query, !query.isEmpty {
            sql = "SELECT \(baseColumns) FROM input_history WHERE content LIKE ? OR title LIKE ? OR summary LIKE ? ORDER BY created_at DESC LIMIT ?;"
        } else {
            sql = "SELECT \(baseColumns) FROM input_history ORDER BY created_at DESC LIMIT ?;"
        }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        var paramIdx: Int32 = 1
        if let query = query, !query.isEmpty {
            let pattern = "%\(query)%"
            sqlite3_bind_text(stmt, paramIdx, pattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, paramIdx + 1, pattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, paramIdx + 2, pattern, -1, SQLITE_TRANSIENT)
            paramIdx += 3
        }
        sqlite3_bind_int(stmt, paramIdx, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let content = String(cString: sqlite3_column_text(stmt, 1))
            let sourceType = String(cString: sqlite3_column_text(stmt, 2))
            let timestamp = sqlite3_column_double(stmt, 3)

            records.append(HistoryRecord(
                id: id,
                content: content,
                sourceType: sourceType,
                createdAt: Date(timeIntervalSince1970: timestamp),
                title: optionalText(stmt, column: 4),
                summary: optionalText(stmt, column: 5),
                audioPath: optionalText(stmt, column: 6),
                markdownPath: optionalText(stmt, column: 7),
                aiProvider: optionalText(stmt, column: 8)
            ))
        }

        return records
    }

    private func optionalText(_ stmt: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    // MARK: - Delete

    func delete(id: Int64) {
        guard let db = db else { return }

        let sql = "DELETE FROM input_history WHERE id = ?;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    func deleteAll() {
        guard let db = db else { return }
        sqlite3_exec(db, "DELETE FROM input_history;", nil, nil, nil)
    }

    // MARK: - Export

    func exportAsText() -> String {
        let records = fetchAll(limit: Int(Int32.max))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return records.map { "[\(formatter.string(from: $0.createdAt))] \($0.content)" }
            .joined(separator: "\n")
    }

    func exportAsCSV() -> String {
        let records = fetchAll(limit: Int(Int32.max))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [LL("history.export.csvHeader")]
        for record in records {
            let escaped = record.content.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(formatter.string(from: record.createdAt)),\"\(escaped)\",\(record.sourceType)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Count

    func count() -> Int {
        guard let db = db else { return 0 }

        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM input_history;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }
}
