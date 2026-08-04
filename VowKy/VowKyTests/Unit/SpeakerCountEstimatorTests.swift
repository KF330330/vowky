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

    // MARK: - 簇总时长地板(2026-08-04 长录音防饱和)

    /// 造一个「长录音」簇:一条 longest 长段 + 若干 3s 段凑够 total
    private func cluster(_ spk: Int, at base: Double, longest: Double, total: Double) -> [DiarizeSegmentDTO] {
        var result = [seg(base, base + longest, spk)]
        var remaining = total - longest
        var cursor = base + longest + 1
        while remaining > 0 {
            let d = Swift.min(3.0, remaining)
            result.append(seg(cursor, cursor + d, spk))
            remaining -= d
            cursor += d + 1
        }
        return result
    }

    func test10_longRecording_floorDropsSmallShareFakes() {
        // 长录音(总语音 600s):两个真实大簇 + 三个过 2.0s 门槛但总时长小的漂移假簇
        // 地板 = min(30, 0.05×600) = 30s → 假簇(总 10~20s)被剔除 → 2
        let segments =
            cluster(0, at: 0, longest: 8, total: 290)
            + cluster(1, at: 700, longest: 6, total: 250)
            + cluster(2, at: 1400, longest: 2.5, total: 10)
            + cluster(3, at: 1500, longest: 3.0, total: 20)
            + cluster(4, at: 1600, longest: 2.2, total: 30 - 0.01)
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 2)
    }

    func test11_floorNeverEliminatesAllCandidates() {
        // 过门槛簇总时长全部低于地板:忽略地板,保留门槛候选(绝不估计为 0)
        // 总语音 ≈ 640s(碎段簇撑大地板),两个过门槛簇各仅 20s
        var segments = cluster(0, at: 0, longest: 3, total: 20) + cluster(1, at: 100, longest: 3, total: 20)
        var cursor: Double = 200
        for _ in 0..<666 {  // 0.9s 碎段,不过 1.0s 档(梯度已被 2.0s 命中,碎段簇不参选)
            segments.append(seg(cursor, cursor + 0.9, 9))
            cursor += 1
        }
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 2)
    }

    // MARK: - 质心合并与小簇保护(合成向量注入)

    /// 按段起点查簇 id → 返回该簇的合成向量(测试里每簇起点唯一)
    private func embedder(_ vectors: [Int: [Float]], startToSpk: [Double: Int]) -> ([(Double, Double)]) -> [Float]? {
        { ranges in
            guard let first = ranges.first, let spk = startToSpk[first.0] else { return nil }
            return vectors[spk]
        }
    }

    func test12_centroidMerge_collapsesSplitSpeaker() {
        // 4 个大簇都过门槛过地板,但 0/1 与 2/3 分别是同一真人被拆(质心距 ≈0)→ 2
        let segments = [
            seg(0, 6, 0), seg(10, 16, 1), seg(20, 26, 2), seg(30, 36, 3),
        ]
        let vectors: [Int: [Float]] = [
            0: [1, 0], 1: [0.995, 0.1], 2: [0, 1], 3: [0.1, 0.995],
        ]
        let embed = embedder(vectors, startToSpk: [0: 0, 10: 1, 20: 2, 30: 3])
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
    }

    func test13_smallClusterProtection_countsDistantQuietSpeaker() {
        // 长录音:两个大簇(不同人) + 一个被地板剔除的小簇(有 2.5s 可信长段,
        // 质心与两个大簇正交=很远)→ 少发言真人,计入 → 3
        let segments =
            cluster(0, at: 0, longest: 8, total: 300)
            + cluster(1, at: 700, longest: 6, total: 280)
            + [seg(1400, 1402.5, 2)]
        let vectors: [Int: [Float]] = [
            0: [1, 0, 0], 1: [0, 1, 0], 2: [0, 0, 1],
        ]
        let embed = embedder(vectors, startToSpk: [0: 0, 700: 1, 1400: 2])
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 3)
    }

    func test14_smallClusterNearKeptCentroid_isAbsorbed() {
        // 被剔除小簇质心贴近大簇 0(同一真人的漂移)→ 不计,交第二遍吞并 → 2
        let segments =
            cluster(0, at: 0, longest: 8, total: 300)
            + cluster(1, at: 700, longest: 6, total: 280)
            + [seg(1400, 1402.5, 2)]
        let vectors: [Int: [Float]] = [
            0: [1, 0, 0], 1: [0, 1, 0], 2: [0.99, 0.14, 0],
        ]
        let embed = embedder(vectors, startToSpk: [0: 0, 700: 1, 1400: 2])
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
    }

    func test15_twoProtectedClustersSameVoice_countOnce() {
        // 两个被剔除小簇同属一个安静真人(彼此质心 ≈0 距离)→ 只计一次 → 3
        let segments =
            cluster(0, at: 0, longest: 8, total: 300)
            + cluster(1, at: 700, longest: 6, total: 280)
            + [seg(1400, 1402.5, 2), seg(1500, 1502.2, 3)]
        let vectors: [Int: [Float]] = [
            0: [1, 0, 0], 1: [0, 1, 0], 2: [0, 0, 1], 3: [0, 0.1, 0.995],
        ]
        let embed = embedder(vectors, startToSpk: [0: 0, 700: 1, 1400: 2, 1500: 3])
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 3)
    }

    func test16_embeddingFailure_fallsBackToDurationOnly() {
        // 嵌入提取失败(闭包返回 nil):退化为纯时长判据,不合并不保护
        let segments = [seg(0, 6, 0), seg(10, 16, 1)]
        let result = SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: { _ in nil })
        XCTAssertEqual(result, 2)
    }

    func test17_shortRecordingBehaviorUnchangedByFloor() {
        // 短录音(总语音 11.4s)地板 ≈0.57s,不影响 08-02 的真实二人形状(纯时长路径)
        let segments = [
            seg(0.03, 0.59, 0), seg(7.03, 7.34, 0),
            seg(3.30, 4.82, 1), seg(27.84, 30.10, 1),
            seg(12.79, 15.17, 3), seg(9.68, 11.13, 3),
            seg(19.32, 20.79, 4), seg(24.65, 26.12, 4),
        ]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 2)
    }
}
