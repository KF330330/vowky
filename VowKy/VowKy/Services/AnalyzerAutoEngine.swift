import Foundation

/// auto 模式听写编排的依赖束。live 版由 AppState.liveAnalyzerAutoDictationProvider()
/// 在编译门控内构造；单测注入闭包 mock（scheduleDetection 注入内联执行以消竞态）。
/// 本文件不编译门控：只依赖协议与闭包，不触碰 SpeechAnalyzer 符号。
struct AnalyzerAutoDictationContext {
    /// 按 locale 取极速识别器（live 版内部按 locale 缓存实例）；不可用返回 nil
    let recognizerForLocale: (String) -> SpeechRecognizerProtocol?
    /// sticky 状态：四候选 locale 或 autoStickySenseVoiceValue（下一句直接用本地引擎）
    let stickyLocale: () -> String
    let updateStickyLocale: (String) -> Void
    let installedLocales: () async -> Set<String>
    /// 后台检测的调度方式：生产 = Task {}；测试 = 内联 await
    let scheduleDetection: (@escaping () async -> Void) -> Void
    /// 目标语言资产未安装时的按需后台下载（全自动理念：缺什么补什么，下载期间本地引擎兜底）
    var requestAssetInstall: ((String) -> Void)? = nil
}

/// auto 模式录音终稿的依赖束（路由决策在 RecordingTranscriptionViewModel.runAnalyzerFinalPass）。
struct AnalyzerAutoFinalPassContext {
    /// 按 locale 建终稿转写器；不可用返回 nil
    let transcriberForLocale: (String) -> FileTranscribing?
    let installedLocales: () async -> Set<String>
    /// 目标语言资产未安装时的按需后台下载
    var requestAssetInstall: ((String) -> Void)? = nil
}

/// 听写 auto 编排（lazy sticky，用户拍板「极速优先」2026-08-02）：
/// 每句立刻用 sticky locale 极速出字；本地 SenseVoice 在后台检测本句语言、只影响下一句 sticky。
/// 已知代价（用户知情接受）：切语言后第一句、sticky 为单语言时的混说句，按旧 locale 识别出错。
/// 契约与手动模式一致：SA nil=infra 失败→回落本地；""=无语音原样返回不回落；
/// 音频保全判据仍由调用方按 speechRecognizer.isReady 判定，本编排不触碰。
enum AnalyzerAutoDictation {

    static func recognize(
        samples: [Float],
        sampleRate: Int,
        senseVoice: @escaping ([Float]) async -> String?,
        context: AnalyzerAutoDictationContext
    ) async -> String? {
        let sticky = context.stickyLocale()

        if sticky != SpeechEngineConfigStore.autoStickySenseVoiceValue,
           let analyzer = context.recognizerForLocale(sticky) {
            if let text = await analyzer.recognize(samples: samples, sampleRate: sampleRate) {
                guard !text.isEmpty else { return text } // 无语音：不检测不回落
                // 极速文本立即返回；后台检测本句语言 → 更新下一句 sticky
                context.scheduleDetection {
                    guard let svText = await senseVoice(samples), !svText.isEmpty else { return }
                    await applyRoute(for: svText, context: context)
                }
                return text
            }
            CrashLogger.log("[AutoDictation] SpeechAnalyzer(\(sticky)) failed, falling back to SenseVoice")
        }

        // sticky=senseVoice 或 SA infra 失败：前台走本地（senseVoice 闭包已封装既有重试语义）；
        // 文本在手 → 检测免费，顺手更新 sticky（单语言句即逃逸回极速）
        let result = await senseVoice(samples)
        if let svText = result, !svText.isEmpty {
            await applyRoute(for: svText, context: context)
        }
        return result
    }

    private static func applyRoute(for text: String, context: AnalyzerAutoDictationContext) async {
        let installed = await context.installedLocales()
        switch AnalyzerLocaleRouter.route(text: text, installedLocales: installed) {
        case .analyzer(let locale):
            context.updateStickyLocale(locale)
        case .keepSenseVoice(.notInstalled(let locale)):
            // 下载期间/失败由本地兜底；装好后下一次单语言句路由即自动逃逸回极速
            context.requestAssetInstall?(locale)
            context.updateStickyLocale(SpeechEngineConfigStore.autoStickySenseVoiceValue)
        case .keepSenseVoice(.mixed), .keepSenseVoice(.likelyCantonese):
            context.updateStickyLocale(SpeechEngineConfigStore.autoStickySenseVoiceValue)
        case .keepSenseVoice(.noSignal):
            break // 无信号不动 sticky
        }
    }
}
