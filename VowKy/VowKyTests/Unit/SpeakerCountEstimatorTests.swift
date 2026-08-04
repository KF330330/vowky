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
        // 长录音(并集 80s):4 个大簇都过门槛过地板,但 0/1 与 2/3 分别是
        // 同一真人被拆(质心距 ≈0)→ 2
        let segments = [
            seg(0, 20, 0), seg(30, 50, 1), seg(60, 80, 2), seg(90, 110, 3),
        ]
        let vectors: [Int: [Float]] = [
            0: [1, 0], 1: [0.995, 0.1], 2: [0, 1], 3: [0.1, 0.995],
        ]
        let embed = embedder(vectors, startToSpk: [0: 0, 30: 1, 60: 2, 90: 3])
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
    }

    func test13_droppedDistantSmallCluster_isNotResurrected() {
        // 长录音:两个大簇 + 一个被地板剔除、质心与两大簇都远的小簇。
        // 「小簇保护」已否决(实测真人 0.59 与噪声簇 0.68 区间倒挂,保护只会造幻影):
        // 被剔除簇一律交第二遍吞并 → 2;安静真人由 UI 手动人数选项兜底
        let segments =
            cluster(0, at: 0, longest: 8, total: 300)
            + cluster(1, at: 700, longest: 6, total: 280)
            + [seg(1400, 1402.5, 2)]
        let vectors: [Int: [Float]] = [
            0: [1, 0, 0], 1: [0, 1, 0], 2: [0, 0, 1],
        ]
        let embed = embedder(vectors, startToSpk: [0: 0, 700: 1, 1400: 2])
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
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

    func test15_multipleDroppedClusters_neverInflateEstimate() {
        // 多个被剔除小簇(无论质心多远)都不增加估计值:估计只由保留簇合并结果决定 → 2
        let segments =
            cluster(0, at: 0, longest: 8, total: 300)
            + cluster(1, at: 700, longest: 6, total: 280)
            + [seg(1400, 1402.5, 2), seg(1500, 1502.2, 3)]
        let vectors: [Int: [Float]] = [
            0: [1, 0, 0], 1: [0, 1, 0], 2: [0, 0, 1], 3: [0, 0.1, 0.995],
        ]
        let embed = embedder(vectors, startToSpk: [0: 0, 700: 1, 1400: 2, 1500: 3])
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
    }

    func test16_embeddingFailure_fallsBackToDurationOnly() {
        // 长录音上嵌入提取失败(闭包返回 nil):退化为纯时长判据,不合并
        let segments = [seg(0, 40, 0), seg(50, 90, 1)]
        let result = SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: { _ in nil })
        XCTAssertEqual(result, 2)
    }

    // MARK: - codex review 修复(2026-08-04):取样上限/重叠排除/NaN/短录音地板

    func test18_centroidSampling_respectsBudgetCap() {
        // 单段 100s 的超长独白簇:送提取的音频总时长必须 ≤ 15s(截断,不整段灌入)
        let segments = [seg(0, 100, 0), seg(200, 210, 1)]
        var requested: [Double] = []
        let embed: ([(Double, Double)]) -> [Float]? = { ranges in
            requested.append(ranges.reduce(0) { $0 + ($1.1 - $1.0) })
            return ranges.first!.0 < 100 ? [1, 0] : [0, 1]
        }
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
        for total in requested {
            XCTAssertLessThanOrEqual(total, SpeakerCountEstimator.centroidMaxTotalDuration + 0.001)
        }
    }

    func test19_centroidSampling_excludesOverlapWithOtherClusters() {
        // 簇 0=(0,40) 簇 1=(35,75) 重叠 5s(并集 75s):各自质心只取非重叠部分
        // (混合波形会让质心趋同),且按 15s 预算截断
        let segments = [seg(0, 40, 0), seg(35, 75, 1)]
        var recorded: [[(Double, Double)]] = []
        let embed: ([(Double, Double)]) -> [Float]? = { ranges in
            recorded.append(ranges)
            return ranges.first!.0 < 35 ? [1, 0] : [0, 1]
        }
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
        let flat = recorded.flatMap { $0 }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(flat.count, 2)
        XCTAssertEqual(flat[0].0, 0, accuracy: 0.001)
        XCTAssertEqual(flat[0].1, 15, accuracy: 0.001)   // (0,35) 截到预算 15s
        XCTAssertEqual(flat[1].0, 40, accuracy: 0.001)
        XCTAssertEqual(flat[1].1, 55, accuracy: 0.001)   // (40,75) 截到预算 15s
    }

    func test20_fullyOverlappedCluster_getsNoCentroid_notMerged() {
        // 簇 1 完全被簇 0 覆盖(并集 100s):无非重叠音频 → 无质心 → 不合并
        // (闭包恒返回相同向量,若质心被误算会并成 1;期望 2)
        let segments = [seg(0, 40, 0), seg(60, 100, 0), seg(0, 40, 1)]
        let embed: ([(Double, Double)]) -> [Float]? = { _ in [1, 0] }
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
    }

    func test21_nanEmbedding_treatedAsExtractionFailure() {
        // 保留簇嵌入含 NaN:视为提取失败(该簇不参与合并按独立计),不得让距离计算被 NaN 污染。
        // 长录音(并集 60s)三个保留簇:0/1 向量相同应合并,2 为 NaN → 2(若 NaN 被放行,行为未定义)
        let segments = [seg(0, 20, 0), seg(30, 50, 1), seg(60, 80, 2)]
        let vectors: [Int: [Float]] = [
            0: [1, 0, 0], 1: [0.995, 0.1, 0], 2: [Float.nan, 0, 1],
        ]
        let embed = embedder(vectors, startToSpk: [0: 0, 30: 1, 60: 2])
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
    }

    func test22_shortRecording_floorInactive_keepsQuietSpeaker() {
        // codex #4 场景:22s 短句对话,主说话人 15×1.4s(总 21s),少发言真人单段 1.0s。
        // 地板若启用会是 1.1s > 1.0s 淘汰真人;60s 以下地板恒 0,旧行为=2
        var segments: [DiarizeSegmentDTO] = []
        var cursor: Double = 0
        for _ in 0..<15 {
            segments.append(seg(cursor, cursor + 1.4, 0))
            cursor += 2
        }
        segments.append(seg(40, 41.0, 1))
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 2)
    }

    // MARK: - codex 二审修复(2026-08-04):并集时长/短录音不合并/碎片不提声纹

    func test23_overlapDoesNotInflateSpanPastActivation() {
        // codex 二审 #2 场景:59s 主簇 + 与其重叠的 2.5s 真人簇,各簇累加 61.5s 会虚高
        // 翻过 60s 门槛 → 地板 3.1s 淘汰真人;并集时长 59s < 60s → 地板不启用 → 2
        let segments = [seg(0, 59, 0), seg(10, 12.5, 1)]
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments), 2)
    }

    func test24_shortRecording_centroidMergeDisabled() {
        // 短录音(并集 40s):质心合并与地板同门槛,不启用——闭包不得被调用,
        // 即便两簇向量相同也不合并 → 2
        let segments = [seg(0, 20, 0), seg(30, 50, 1)]
        var called = 0
        let embed: ([(Double, Double)]) -> [Float]? = { _ in
            called += 1
            return [1, 0]
        }
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
        XCTAssertEqual(called, 0, "短录音不得触发质心提取")
    }

    func test25_subSecondPiecesAfterOverlapRemoval_noCentroid() {
        // codex 二审 #3:簇 1 过门槛(原段 2.0s)但重叠剔除后仅剩 0.9s 碎片——
        // 碎片声纹不可靠,不得提质心;闭包恒同向量,若碎片被提会并成 1 → 期望 2
        let segments = [
            seg(0, 40, 0), seg(50, 71, 0),            // 并集 61.9s,门槛启用
            seg(38.9, 40.9, 1), seg(58.9, 60.9, 1),   // 剔除重叠后仅 (40,40.9)=0.9s
        ]
        let embed: ([(Double, Double)]) -> [Float]? = { _ in [1, 0] }
        XCTAssertEqual(SpeakerCountEstimator.estimate(segments: segments, embeddingForRanges: embed), 2)
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
