import Foundation

// MARK: - Public types

struct EnhancementInput: Equatable {
    let rawText: String
    let audioURL: URL?
    let startedAt: Date
    let durationSeconds: TimeInterval?
    /// "recording" | "file" | "voice"
    let sourceType: String
}

struct EnhancementProgress: Equatable {
    enum Task: String, Equatable { case title, summary, outline }
    enum Status: Equatable {
        case running
        case succeeded
        case failed(String)
    }
    let task: Task
    let status: Status
}

struct EnhancementResult: Equatable {
    let metadata: TranscriptionMetadata
    /// 已带 frontmatter 的完整 Markdown 文档内容。
    let fullMarkdownDocument: String
    let titleSucceeded: Bool
    let summarySucceeded: Bool
    let outlineSucceeded: Bool
    let warnings: [String]
}

protocol TranscriptionEnhancing {
    func enhance(
        input: EnhancementInput,
        markdownPath: String,
        logFilePath: String?,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult
}

// 旧调用方（不传 logFilePath）的默认实现：转发到带 logFilePath 的版本，传 nil。
extension TranscriptionEnhancing {
    func enhance(
        input: EnhancementInput,
        markdownPath: String,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        await enhance(
            input: input,
            markdownPath: markdownPath,
            logFilePath: nil,
            progress: progress
        )
    }
}

// MARK: - Logger

/// AI 调用日志记录器。线程安全（通过 DispatchQueue 串行化 append）。
final class AIEnhancementLogger: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.vowky.ai-log", qos: .utility)

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(url: URL) {
        self.url = url
        queue.sync {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
    }

    /// 根据 markdown 输出路径推导对应的 AI 日志 URL；与 TranscriptionEnhancementRunner 中的路径规则保持一致。
    static func logURL(forMarkdownURL markdownURL: URL) -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let base = markdownURL.deletingPathExtension().lastPathComponent
        return appSupport
            .appendingPathComponent("VowKy", isDirectory: true)
            .appendingPathComponent("AILogs", isDirectory: true)
            .appendingPathComponent("\(base).ai-log.txt")
    }

    func appendHeader(input: EnhancementInput, provider: String, markdownPath: String) {
        var lines: [String] = []
        lines.append("############################################################")
        lines.append("# AI Enhancement Log — \(Self.timestampFormatter.string(from: Date()))")
        lines.append("# provider: \(provider)")
        lines.append("# source_type: \(input.sourceType)")
        if let audio = input.audioURL { lines.append("# audio: \(audio.path)") }
        lines.append("# markdown: \(markdownPath)")
        lines.append("# raw_chars: \(input.rawText.count)")
        lines.append("############################################################")
        lines.append("")
        write(lines.joined(separator: "\n") + "\n")
    }

    func appendDiagnostics(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        var outLines: [String] = []
        outLines.append("############################################################")
        outLines.append("# Diagnostics")
        for line in lines { outLines.append("# \(line)") }
        outLines.append("############################################################")
        outLines.append("")
        write(outLines.joined(separator: "\n") + "\n")
    }

    func appendFooter(titleOK: Bool, summaryOK: Bool, outlineOK: Bool, warnings: [String]) {
        var lines: [String] = []
        lines.append("############################################################")
        lines.append("# Summary: title=\(titleOK ? "OK" : "FAIL") summary=\(summaryOK ? "OK" : "FAIL") outline=\(outlineOK ? "OK" : "FAIL")")
        if warnings.isEmpty {
            lines.append("# warnings: (none)")
        } else {
            lines.append("# warnings:")
            for w in warnings { lines.append("#   - \(w)") }
        }
        lines.append("############################################################")
        lines.append("")
        write(lines.joined(separator: "\n") + "\n")
    }

    func append(
        task: String,
        provider: String,
        request: AIRequest,
        response: String?,
        error: String?,
        elapsed: TimeInterval
    ) {
        let ts = Self.timestampFormatter.string(from: Date())
        var lines: [String] = []
        lines.append("============================================================")
        lines.append("[\(ts)] task=\(task) provider=\(provider) elapsed=\(String(format: "%.1f", elapsed))s")
        lines.append("--- prompt (system) ---")
        lines.append(request.systemPrompt)
        lines.append("--- prompt (user) ---")
        lines.append(request.userPrompt)
        if let response {
            lines.append("--- response ---")
            lines.append(response)
        }
        if let error {
            lines.append("--- ERROR ---")
            lines.append(error)
        }
        lines.append("")
        write(lines.joined(separator: "\n") + "\n")
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let targetURL = url
        queue.sync {
            if let handle = try? FileHandle(forWritingTo: targetURL) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }
}
