import Foundation

/// 把 `TranscriptionMetadata` + 已格式化的 Markdown 正文拼成完整的 .md 文档（带 YAML frontmatter），并写盘。
enum TranscriptionMarkdownWriter {

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 拼接完整 Markdown（frontmatter + body）。
    /// body 可以是原始 raw text 也可以是 OutlinePatchApplier 输出的格式化 markdown。
    static func compose(metadata: TranscriptionMetadata, body: String) -> String {
        let frontmatter = frontmatterString(from: metadata)
        return "\(frontmatter)\n\(body)\n"
    }

    static func write(
        metadata: TranscriptionMetadata,
        body: String,
        to url: URL
    ) throws {
        let content = compose(metadata: metadata, body: body)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Frontmatter

    static func frontmatterString(from metadata: TranscriptionMetadata) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(yamlScalar(metadata.title))")
        lines.append("summary: \(yamlScalar(metadata.summary))")
        if let audio = metadata.audioPath {
            lines.append("audio_path: \(yamlScalar(audio))")
        }
        lines.append("markdown_path: \(yamlScalar(metadata.markdownPath))")
        lines.append("generated_at: \(isoFormatter.string(from: metadata.generatedAt))")
        if let dur = metadata.durationSeconds {
            lines.append("duration_seconds: \(Int(dur.rounded()))")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// 极简 YAML 标量转义：含特殊字符（`:` `#` `"` `\n` 前导/尾随空白等）时用双引号包裹并转义。
    private static func yamlScalar(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let needsQuoting = s.contains(":") || s.contains("#") || s.contains("\"") ||
            s.contains("\n") || s.contains("'") || s.first == " " || s.last == " " ||
            s.first == "[" || s.first == "{" || s.first == "-" || s.first == "&" ||
            s.first == "*" || s.first == "?" || s.first == "|" || s.first == ">" ||
            s.first == "%" || s.first == "@" || s.first == "`"
        if !needsQuoting { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
