import Foundation

/// 用 token 级时间戳把识别文本按「说话停顿」切分——语言无关的声学句子边界，
/// 不依赖标点（SenseVoice 对日语等语言的标点输出不可靠）。
/// 任何对不齐/无时间戳的情况一律返回原文整体，优雅退化为纯文本逻辑。
enum PauseSegmenter {
    /// 相邻 token 起始时间差阈值（秒）。CJK token 通常 0.15–0.3s，
    /// 0.8s 的 start-to-start 间隔约等于 0.5s 以上的真实静音。
    static let defaultMinGap: Float = 0.8

    static func split(
        text: String,
        tokens: [String],
        timestamps: [Float],
        minGap: Float = defaultMinGap
    ) -> [String] {
        segmentWithCut(text: text, tokens: tokens, timestamps: timestamps, minGap: minGap).pieces
    }

    /// 切分并给出「最后一个停顿边界」的音频信息（相对本次解码音频起点）：
    /// cutTime = 边界后首 token 的起始时间；gapStart = 边界前最后一个 token 的起始时间。
    /// 调用方据此在停顿区间内选安全切点，冻结之前的音频不再重解码。
    /// 切分不成立（无边界/对不齐/收敛成单片）时 cutTime/gapStart 为 nil。
    static func segmentWithCut(
        text: String,
        tokens: [String],
        timestamps: [Float],
        minGap: Float = defaultMinGap
    ) -> (pieces: [String], cutTime: Float?, gapStart: Float?) {
        guard !text.isEmpty else { return ([], nil, nil) }
        guard tokens.count == timestamps.count, tokens.count > 1 else { return ([text], nil, nil) }

        var boundaries: Set<Int> = []
        for i in 1..<timestamps.count where timestamps[i] - timestamps[i - 1] >= minGap {
            boundaries.insert(i)
        }
        guard !boundaries.isEmpty else { return ([text], nil, nil) }

        // tokens 顺序对齐 text 换算切分位置。text 与 tokens 拼接基本一致，
        // 但需容忍：token 间插入的空格、BPE 空格标记 ▁、被剔除的特殊标记 <|zh|> 等。
        var pieces: [(text: String, startToken: Int)] = []
        var current = ""
        var currentStartToken = 0
        var remainder = Substring(text)
        for (index, rawToken) in tokens.enumerated() {
            if boundaries.contains(index) {
                pieces.append((current, currentStartToken))
                current = ""
                currentStartToken = index
            }
            let token = rawToken.replacingOccurrences(of: "\u{2581}", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            while let first = remainder.first, first == " " {
                current.append(remainder.removeFirst())
            }
            if remainder.hasPrefix(token) {
                current.append(contentsOf: remainder.prefix(token.count))
                remainder = remainder.dropFirst(token.count)
            } else if rawToken.hasPrefix("<|"), rawToken.hasSuffix("|>") {
                continue  // 特殊标记不出现在 text 里，跳过
            } else {
                return ([text], nil, nil)  // 对不齐：放弃切分，保证不破坏文本
            }
        }
        current += remainder  // 理论为空或尾随空白
        pieces.append((current, currentStartToken))

        let cleaned = pieces
            .map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), startToken: $0.startToken) }
            .filter { !$0.text.isEmpty }
        guard cleaned.count > 1, let last = cleaned.last, last.startToken >= 1 else {
            return (cleaned.map(\.text), nil, nil)
        }
        return (cleaned.map(\.text), timestamps[last.startToken], timestamps[last.startToken - 1])
    }
}
