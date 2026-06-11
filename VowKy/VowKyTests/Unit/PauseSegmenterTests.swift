import XCTest
@testable import VowKy

final class PauseSegmenterTests: XCTestCase {

    // MARK: - 正常停顿切分

    func test01_cjkTokens_splitAtPauseGap() {
        let tokens = ["今", "日", "の", "天", "気", "は", "い", "い", "で", "す", "ね",
                      "君", "は", "ど", "う", "思", "い", "ま", "す", "か"]
        // 前 11 个 token 间隔 0.2s；「ね」→「君」之间跳 1.0s（≥0.8 阈值）
        var timestamps: [Float] = (0..<11).map { Float($0) * 0.2 }
        timestamps += (0..<9).map { 3.0 + Float($0) * 0.2 }
        XCTAssertEqual(
            PauseSegmenter.split(text: tokens.joined(), tokens: tokens, timestamps: timestamps),
            ["今日の天気はいいですね", "君はどう思いますか"]
        )
    }

    func test02_textWithSpacesBetweenTokens_aligned() {
        // SenseVoice 会在 CJK token 间插空格（截图实证），对齐需容忍
        XCTAssertEqual(
            PauseSegmenter.split(
                text: "今日 の 天気",
                tokens: ["今日", "の", "天気"],
                timestamps: [0.0, 0.3, 1.5]
            ),
            ["今日 の", "天気"]
        )
    }

    func test03_bpeTokensWithUnderscoreMarker_aligned() {
        XCTAssertEqual(
            PauseSegmenter.split(
                text: "hello world goodbye",
                tokens: ["\u{2581}hello", "\u{2581}world", "\u{2581}goodbye"],
                timestamps: [0.0, 0.4, 2.0]
            ),
            ["hello world", "goodbye"]
        )
    }

    func test04_specialTokens_skipped() {
        XCTAssertEqual(
            PauseSegmenter.split(
                text: "你好",
                tokens: ["<|zh|>", "你", "好"],
                timestamps: [0.0, 0.1, 1.5]
            ),
            ["你", "好"]
        )
    }

    // MARK: - 优雅退化

    func test05_misalignedTokens_fallBackToWholeText() {
        XCTAssertEqual(
            PauseSegmenter.split(
                text: "你好",
                tokens: ["xx", "yy"],
                timestamps: [0.0, 2.0]
            ),
            ["你好"]
        )
    }

    func test06_emptyTimestamps_fallBackToWholeText() {
        XCTAssertEqual(
            PauseSegmenter.split(text: "完整文本", tokens: [], timestamps: []),
            ["完整文本"]
        )
    }

    func test07_countMismatch_fallBackToWholeText() {
        XCTAssertEqual(
            PauseSegmenter.split(text: "你好", tokens: ["你", "好"], timestamps: [0.0]),
            ["你好"]
        )
    }

    func test08_noGapAboveThreshold_singlePiece() {
        XCTAssertEqual(
            PauseSegmenter.split(
                text: "你好世界",
                tokens: ["你", "好", "世", "界"],
                timestamps: [0.0, 0.2, 0.4, 0.6]
            ),
            ["你好世界"]
        )
    }

    func test09_emptyText_returnsEmpty() {
        XCTAssertEqual(PauseSegmenter.split(text: "", tokens: [], timestamps: []), [])
    }

    // MARK: - segmentWithCut（冻结点）

    func test11_segmentWithCut_returnsLastBoundaryTime() {
        let result = PauseSegmenter.segmentWithCut(
            text: "你好世界再见",
            tokens: ["你", "好", "世", "界", "再", "见"],
            timestamps: [0.0, 0.2, 0.4, 0.6, 1.8, 2.0]
        )
        XCTAssertEqual(result.pieces, ["你好世界", "再见"])
        XCTAssertEqual(result.cutTime, 1.8, "cutTime 应是最后边界后首 token 的起始时刻")
        XCTAssertEqual(result.gapStart, 0.6, "gapStart 应是边界前最后一个 token 的起始时刻")
    }

    func test12_segmentWithCut_noBoundary_nilCutTime() {
        let result = PauseSegmenter.segmentWithCut(
            text: "你好",
            tokens: ["你", "好"],
            timestamps: [0.0, 0.2]
        )
        XCTAssertEqual(result.pieces, ["你好"])
        XCTAssertNil(result.cutTime)
    }

    func test13_segmentWithCut_misaligned_nilCutTime() {
        let result = PauseSegmenter.segmentWithCut(
            text: "你好",
            tokens: ["xx", "yy"],
            timestamps: [0.0, 2.0]
        )
        XCTAssertEqual(result.pieces, ["你好"])
        XCTAssertNil(result.cutTime)
    }

    func test10_customGapThreshold() {
        // 0.5s 间隔在默认 0.8 阈值下不切，在 0.4 阈值下切
        let tokens = ["你", "好"]
        let timestamps: [Float] = [0.0, 0.5]
        XCTAssertEqual(
            PauseSegmenter.split(text: "你好", tokens: tokens, timestamps: timestamps),
            ["你好"]
        )
        XCTAssertEqual(
            PauseSegmenter.split(text: "你好", tokens: tokens, timestamps: timestamps, minGap: 0.4),
            ["你", "好"]
        )
    }
}
