import XCTest
@testable import VowKy

final class SpeechAnalyzerTextCleanerTests: XCTestCase {

    // MARK: - clean

    func test01_removesSpaceBeforeCJKPunctuation() {
        XCTAssertEqual(
            SpeechAnalyzerTextCleaner.clean("今天天气很好 ，适合出门 。"),
            "今天天气很好，适合出门。"
        )
    }

    func test02_removesSpaceBetweenHanAndDigit() {
        XCTAssertEqual(SpeechAnalyzerTextCleaner.clean("第 10页"), "第10页")
        XCTAssertEqual(SpeechAnalyzerTextCleaner.clean("共 3 章"), "共3章")
    }

    func test03_keepsEnglishWordSpacing() {
        XCTAssertEqual(
            SpeechAnalyzerTextCleaner.clean("我在用 GitHub Actions 部署"),
            "我在用 GitHub Actions 部署"
        )
    }

    func test04_pureEnglishUntouched() {
        let english = "It costs 23 dollars , really ."
        XCTAssertEqual(SpeechAnalyzerTextCleaner.clean(english), english)
    }

    func test05_collapsesRepeatedSpaces() {
        XCTAssertEqual(SpeechAnalyzerTextCleaner.clean("你好  世界"), "你好 世界")
    }

    func test06_emptyString() {
        XCTAssertEqual(SpeechAnalyzerTextCleaner.clean(""), "")
    }

    // MARK: - assembleParagraphs

    private func piece(_ text: String, _ start: Double, _ end: Double) -> SpeechAnalyzerTextCleaner.TimedText {
        .init(text: text, start: start, end: end)
    }

    func test07_insertsNewlineAtLongGap() {
        let output = SpeechAnalyzerTextCleaner.assembleParagraphs([
            piece("第一句。", 0, 3),
            piece("第二句。", 3.5, 6),      // 间隙 0.5s < 1.5s → 拼接
            piece("新段落。", 8.0, 10),     // 间隙 2.0s > 1.5s → 换行
        ])
        XCTAssertEqual(output, "第一句。第二句。\n新段落。")
    }

    func test08_skipsEmptyPiecesAndTrimsEdges() {
        let output = SpeechAnalyzerTextCleaner.assembleParagraphs([
            piece("", 0, 1),
            piece(" Hello world", 1.2, 3),
        ])
        XCTAssertEqual(output, "Hello world")
    }

    func test09_emptyInput() {
        XCTAssertEqual(SpeechAnalyzerTextCleaner.assembleParagraphs([]), "")
    }
}
