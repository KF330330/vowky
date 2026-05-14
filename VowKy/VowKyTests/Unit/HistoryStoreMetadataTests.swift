import XCTest
import SQLite3
@testable import VowKy

final class HistoryStoreMetadataTests: XCTestCase {

    private var tmpDB: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky-history-tests-\(UUID().uuidString)")
            .appendingPathComponent("history.db")
        store = HistoryStore()
        store.open(at: tmpDB)
    }

    override func tearDownWithError() throws {
        store.closeForTesting()
        try? FileManager.default.removeItem(at: tmpDB.deletingLastPathComponent())
        store = nil
        tmpDB = nil
    }

    private func makeMetadata(title: String = "标题 A", summary: String = "摘 A") -> TranscriptionMetadata {
        TranscriptionMetadata(
            id: UUID(),
            title: title,
            summary: summary,
            audioPath: "/tmp/a.wav",
            markdownPath: "/tmp/a.md",
            generatedAt: Date(),
            durationSeconds: 30,
            provider: "openai-compatible@api.openai.com",
            sourceType: "recording",
            aiEnhancementSucceeded: true,
            warnings: []
        )
    }

    // MARK: - 新插入路径

    func testInsertWithMetadataPersistsFields() {
        let md = makeMetadata()
        let id = store.insertWithMetadata(content: "原文 A", sourceType: "recording", metadata: md)
        XCTAssertGreaterThan(id, 0)

        let all = store.fetchAll()
        XCTAssertEqual(all.count, 1)
        let r = all[0]
        XCTAssertEqual(r.content, "原文 A")
        XCTAssertEqual(r.sourceType, "recording")
        XCTAssertEqual(r.title, "标题 A")
        XCTAssertEqual(r.summary, "摘 A")
        XCTAssertEqual(r.audioPath, "/tmp/a.wav")
        XCTAssertEqual(r.markdownPath, "/tmp/a.md")
        XCTAssertEqual(r.aiProvider, "openai-compatible@api.openai.com")
    }

    // MARK: - 老插入路径继续工作（metadata 字段为 nil）

    func testLegacyInsertHasNilMetadataFields() {
        store.insert(content: "old voice", sourceType: "voice")
        let all = store.fetchAll()
        XCTAssertEqual(all.count, 1)
        let r = all[0]
        XCTAssertEqual(r.content, "old voice")
        XCTAssertEqual(r.sourceType, "voice")
        XCTAssertNil(r.title)
        XCTAssertNil(r.summary)
        XCTAssertNil(r.audioPath)
        XCTAssertNil(r.markdownPath)
        XCTAssertNil(r.aiProvider)
    }

    // MARK: - 老库 ALTER TABLE 兼容

    func testReopeningOldSchemaDatabaseAddsNewColumns() {
        // 1) 关掉新 store
        store.closeForTesting()

        // 2) 直接用 sqlite3 创建一个"老版本"的库（只有原始 4 列），写一条数据
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tmpDB.path, &legacy), SQLITE_OK)
        let oldSchema = """
        CREATE TABLE IF NOT EXISTS input_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            source_type TEXT NOT NULL DEFAULT 'voice',
            created_at REAL NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(legacy, oldSchema, nil, nil, nil), SQLITE_OK)
        let insertSQL = "INSERT INTO input_history (content, source_type, created_at) VALUES ('legacy row', 'voice', \(Date().timeIntervalSince1970));"
        XCTAssertEqual(sqlite3_exec(legacy, insertSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(legacy)

        // 3) 用新 store 打开，应该补上 5 列并能读出老数据
        let newStore = HistoryStore()
        newStore.open(at: tmpDB)
        defer { newStore.closeForTesting() }

        let records = newStore.fetchAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].content, "legacy row")
        XCTAssertNil(records[0].title)

        // 4) 此时插入带 metadata 的新行也应成功
        _ = newStore.insertWithMetadata(content: "new row", sourceType: "recording", metadata: makeMetadata())
        let all = newStore.fetchAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first(where: { $0.content == "new row" })?.title, "标题 A")
        XCTAssertEqual(all.first(where: { $0.content == "legacy row" })?.title, nil)
    }

    // MARK: - 搜索范围扩展到 title/summary

    func testSearchMatchesTitleOrSummary() {
        store.insertWithMetadata(
            content: "原文 X",
            sourceType: "recording",
            metadata: makeMetadata(title: "Q2 OKR 回顾", summary: "公司绩效讨论。")
        )
        store.insertWithMetadata(
            content: "原文 Y",
            sourceType: "recording",
            metadata: makeMetadata(title: "周会", summary: "本周进度同步")
        )

        let byTitle = store.fetchAll(query: "OKR")
        XCTAssertEqual(byTitle.count, 1)
        XCTAssertEqual(byTitle[0].content, "原文 X")

        let bySummary = store.fetchAll(query: "进度")
        XCTAssertEqual(bySummary.count, 1)
        XCTAssertEqual(bySummary[0].content, "原文 Y")

        let byContent = store.fetchAll(query: "原文")
        XCTAssertEqual(byContent.count, 2)
    }
}
