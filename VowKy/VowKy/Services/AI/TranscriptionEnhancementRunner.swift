import Foundation

struct TranscriptionEnhancementRunner {
    let service: TranscriptionEnhancing

    func run(
        rawText: String,
        audioURL: URL?,
        sourceType: String,
        startedAt: Date,
        durationSeconds: TimeInterval?,
        markdownURL: URL?,
        progress: @escaping @MainActor (EnhancementProgress) -> Void
    ) async -> EnhancementResult {
        let input = EnhancementInput(
            rawText: rawText,
            audioURL: audioURL,
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            sourceType: sourceType
        )
        let markdownPath = markdownURL?.path ?? ""
        let logFilePath = markdownURL.flatMap { url -> String? in
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let logsDir = appSupport
                .appendingPathComponent("VowKy", isDirectory: true)
                .appendingPathComponent("AILogs", isDirectory: true)
            let base = url.deletingPathExtension().lastPathComponent
            return logsDir.appendingPathComponent("\(base).ai-log.txt").path
        }

        let result = await service.enhance(
            input: input,
            markdownPath: markdownPath,
            logFilePath: logFilePath,
            progress: progress
        )

        if let markdownURL {
            do {
                try result.fullMarkdownDocument.write(to: markdownURL, atomically: true, encoding: .utf8)
            } catch {
                print("[VowKy][Enhancement] AI markdown 覆盖写盘失败: \(error.localizedDescription)")
            }
        }

        return result
    }
}
