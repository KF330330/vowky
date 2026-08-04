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
///    (地板只在长录音启用,短录音逐位保持 08-02 行为)。
/// 2. 声纹质心合并:候选簇取最长几段音频(排除与他簇重叠的区间)提取 CAM++ 质心,
///    距离近的候选簇合并计数——解决「主说话人被拆成多个大簇都被保留」。
///    实测(08-04 一小时录音)同人分裂簇质心距 0.08~0.12,异人 0.84~0.87,鸿沟清晰。
///
/// 曾试验第三级「小簇保护」(被过滤簇质心距所有保留簇都远则计为安静真人),已否决:
/// 实测真实安静说话人距离 0.59,而噪声/重叠假簇 0.68/0.79——区间倒挂无阈值可分,
/// 一小时录音上保护级把 2 个噪声簇计成幻影真人并污染整体归属(464 碎段进幻影桶)。
/// 安静少发言真人由 UI 手动「说话人数」选项兜底(该路径不走本估计器)。
/// N 与第一遍簇数不同时,由调用方强制 num_clusters=N 重跑归属。
enum SpeakerCountEstimator {

    /// 「可靠簇」最长单段门槛梯度(秒),从严到宽,取第一个命中至少一个簇的门槛。
    /// 2.0s 实测分界最稳:真实二人录音(阈值0.7)真实说话人最长段 ≥2.26s,
    /// 假簇最长段 ≤1.47s;四人基准每簇最长段 ≥3.29s。宽档只在全篇短句时兜底。
    static let reliableDurationBars: [Double] = [2.0, 1.5, 1.0]

    /// 簇总时长地板 = min(cap, share × 全部语音时长),仅当全部语音 ≥ activation 才启用。
    /// 地板专治长录音防饱和;短录音(如 22s 短句对话)地板可能倒挂淘汰少发言真人,
    /// 故 60s 以下地板恒 0,逐位保持 08-02 既有行为(codex review #4)。
    /// 若地板淘汰了全部候选簇则忽略地板(绝不允许估计为 0)。
    static let durationFloorShare: Double = 0.05
    static let durationFloorCap: Double = 30.0
    static let durationFloorActivation: Double = 60.0

    /// 质心合并距离(余弦距离,1−cos):候选簇质心距离 ≤ 此值视为同一真人。
    /// 2026-08-04 校准:一小时双人录音同人分裂簇 0.08~0.12,异人 0.84~0.87;
    /// 四人基准异人最小 0.50;8-02 双人异人 0.67——0.45 居鸿沟中间且不误并 0.50。
    static let centroidMergeDistance: Float = 0.45

    /// 质心取样:每簇取最长的至多 3 片(各 ≥1.0s),拼接总时长封顶 15s。
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

        // 一级:簇总时长地板(长录音防饱和;短录音不启用;淘汰全部则忽略地板)
        let floor = totalSpeech >= durationFloorActivation
            ? Swift.min(durationFloorCap, durationFloorShare * totalSpeech)
            : 0
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

        // 质心提取:先减去其他簇的时间区间(重叠语音是混合波形,会让不同真人质心趋同,
        // codex review #2;sherpa 上游算聚类嵌入同样排除重叠帧),再取最长几片拼接,
        // 按剩余预算截断(codex review #1)。全重叠/提取失败/非有限值 → 无质心:
        // 该簇不参与合并按独立计,也不参与小簇保护(保守方向,codex review #3)。
        func centroid(of id: Int, _ cluster: Cluster) -> [Float]? {
            let others = mergeIntervals(segments.filter { $0.spk != id }.map { ($0.s, $0.e) })
            var pieces: [(Double, Double)] = []
            for range in cluster.segments {
                pieces.append(contentsOf: subtract(range, others))
            }
            pieces.sort { ($0.1 - $0.0) > ($1.1 - $1.0) }
            var ranges: [(Double, Double)] = []
            var budget = centroidMaxTotalDuration
            for piece in pieces {
                if ranges.count >= centroidMaxSegments || budget <= 0 { break }
                let duration = piece.1 - piece.0
                if duration < centroidMinSegmentDuration && !ranges.isEmpty { break }
                ranges.append((piece.0, piece.0 + Swift.min(duration, budget)))
                budget -= Swift.min(duration, budget)
            }
            guard !ranges.isEmpty,
                  let embedding = embeddingForRanges(ranges),
                  !embedding.isEmpty,
                  embedding.allSatisfy(\.isFinite) else { return nil }
            return embedding
        }

        let keptIDs = kept.keys.sorted()
        var centroids: [Int: [Float]] = [:]
        for id in keptIDs {
            centroids[id] = centroid(of: id, kept[id]!)
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
        let estimated = mergedRoots.count
        log?("merged: \(kept.count) kept -> \(estimated) speakers")
        return estimated
    }

    /// 区间归并:排序后合并重叠/相接区间。
    static func mergeIntervals(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var result: [(Double, Double)] = [sorted[0]]
        for interval in sorted.dropFirst() {
            if interval.0 <= result[result.count - 1].1 {
                result[result.count - 1].1 = Swift.max(result[result.count - 1].1, interval.1)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// 区间减法:从 range 中减去 others(须已归并排序),返回剩余子区间。
    static func subtract(_ range: (Double, Double), _ others: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var cursor = range.0
        for other in others {
            if other.1 <= cursor { continue }
            if other.0 >= range.1 { break }
            if other.0 > cursor {
                result.append((cursor, other.0))
            }
            cursor = Swift.max(cursor, other.1)
        }
        if cursor < range.1 {
            result.append((cursor, range.1))
        }
        return result
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
