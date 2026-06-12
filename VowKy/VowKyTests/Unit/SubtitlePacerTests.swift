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

    func test10_rewrittenPartial_withEarlyPrefixTwin_doesNotReplayHistory() async {
        let pacer = SubtitlePacer(minDisplay: 0.05, linger: 0.02)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        // 首句「嗯。」恰好是当前 partial「嗯这」的归一化前缀
        let committed = [
            p("c-0", "嗯。", isPartial: false),
            p("c-1", "维基百科是一个百科全书。", isPartial: false),
            p("c-2", "它由志愿者共同编写。", isPartial: false),
            p("c-3", "内容可以自由使用。", isPartial: false),
            p("c-4", "今天我们来读一段。", isPartial: false),
        ]
        pacer.ingest([p("p-0", "嗯。")])
        pacer.ingest(committed + [p("p-0", "嗯这")])
        await waitUntil { shown.last == "嗯这" }
        let played = shown
        XCTAssertEqual(played.count, 6, "前置条件：六句依序上屏 \(shown)")

        // 预览重解码把当前 partial 整句改写：精确匹配失败后，
        // 前缀匹配不得回溯到远在前面的「嗯。」——否则历史五句全部重新入队加速重放
        pacer.ingest(committed + [p("p-0", "对吧")])
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(shown, played + ["对吧"], "不得回放任何已播历史句")
    }

    func test11_listShrinks_hintClampedToTail_stillLocatesInPlace() async {
        let pacer = SubtitlePacer(minDisplay: 0.05, linger: 0.02)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "第一句。")])
        pacer.ingest([p("p-0", "第一句。"), p("p-1", "第二句。"), p("p-2", "第三的开头")])
        await waitUntil { shown.last == "第三的开头" }
        XCTAssertEqual(shown.count, 3)

        // 重切分把前两句合并、列表收缩：hint 被钳制到新末尾后应原地命中当前句
        pacer.ingest([p("c-0", "第一句。第二句。", isPartial: false), p("p-0", "第三的开头继续")])
        XCTAssertEqual(shown.last, "第三的开头继续", "列表收缩后应原地刷新，不跳最新不回放")
        XCTAssertEqual(shown.count, 4)
    }

    func test13_backwardShiftAtToleranceBoundary_locatesInPlace_keepsBacklog() async {
        let pacer = SubtitlePacer(minDisplay: 0.05, linger: 0.02)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        pacer.ingest([p("p-0", "甲句。")])
        pacer.ingest([
            p("c-0", "甲句。"), p("c-1", "乙句。"), p("c-2", "丙句。"),
            p("c-3", "丁句。"), p("c-4", "戊句。"), p("p-0", "己句的开头"),
        ])
        await waitUntil { shown.last == "己句的开头" }
        XCTAssertEqual(shown.count, 6, "前置条件：六句依序上屏 \(shown)")

        // 重解码把前四句并成一段（列表不收缩，hint 不被钳制吸收）：
        // 当前句下标 5→2，回移恰好 = backTolerance，必须原地命中并继续补播——
        // 窗口再紧一格就会误判定位失败而跳最新，把排队中的句子静默丢掉
        pacer.ingest([
            p("c-0", "甲句。乙句。丙句。丁句。", isPartial: false),
            p("c-1", "戊句。", isPartial: false),
            p("p-0", "己句的开头继续"),
            p("p-1", "庚句。"),
            p("p-2", "辛句。"),
            p("p-3", "壬句。"),
        ])
        await waitUntil { shown.last == "壬句。" }
        XCTAssertEqual(
            Array(shown.suffix(4)),
            ["己句的开头继续", "庚句。", "辛句。", "壬句。"],
            "回移恰为容忍上限时应原地刷新并按序补播，不丢句：\(shown)"
        )
    }

    func test12_rewrittenPartial_matchingFarBackDuplicate_jumpsToLatestInstead() async {
        let pacer = SubtitlePacer(minDisplay: 0.05, linger: 0.02)
        var shown: [String] = []
        pacer.onDisplay = { shown.append($0.text) }

        // 口头禅「好的。」在远前方出现过，当前 partial 旧文本与之完全相同
        let committed = [
            p("c-0", "好的。", isPartial: false),
            p("c-1", "我们继续看下一节。", isPartial: false),
            p("c-2", "这里有三个要点。", isPartial: false),
            p("c-3", "先看第一个要点。", isPartial: false),
        ]
        pacer.ingest([p("p-0", "好的。")])
        pacer.ingest(committed + [p("p-0", "好的。")])
        await waitUntil { shown.count == 5 }
        let played = shown
        XCTAssertEqual(played.count, 5, "前置条件：五句依序上屏（含真实重复句）\(shown)")

        // 当前 partial 被整句改写：精确匹配不得命中远前方的重复句 → 跳到最新，不回放
        pacer.ingest(committed + [p("p-0", "完全换了内容")])
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(shown, played + ["完全换了内容"], "不得回放任何已播历史句")
    }
}
