import Foundation

/// 一条「实际展示过」的字幕记录：该句离屏前最后展示的形态。
struct SubtitleDisplayRecord: Equatable {
    /// 首次上屏时刻（相对录音开始的秒数）
    let firstShownOffset: TimeInterval
    /// 离屏前最后展示的原文
    var text: String
    /// 离屏前最后展示的译文状态
    var translation: ParagraphTranslationState
}

/// 字幕实录：记录字幕浮窗真实展示过的每一句（逐句断句 + 当时展示的译文），
/// 录音完成保存时拼成 Markdown 落在录音同目录，供评估断句/翻译效果。
/// 只消费 SubtitlePacer.onDisplay，天然只记「真实上过屏」的内容。
///
/// 已知如实保留的现象（实录定位，不做去重/追溯）：
/// - 冻结切段瞬间 pacer 跳过「回缩」上屏（isShrinkIntoNext），被划走的句尾可能
///   同时出现在相邻两条记录的尾部和开头——屏幕真实呈现过的重复，照记。
/// - 头部翻译配置反映保存时刻的设置，录音中途切换引擎/目标语言不追溯。
@MainActor
final class SubtitleDisplayRecorder {
    private(set) var records: [SubtitleDisplayRecord] = []

    var isEmpty: Bool { records.isEmpty }

    /// 唯一写入口，镜像 pacer 回调：新句上屏追加一条，同句刷新更新最后一条。
    /// TranscriptParagraph.id 不可靠（同句从预览 "p-N" 定稿为 "c-M" 会变），
    /// 归并只信 isNewSentence 信号；records 为空时防御性追加。
    func record(_ paragraph: TranscriptParagraph, isNewSentence: Bool, at offset: TimeInterval) {
        if isNewSentence || records.isEmpty {
            records.append(SubtitleDisplayRecord(
                firstShownOffset: max(0, offset),
                text: paragraph.text,
                translation: paragraph.translation
            ))
        } else {
            records[records.count - 1].text = paragraph.text
            records[records.count - 1].translation = paragraph.translation
        }
    }

    func reset() {
        records = []
    }

    // MARK: - Markdown 拼装（纯函数，不做 IO，仿 BilingualTranscriptComposer）

    /// 头部两行元数据 + 每条字幕一块：`[mm:ss] 原文` + 紧随的 `> 译文` 引用行。
    /// 译文四态：translated 引用译文；pending 注记「译文未上屏」；failed 注记「翻译失败」
    /// （浮窗对 failed 不渲染译文行，但评估需区分"没等到"和"失败了"）；
    /// skippedSameLanguage（含翻译关闭的纯原文模式）不输出译文行。
    static func compose(
        records: [SubtitleDisplayRecord],
        startedAt: Date?,
        translation: TranslationConfig
    ) -> String {
        var header = "# \(LL("subtitleLog.export.title"))\n"
        if let startedAt {
            header += "\n- \(LL("subtitleLog.export.recordingStartedAt", headerDateFormatter.string(from: startedAt)))"
        }
        if translation.enabled {
            header += "\n- \(LL("subtitleLog.export.translationOn", translation.engine.rawValue, translation.target.displayName))"
        } else {
            header += "\n- \(LL("subtitleLog.export.translationOff"))"
        }

        let blocks = records.map { record -> String in
            let line = "\(timestamp(record.firstShownOffset)) \(record.text)"
            switch record.translation {
            case .translated(let translation):
                return "\(line)\n> \(quoted(translation))"
            case .pending:
                return "\(line)\n> \(LL("subtitleLog.export.pendingTranslation"))"
            case .failed:
                return "\(line)\n> \(LL("bilingual.export.translationFailed"))"
            case .skippedSameLanguage:
                return line
            }
        }
        return header + "\n\n" + blocks.joined(separator: "\n\n") + "\n"
    }

    /// 由原文文件路径派生实录文件路径：`xxx.md` → `xxx (字幕实录).md`。
    static func outputURL(for transcriptURL: URL) -> URL {
        let baseName = transcriptURL.deletingPathExtension().lastPathComponent
        return transcriptURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName) (\(LL("subtitleLog.export.filenameSuffix"))).md")
    }

    /// `[mm:ss]`，超过 60 分钟 mm 自然增长；负数钳到 [00:00]。
    private static func timestamp(_ offset: TimeInterval) -> String {
        let total = max(0, Int(offset.rounded(.down)))
        return String(format: "[%02d:%02d]", total / 60, total % 60)
    }

    /// 译文若含换行，每行都补 `> ` 前缀，保持整段在同一个引用块内。
    private static func quoted(_ translation: String) -> String {
        translation.replacingOccurrences(of: "\n", with: "\n> ")
    }

    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
