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
        let logFilePath = markdownURL
            .flatMap { AIEnhancementLogger.logURL(forMarkdownURL: $0) }?
            .path

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
