import XCTest
@testable import VowKy

/// 自动人数两遍估计的第一遍统计。夹具形状取自 2026-08-02 实测:
/// 真实二人录音(阈值0.7 出 4 簇,假簇最长段 0.56s/1.47s)与四人基准(每簇最长段 ≥3.29s)。
final class SpeakerCountEstimatorTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ spk: Int) -> DiarizeSegmentDTO {
        DiarizeSegmentDTO(s: start, e: end, spk: spk)
    }

    func test01_emptySegments_returnsNil() {
        XCTAssertNil(SpeakerCountEstimator.estimate(segments: []))
    }

    func test02_allClustersBelowLowestBar_returnsNil() {
        // 全部短段(<1.0s):无法估计,沿用第一遍结果
        let segments = [seg(0, 0.5, 0), seg(1, 1.8, 1), seg(3, 3.6, 2)]
        XCTAssertNil(SpeakerCountEstimator.estimate(segments: segments))
    }

    func test03_realTwoSpeakerShape_estimatesTwo() {
        // 用户真实二人录音在阈值 0.7 下的簇形状:2 个真实簇(最长 2.26/2.38s)
        // + 2 个假簇(最长 0.56/1.47s)→ 2.0s 门槛数出 2
        let segments = [
            seg(0.03, 0.59, 0), seg(7.03, 7.34, 0),               // 假簇:最长 0.56s
            seg(3.30, 4.82, 1), seg(27.84, 30.10, 1),             // 真实:最长 2.26s
            seg(12.79, 15.17, 3), seg(9.68, 11.13, 3),            // 真实:最长 2.38s
            seg(19.32, 20.79, 4), seg(24.65, 26.12, 4),           // 假簇:最长 1.47s
        ]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 2)
    }

    func test04_fourSpeakerBenchmarkShape_estimatesFour() {
        // 四人基准:每簇都有 ≥3.29s 长段 → 4(与第一遍簇数一致,子进程跳过第二遍)
        let segments = [
            seg(0, 6.55, 0), seg(10, 13.73, 1), seg(20, 23.29, 2), seg(30, 34.25, 3),
        ]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 4)
    }

    func test05_ladderFallsBackTo1_5WhenNoClusterReaches2_0() {
        // 无簇过 2.0s,但有簇过 1.5s:用 1.5s 档,只数过档的簇
        let segments = [seg(0, 1.8, 0), seg(3, 3.9, 1)]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 1)
    }

    func test06_ladderFallsBackTo1_0AsLastResort() {
        let segments = [seg(0, 1.2, 0), seg(2, 3.1, 1), seg(5, 5.5, 2)]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 2)
    }

    func test07_reliabilityUsesLongestSingleSegmentNotClusterTotal() {
        // 簇 0 总时长 2.5s 但全是 0.5s 碎段(不可靠);簇 1 有 2.5s 单段(可靠)→ 1
        let segments = [
            seg(0, 0.5, 0), seg(1, 1.5, 0), seg(2, 2.5, 0), seg(3, 3.5, 0), seg(4, 4.5, 0),
            seg(6, 8.5, 1),
        ]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 1)
    }

    func test08_estimateNeverExceedsClusterCount() {
        // 单簇多长段:仍是 1
        let segments = [seg(0, 3, 0), seg(5, 9, 0), seg(12, 18, 0)]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 1)
    }

    func test09_barBoundaryIsInclusive() {
        // 恰好 2.0s 的段算过 2.0s 档
        let segments = [seg(0, 2.0, 0), seg(3, 4.47, 1)]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 1)
    }
}
