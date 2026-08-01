import Foundation

/// SpeechAnalyzer 输出的轻量清理与分段。纯函数、无编译门控（任何工具链可编译可单测）；
/// 只挂在 SpeechAnalyzer 路径，绝不处理 SenseVoice 输出。
/// 实测怪癖：标点/数字前带空格（「第 10页」「 ，」）；连续数字错位无法修复，不处理。
enum SpeechAnalyzerTextCleaner {

    /// 仅当文本含汉字时启用 CJK 规则（纯英文输出原样返回）。
    static func clean(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return text }
        var result = text
        // 1) CJK 标点前的空白
        result = replacing(result, pattern: "\\s+(?=[，。！？；：、）】」』…])", with: "")
        // 2) 汉字与数字之间的单个空格（对齐 SenseVoice 输出风格；英文单词两侧空格不动）
        result = replacing(result, pattern: "(?<=\\p{Han}) (?=[0-9])", with: "")
        result = replacing(result, pattern: "(?<=[0-9]) (?=\\p{Han})", with: "")
        // 3) 折叠连续空格
        result = replacing(result, pattern: " {2,}", with: " ")
        return result
    }

    /// 带时间的已定稿片段（来自 SpeechTranscriber isFinal 结果的 CMTimeRange）。
    struct TimedText: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// 单流输出没有 SenseVoice 30s 切块的天然换行，长音频会成一坨——
    /// 用相邻定稿片段的音频间隙分段：间隙 > gapThreshold 插换行，否则原样拼接
    /// （保留片段自带空格，不 trim，避免破坏英文词间距）。
    static func assembleParagraphs(
        _ results: [TimedText],
        gapThreshold: TimeInterval = 1.5
    ) -> String {
        var output = ""
        var previousEnd: TimeInterval?
        for piece in results where !piece.text.isEmpty {
            if let previousEnd, piece.start - previousEnd > gapThreshold {
                output = output.trimmingCharacters(in: .whitespaces) + "\n"
            }
            output += piece.text
            previousEnd = piece.end
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
