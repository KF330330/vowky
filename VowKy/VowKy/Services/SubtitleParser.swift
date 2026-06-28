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
            // 按 token 切：CJK/假名按单字，拉丁串整块。让重叠去重对中文/日文等无空格语言也有效。
            let words = tokenize(cue)
            guard !words.isEmpty else { continue }

            // 最长 k：out 的后 k 个 token == 当前 cue 的前 k 个 token。
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

        return joinTokens(out).trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: CJK-aware 分词 / 拼接

    /// 是否 CJK/假名/全角等无空格分词的字符。
    private static func isCJK(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(s)   // CJK 统一汉字
            || (0x3400...0x4DBF).contains(s)   // 扩展 A
            || (0x3040...0x30FF).contains(s)   // 平假名 + 片假名
            || (0xF900...0xFAFF).contains(s)   // CJK 兼容汉字
            || (0x3000...0x303F).contains(s)   // CJK 标点
            || (0xFF00...0xFFEF).contains(s)   // 全角
    }

    /// 切 token：空白分隔；CJK/假名每字一个 token；连续拉丁串（含数字/标点）保持整块。
    private static func tokenize(_ cue: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        func flush() { if !latin.isEmpty { tokens.append(latin); latin = "" } }
        for ch in cue {
            if ch == " " || ch == "\t" {
                flush()
            } else if isCJK(ch) {
                flush()
                tokens.append(String(ch))
            } else {
                latin.append(ch)
            }
        }
        flush()
        return tokens
    }

    private static func tokenIsCJK(_ tok: String) -> Bool {
        tok.count == 1 && isCJK(tok.first!)
    }

    /// 拼接：只在两个拉丁 token 之间补空格（CJK-CJK / CJK-拉丁不补）；哨兵 → 换行。
    private static func joinTokens(_ tokens: [String]) -> String {
        var result = ""
        var prevSpaceable = false
        for tok in tokens {
            if tok == newlineSentinel {
                result += "\n"
                prevSpaceable = false
                continue
            }
            let spaceable = !tokenIsCJK(tok)
            if !result.isEmpty, !result.hasSuffix("\n"), prevSpaceable, spaceable {
                result += " "
            }
            result += tok
            prevSpaceable = spaceable
        }
        return result
    }
}
