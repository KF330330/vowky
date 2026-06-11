import Foundation

/// 把一段无换行的转写文本按句切分：先按终止标点切，超长片段再按子句标点/空格/硬切兜底。
/// SenseVoice 原始输出自带标点，因此终止标点是字幕「换句」的主信号；
/// 兜底规则保证无终止标点的长难句也不会撑爆字幕浮窗（约 2 行容量）。
enum SentenceSplitter {
    /// 字幕 2 行大约能容纳的字符数，超过则在子句标点处强制断行。
    static let defaultMaxLength = 50

    static func splitSentences(_ text: String, maxLength: Int = defaultMaxLength) -> [String] {
        splitAtTerminators(text)
            .flatMap { breakOverlong($0, maxLength: max(1, maxLength)) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 第一级：终止标点切分

    private static let terminators: Set<Character> = ["。", "！", "？", "；", "…", "!", "?", ";"]

    private static func splitAtTerminators(_ text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var current = ""
        for (index, ch) in chars.enumerated() {
            current.append(ch)
            guard isTerminator(at: index, in: chars) else { continue }
            // 连续标点（?!、……）作为整体，在最后一个标点后才切
            if index + 1 < chars.count, isTerminator(at: index + 1, in: chars) { continue }
            result.append(current)
            current = ""
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func isTerminator(at index: Int, in chars: [Character]) -> Bool {
        let ch = chars[index]
        if ch == "." {
            // 半角句点：前一字符非数字、后面是空白/行尾才算句末（保护 3.14、vowky.com）
            if index > 0, chars[index - 1].isNumber { return false }
            if index + 1 < chars.count, !chars[index + 1].isWhitespace { return false }
            return true
        }
        return terminators.contains(ch)
    }

    // MARK: - 第二级：超长兜底

    private static let clauseBreakers: Set<Character> = ["，", "、", ",", "：", ":"]

    private static func breakOverlong(_ piece: String, maxLength: Int) -> [String] {
        var chars = ArraySlice(Array(piece))
        var result: [String] = []
        while chars.count > maxLength {
            let window = chars[chars.startIndex..<(chars.startIndex + maxLength)]
            var cut = chars.startIndex + maxLength
            if let idx = window.lastIndex(where: { clauseBreakers.contains($0) }) {
                cut = idx + 1
            } else if let idx = window.lastIndex(where: { $0.isWhitespace }), idx > chars.startIndex {
                cut = idx
            }
            result.append(String(chars[chars.startIndex..<cut]))
            chars = chars[cut...]
        }
        if !chars.isEmpty { result.append(String(chars)) }
        return result
    }
}
