import Foundation

/// auto 模式（语言=「自动」）的文件/链接转录包装器（用户拍板「抽样检测」2026-08-02）：
/// 按需解码头/中/尾三个 ~10s 窗喂本地 SenseVoice 探测语言 → 单语言委派极速引擎全量转录
/// （保住长文件的速度优势）；混说/歧义/未安装委派本地切块路径。
/// 极速委派抛错（取消除外）时包装器内回落本地服务——两引擎间的运行时回落决策收敛于此一处，绝不丢转录。
/// 不编译门控：极速转写器经 analyzerFactory 闭包注入（live 闭包在 AppState 的门控块内构造）。
final class AutoRoutingFileTranscriber: FileTranscribing {

    /// 探测窗时长；≤ shortFileThreshold 的短文件退化为整段单窗。
    private static let probeWindowDuration: TimeInterval = 10
    private static let shortFileThreshold: TimeInterval = 35

    private let decoder: MediaAudioDecoding
    private let probeRecognizer: SpeechRecognizerProtocol
    private let senseVoiceService: FileTranscribing
    private let analyzerFactory: (String) -> FileTranscribing?
    private let installedLocales: () async -> Set<String>
    /// 礼让闸：每个探测窗前调用，语音输入活动时挂起（探测与听写共用 helper）。
    private let yieldToVoiceInput: (() async -> Void)?

    init(
        decoder: MediaAudioDecoding,
        probeRecognizer: SpeechRecognizerProtocol,
        senseVoiceService: FileTranscribing,
        analyzerFactory: @escaping (String) -> FileTranscribing?,
        installedLocales: @escaping () async -> Set<String>,
        yieldToVoiceInput: (() async -> Void)? = nil
    ) {
        self.decoder = decoder
        self.probeRecognizer = probeRecognizer
        self.senseVoiceService = senseVoiceService
        self.analyzerFactory = analyzerFactory
        self.installedLocales = installedLocales
        self.yieldToVoiceInput = yieldToVoiceInput
    }

    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String {
        let decision = try await probeRouteDecision(url: url, progress: progress)
        if case .analyzer(let locale) = decision, let analyzer = analyzerFactory(locale) {
            do {
                return try await analyzer.transcribe(url: url, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 资产缺失/不支持/极速失败 → 回落本地切块路径（本地再失败才把错误抛给用户）
                NSLog("[VowKy][AutoRoute] 极速引擎转录失败，回落本地切块路径: \(error.localizedDescription)")
            }
        }
        return try await senseVoiceService.transcribe(url: url, progress: progress)
    }

    // MARK: - 语言探测

    private func probeRouteDecision(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> AnalyzerRouteDecision {
        do {
            await progress(FileTranscriptionProgress(
                phase: .reading, progress: 0, currentSegment: 0, totalSegments: 0, partialText: ""
            ))
            let info = try await decoder.loadInfo(url: url)
            var probeTexts: [String] = []
            for window in Self.probeWindows(duration: info.duration) {
                try Task.checkCancellation()
                await yieldToVoiceInput?()
                let audio = try await decoder.decode(url: url, timeRange: window)
                if let text = await probeRecognizer.recognize(samples: audio.samples, sampleRate: audio.sampleRate),
                   !text.isEmpty {
                    probeTexts.append(text)
                }
            }
            let installed = await installedLocales()
            return AnalyzerLocaleRouter.route(
                text: probeTexts.joined(separator: " "),
                installedLocales: installed
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 探测失败不致命：按无信号处理，走本地路径
            NSLog("[VowKy][AutoRoute] 语言探测失败，走本地路径: \(error.localizedDescription)")
            return .keepSenseVoice(.noSignal)
        }
    }

    /// 头/中/尾三窗（贴边 clamp、去重叠）；短文件整段单窗。internal 供单测直验。
    static func probeWindows(duration: TimeInterval) -> [MediaAudioTimeRange] {
        guard duration > 0 else { return [] }
        if duration <= shortFileThreshold {
            return [MediaAudioTimeRange(start: 0, duration: duration)]
        }
        let w = probeWindowDuration
        var windows: [MediaAudioTimeRange] = []
        for start in [0, (duration - w) / 2, duration - w] {
            let clamped = max(0, min(start, duration - w))
            if let last = windows.last, clamped < last.end { continue }
            windows.append(MediaAudioTimeRange(start: clamped, duration: w))
        }
        return windows
    }
}
