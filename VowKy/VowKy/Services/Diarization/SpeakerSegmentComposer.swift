import Foundation

/// 说话人分离段的后处理与文稿组装。全部纯函数,不触 i18n(标签经 labelProvider 注入)。
enum SpeakerSegmentComposer {

    /// 实测确认的边界补偿:分离分段偏紧会切掉半个词,每段前后各扩 0.25s。
    static let defaultPadding: TimeInterval = 0.25

    /// 每段 ±padding,并做边界裁剪:
    /// - clamp 到 [0, totalDuration]
    /// - 与相邻段原本不重叠时,扩展不越过邻段的原始边界(邻段的话不被吃进来)
    /// - 原始就重叠的段保持原状容忍(pyannote 可产出重叠说话段)
    /// 输入须已按 start 升序(引擎输出即有序)。
    static func padAndClip(
        _ segments: [SpeakerSegment],
        padding: TimeInterval = defaultPadding,
        totalDuration: TimeInterval
    ) -> [SpeakerSegment] {
        segments.enumerated().map { index, segment in
            let previousEnd = index > 0 ? segments[index - 1].end : 0
            let nextStart = index < segments.count - 1 ? segments[index + 1].start : totalDuration

            var start = segment.start
            var end = segment.end
            if segment.start >= previousEnd {
                start = max(segment.start - padding, previousEnd)
            }
            if segment.end <= nextStart {
                end = min(segment.end + padding, nextStart)
            }
            start = max(0, start)
            end = min(totalDuration, max(end, start))
            return SpeakerSegment(start: start, end: end, speaker: segment.speaker)
        }
    }

    /// 引擎原始簇 id(可能非连续,如 0,1,2,7)按首次出现顺序重编号为 1..N。
    static func renumberByFirstAppearance(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
        var mapping: [Int: Int] = [:]
        return segments.map { segment in
            let renumbered: Int
            if let existing = mapping[segment.speaker] {
                renumbered = existing
            } else {
                renumbered = mapping.count + 1
                mapping[segment.speaker] = renumbered
            }
            return SpeakerSegment(start: segment.start, end: segment.end, speaker: renumbered)
        }
    }

    static func distinctSpeakerCount(_ segments: [SpeakerSegment]) -> Int {
        Set(segments.map(\.speaker)).count
    }

    /// 识别后的带标签段(speaker 已重编号 1..N)。
    struct LabeledSegment: Equatable {
        let speaker: Int
        let text: String
    }

    /// 组装最终文稿。
    /// - mergeConsecutive=true(产品呈现):连续同 speaker 的段合并到一个标签下,段文本换行续接;
    ///   不同 speaker 之间空行分隔。
    /// - mergeConsecutive=false:每段一行「标签+文本」(与 E2E 基准粒度一致)。
    /// 空文本段直接跳过;单一说话人时调用方应走无标签路径,不进本函数。
    static func compose(
        _ labeled: [LabeledSegment],
        labelProvider: (Int) -> String,
        mergeConsecutive: Bool = true
    ) -> String {
        let nonEmpty = labeled.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return "" }

        if !mergeConsecutive {
            return nonEmpty
                .map { labelProvider($0.speaker) + $0.text }
                .joined(separator: "\n")
        }

        var paragraphs: [String] = []
        var currentSpeaker: Int?
        var currentLines: [String] = []
        for segment in nonEmpty {
            if segment.speaker != currentSpeaker {
                if !currentLines.isEmpty {
                    paragraphs.append(currentLines.joined(separator: "\n"))
                }
                currentSpeaker = segment.speaker
                currentLines = [labelProvider(segment.speaker) + segment.text]
            } else {
                currentLines.append(segment.text)
            }
        }
        if !currentLines.isEmpty {
            paragraphs.append(currentLines.joined(separator: "\n"))
        }
        return paragraphs.joined(separator: "\n\n")
    }
}
