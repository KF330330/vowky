import XCTest
@testable import VowKy

@MainActor
final class AnchoredParagraphSplitterTests: XCTestCase {

    // MARK: - 追加与锚定

    func test01_growth_appendsOnly() {
        let splitter = AnchoredParagraphSplitter()
        XCTAssertEqual(splitter.split(committed: "", partial: ""), .init(committed: [], partial: []))

        let first = splitter.split(committed: "", partial: "第一句到此。")
        XCTAssertEqual(first.partial, ["第一句到此。"])

        let second = splitter.split(committed: "", partial: "第一句到此。第二句还在说")
        XCTAssertEqual(second.partial, ["第一句到此。", "第二句还在说"])
    }

    func test02_punctuationDriftMerge_keptSplitInOriginalForm() {
        let splitter = AnchoredParagraphSplitter()
        _ = splitter.split(committed: "", partial: "第一点是项目进度。第二点是主要风险。")

        // 重解码漂移：句号变逗号，全量重切会并成一个大段
        let drifted = splitter.split(
            committed: "", partial: "第一点是项目进度，第二点是主要风险，第三点是预算控制。"
        )
        XCTAssertEqual(
            drifted.partial,
            ["第一点是项目进度。", "第二点是主要风险。", "第三点是预算控制。"],
            "已锚定句保持首次成句形态，只追加新句，不合并"
        )
    }

    func test03_boundarySentence_growsThenPromotes() {
        let splitter = AnchoredParagraphSplitter()
        // 边界句（无终止标点）不晋升，可继续长大
        XCTAssertEqual(splitter.split(committed: "", partial: "第三点是预算").partial, ["第三点是预算"])

        let grown = splitter.split(committed: "", partial: "第三点是预算控制。第四点搞定。")
        XCTAssertEqual(grown.partial, ["第三点是预算控制。", "第四点搞定。"])

        // 两句终结后均已锚定：漂移不再影响它们
        let drifted = splitter.split(committed: "", partial: "第三点是预算控制，第四点搞定，第五点继续。")
        XCTAssertEqual(drifted.partial, ["第三点是预算控制。", "第四点搞定。", "第五点继续。"])
    }

    // MARK: - partial → committed 交接

    func test04_handoffLineStructureChange_reclassifiedAsCommitted() {
        let splitter = AnchoredParagraphSplitter()
        // 预览期：冻结句一行 + 边界句一行
        let preview = splitter.split(committed: "", partial: "早上好各位。\n今天讲三件事")
        XCTAssertEqual(preview.partial, ["早上好各位。", "今天讲三件事"])

        // 交接：段最终稿一行逗号连写替换预览行；锚跨行归一化匹配
        let handoff = splitter.split(committed: "早上好各位，今天讲三件事。", partial: "")
        XCTAssertEqual(handoff.committed, ["早上好各位。", "今天讲三件事。"])
        XCTAssertEqual(handoff.partial, [])
    }

    func test05_anchorStraddlingBoundary_classifiedAsPartial() {
        let splitter = AnchoredParagraphSplitter()
        _ = splitter.split(committed: "", partial: "第三点是预算控制。")

        // 切段切在句中：句子内容一半在 committed、一半在 partial
        let straddled = splitter.split(committed: "第三点是预算控", partial: "制。第四点走起。")
        XCTAssertEqual(straddled.committed, [])
        XCTAssertEqual(straddled.partial, ["第三点是预算控制。", "第四点走起。"])
    }

    func test06_committedGrowth_appendsNewLine() {
        let splitter = AnchoredParagraphSplitter()
        XCTAssertEqual(
            splitter.split(committed: "第一段结束。", partial: "").committed,
            ["第一段结束。"]
        )
        let grown = splitter.split(committed: "第一段结束。\n第二段开始。", partial: "")
        XCTAssertEqual(grown.committed, ["第一段结束。", "第二段开始。"])
    }

    // MARK: - 兜底与边界情况

    func test07_wordDrift_truncatesAnchors_fallsBackToFreshSplit() {
        let splitter = AnchoredParagraphSplitter()
        _ = splitter.split(committed: "", partial: "今天天气很好。我们出发吧。")

        // 第二句词级漂移：锚从失配句起截断，剩余重切
        let drifted = splitter.split(committed: "", partial: "今天天气很好。他们出发了。")
        XCTAssertEqual(drifted.partial, ["今天天气很好。", "他们出发了。"])

        // 新句已重新锚定
        let appended = splitter.split(committed: "", partial: "今天天气很好。他们出发了。好的。")
        XCTAssertEqual(appended.partial, ["今天天气很好。", "他们出发了。", "好的。"])
    }

