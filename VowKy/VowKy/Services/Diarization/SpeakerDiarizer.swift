import Foundation

/// 一段说话人分离结果。speaker 为引擎原始簇 id(可能非连续,如 0,1,2,7),
/// 呈现前须经 SpeakerSegmentComposer.renumberByFirstAppearance 重编号。
struct SpeakerSegment: Equatable, Codable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int
}

enum SpeakerDiarizationError: LocalizedError, Equatable {
    case helperNotFound
    case processFailed(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .helperNotFound: return "diarization helper not found"
        case .processFailed(let message): return "diarization failed: \(message)"
        case .timedOut: return "diarization timed out"
        case .cancelled: return "diarization cancelled"
        }
    }
}

/// 说话人分离服务。生产实现 SubprocessSpeakerDiarizer(一次性子进程);测试用 MockDiarizer。
/// 任何 throw 都必须由调用方兜底为「无标签文稿」——分离失败绝不丢文稿。
protocol SpeakerDiarizing {
    /// - Parameters:
    ///   - wavURL: 16k mono WAV(canonical Float32 或 Int16 PCM)
    ///   - audioDuration: 音频时长(秒),用于推导超时上限
    ///   - onProgress: 分离进度 0...1(可能从任意线程回调)
    func diarize(
        wavURL: URL,
        audioDuration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerSegment]
}
