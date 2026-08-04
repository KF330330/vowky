import Foundation

/// 说话人自动人数的两遍估计——第一遍统计(纯函数,helper 子进程与测试共用)。
///
/// 根因:<1s 短段的声纹嵌入不可靠,阈值聚类会把它们聚成只含短段的「假说话人」簇;
/// 而不存在对短句对话和清晰长句都正确的全局阈值(2026-08-02 双音频扫描实测)。
/// 2026-08-04 一小时双人录音进一步实证:长录音里假簇/漂移簇也能攒出 ≥2s 长段,
/// 单靠「最长单段」判据会饱和(20 簇全部达标→估计失效)。
///
/// 对策(两级估计,2026-08-04 升级):
/// 1. 时长过滤:最长单段 ≥ 梯度门槛(真实说话人几乎总有长句)且簇总时长过地板
///    (地板随录音总语音时长伸缩,短录音自动退化为无地板,保持 08-02 行为)。
/// 2. 声纹质心合并:候选簇取最长几段音频提取 CAM++ 质心,距离近的候选簇合并计数
///    ——解决「主说话人被拆成多个大簇都被保留」(同上游「长簇定人数」通行做法的质心版)。
/// 3. 小簇保护:被过滤但有 ≥protectMinSegment 长段的簇,若质心距所有保留簇都很远,
///    视为「少发言的真人」计入,不强行吞并。
/// N 与第一遍簇数不同时,由调用方强制 num_clusters=N 重跑归属。
enum SpeakerCountEstimator {

    /// 「可靠簇」最长单段门槛梯度(秒),从严到宽,取第一个命中至少一个簇的门槛。
    /// 2.0s 实测分界最稳:真实二人录音(阈值0.7)真实说话人最长段 ≥2.26s,
    /// 假簇最长段 ≤1.47s;四人基准每簇最长段 ≥3.29s。宽档只在全篇短句时兜底。
    static let reliableDurationBars: [Double] = [2.0, 1.5, 1.0]

    /// 簇总时长地板 = min(cap, share × 全部语音时长)。
    /// 短录音 share 项趋近 0 → 地板失效(08-02 行为不变);长录音里
    /// 总时长占比过小的过门槛簇多为漂移假簇,先过滤再交质心合并兜底。
    /// 若地板淘汰了全部候选簇则忽略地板(绝不允许估计为 0)。
    static let durationFloorShare: Double = 0.05
    static let durationFloorCap: Double = 30.0

    /// 质心合并距离(余弦距离,1−cos):候选簇质心距离 ≤ 此值视为同一真人。
    /// 2026-08-04 校准:一小时双人录音同人跨簇质心距 ≤0.35,四人基准异人质心距 ≥0.62。
    static let centroidMergeDistance: Float = 0.45

    /// 小簇保护距离:被过滤簇质心距所有保留簇质心都 > 此值才算独立真人。
    /// 取值须 ≥ centroidMergeDistance;介于两者之间视为归属不明,交第二遍吞并。
    static let centroidProtectDistance: Float = 0.65

    /// 小簇保护的最长单段下限(秒):短于此的段声纹不可信,不参与保护判定。
    static let protectMinSegment: Double = 1.5

    /// 质心取样:每簇取最长的至多 3 段(各 ≥1.0s),拼接总时长封顶 15s。
    static let centroidMaxSegments = 3
    static let centroidMinSegmentDuration: Double = 1.0
    static let centroidMaxTotalDuration: Double = 15.0

