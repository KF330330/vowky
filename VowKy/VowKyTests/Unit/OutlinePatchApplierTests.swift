import XCTest
@testable import VowKy

final class OutlinePatchApplierTests: XCTestCase {

    // MARK: - Happy path

    func testAppliesSingleHeading() {
        let raw = "开始今天的会议。我们先回顾 OKR。然后讨论人事。"
        let json = """
        {
          "version": 1,
          "operations": [
            {
              "kind": "heading",
              "level": 1,
              "text": "会议纪要",
              "anchor": { "before": "", "occurrence": 1 }
            },
            {
              "kind": "heading",
              "level": 2,
              "text": "OKR 回顾",
              "anchor": { "before": "开始今天的会议。" }
            }
          ]
        }
        """

        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)

        XCTAssertEqual(result.appliedCount, 2)
        XCTAssertTrue(result.markdown.contains("# 会议纪要"))
        XCTAssertTrue(result.markdown.contains("## OKR 回顾"))
        XCTAssertTrue(result.markdown.contains("我们先回顾 OKR。"))
        // 原文一字未改：去掉 heading 行后应包含原文片段
        XCTAssertTrue(result.markdown.contains("开始今天的会议。"))
    }

    func testRawTextPreservedExactly() {
        let raw = "句子甲。句子乙。句子丙。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "level": 2, "text": "分段",
              "anchor": { "before": "句子甲。" } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)

        // 拼回原文（剔除所有非原文字符）后应等于 raw
        var stripped = result.markdown
        stripped = stripped.replacingOccurrences(of: "## 分段", with: "")
        stripped = stripped.replacingOccurrences(of: "\n", with: "")
        XCTAssertEqual(stripped, raw)
    }

    // MARK: - Invalid JSON

    func testInvalidJSONFallsBackToRawText() {
        let raw = "hello world"
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: "{not valid json")
        XCTAssertEqual(result.markdown, raw)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testEmptyResponseFallsBackToRawText() {
        let raw = "hello"
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: "")
        XCTAssertEqual(result.markdown, raw)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testNonObjectJSONFallsBack() {
        let raw = "hello"
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: "[1, 2, 3]")
        XCTAssertEqual(result.markdown, raw)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    // MARK: - Markdown fence

    func testStripsJSONFence() {
        let raw = "原文一段。原文二段。"
        let json = """
        ```json
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "level": 1, "text": "标题",
              "anchor": { "before": "原文一段。" } }
          ]
        }
        ```
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertTrue(result.markdown.contains("# 标题"))
    }

    func testStripsBareFence() {
        let raw = "原文。"
        let json = """
        ```
        { "version": 1, "operations": [
          { "kind": "heading", "level": 1, "text": "T", "anchor": { "before": "原文。" } } ] }
        ```
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 1)
    }

    // MARK: - Anchor not found

    func testAnchorNotFoundProducesWarning() {
        let raw = "实际内容。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "level": 1, "text": "X",
              "anchor": { "before": "幻觉文字" } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.markdown, raw)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("anchor.before 未找到") }))
    }

    // MARK: - Occurrence handling

    func testOccurrenceSelectsCorrectMatch() {
        let raw = "abc。def。abc。ghi。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "level": 2, "text": "H2",
              "anchor": { "before": "abc。", "occurrence": 2 } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 1)
        // 第 2 次出现 "abc。" 之后插入 → "abc。def。abc。\n## H2\nghi。"
        // 也即 "## H2" 应该出现在 "ghi" 之前
        let h2Range = result.markdown.range(of: "## H2")
        let ghiRange = result.markdown.range(of: "ghi。")
        XCTAssertNotNil(h2Range)
        XCTAssertNotNil(ghiRange)
        if let h2Range, let ghiRange {
            XCTAssertLessThan(h2Range.lowerBound, ghiRange.lowerBound)
        }
    }

    func testOccurrenceFallsBackWhenMissing() {
        let raw = "abc。def。ghi。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "level": 1, "text": "T",
              "anchor": { "before": "abc。", "occurrence": 5 } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("回退到第 1 次") }))
    }

    // MARK: - Anchor empty = document start

    func testEmptyAnchorMeansDocumentStart() {
        let raw = "正文开始。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "level": 1, "text": "Top",
              "anchor": { "before": "" } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertTrue(result.markdown.hasPrefix("# Top"))
    }

    // MARK: - Same-position overlap

    func testSamePositionParagraphBreakAndHeading() {
        let raw = "甲段。乙段。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "paragraph_break", "anchor": { "before": "甲段。" } },
            { "kind": "heading", "level": 2, "text": "Mid", "anchor": { "before": "甲段。" } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        // 同位置：paragraph_break 应在 heading 前；最终连续 \n 折叠到 2 个
        XCTAssertTrue(result.markdown.contains("## Mid"))
        XCTAssertTrue(result.markdown.contains("甲段。"))
        XCTAssertTrue(result.markdown.contains("乙段。"))
        // 连续 \n 不超过 2
        XCTAssertFalse(result.markdown.contains("\n\n\n"))
    }

    func testMultipleHeadingsSamePositionKeepsFirst() {
        let raw = "甲。乙。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "level": 1, "text": "First", "anchor": { "before": "甲。" } },
            { "kind": "heading", "level": 2, "text": "Second", "anchor": { "before": "甲。" } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertTrue(result.markdown.contains("# First"))
        XCTAssertFalse(result.markdown.contains("## Second"))
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("同位置出现多个 heading") }))
    }

    // MARK: - Schema rejection

    func testUnknownKindIsDiscarded() {
        let raw = "原文。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "delete", "anchor": { "before": "原文。" } },
            { "kind": "rewrite", "text": "改写", "anchor": { "before": "原文。" } },
            { "kind": "heading", "level": 1, "text": "OK", "anchor": { "before": "原文。" } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertTrue(result.markdown.contains("# OK"))
        XCTAssertEqual(
            result.warnings.filter { $0.contains("未知 operation kind") }.count,
            2
        )
    }

    func testHeadingMissingFieldsIsDiscarded() {
        let raw = "原文。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "anchor": { "before": "原文。" } },
            { "kind": "heading", "level": 9, "text": "X", "anchor": { "before": "原文。" } },
            { "kind": "heading", "level": 2, "text": "   ", "anchor": { "before": "原文。" } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.markdown, raw)
    }

    func testOperationMissingAnchorIsDiscarded() {
        let raw = "原文。"
        let json = """
        { "version": 1, "operations": [ { "kind": "heading", "level": 1, "text": "X" } ] }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("anchor.before") }))
    }

    // MARK: - Multiple headings in order

    func testMultipleHeadingsAppliedInTextOrder() {
        let raw = "A段。B段。C段。D段。"
        let json = """
        {
          "version": 1,
          "operations": [
            { "kind": "heading", "level": 1, "text": "T1", "anchor": { "before": "A段。" } },
            { "kind": "heading", "level": 2, "text": "T2", "anchor": { "before": "B段。" } },
            { "kind": "heading", "level": 3, "text": "T3", "anchor": { "before": "C段。" } }
          ]
        }
        """
        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 3)

        let t1 = result.markdown.range(of: "# T1")!
        let t2 = result.markdown.range(of: "## T2")!
        let t3 = result.markdown.range(of: "### T3")!
        XCTAssertLessThan(t1.lowerBound, t2.lowerBound)
        XCTAssertLessThan(t2.lowerBound, t3.lowerBound)
    }

    // MARK: - Long text smoke

    func testLongTextManyHeadings() {
        // 构造 ~5000 字符的文本，每 250 字符插一个 heading
        var raw = ""
        let chunk = String(repeating: "测", count: 250)
        for i in 0..<20 {
            raw += chunk + "。\(i)。"
        }

        var ops: [String] = []
        for i in 0..<20 {
            // 每个 chunk 后面跟着 "。{i}。"，这是唯一的 anchor
            let anchor = "。\(i)。"
            ops.append("""
            { "kind": "heading", "level": 2, "text": "Section \(i)",
              "anchor": { "before": "\(anchor)" } }
            """)
        }
        let json = "{ \"version\": 1, \"operations\": [ \(ops.joined(separator: ",")) ] }"

        let result = OutlinePatchApplier.apply(rawText: raw, aiResponse: json)
        XCTAssertEqual(result.appliedCount, 20)
        for i in 0..<20 {
            XCTAssertTrue(result.markdown.contains("## Section \(i)"))
        }
        XCTAssertFalse(result.markdown.contains("\n\n\n"))
    }

    // MARK: - Newline collapsing

    func testCollapseExcessNewlines() {
        let input = "a\n\n\n\nb\n\nc\n\n\n\n\n\nd"
        let collapsed = OutlinePatchApplier.collapseExcessNewlines(input)
        XCTAssertEqual(collapsed, "a\n\nb\n\nc\n\nd")
    }

    // MARK: - String helper

    func testNthOccurrenceUpperBoundBasics() {
        let s = "abcXabcXabc"
        XCTAssertEqual(s.nthOccurrenceUpperBound(of: "abc", occurrence: 1), s.index(s.startIndex, offsetBy: 3))
        XCTAssertEqual(s.nthOccurrenceUpperBound(of: "abc", occurrence: 2), s.index(s.startIndex, offsetBy: 7))
        XCTAssertEqual(s.nthOccurrenceUpperBound(of: "abc", occurrence: 3), s.endIndex)
        XCTAssertNil(s.nthOccurrenceUpperBound(of: "abc", occurrence: 4))
        XCTAssertNil(s.nthOccurrenceUpperBound(of: "", occurrence: 1))
        XCTAssertNil(s.nthOccurrenceUpperBound(of: "abc", occurrence: 0))
    }
}
