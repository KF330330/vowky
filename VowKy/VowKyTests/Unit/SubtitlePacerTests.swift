import XCTest
@testable import VowKy

@MainActor
final class SubtitlePacerTests: XCTestCase {

    private func p(
        _ id: String,
        _ text: String,
        isPartial: Bool = true,
        translation: ParagraphTranslationState = .pending
    ) -> TranscriptParagraph {
        TranscriptParagraph(id: id, text: text, isPartial: isPartial, translation: translation)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test01_backlogAdvancesSequentially_noSkip() async {
        let pacer = SubtitlePacer(minDisplay: 0.15, linger: 0.05)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "句一。")])
        XCTAssertEqual(shown, ["句一。"])

        // 一次更新同时带来两个新句：不允许直接跳到最后
        pacer.ingest([p("c-0", "句一。"), p("c-1", "句二。"), p("p-0", "句三")])
        XCTAssertEqual(shown, ["句一。"], "minDisplay 未满不应立即前进")

        await waitUntil { shown == ["句一。", "句二。", "句三"] }
        XCTAssertEqual(shown, ["句一。", "句二。", "句三"], "应依序补播，不跳句")
    }

    func test02_sameSentenceGrowth_updatesInPlace() async {
        let pacer = SubtitlePacer(minDisplay: 0.1, linger: 0.05)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "今天")])
        pacer.ingest([p("p-0", "今天天气很好")])
        XCTAssertEqual(shown, ["今天", "今天天气很好"], "同句增长应原地刷新")

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(shown.count, 2, "无新句时不应有额外上屏")
    }

    func test03_timerDrivenAdvance_withoutFurtherIngest() async {
        let pacer = SubtitlePacer(minDisplay: 0.15, linger: 0.05)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "第一句。")])
        pacer.ingest([p("c-0", "第一句。"), p("p-0", "第二句")])
        XCTAssertEqual(shown, ["第一句。"])

        // 不再 ingest，靠内部定时器前进
        await waitUntil { shown.count == 2 }
        XCTAssertEqual(shown, ["第一句。", "第二句"])
    }

    func test04_translationArrival_refreshesDisplayedInPlace() async {
        let pacer = SubtitlePacer(minDisplay: 0.1, linger: 0.05)
        var lastShown: TranscriptParagraph?
        var emitCount = 0
        pacer.onDisplay = { lastShown = $0; emitCount += 1 }

        pacer.ingest([p("c-0", "Hello.")])
        pacer.ingest([p("c-0", "Hello.", translation: .translated("你好。"))])

        XCTAssertEqual(emitCount, 2)
        XCTAssertEqual(lastShown?.translation, .translated("你好。"))
    }

    func test05_burstBacklog_allShownInOrder_nothingDropped() async {
        let pacer = SubtitlePacer(minDisplay: 0.12, linger: 0.04)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "一。")])
        pacer.ingest([
            p("c-0", "一。"), p("c-1", "二。"), p("c-2", "三。"),
            p("c-3", "四。"), p("p-0", "五"),
        ])

        await waitUntil { shown.last == "五" }
        XCTAssertEqual(shown, ["一。", "二。", "三。", "四。", "五"], "绝不丢句，全部按序上屏")
    }

    func test06_unmatchedRewrite_jumpsToLatestWithoutReplay() async {
        let pacer = SubtitlePacer(minDisplay: 0.1, linger: 0.05)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "ABC")])
        // 当前句在新列表中完全消失（大改写）→ 跳到最新，不回放中间句
        pacer.ingest([p("c-0", "XYZ一。"), p("p-0", "XYZ二")])
        XCTAssertEqual(shown, ["ABC", "XYZ二"])
    }

    func test07_repeatedSentences_anchoredByPosition_noReplay() async {
        let pacer = SubtitlePacer(minDisplay: 0.05, linger: 0.02)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "好的。")])
        pacer.ingest([p("c-0", "好的。"), p("p-0", "好的。")])
        await waitUntil { shown.count == 2 }
        XCTAssertEqual(shown, ["好的。", "好的。"], "真实的重复句要播两次")

        // 同一列表反复 ingest（译文状态刷新会触发）：锚定在第二条，不应再回放
        pacer.ingest([p("c-0", "好的。"), p("p-0", "好的。")])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(shown.count, 2, "重复 ingest 不应回放:\(shown)")
    }

    func test09_punctuationDrift_matchedAsSameSentence_noJump() async {
        let pacer = SubtitlePacer(minDisplay: 0.05, linger: 0.02)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        // 预览重解码把「ありがとう。」修订为「ありがとうございました」：
        // 标点漂移不应被当成新句/大改写
        pacer.ingest([p("p-0", "ありがとう。")])
        pacer.ingest([p("p-0", "ありがとうございました"), p("p-1", "次の文")])
        await waitUntil { shown.count == 3 }
        XCTAssertEqual(shown, ["ありがとう。", "ありがとうございました", "次の文"])
    }

    func test08_emptyIngest_keepsState_andResetClears() async {
        let pacer = SubtitlePacer(minDisplay: 0.1, linger: 0.05)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "内容")])
        pacer.ingest([])
        XCTAssertEqual(shown, ["内容"], "空列表应保持现状")

        pacer.reset()
        XCTAssertNil(pacer.displayed)

        // reset 后再来：当作首条直接上屏
        pacer.ingest([p("p-0", "新内容")])
        XCTAssertEqual(shown, ["内容", "新内容"])
    }
}
