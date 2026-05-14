import XCTest
@testable import VowKy

final class TranscriptionMarkdownWriterTests: XCTestCase {

    private func makeMetadata(
        title: String = "测试标题",
        summary: String = "简短摘要。",
        warnings: [String] = []
    ) -> TranscriptionMetadata {
        TranscriptionMetadata(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
            title: title,
            summary: summary,
            audioPath: "/tmp/audio.wav",
            markdownPath: "/tmp/doc.md",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 90,
            provider: "openai-compatible@api.openai.com",
            sourceType: "recording",
            aiEnhancementSucceeded: true,
            warnings: warnings
        )
    }

    func testFrontmatterContainsExpectedKeys() {
        let md = TranscriptionMetadata(
            id: UUID(),
            title: "T",
            summary: "S",
            audioPath: nil,
            markdownPath: "/tmp/x.md",
            generatedAt: Date(),
            durationSeconds: nil,
            provider: "codex",
            sourceType: "recording",
            aiEnhancementSucceeded: false,
            warnings: []
        )
        let fm = TranscriptionMarkdownWriter.frontmatterString(from: md)
        XCTAssertTrue(fm.hasPrefix("---\n"))
        XCTAssertTrue(fm.hasSuffix("---"))
        XCTAssertTrue(fm.contains("title: T"))
        XCTAssertTrue(fm.contains("summary: S"))
        XCTAssertTrue(fm.contains("provider: codex"))
        XCTAssertTrue(fm.contains("ai_enhancement: false"))
        XCTAssertTrue(fm.contains("warnings: []"))
        // 缺省字段不应出现
        XCTAssertFalse(fm.contains("audio_path:"))
        XCTAssertFalse(fm.contains("duration_seconds:"))
    }

    func testFrontmatterQuotesValuesWithColon() {
        let md = makeMetadata(title: "讨论: Q2 OKR")
        let fm = TranscriptionMarkdownWriter.frontmatterString(from: md)
        XCTAssertTrue(fm.contains("title: \"讨论: Q2 OKR\""), "got: \(fm)")
    }

    func testFrontmatterEscapesQuotesAndNewlines() {
        let md = makeMetadata(summary: "包含\"引号\"和\n换行")
        let fm = TranscriptionMarkdownWriter.frontmatterString(from: md)
        XCTAssertTrue(fm.contains("\\\""))
        XCTAssertTrue(fm.contains("\\n"))
        // 不应该把真换行字符放到 YAML 行里
        let summaryLine = fm.components(separatedBy: "\n").first(where: { $0.hasPrefix("summary:") })!
        XCTAssertFalse(summaryLine.contains("\n"))
    }

    func testFrontmatterListsWarnings() {
        let md = makeMetadata(warnings: ["anchor 未找到", "JSON 解析失败"])
        let fm = TranscriptionMarkdownWriter.frontmatterString(from: md)
        XCTAssertTrue(fm.contains("warnings:"))
        XCTAssertTrue(fm.contains("- anchor 未找到"))
        XCTAssertTrue(fm.contains("- JSON 解析失败"))
    }

    func testComposeJoinsFrontmatterAndBody() {
        let md = makeMetadata()
        let body = "# 标题\n\n正文一段。"
        let composed = TranscriptionMarkdownWriter.compose(metadata: md, body: body)
        XCTAssertTrue(composed.hasPrefix("---\n"))
        XCTAssertTrue(composed.contains("\n---\n"))
        XCTAssertTrue(composed.contains("# 标题"))
        XCTAssertTrue(composed.contains("正文一段。"))
    }

    func testWriteToDisk() throws {
        let md = makeMetadata()
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky-md-writer-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try TranscriptionMarkdownWriter.write(metadata: md, body: "原文。", to: tmpURL)

        let content = try String(contentsOf: tmpURL, encoding: .utf8)
        XCTAssertTrue(content.contains("title: 测试标题"))
        XCTAssertTrue(content.contains("原文。"))
    }
}
