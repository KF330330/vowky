import Foundation

/// 极速引擎(SpeechAnalyzer)一句话的置信度聚合。
/// 均值会被少数疑难词掩盖,故同时给出时长加权 P10(最低一档的代表值);
/// 自动回落阈值(若启用)应看 p10 而非 mean(codex 计划审 P4)。
struct SpeechConfidenceStats {
    /// 时长加权均值 ∈ [0,1]
    let mean: Double
    /// 时长加权 10 分位:按置信度升序累计权重,首个越过总权重 10% 的 run 的置信度
    let p10: Double
    /// 参与聚合的总权重(秒;无时间属性的 run 按字符数折算)
    let totalWeight: Double
}

enum SpeechConfidenceAggregator {

    /// 聚合 (置信度, 权重) 序列。空输入或总权重为 0 返回 nil。
    static func aggregate(_ runs: [(confidence: Double, weight: Double)]) -> SpeechConfidenceStats? {
        let valid = runs.filter { $0.weight > 0 && $0.confidence.isFinite }
        let total = valid.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        let mean = valid.reduce(0) { $0 + $1.confidence * $1.weight } / total
        var cumulative = 0.0
        var p10 = valid[0].confidence
        for run in valid.sorted(by: { $0.confidence < $1.confidence }) {
            cumulative += run.weight
            p10 = run.confidence
            if cumulative >= total * 0.1 { break }
        }
        return SpeechConfidenceStats(mean: mean, p10: p10, totalWeight: total)
    }
}
