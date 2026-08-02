import Foundation

/// 说话人自动人数的两遍估计——第一遍统计(纯函数,helper 子进程与测试共用)。
///
/// 根因:<1s 短段的声纹嵌入不可靠,阈值聚类会把它们聚成只含短段的「假说话人」簇;
/// 而不存在对短句对话和清晰长句都正确的全局阈值(2026-08-02 双音频扫描实测)。
/// 对策:只数「有足够长单段」的可靠簇作为真实人数 N——真实说话人几乎总有至少一句长话,
/// 假簇几乎只由短段组成。N 与第一遍簇数不同时,由调用方强制 num_clusters=N 重跑归属
/// (同上游 DKU/Microsoft VoxSRC 系统「长簇定人数、短簇归入长簇」的通行做法)。
enum SpeakerCountEstimator {

    /// 「可靠簇」最长单段门槛梯度(秒),从严到宽,取第一个命中至少一个簇的门槛。
    /// 2.0s 实测分界最稳:真实二人录音(阈值0.7)真实说话人最长段 ≥2.26s,
    /// 假簇最长段 ≤1.47s;四人基准每簇最长段 ≥3.29s。宽档只在全篇短句时兜底。
    static let reliableDurationBars: [Double] = [2.0, 1.5, 1.0]

    /// 从第一遍分离段估计真实说话人数(数最长单段 ≥ 门槛的簇)。
    /// 返回 nil = 无法估计(无段,或所有簇最长段 < 最宽门槛),调用方应沿用第一遍结果。
    /// 估计值恒 ≤ 第一遍簇数,只会减少假说话人,不会凭空增加。
    static func estimate(segments: [DiarizeSegmentDTO]) -> Int? {
        var longestBySpeaker: [Int: Double] = [:]
        for segment in segments {
            let duration = segment.e - segment.s
            longestBySpeaker[segment.spk] = max(longestBySpeaker[segment.spk] ?? 0, duration)
        }
        guard !longestBySpeaker.isEmpty else { return nil }
        for bar in reliableDurationBars {
            let count = longestBySpeaker.values.filter { $0 >= bar }.count
            if count > 0 { return count }
        }
        return nil
    }
}