    /// 从第一遍分离段估计真实说话人数。
    /// - Parameter embeddingForRanges: 对若干时间段(秒)的拼接音频提取声纹嵌入;
    ///   nil(或提取失败)时跳过质心合并与小簇保护,退化为纯时长判据。
    ///   helper 注入真实 CAM++ 提取;单测注入合成向量。
    /// - Parameter log: 诊断输出(簇统计/质心距离/合并决策),校准与线上排查用;nil 静默。
    /// 返回 nil = 无法估计(无段,或所有簇最长段 < 最宽门槛),调用方应沿用第一遍结果。
    /// 估计值恒 ≤ 第一遍簇数,只会减少假说话人,不会凭空增加。
    static func estimate(
        segments: [DiarizeSegmentDTO],
        embeddingForRanges: (([(Double, Double)]) -> [Float]?)? = nil,
        log: ((String) -> Void)? = nil
    ) -> Int? {
        // 簇级统计
        struct Cluster {
            var longest: Double = 0
            var total: Double = 0
            var segments: [(Double, Double)] = []
        }
        var clusters: [Int: Cluster] = [:]
        var totalSpeech: Double = 0
        for segment in segments {
            let duration = segment.e - segment.s
            totalSpeech += duration
            var cluster = clusters[segment.spk] ?? Cluster()
            cluster.longest = max(cluster.longest, duration)
            cluster.total += duration
            cluster.segments.append((segment.s, segment.e))
            clusters[segment.spk] = cluster
        }
        guard !clusters.isEmpty else { return nil }

        // 一级:最长单段梯度门槛
        var bar: Double?
        for candidate in reliableDurationBars where clusters.values.contains(where: { $0.longest >= candidate }) {
            bar = candidate
            break
        }
        guard let bar else { return nil }
        let barPassed = clusters.filter { $0.value.longest >= bar }

        // 一级:簇总时长地板(长录音防饱和;淘汰全部则忽略地板)
        let floor = Swift.min(durationFloorCap, durationFloorShare * totalSpeech)
        var kept = barPassed.filter { $0.value.total >= floor }
        if kept.isEmpty { kept = barPassed }

        if let log {
            log("totalSpeech=\(f1(totalSpeech))s bar=\(bar) floor=\(f1(floor))s clusters=\(clusters.count) barPassed=\(barPassed.count) kept=\(kept.count)")
            for (id, c) in clusters.sorted(by: { $0.key < $1.key }) {
                log("cluster \(id): longest=\(f1(c.longest))s total=\(f1(c.total))s segs=\(c.segments.count) \(kept[id] != nil ? "KEPT" : (barPassed[id] != nil ? "floor-dropped" : "bar-dropped"))")
            }
        }

        // 无嵌入注入:退化为纯时长判据
        guard let embeddingForRanges else { return kept.count }

        // 质心提取(取最长几段拼接;失败的簇不参与合并,按独立计)
        func centroid(of cluster: Cluster) -> [Float]? {
            var ranges: [(Double, Double)] = []
            var budget = centroidMaxTotalDuration
            for range in cluster.segments.sorted(by: { ($0.1 - $0.0) > ($1.1 - $1.0) }) {
                let duration = range.1 - range.0
                if ranges.count >= centroidMaxSegments || budget <= 0 { break }
                if duration < centroidMinSegmentDuration && !ranges.isEmpty { break }
                ranges.append(range)
                budget -= duration
            }
            guard !ranges.isEmpty, let embedding = embeddingForRanges(ranges), !embedding.isEmpty else { return nil }
            return embedding
        }

        let keptIDs = kept.keys.sorted()
        var centroids: [Int: [Float]] = [:]
        for id in keptIDs {
            centroids[id] = centroid(of: kept[id]!)
        }

        // 二级:保留簇质心 union-find 合并
        var parent: [Int: Int] = Dictionary(uniqueKeysWithValues: keptIDs.map { ($0, $0) })
        func root(_ id: Int) -> Int {
            var id = id
            while parent[id]! != id { id = parent[id]! }
            return id
        }
        for (i, a) in keptIDs.enumerated() {
            guard let ca = centroids[a] else { continue }
            for b in keptIDs.dropFirst(i + 1) {
                guard let cb = centroids[b] else { continue }
                let distance = cosineDistance(ca, cb)
                log?("centroid \(a)<->\(b): d=\(f2(distance))\(distance <= centroidMergeDistance ? " MERGE" : "")")
                if distance <= centroidMergeDistance {
                    parent[root(b)] = root(a)
                }
            }
        }
        let mergedRoots = Set(keptIDs.map(root))
        var estimated = mergedRoots.count
        log?("merged: \(kept.count) kept -> \(estimated) speakers")

        // 三级:小簇保护——被过滤但有可信长段、且距所有保留簇质心都远的簇,计为独立真人。
        // 保护簇之间也可能同人:彼此距离 ≤ 合并距离的只计一次。
        let keptCentroids = keptIDs.compactMap { centroids[$0] }
        var protectedCentroids: [[Float]] = []
        for (id, cluster) in clusters.sorted(by: { $0.key < $1.key }) {
            guard kept[id] == nil, cluster.longest >= protectMinSegment else { continue }
            guard let c = centroid(of: cluster) else { continue }
            let minDistance = keptCentroids.map { cosineDistance(c, $0) }.min() ?? 2
            log?("protect? cluster \(id): minDistToKept=\(f2(minDistance)) \(minDistance > centroidProtectDistance ? "FAR" : "near, absorbed")")
            guard minDistance > centroidProtectDistance else { continue }
            let sameAsProtected = protectedCentroids.contains { cosineDistance(c, $0) <= centroidMergeDistance }
            if !sameAsProtected {
                protectedCentroids.append(c)
                estimated += 1
                log?("protect: cluster \(id) counted as independent speaker")
            }
        }
        return estimated
    }

    private static func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func f2(_ v: Float) -> String { String(format: "%.2f", v) }

    /// 余弦距离 1−cos∈[0,2],0=同向。零向量按最远处理(防御,正常嵌入不为零)。
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 2 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }
}
