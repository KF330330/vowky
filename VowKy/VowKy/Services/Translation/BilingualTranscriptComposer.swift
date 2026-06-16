import Foundation

/// 把翻译终态的段落列表拼成「原文 + 译文」对照 Markdown，并派生双语文件路径。
/// 只负责纯文本拼装，不做 IO；写盘由调用方（ViewModel）完成。
enum BilingualTranscriptComposer {

    /// 全部段落都到达终态（无 pending）且至少有一段译文成功时才值得落盘。
    /// 全部同语言跳过/全部失败 → 双语文件没有信息量，不写。
    static func isReadyToWrite(_ paragraphs: [TranscriptParagraph]) -> Bool {
        guard !paragraphs.isEmpty else { return false }
        guard !paragraphs.contains(where: { $0.translation == .pending }) else { return false }
        return paragraphs.contains { paragraph in
            if case .translated = paragraph.translation { return true }
            return false
        }
    }

    /// 原文行 + 紧随的 `> 译文` 引用行为一组，组间空行分隔。
    /// 失败段标注「（翻译失败）」，同语言跳过段只保留原文——原文永远完整。
    static func compose(paragraphs: [TranscriptParagraph]) -> String {
        let blocks = paragraphs.map { paragraph -> String in
            switch paragraph.translation {
            case .translated(let translation):
                return "\(paragraph.text)\n> \(quoted(translation))"
            case .failed:
                return "\(paragraph.text)\n> \(LL("bilingual.export.translationFailed"))"
            case .pending, .skippedSameLanguage:
                return paragraph.text
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// 由原文文件路径派生双语文件路径：`xxx.md` → `xxx (双语).md`。
    static func outputURL(for transcriptURL: URL) -> URL {
        let baseName = transcriptURL.deletingPathExtension().lastPathComponent
        return transcriptURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName) (\(LL("bilingual.export.filenameSuffix"))).md")
    }

    /// 译文若含换行，每行都补 `> ` 前缀，保持整段在同一个引用块内。
    private static func quoted(_ translation: String) -> String {
        translation.replacingOccurrences(of: "\n", with: "\n> ")
    }
}
