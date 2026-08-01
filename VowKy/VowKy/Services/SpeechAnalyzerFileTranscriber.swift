// SpeechAnalyzer 极速引擎（需求 C）：macOS 26+ 的系统级转写,零模型体积,实测比 SenseVoice 4 线程快约 10 倍。
// 仅用于文件/链接转录(用户拍板);热键听写与录音仍走 SenseVoice。
//
// 编译门控:Speech framework 自 10.15 就存在,#if canImport(Speech) 恒真——必须用 compiler(>=6.2)
// (Xcode 26 带 Swift 6.2+)整文件隔离,Xcode 16.2 回退构建时本文件整体排除,其余一切照旧。
#if compiler(>=6.2)

import AVFoundation
import Foundation
import Speech

enum SpeechAnalyzerTranscriptionError: LocalizedError {
    case unsupportedLocale(String)
    case assetsUnavailable
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let locale):
            return LL("speechAnalyzer.error.unsupportedLocale", locale)
        case .assetsUnavailable:
            return LL("speechAnalyzer.error.assetsUnavailable")
        case .analysisFailed(let message):
            return LL("speechAnalyzer.error.analysisFailed", message)
        }
    }
}

/// 与 FileTranscriptionService 并列的第二引擎实现(FileTranscribing 多态缝)。
/// 结构性差异:SenseVoice 是 30s 切块逐段 IPC 识别;本引擎是连续单流喂给系统分析器
/// (因此 SenseVoice 的分块边界重复字怪癖不会出现),推理在系统服务进程,app 侧内存≈0。
@available(macOS 26.0, *)
final class SpeechAnalyzerFileTranscriber: FileTranscribing {

    /// 每次解码窗口时长。窗口只是解码手段,分析器看到的是连续流;
    /// 60s@16k Float32 ≈ 3.8MB,靠 AsyncSequence 拉式背压保持恒定内存。
    private static let decodeWindowSeconds: TimeInterval = 60

    private let decoder: MediaAudioDecoding
    private let localeIdentifier: String
    /// 礼让闸:每个解码窗口前调用(不占 helper 管道,但解码 CPU 尖峰仍礼让热键听写,与 SenseVoice 路径行为一致)。
    private let yieldToVoiceInput: (() async -> Void)?

    init(
        decoder: MediaAudioDecoding = MediaAudioDecoder(),
        localeIdentifier: String,
        yieldToVoiceInput: (() async -> Void)? = nil
    ) {
        self.decoder = decoder
        self.localeIdentifier = localeIdentifier
        self.yieldToVoiceInput = yieldToVoiceInput
    }

    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        await progress(FileTranscriptionProgress(
            phase: .reading, progress: 0, currentSegment: 0, totalSegments: 0, partialText: ""
        ))

        // 1) locale 支持性 + 系统语音资产(转录侧兜底;设置侧已有主动下载入口)
        let locale = Locale(identifier: localeIdentifier)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else {
            throw SpeechAnalyzerTranscriptionError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[VowKy][SpeechAnalyzer] 资产下载失败: \(error.localizedDescription)")
            throw SpeechAnalyzerTranscriptionError.assetsUnavailable
        }
        try Task.checkCancellation()

        let info = try await decoder.loadInfo(url: url)
        let totalDuration = max(0, info.duration)

        // 2) 泵 + 收两路并发:结果消费与音频泵入并行,靠拉式背压保持恒定内存
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let collectTask = Task<[SpeechAnalyzerTextCleaner.TimedText], Error> {
            var pieces: [SpeechAnalyzerTextCleaner.TimedText] = []
            for try await result in transcriber.results where result.isFinal {
                let range = result.range
                pieces.append(SpeechAnalyzerTextCleaner.TimedText(
                    text: String(result.text.characters),
                    start: range.start.seconds.isFinite ? range.start.seconds : 0,
                    end: range.end.seconds.isFinite ? range.end.seconds : 0
                ))
            }
            return pieces
        }

