import Foundation

struct TranscriptionMetadata: Codable, Equatable {
    var id: UUID
    var title: String
    var summary: String
    var audioPath: String?
    var markdownPath: String
    var generatedAt: Date
    var durationSeconds: TimeInterval?
    /// 例如 "openai-compatible@api.openai.com" / "codex" / "claude-code"
    var provider: String
    /// "recording" | "file" | "voice"
    var sourceType: String
    var aiEnhancementSucceeded: Bool
    var warnings: [String]
}

struct ProcessedTranscription: Equatable {
    let rawText: String
    let formattedMarkdown: String
    let metadata: TranscriptionMetadata
}
