import Foundation
import SQLite3

struct HistoryRecord: Identifiable {
    let id: Int64
    let content: String
    let sourceType: String
    let createdAt: Date
}

final class HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?

    // MARK: - Open / Close

    func open() {
        guard db == nil else { return }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoKey", isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbPath = dir.appendingPathComponent("history.db").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("[VoKey][HistoryStore] Failed to open database at \(dbPath)")
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
        print("[VoKey][HistoryStore] Database opened at \(dbPath)")
    }

    // MARK: - Insert

    func insert(content: String, sourceType: String = "voice") {
        guard let db = db else { return }

        let sql = "INSERT INTO input_history (content, source_type, created_at) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (content as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sourceType as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)

        sqlite3_step(stmt)
    }

    // MARK: - Fetch

    func fetchAll(query: String? = nil, limit: Int = 500) -> [HistoryRecord] {
        guard let db = db else { return [] }

        var records: [HistoryRecord] = []
        var stmt: OpaquePointer?

        let sql: String
        if let query = query, !query.isEmpty {
            sql = "SELECT id, content, source_type, created_at FROM input_history WHERE content LIKE ? ORDER BY created_at DESC LIMIT ?;"
        } else {
            sql = "SELECT id, content, source_type, created_at FROM input_history ORDER BY created_at DESC LIMIT ?;"
        }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var paramIdx: Int32 = 1
        if let query = query, !query.isEmpty {
            let pattern = "%\(query)%"
            sqlite3_bind_text(stmt, paramIdx, (pattern as NSString).utf8String, -1, nil)
            paramIdx += 1
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
                createdAt: Date(timeIntervalSince1970: timestamp)
            ))
        }

        return records
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