        do {
            try await withTaskCancellationHandler {
                let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
                try await analyzer.start(inputSequence: inputSequence)

                // 手动拉式泵:每窗解码→yield→等分析器消化(makeStream 无界缓冲,
                // 这里靠「解码一窗 yield 一窗」的循环节奏 + 窗口小,内存峰值恒定一窗。
                var pumpedSeconds: TimeInterval = 0
                var lastPartialCount = 0
                while totalDuration <= 0 || pumpedSeconds < totalDuration {
                    await yieldToVoiceInput?()
                    try Task.checkCancellation()
                    let remaining = totalDuration > 0
                        ? min(Self.decodeWindowSeconds, totalDuration - pumpedSeconds)
                        : Self.decodeWindowSeconds
                    guard remaining > 0.05 else { break }
                    let decoded = try await decoder.decode(
                        url: url,
                        timeRange: MediaAudioTimeRange(start: pumpedSeconds, duration: remaining)
                    )
                    guard !decoded.samples.isEmpty, decoded.sampleRate > 0 else { break }
                    guard let buffer = Self.makeBuffer(
                        samples: decoded.samples,
                        sampleRate: decoded.sampleRate,
                        targetFormat: analysisFormat
                    ) else {
                        throw SpeechAnalyzerTranscriptionError.analysisFailed("audio format conversion failed")
                    }
                    inputBuilder.yield(AnalyzerInput(buffer: buffer))

                    let decodedSeconds = Double(decoded.samples.count) / Double(decoded.sampleRate)
                    guard decodedSeconds > 0.01 else { break }
                    pumpedSeconds += decodedSeconds

                    let fraction = totalDuration > 0 ? min(0.95, pumpedSeconds / totalDuration) : 0.5
                    let partialCount = lastPartialCount
                    lastPartialCount = partialCount
                    await progress(FileTranscriptionProgress(
                        phase: .transcribing,
                        progress: fraction,
                        currentSegment: Int(pumpedSeconds / Self.decodeWindowSeconds) + 1,
                        totalSegments: totalDuration > 0
                            ? max(1, Int(ceil(totalDuration / Self.decodeWindowSeconds)))
                            : 0,
                        partialText: ""
                    ))
                    if totalDuration <= 0 { break }
                }
                inputBuilder.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch is CancellationError {
            collectTask.cancel()
            throw CancellationError()
        } catch let error as SpeechAnalyzerTranscriptionError {
            collectTask.cancel()
            throw error
        } catch {
            collectTask.cancel()
            throw SpeechAnalyzerTranscriptionError.analysisFailed(error.localizedDescription)
        }

        let pieces: [SpeechAnalyzerTextCleaner.TimedText]
        do {
            pieces = try await collectTask.value
        } catch {
            throw SpeechAnalyzerTranscriptionError.analysisFailed(error.localizedDescription)
        }

        // 3) 怪癖清理 + 间隙分段
        let assembled = SpeechAnalyzerTextCleaner.assembleParagraphs(pieces)
        let result = SpeechAnalyzerTextCleaner.clean(assembled)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw FileTranscriptionError.noRecognizedText
        }
        await progress(FileTranscriptionProgress(
            phase: .finishing, progress: 1,
            currentSegment: 1, totalSegments: 1,
            partialText: result
        ))
        return result
    }

    /// Float32 mono 样本 → AVAudioPCMBuffer;分析格式不同时经 AVAudioConverter 转换。
    private static func makeBuffer(
        samples: [Float],
        sampleRate: Int,
        targetFormat: AVAudioFormat?
    ) -> AVAudioPCMBuffer? {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            sourceBuffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }

        guard let targetFormat, targetFormat != sourceFormat else { return sourceBuffer }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up) + 1024)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        return conversionError == nil ? converted : nil
    }
}

/// 设置界面用的资产/支持性查询封装(同样受编译门控,调用方经 #if compiler(>=6.2) 访问)。
@available(macOS 26.0, *)
enum SpeechAnalyzerAssetStatus {
    /// locale 是否受支持(bcp47 对比)。
    static func isSupported(_ identifier: String) async -> Bool {
        let locale = Locale(identifier: identifier)
        return await SpeechTranscriber.supportedLocales.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
    }

    /// locale 的语音资产是否已安装。
    static func isInstalled(_ identifier: String) async -> Bool {
        let locale = Locale(identifier: identifier)
        return await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
    }

    /// 主动下载 locale 资产(设置侧入口)。无需下载时直接返回。
    static func ensureInstalled(_ identifier: String) async throws {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: identifier),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}

#endif
