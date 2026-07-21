import Foundation

/// 主应用专用的媒体恢复器。独立转录 helper 不编译此文件，因此仍保持自身零工具依赖。
final class FFmpegAudioFallbackDecoder: FFmpegAudioFallbackDecoding {
    private let provisioner: ToolProvisioner

    init(provisioner: ToolProvisioner = .shared) {
        self.provisioner = provisioner
    }

    func decode(url: URL, timeRange: MediaAudioTimeRange?) async throws -> DecodedAudio {
        try Task.checkCancellation()
        let ffmpeg = try await provisioner.ensureFFmpeg()
        try Task.checkCancellation()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky-audio-recovery-\(UUID().uuidString)")
            .appendingPathExtension("f32le")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", url.path
        ]
        if let timeRange {
            arguments += [
                "-ss", Self.ffmpegTime(timeRange.start),
                "-t", Self.ffmpegTime(timeRange.duration)
            ]
        }
        arguments += [
            "-map", "0:a:0", "-vn",
            "-ac", "1", "-ar", String(MediaAudioDecoder.outputSampleRate),
            "-c:a", "pcm_f32le", "-f", "f32le", outputURL.path
        ]

        let exitCode = try await Self.run(executable: ffmpeg, arguments: arguments)
        try Task.checkCancellation()
        guard exitCode == 0 else {
            throw MediaAudioDecoderError.readFailed("ffmpeg exit \(exitCode)")
        }

        let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw MediaAudioDecoderError.emptyAudio
        }

        var samples = data.withUnsafeBytes { rawBuffer -> [Float] in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
        for index in samples.indices {
            let value = samples[index]
            samples[index] = value.isFinite ? min(1, max(-1, value)) : 0
        }

        let duration = Double(samples.count) / Double(MediaAudioDecoder.outputSampleRate)
        return DecodedAudio(
            samples: samples,
            sampleRate: MediaAudioDecoder.outputSampleRate,
            duration: timeRange.map { min($0.duration, duration) } ?? duration
        )
    }

    private static func ffmpegTime(_ seconds: TimeInterval) -> String {
        String(format: "%.6f", max(0, seconds))
    }

    private static func run(executable: URL, arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminated in
                    continuation.resume(returning: terminated.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
