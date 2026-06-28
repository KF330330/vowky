import Foundation

/// 把平台字幕（WebVTT / SRT）解析成干净的纯文本。三个平台（YouTube / 哔哩哔哩 / DeepLearning.AI）共用。
///
/// 难点在 **YouTube 自动字幕的「滚动重复」格式**：每条 cue = 上一条的尾部（carryover）+ 新词，
/// 还夹着行内 `<时间><c>词</c>` 标签。直接拼接会得到大量重复。解法是**按词做重叠合并**：
/// 每条 cue 清洗后，找它与已输出尾部的最长「后缀==前缀」重叠，只追加非重叠的新词。
/// 人工字幕 / SRT 无滚动，按 cue 逐行输出。
enum SubtitleParser {
    /// - Parameters:
    ///   - raw: 原始 .vtt 或 .srt 文本。
    ///   - rolling: 是否为滚动式自动字幕。true → 重叠合并成连续段落；false → 每条 cue 自成一行。
    static func plainText(from raw: String, rolling: Bool) -> String {
        let cues = extractCues(from: raw)

        var out: [String] = []
        for cue in cues {
            let words = cue.split(separator: " ").map(String.init)
            guard !words.isEmpty else { continue }

            // 最长 k：out 的后 k 个词 == 当前 cue 的前 k 个词。
            let cap = min(out.count, words.count)
            var k = 0
            if cap > 0 {
                for n in stride(from: cap, through: 1, by: -1) {
                    if Array(out.suffix(n)) == Array(words.prefix(n)) { k = n; break }
                }
            }
            let newWords = Array(words[k...])
            guard !newWords.isEmpty else { continue }

            // 人工字幕：每条 cue 换行（用哨兵标记，最后替换）。自动字幕：合并成连续段落。
            if !rolling && !out.isEmpty {
                out.append(Self.newlineSentinel)
            }
            out.append(contentsOf: newWords)
        }

        var joined = out.joined(separator: " ")
        for variant in [" \(newlineSentinel) ", "\(newlineSentinel) ", " \(newlineSentinel)", newlineSentinel] {
            joined = joined.replacingOccurrences(of: variant, with: "\n")
        }
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let newlineSentinel = "\u{0001}"

    /// 按空行切块，丢掉头部/序号/时间轴行，清洗每条 cue 文本。
    private static func extractCues(from raw: String) -> [String] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var cues: [String] = []
        for block in blocks {
            var lines = block.components(separatedBy: "\n")
            if let first = lines.first?.trimmingCharacters(in: .whitespaces),
               first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE")
                || first.hasPrefix("STYLE") || first.hasPrefix("Kind:") || first.hasPrefix("Language:") {
                continue
            }
            lines = lines.filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { return false }
                if t.contains("-->") { return false }              // 时间轴
                if t.allSatisfy({ $0.isNumber }) { return false }  // SRT 序号
                return true
            }
            guard !lines.isEmpty else { continue }

            let cueText = lines
                .map(cleanLine)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cueText.isEmpty else { continue }
            cues.append(cueText)
        }
        return cues
    }

    /// 去行内标签 `<...>`、声音注释 `[Music]`/`[Applause]`、音符 `♪`，并压缩空白。
    private static func cleanLine(_ line: String) -> String {
        var s = line
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "♪", with: "")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
