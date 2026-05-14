import Foundation

/// 集中管理三个 AI 任务（outline / title / summary）的 prompt 与长文本预处理策略。
enum EnhancementPrompts {

    /// 单次调用允许的最大原文长度；超过则触发 outline 分块或 title/summary 抽样。
    static let singleCallMaxChars = 8000
    /// outline 分块时相邻窗口的重叠字符数。
    static let outlineChunkOverlap = 200
    /// title/summary 抽样时取头部字符数。
    static let abridgeHeadChars = 3000
    /// title/summary 抽样时取尾部字符数。
    static let abridgeTailChars = 1500

    // MARK: - Outline

    static func outlineSystemPrompt() -> String {
        """
        You are a meticulous editor. Add structure (Markdown headings and paragraph breaks) to a raw speech transcript WITHOUT changing any of the original words.

        Hard rules:
        1. NEVER change, delete, reorder, paraphrase, translate, or correct any character of the original.
        2. Output INSERT operations only. No replace, no delete, no rewrite.
        3. Heading text must be NEW words you invent to summarize the following section. Do not quote the transcript verbatim if doing so changes meaning.
        4. Use at most 3 heading levels.
        5. Insert a heading roughly every 200-500 characters of substantive content. Skip headings for very short transcripts (< 300 chars).
        6. Each insertion has an `anchor.before` = the LAST 20-40 characters of the segment that should appear BEFORE the insertion. Use literal substring of the transcript, INCLUDING punctuation and whitespace.
        7. Output JSON only. No prose, no markdown code fence.

        Schema:
        {
          "version": 1,
          "operations": [
            {
              "kind": "heading" | "paragraph_break",
              "level": 1 | 2 | 3,
              "text": "string",
              "anchor": { "before": "string", "occurrence": 1 }
            }
          ]
        }
        """
    }

    static func outlineUserPrompt(rawText: String) -> String {
        """
        Transcript:
        \"\"\"
        \(rawText)
        \"\"\"

        Output the JSON now.
        """
    }

    // MARK: - Title

    static func titleSystemPrompt() -> String {
        """
        Generate a concise title (≤ 20 characters in the source language) summarizing the transcript. \
        Output the title text ONLY. No quotes. No trailing punctuation. No prefixes like "Title:".
        """
    }

    static func titleUserPrompt(rawText: String) -> String {
        abridgeIfNeeded(rawText)
    }

    // MARK: - Summary

    static func summarySystemPrompt() -> String {
        """
        Write a 1-3 sentence summary (≤ 120 characters in the source language) of the transcript's main points. \
        Output the summary text ONLY. No prefixes like "Summary:".
        """
    }

    static func summaryUserPrompt(rawText: String) -> String {
        abridgeIfNeeded(rawText)
    }

    // MARK: - Abridgement (for title / summary)

    /// 太长时取头部 + 中略 + 尾部，避免超 token 同时保留主旨与结尾结论。
    static func abridgeIfNeeded(_ text: String) -> String {
        if text.count <= singleCallMaxChars {
            return text
        }
        let head = text.prefix(abridgeHeadChars)
        let tail = text.suffix(abridgeTailChars)
        return "\(head)\n\n...(中略)...\n\n\(tail)"
    }

    // MARK: - Outline chunking (for long transcripts)

    /// 把长文本切成不超过 maxChars 的窗口，相邻窗口共享 overlap 字符。
    /// 按句号/问号/感叹号/换行切句，避免在句中拆开。
    static func chunkForOutline(
        _ text: String,
        maxChars: Int = singleCallMaxChars,
        overlap: Int = outlineChunkOverlap
    ) -> [String] {
        if text.count <= maxChars { return [text] }

        // 切句
        let sentenceDelimiters: Set<Character> = ["。", "？", "！", ".", "?", "!", "\n"]
        var sentences: [String] = []
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            if sentenceDelimiters.contains(ch) {
                sentences.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { sentences.append(buffer) }

        var chunks: [String] = []
        var currentChunk = ""
        for sentence in sentences {
            if currentChunk.count + sentence.count > maxChars, !currentChunk.isEmpty {
                chunks.append(currentChunk)
                // overlap：从上一块尾部取 overlap 字符作为下一块开头
                let overlapStart = currentChunk.index(
                    currentChunk.endIndex,
                    offsetBy: -min(overlap, currentChunk.count)
                )
                currentChunk = String(currentChunk[overlapStart...])
            }
            currentChunk += sentence
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks
    }
}
