import XCTest
@testable import VowKy

@MainActor
final class SubtitleDisplayRecorderTests: XCTestCase {

    private func p(
        _ id: String,
        _ text: String,
        isPartial: Bool = true,
        translation: ParagraphTranslationState = .pending
    ) -> TranscriptParagraph {
        TranscriptParagraph(id: id, text: text, isPartial: isPartial, translation: translation)
    }

    private func record(
        _ text: String,
        at offset: TimeInterval,
        translation: ParagraphTranslationState = .skippedSameLanguage
    ) -> SubtitleDisplayRecord {
        SubtitleDisplayRecord(firstShownOffset: offset, text: text, translation: translation)
    }

    /// 翻译关闭的配置（头部输出「翻译：关闭」行）
    private let translationOff = TranslationConfig.default

    // MARK: - record 归并

    func test01_record_mergesRefreshIntoLastRecord_appendsOnNewSentence() {
        let recorder = SubtitleDisplayRecorder()

        recorder.record(p("p-0", "今天"), isNewSentence: true, at: 3.2)
        recorder.record(p("p-0", "今天天气好"), isNewSentence: false, at: 4.0)
        // 同句定稿 id 从 p-0 变 c-0：归并只信 isNewSentence 信号，不受 id 影响
        recorder.record(
            p("c-0", "今天天气好。", translation: .translated("Nice weather today.")),
            isNewSentence: false, at: 4.6
        )
        recorder.record(p("p-0", "明天"), isNewSentence: true, at: 6.1)

        XCTAssertEqual(recorder.records.count, 2)
        XCTAssertEqual(recorder.records[0].firstShownOffset, 3.2, "刷新不应改写首次上屏时刻")
        XCTAssertEqual(recorder.records[0].text, "今天天气好。", "应保留离屏前最后展示的形态")
        XCTAssertEqual(recorder.records[0].translation, .translated("Nice weather today."))
        XCTAssertEqual(recorder.records[1].text, "明天")
        XCTAssertEqual(recorder.records[1].translation, .pending)
    }

    func test02_record_refreshOnEmpty_appendsDefensively() {
        let recorder = SubtitleDisplayRecorder()
        recorder.record(p("p-0", "内容"), isNewSentence: false, at: 1.0)
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(recorder.records[0].text, "内容")
    }

    // MARK: - compose

    func test03_compose_translated_quotedAndMultiline() {
        let result = SubtitleDisplayRecorder.compose(
            records: [record("原文。", at: 3, translation: .translated("line one\nline two"))],
            startedAt: nil,
            translation: translationOff
        )
        XCTAssertEqual(result, """
        # \(LL("subtitleLog.export.title"))

        - \(LL("subtitleLog.export.translationOff"))

        [00:03] 原文。
        > line one
        > line two

        """)
    }

    func test04_compose_fourTranslationStates() {
        let result = SubtitleDisplayRecorder.compose(
            records: [
                record("翻好了。", at: 3, translation: .translated("Done.")),
                record("没等到译文。", at: 7, translation: .pending),
                record("翻失败了。", at: 12, translation: .failed("网络错误")),
                record("同语言跳过。", at: 15, translation: .skippedSameLanguage),
            ],
            startedAt: nil,
            translation: translationOff
        )
        XCTAssertEqual(result, """
        # \(LL("subtitleLog.export.title"))

        - \(LL("subtitleLog.export.translationOff"))

        [00:03] 翻好了。
        > Done.

        [00:07] 没等到译文。
        > \(LL("subtitleLog.export.pendingTranslation"))

        [00:12] 翻失败了。
        > \(LL("bilingual.export.translationFailed"))

        [00:15] 同语言跳过。

        """)
    }

    func test05_compose_timestampFormatting() {
        let result = SubtitleDisplayRecorder.compose(
            records: [
                record("五秒。", at: 5),
                record("十二分半。", at: 754),
                record("负数钳零。", at: -3),
            ],
            startedAt: nil,
            translation: translationOff
        )
        XCTAssertTrue(result.contains("[00:05] 五秒。"), result)
        XCTAssertTrue(result.contains("[12:34] 十二分半。"), result)
        XCTAssertTrue(result.contains("[00:00] 负数钳零。"), result)
    }

    func test07_compose_header_translationOnAndOff() {
        var config = TranslationConfig.default
        config.enabled = true
        config.engine = .apple
        config.target = .zhHans

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let startedAt = formatter.date(from: "2026-07-08 10:00:00")!

        let on = SubtitleDisplayRecorder.compose(
            records: [record("原文。", at: 3, translation: .translated("Text."))],
            startedAt: startedAt,
            translation: config
        )
        XCTAssertTrue(
            on.contains("- \(LL("subtitleLog.export.recordingStartedAt", "2026-07-08 10:00:00"))"),
            on
        )
        XCTAssertTrue(
            on.contains("- \(LL("subtitleLog.export.translationOn", "apple", "简体中文"))"),
            on
        )

        let off = SubtitleDisplayRecorder.compose(
            records: [record("原文。", at: 3)],
            startedAt: nil,
            translation: translationOff
        )
        XCTAssertTrue(off.contains("- \(LL("subtitleLog.export.translationOff"))"), off)
        XCTAssertFalse(off.contains(LL("subtitleLog.export.recordingStartedAt", "")), off)
    }

    // MARK: - outputURL

    func test06_outputURL_insertsSuffixBeforeExtension() {
        let textURL = URL(fileURLWithPath: "/tmp/VowKy Recordings/VowKy Recording 2026-07-08 10.00.00.md")
        let result = SubtitleDisplayRecorder.outputURL(for: textURL)
        XCTAssertEqual(
            result.lastPathComponent,
            "VowKy Recording 2026-07-08 10.00.00 (\(LL("subtitleLog.export.filenameSuffix"))).md"
        )
        XCTAssertEqual(result.deletingLastPathComponent().path, "/tmp/VowKy Recordings")
    }
}
