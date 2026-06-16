import XCTest
@testable import VowKy

final class BilingualTranscriptComposerTests: XCTestCase {

    private func paragraph(
        id: String = "c-0",
        _ text: String,
        _ state: ParagraphTranslationState
    ) -> TranscriptParagraph {
        TranscriptParagraph(id: id, text: text, isPartial: false, translation: state)
    }

    // MARK: - compose

    func test01_compose_translatedParagraphs_interleavedWithQuote() {
        let result = BilingualTranscriptComposer.compose(paragraphs: [
            paragraph(id: "c-0", "今天讨论产品方案。", .translated("Let's discuss the product plan today.")),
            paragraph(id: "c-1", "先看数据。", .translated("Let's look at the data first.")),
        ])
        XCTAssertEqual(result, """
        今天讨论产品方案。
        > Let's discuss the product plan today.

        先看数据。
        > Let's look at the data first.

        """)
    }

    func test02_compose_failedParagraph_keepsOriginalWithMarker() {
        let result = BilingualTranscriptComposer.compose(paragraphs: [
            paragraph("这句翻译失败了。", .failed("网络错误")),
        ])
        XCTAssertEqual(result, "这句翻译失败了。\n> \(LL("bilingual.export.translationFailed"))\n")
    }

    func test03_compose_skippedAndPendingParagraphs_originalOnly() {
        let result = BilingualTranscriptComposer.compose(paragraphs: [
            paragraph(id: "c-0", "同语言段落。", .skippedSameLanguage),
            paragraph(id: "c-1", "还没翻完的段落。", .pending),
        ])
        XCTAssertEqual(result, "同语言段落。\n\n还没翻完的段落。\n")
    }

    func test04_compose_multilineTranslation_everyLineQuoted() {
        let result = BilingualTranscriptComposer.compose(paragraphs: [
            paragraph("原文。", .translated("line one\nline two")),
        ])
        XCTAssertEqual(result, "原文。\n> line one\n> line two\n")
    }

    // MARK: - isReadyToWrite

    func test05_isReadyToWrite_pendingParagraphBlocks() {
        XCTAssertFalse(BilingualTranscriptComposer.isReadyToWrite([
            paragraph(id: "c-0", "翻完了。", .translated("Done.")),
            paragraph(id: "c-1", "还在翻。", .pending),
        ]))
    }

    func test06_isReadyToWrite_requiresAtLeastOneTranslation() {
        XCTAssertFalse(BilingualTranscriptComposer.isReadyToWrite([
            paragraph(id: "c-0", "同语言。", .skippedSameLanguage),
            paragraph(id: "c-1", "失败。", .failed("超时")),
        ]))
        XCTAssertTrue(BilingualTranscriptComposer.isReadyToWrite([
            paragraph(id: "c-0", "同语言。", .skippedSameLanguage),
            paragraph(id: "c-1", "成功。", .translated("OK.")),
        ]))
    }

    func test07_isReadyToWrite_emptyParagraphs_false() {
        XCTAssertFalse(BilingualTranscriptComposer.isReadyToWrite([]))
    }

    // MARK: - outputURL

    func test08_outputURL_insertsBilingualSuffixBeforeExtension() {
        let textURL = URL(fileURLWithPath: "/tmp/VowKy Recordings/VowKy Recording 2026-06-11 10.00.00.md")
        let result = BilingualTranscriptComposer.outputURL(for: textURL)
        XCTAssertEqual(result.lastPathComponent, "VowKy Recording 2026-06-11 10.00.00 (\(LL("bilingual.export.filenameSuffix"))).md")
        XCTAssertEqual(result.deletingLastPathComponent().path, "/tmp/VowKy Recordings")
    }
}