    func test08_driftedBoundaryPunctuation_strippedFromTail() {
        let splitter = AnchoredParagraphSplitter()
        _ = splitter.split(committed: "", partial: "第一点。")

        let drifted = splitter.split(committed: "", partial: "第一点，第二点。")
        XCTAssertEqual(drifted.partial, ["第一点。", "第二点。"])
        XCTAssertFalse(drifted.partial.contains { $0.hasPrefix("，") }, "漂移边界标点不应残留在句首")
    }

    func test09_purePunctuation_notPromoted_freshBehaviorPreserved() {
        let splitter = AnchoredParagraphSplitter()
        // 无锚可消费时保持旧行为：纯标点段原样输出（供 trivial 过滤层处理）
        XCTAssertEqual(splitter.split(committed: ".", partial: "").committed, ["."])

        let mixed = splitter.split(committed: "", partial: ". 你好。")
        XCTAssertEqual(mixed.partial, [".", "你好。"])

        // 纯标点句不晋升为锚；后续从内容句正常锚定
        let appended = splitter.split(committed: "", partial: ". 你好。再见。")
        XCTAssertEqual(appended.partial, ["你好。", "再见。"])
    }

    func test10_overlongCommaRun_fragmentsStableAcrossDrift() {
        let splitter = AnchoredParagraphSplitter()
        let unit = "苹果香蕉橘子葡萄西瓜，"
        let text1 = String(repeating: unit, count: 5)
        var chars = Array(text1)
        chars[21] = "。"  // 漂移：中段一个逗号变句号，全量重切会改变 breakOverlong 边界
        let text2 = String(chars)

        let first = splitter.split(committed: "", partial: text1)
        XCTAssertEqual(first.partial.count, 2, "55 字逗号连写应被超长兜底切成 2 片")

        let drifted = splitter.split(committed: "", partial: text2)
        XCTAssertEqual(drifted, first, "已锚定的超长片段不因标点漂移重排")
    }

    // MARK: - 有界重同步（词级漂移不拖垮后续锚）

    func test12_leadingInsertion_resyncKeepsAnchor() {
        let splitter = AnchoredParagraphSplitter()
        _ = splitter.split(committed: "", partial: "第一点是项目进度。")

        // 重解码在句首幻听出「嗯」：插入容忍，锚不失效、不合并
        let drifted = splitter.split(committed: "", partial: "嗯，第一点是项目进度。第二点是主要风险。")
        XCTAssertEqual(drifted.partial, ["嗯，", "第一点是项目进度。", "第二点是主要风险。"])
    }

    func test13_deadAnchorReplacedInPlace_laterAnchorsSurvive() {
        let splitter = AnchoredParagraphSplitter()
        _ = splitter.split(committed: "", partial: "今天讲三件事。周一开评审。周二发版本。")

        // 中间一句词级漂移（周一→周天）：死锚原位替换为新内容，后面的锚继续存活，
        // 不再把「周二发版本」拖进合并段重现
        let drifted = splitter.split(committed: "", partial: "今天讲三件事。周天开评审。周二发版本，周三上线。")
        XCTAssertEqual(
            drifted.partial,
            ["今天讲三件事。", "周天开评审。", "周二发版本。", "周三上线。"]
        )
    }

    func test14_wholesaleRewrite_fallsBackToFreshSplit() {
        let splitter = AnchoredParagraphSplitter()
        _ = splitter.split(committed: "", partial: "早上好。今天晴。")

        // 内容全变：重同步失败，截断全部锚，退回全量切分（旧行为兜底）
        let rewritten = splitter.split(committed: "", partial: "完全不同的内容，全部重写了。")
        XCTAssertEqual(rewritten.partial, ["完全不同的内容，全部重写了。"])
    }

    func test11_reset_clearsAnchors() {
        let splitter = AnchoredParagraphSplitter()
        _ = splitter.split(committed: "", partial: "第一句好。")
        splitter.reset()

        let after = splitter.split(committed: "", partial: "第一句好，第二句来。")
        XCTAssertEqual(after.partial, ["第一句好，第二句来。"], "reset 后无锚，退回全量切分")
    }
}
