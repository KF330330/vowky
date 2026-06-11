import XCTest
@testable import VowKy

final class SentenceSplitterTests: XCTestCase {

    // MARK: - 终止标点切分

    func test01_chineseSentences_splitAtTerminalPunctuation() {
        XCTAssertEqual(
            SentenceSplitter.splitSentences("今天天气不错。我们出去走走吧！好不好？"),
            ["今天天气不错。", "我们出去走走吧！", "好不好？"]
        )
    }

    func test02_englishSentences_splitAtPeriodAndQuestionMark() {
        XCTAssertEqual(
            SentenceSplitter.splitSentences("Hello world. How are you? I am fine"),
            ["Hello world.", "How are you?", "I am fine"]
        )
    }

    func test03_trailingPartialSentence_keptAsLastPiece() {
        XCTAssertEqual(
            SentenceSplitter.splitSentences("第一句说完了。第二句还没说完"),
            ["第一句说完了。", "第二句还没说完"]
        )
    }

    func test04_decimalAndDomain_notSplit() {
        XCTAssertEqual(
            SentenceSplitter.splitSentences("圆周率是3.14对吧。请访问vowky.com查看。"),
            ["圆周率是3.14对吧。", "请访问vowky.com查看。"]
        )
    }

    func test05_consecutiveMarks_treatedAsOneRun() {
        XCTAssertEqual(
            SentenceSplitter.splitSentences("真的吗？！我不信……他说的。"),
            ["真的吗？！", "我不信……", "他说的。"]
        )
    }

    func test06_semicolons_splitBothWidths() {
        XCTAssertEqual(
            SentenceSplitter.splitSentences("先做这个；再做那个; then done."),
            ["先做这个；", "再做那个;", "then done."]
        )
    }

    func test07_emptyAndWhitespace_returnEmpty() {
        XCTAssertEqual(SentenceSplitter.splitSentences(""), [])
        XCTAssertEqual(SentenceSplitter.splitSentences("   \n  "), [])
    }

    func test08_singlePunctuationOnly_kept() {
        // SenseVoice 噪声段可能只输出一个句点，保持原样交给 isTrivialText 跳过翻译
        XCTAssertEqual(SentenceSplitter.splitSentences("."), ["."])
    }

    // MARK: - 超长兜底

    func test09_overlongWithCommas_breaksAtLastClauseBreaker() {
        let part1 = String(repeating: "前", count: 30)
        let part2 = String(repeating: "后", count: 30)
        let text = part1 + "，" + part2
        XCTAssertEqual(
            SentenceSplitter.splitSentences(text, maxLength: 50),
            [part1 + "，", part2]
        )
    }

    func test10_overlongWithoutBreakers_hardCutAtMaxLength() {
        let text = String(repeating: "字", count: 120)
        let pieces = SentenceSplitter.splitSentences(text, maxLength: 50)
        XCTAssertEqual(pieces.map(\.count), [50, 50, 20])
        XCTAssertEqual(pieces.joined(), text)
    }

    func test11_overlongEnglish_breaksAtLastSpace() {
        let words = Array(repeating: "word", count: 14).joined(separator: " ")  // 69 字符
        let pieces = SentenceSplitter.splitSentences(words, maxLength: 50)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 50 })
        XCTAssertTrue(pieces.allSatisfy { $0.hasPrefix("word") && $0.hasSuffix("word") },
                      "应在空格处断行，不应切碎单词：\(pieces)")
    }

    func test12_shortSentences_neverTouchedByFallback() {
        XCTAssertEqual(
            SentenceSplitter.splitSentences("短句，带逗号但不超长"),
            ["短句，带逗号但不超长"]
        )
    }
}
