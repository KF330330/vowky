import AVFoundation
import Foundation

struct DecodedAudio {
    let samples: [Float]
    let sampleRate: Int
    let duration: TimeInterval
}

struct MediaAudioInfo {
    let duration: TimeInterval
}

struct MediaAudioTimeRange: Equatable {
    let start: TimeInterval
    let duration: TimeInterval

    var end: TimeInterval {
        start + duration
    }
}

protocol MediaAudioDecoding {
    func loadInfo(url: URL) async throws -> MediaAudioInfo
    func decode(url: URL) async throws -> DecodedAudio
    func decode(url: URL, timeRange: MediaAudioTimeRange) async throws -> DecodedAudio
}

enum MediaAudioDecoderError: LocalizedError, Equatable {
    case unsupportedFileType(String)
    case cannotLoadAsset(String)
    case noAudioTrack
    case cannotCreateReader(String)
    case cannotAddReaderOutput
    case cannotStartReading(String)
    case cannotCreateOutputFormat
    case cannotCreatePCMBuffer
    case cannotCopySampleBufferData(String)
    case cannotCreateAudioConverter(String)
    case conversionFailed(String)
    case readFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return ext.isEmpty ? "不支持没有扩展名的文件" : "暂不支持 .\(ext) 文件"
        case .cannotLoadAsset(let reason):
            return reason.isEmpty ? "无法读取该媒体文件" : "无法读取该媒体文件：\(reason)"
        case .noAudioTrack:
            return "文件中没有可转录的音轨"
        case .cannotCreateReader(let reason):
            return reason.isEmpty ? "无法创建媒体读取器" : "无法创建媒体读取器：\(reason)"
        case .cannotAddReaderOutput:
            return "无法读取该音轨"
        case .cannotStartReading(let reason):
            return reason.isEmpty ? "媒体读取失败" : "媒体读取失败：\(reason)"
        case .cannotCreateOutputFormat:
            return "无法创建目标音频格式"
        case .cannotCreatePCMBuffer:
            return "无法创建音频缓冲区"
        case .cannotCopySampleBufferData(let reason):
            return reason.isEmpty ? "无法读取音频采样数据" : "无法读取音频采样数据：\(reason)"
        case .cannotCreateAudioConverter(let reason):
            return reason.isEmpty ? "无法创建音频转换器" : "无法创建音频转换器：\(reason)"
        case .conversionFailed(let reason):
            return reason.isEmpty ? "音频格式转换失败" : "音频格式转换失败：\(reason)"
        case .readFailed(let reason):
            return reason.isEmpty ? "音频解码失败" : "音频解码失败：\(reason)"
        case .emptyAudio:
            return "没有读取到有效音频"
        }
    }
}

final class MediaAudioDecoder: MediaAudioDecoding {
    static let outputSampleRate = 16_000

