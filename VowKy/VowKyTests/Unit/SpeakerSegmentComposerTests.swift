import XCTest
@testable import VowKy

final class SpeakerSegmentComposerTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ speaker: Int) -> SpeakerSegment {
        SpeakerSegment(start: start, end: end, speaker: speaker)
    }

    // MARK: - padAndClip

    func test01_padding_expandsBothSidesWhenGapIsWide() {
        let padded = SpeakerSegmentComposer.padAndClip(
            [seg(5.0, 8.0, 0)], totalDuration: 60
        )
        XCTAssertEqual(padded, [seg(4.75, 8.25, 0)])
    }

    func test02_padding_clampsToAudioBounds() {
        let padded = SpeakerSegmentComposer.padAndClip(
            [seg(0.1, 59.9, 0)], totalDuration: 60
        )
        XCTAssertEqual(padded, [seg(0, 60, 0)])
    }

    func test03_padding_doesNotCrossNeighborOriginalBoundary() {
        // 两段间隙 0.1s < 2×0.25s:各自扩到对方原始边界为止,互不吃进对方的话
        let padded = SpeakerSegmentComposer.padAndClip(
            [seg(1.0, 5.0, 0), seg(5.1, 9.0, 1)], totalDuration: 60
        )
        XCTAssertEqual(padded[0].end, 5.1, accuracy: 1e-9)
        XCTAssertEqual(padded[1].start, 5.0, accuracy: 1e-9)
    }

    func test04_padding_wideGapGetsFullPadding() {
        let padded = SpeakerSegmentComposer.padAndClip(
            [seg(1.0, 5.0, 0), seg(10.0, 12.0, 1)], totalDuration: 60
        )
        XCTAssertEqual(padded[0].end, 5.25, accuracy: 1e-9)
        XCTAssertEqual(padded[1].start, 9.75, accuracy: 1e-9)
    }

    func test05_padding_overlappingOriginalSegmentsKeptAsIs() {
        // pyannote 可产出重叠说话段:重叠侧不扩不裁,原样容忍
        let padded = SpeakerSegmentComposer.padAndClip(
            [seg(1.0, 6.0, 0), seg(5.0, 9.0, 1)], totalDuration: 60
        )
        XCTAssertEqual(padded[0].start, 0.75, accuracy: 1e-9)
        XCTAssertEqual(padded[0].end, 6.0, accuracy: 1e-9)   // 重叠,end 不动
        XCTAssertEqual(padded[1].start, 5.0, accuracy: 1e-9) // 重叠,start 不动
        XCTAssertEqual(padded[1].end, 9.25, accuracy: 1e-9)
    }

    // MARK: - renumberByFirstAppearance

    func test06_renumber_nonContiguousClusterIDs() {
        // 实测:引擎簇 id 可非连续(0,1,2,7)
        let renumbered = SpeakerSegmentComposer.renumberByFirstAppearance([
            seg(0, 1, 0), seg(1, 2, 1), seg(2, 3, 1), seg(3, 4, 2),
            seg(4, 5, 0), seg(5, 6, 7), seg(6, 7, 7), seg(7, 8, 2),
        ])
        XCTAssertEqual(renumbered.map(\.speaker), [1, 2, 2, 3, 1, 4, 4, 3])
    }

    func test07_distinctSpeakerCount() {
        XCTAssertEqual(
            SpeakerSegmentComposer.distinctSpeakerCount([seg(0, 1, 0), seg(1, 2, 7), seg(2, 3, 0)]),
            2
        )
        XCTAssertEqual(SpeakerSegmentComposer.distinctSpeakerCount([]), 0)
    }

    // MARK: - compose

    private let label: (Int) -> String = { "说话人 \($0)：" }

    func test08_compose_mergesConsecutiveSameSpeaker() {
        let text = SpeakerSegmentComposer.compose(
            [
                .init(speaker: 1, text: "第一段"),
                .init(speaker: 2, text: "第二段"),
                .init(speaker: 2, text: "第三段"),
                .init(speaker: 1, text: "第四段"),
            ],
            labelProvider: label
        )
        XCTAssertEqual(text, "说话人 1：第一段\n\n说话人 2：第二段\n第三段\n\n说话人 1：第四段")
    }

    func test09_compose_unmergedOneLinePerSegment() {
        let text = SpeakerSegmentComposer.compose(
            [
                .init(speaker: 1, text: "第一段"),
                .init(speaker: 1, text: "第二段"),
            ],
            labelProvider: label,
            mergeConsecutive: false
        )
        XCTAssertEqual(text, "说话人 1：第一段\n说话人 1：第二段")
    }

    func test10_compose_skipsEmptySegments() {
        let text = SpeakerSegmentComposer.compose(
            [
                .init(speaker: 1, text: "有话"),
                .init(speaker: 2, text: "   "),
                .init(speaker: 1, text: "又有话"),
            ],
            labelProvider: label
        )
        // 中间空段被跳过后,前后同为说话人 1,合并到一个标签下
        XCTAssertEqual(text, "说话人 1：有话\n又有话")
    }

    func test11_compose_allEmpty_returnsEmptyString() {
        XCTAssertEqual(
            SpeakerSegmentComposer.compose([.init(speaker: 1, text: "")], labelProvider: label),
            ""
        )
    }
}
