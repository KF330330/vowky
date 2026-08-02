// SpeechAnalyzer 极速引擎的听写适配：把内存样本包成单个 PCM buffer 走一次性
// analyzer 会话，暴露成 SpeechRecognizerProtocol 供热键听写路径按引擎选择使用。
//
// 返回契约（AppState.recognizeForDictation 依赖，改动前先看调用方）：
//   nil = 基础设施失败（语音资产未装 / 会话失败）→ 调用方回落 SenseVoice；
//   ""  = 会话成功但没识别到语音 → 调用方按「无内容」处理（删备份，不回落）。
// 音频保全判据永远只看 SenseVoice transport 的 isReady——本类失败必先回落，
// 绝不因 SpeechAnalyzer 单独失败触发音频保全。
//
// 编译门控同 SpeechAnalyzerFileTranscriber：必须 compiler(>=6.2) 整文件隔离。
#if compiler(>=6.2)

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class SpeechAnalyzerSpeechRecognizer: SpeechRecognizerProtocol {

    private let localeIdentifier: String
    /// 资产就绪缓存（warmUp / 每次 recognize 刷新）。听写路径绝不触发资产下载
    /// （下载入口在设置页），资产未装直接返回 nil 让调用方回落。
    private var assetReady = false

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    var isReady: Bool { assetReady }

    func warmUp() async {
        assetReady = await SpeechAnalyzerAssetStatus.isInstalled(localeIdentifier)
    }

    func recognize(samples: [Float], sampleRate: Int) async -> String? {
        guard !samples.isEmpty else { return "" }
        guard await SpeechAnalyzerAssetStatus.isInstalled(localeIdentifier) else {
            assetReady = false
            NSLog("[VowKy][SpeechAnalyzer] 听写：语音资产未安装(\(localeIdentifier))，回落本地引擎")
            return nil
        }
        assetReady = true

        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: localeIdentifier),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let collectTask = Task<String, Error> {
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts.joined()
        }

        do {
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputSequence)
            guard let buffer = SpeechAnalyzerAudio.makeBuffer(
                samples: samples,
                sampleRate: sampleRate,
                targetFormat: analysisFormat
            ) else {
                collectTask.cancel()
                await analyzer.cancelAndFinishNow()
                NSLog("[VowKy][SpeechAnalyzer] 听写：音频格式转换失败，回落本地引擎")
                return nil
            }
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            inputBuilder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await collectTask.value
            return SpeechAnalyzerTextCleaner.clean(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            collectTask.cancel()
            await analyzer.cancelAndFinishNow()
            NSLog("[VowKy][SpeechAnalyzer] 听写识别失败，回落本地引擎: \(error.localizedDescription)")
            return nil
        }
    }
}

#endif