    private static let supportedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "flac",
        "mp4", "mov", "m4v"
    ]

    func loadInfo(url: URL) async throws -> MediaAudioInfo {
        try Task.checkCancellation()
        try validateSupportedFile(url)

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else {
                throw MediaAudioDecoderError.noAudioTrack
            }
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds.isFinite ? max(0, duration.seconds) : 0
            return MediaAudioInfo(duration: seconds)
        } catch let error as MediaAudioDecoderError {
            throw error
        } catch {
            throw MediaAudioDecoderError.cannotLoadAsset(Self.describe(error))
        }
    }

    func decode(url: URL) async throws -> DecodedAudio {
        try await decodeAsset(url: url, timeRange: nil)
    }

    func decode(url: URL, maximumDuration: TimeInterval) async throws -> DecodedAudio {
        try await decode(url: url, timeRange: MediaAudioTimeRange(
            start: 0,
            duration: maximumDuration
        ))
    }

    func decode(url: URL, timeRange: MediaAudioTimeRange) async throws -> DecodedAudio {
        try await decodeAsset(url: url, timeRange: timeRange)
    }

    private func decodeAsset(url: URL, timeRange: MediaAudioTimeRange?) async throws -> DecodedAudio {
        try Task.checkCancellation()
        try validateSupportedFile(url)

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw MediaAudioDecoderError.cannotLoadAsset(Self.describe(error))
        }

        guard let audioTrack = tracks.first else {
            throw MediaAudioDecoderError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaAudioDecoderError.cannotCreateReader(Self.describe(error))
        }

        if let timeRange {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: timeRange.start, preferredTimescale: 600),
                duration: CMTime(seconds: timeRange.duration, preferredTimescale: 600)
            )
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw MediaAudioDecoderError.cannotAddReaderOutput
        }
        reader.add(output)

        guard reader.startReading() else {
            throw MediaAudioDecoderError.cannotStartReading(Self.describe(reader.error))
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.outputSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw MediaAudioDecoderError.cannotCreateOutputFormat
        }

        var samples: [Float] = []

        while reader.status == .reading {
            try Task.checkCancellation()

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            let inputBuffer = try makePCMBuffer(from: sampleBuffer)
            if inputBuffer.frameLength == 0 {
                continue
            }

            let sourceFormat = inputBuffer.format
            if canAppendDirectly(sourceFormat, targetFormat) {
                appendSamples(from: inputBuffer, to: &samples)
            } else {
                guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                    throw MediaAudioDecoderError.cannotCreateAudioConverter(sourceFormatDescription(sourceFormat))
                }

                try appendConvertedSamples(
                    from: inputBuffer,
                    using: converter,
                    to: targetFormat,
                    samples: &samples
                )
            }
        }

        switch reader.status {
        case .completed, .reading:
            break
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw MediaAudioDecoderError.readFailed(Self.describe(reader.error, timeRange: timeRange))
        default:
            break
        }

        guard !samples.isEmpty else {
            throw MediaAudioDecoderError.emptyAudio
        }

        let decodedSampleDuration = Double(samples.count) / Double(Self.outputSampleRate)
        let assetDuration = duration.seconds.isFinite ? duration.seconds : decodedSampleDuration
        let decodedDuration = timeRange.map { min(max(0, assetDuration - $0.start), $0.duration, decodedSampleDuration) }
            ?? assetDuration

        return DecodedAudio(
            samples: samples,
            sampleRate: Self.outputSampleRate,
            duration: decodedDuration
        )
    }

    private func validateSupportedFile(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw MediaAudioDecoderError.unsupportedFileType(ext)
        }
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw MediaAudioDecoderError.cannotCreateOutputFormat
        }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: frameCount
        ) else {
            throw MediaAudioDecoderError.cannotCreatePCMBuffer
        }
        inputBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw MediaAudioDecoderError.cannotCopySampleBufferData(Self.describe(status))
        }

        return inputBuffer
    }

    private func appendConvertedSamples(
        from inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat,
        samples: inout [Float]
    ) throws {
        let sourceSampleRate = max(inputBuffer.format.sampleRate, 1)
        let ratio = targetFormat.sampleRate / sourceSampleRate
        let capacity = max(
            inputBuffer.frameLength,
            AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio) + 512)
        )
        var didProvideInput = false
        var iterations = 0

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else {
                throw MediaAudioDecoderError.cannotCreatePCMBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            appendSamples(from: outputBuffer, to: &samples)

            switch status {
            case .haveData:
                iterations += 1
                if outputBuffer.frameLength == 0 || iterations >= 8 {
                    return
                }
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw MediaAudioDecoderError.conversionFailed(Self.describe(conversionError))
            @unknown default:
                return
            }
        }
    }

    private func canAppendDirectly(_ sourceFormat: AVAudioFormat, _ targetFormat: AVAudioFormat) -> Bool {
        sourceFormat.commonFormat == .pcmFormatFloat32
            && sourceFormat.channelCount == targetFormat.channelCount
            && abs(sourceFormat.sampleRate - targetFormat.sampleRate) < 0.5
    }

    private func appendSamples(from buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channelCount = max(1, Int(buffer.format.channelCount))

        samples.reserveCapacity(samples.count + frameCount)

        if let channelData = buffer.floatChannelData {
            for frameIndex in 0..<frameCount {
                var total: Float = 0
                for channelIndex in 0..<channelCount {
                    total += channelData[channelIndex][frameIndex]
                }
                appendClamped(total / Float(channelCount), to: &samples)
            }
            return
        }

        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData else { return }

        let values = data.bindMemory(
            to: Float.self,
            capacity: frameCount * channelCount
        )
        for frameIndex in 0..<frameCount {
            var total: Float = 0
            let baseIndex = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                total += values[baseIndex + channelIndex]
            }
            appendClamped(total / Float(channelCount), to: &samples)
        }
    }

    private func appendClamped(_ value: Float, to samples: inout [Float]) {
        samples.append(value.isFinite ? min(1, max(-1, value)) : 0)
    }

    private func sourceFormatDescription(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz, \(format.channelCount)ch, \(format.commonFormat)"
    }

    private static func describe(_ error: Error?, timeRange: MediaAudioTimeRange? = nil) -> String {
        guard let error else { return "" }

        let nsError = error as NSError
        var parts = [
            "\(nsError.domain) \(nsError.code)",
            nsError.localizedDescription
        ]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            parts.append(reason)
        }
        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            parts.append(suggestion)
        }
        if let timeRange {
            parts.append("约 \(formatTime(timeRange.start)) 处")
        }
        return parts.joined(separator: "；")
    }

    private static func describe(_ status: OSStatus) -> String {
        "OSStatus \(status)"
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
