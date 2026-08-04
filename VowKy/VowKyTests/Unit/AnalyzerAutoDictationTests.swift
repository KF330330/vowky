import XCTest
@testable import VowKy

/// AnalyzerAutoDictation lazy sticky 编排（用户拍板「极速优先」）：
/// 每句立刻用 sticky locale 极速出字，后台检测只影响下一句 sticky。
/// scheduleDetection 由测试捕获后显式 drain，消除后台竞态。
final class AnalyzerAutoDictationTests: XCTestCase {

    private final class StubAnalyzer: SpeechRecognizerProtocol {
        var result: String?
        private(set) var callCount = 0
        var isReady: Bool = true
        init(_ result: String?) { self.result = result }
        func recognize(samples: [Float], sampleRate: Int) async -> String? {
            callCount += 1
            return result
        }
    }

    private final class Harness {
        var analyzers: [String: StubAnalyzer] = [:]
        private(set) var recognizerRequests: [String] = []
        var sticky: String
        private(set) var stickyUpdates: [String] = []
        var installed: Set<String> = ["zh-CN", "en-US", "ja-JP", "ko-KR"]
        var svResults: [String?] = []
        private(set) var svCallCount = 0
        private(set) var installRequests: [String] = []
        private var pendingDetections: [() async -> Void] = []
        var detectionScheduledCount: Int { scheduledCount }
        private var scheduledCount = 0

        init(sticky: String) { self.sticky = sticky }

        func context() -> AnalyzerAutoDictationContext {
            AnalyzerAutoDictationContext(
                recognizerForLocale: { locale in
                    self.recognizerRequests.append(locale)
                    return self.analyzers[locale]
                },
                stickyLocale: { self.sticky },
                updateStickyLocale: {
                    self.stickyUpdates.append($0)
                    self.sticky = $0
                },
                installedLocales: { self.installed },
                scheduleDetection: {
                    self.scheduledCount += 1
                    self.pendingDetections.append($0)
                },
                requestAssetInstall: { self.installRequests.append($0) }
            )
        }

        func senseVoice(_ samples: [Float]) async -> String? {
            svCallCount += 1
            return svResults.isEmpty ? nil : svResults.removeFirst()
        }

        func drainDetections() async {
            while !pendingDetections.isEmpty {
                await pendingDetections.removeFirst()()
            }
        }
    }

    private let samples: [Float] = [0.1, -0.2, 0.3]

    private func recognize(_ harness: Harness) async -> String? {
        await AnalyzerAutoDictation.recognize(
            samples: samples, sampleRate: 16000,
            senseVoice: { await harness.senseVoice($0) },
            context: harness.context()
        )
    }

    // MARK: - sticky 命中：极速文本立即返回，后台检测更新 sticky

    func test01_stickyHit_returnsAnalyzerText_detectionConfirmsSticky() async {
        let harness = Harness(sticky: "zh-CN")
        harness.analyzers["zh-CN"] = StubAnalyzer("极速稿")
        harness.svResults = ["你好世界今天天气不错我们出去走走"]

        let result = await recognize(harness)
        XCTAssertEqual(result, "极速稿")
        XCTAssertEqual(harness.recognizerRequests, ["zh-CN"])

        await harness.drainDetections()
        XCTAssertEqual(harness.svCallCount, 1)
        XCTAssertEqual(harness.stickyUpdates, ["zh-CN"]) // 检测确认中文，sticky 不变
    }

    func test02_detectionFindsJapanese_stickySwitchesForNextUtterance() async {
        let harness = Harness(sticky: "zh-CN")
        harness.analyzers["zh-CN"] = StubAnalyzer("按中文识别的本句结果")
        harness.svResults = ["今日は会議がありますのでよろしくお願いします"]

        let result = await recognize(harness)
        XCTAssertEqual(result, "按中文识别的本句结果") // 本句结果不变（拍板接受的代价）

        await harness.drainDetections()
        XCTAssertEqual(harness.sticky, "ja-JP") // 下一句起用日语
    }

    func test03_detectionFindsMixed_stickyFallsToSenseVoice() async {
        let harness = Harness(sticky: "zh-CN")
        harness.analyzers["zh-CN"] = StubAnalyzer("本句极速结果")
        harness.svResults = ["我们今天讨论了三个重要问题都解决了ありがとうございます"]

        _ = await recognize(harness)
        await harness.drainDetections()
        XCTAssertEqual(harness.sticky, SpeechEngineConfigStore.autoStickySenseVoiceValue)
    }

    // MARK: - SA ""/nil 契约

    func test04_analyzerEmptyString_returnsAsIs_noDetection() async {
        let harness = Harness(sticky: "zh-CN")
        harness.analyzers["zh-CN"] = StubAnalyzer("")

        let result = await recognize(harness)
        XCTAssertEqual(result, "") // 无语音：原样返回不回落（契约与手动模式一致）
        XCTAssertEqual(harness.detectionScheduledCount, 0)
        XCTAssertEqual(harness.svCallCount, 0)
        XCTAssertTrue(harness.stickyUpdates.isEmpty)
    }

    func test05_analyzerNil_fallsBackToSenseVoice_andRoutesInline() async {
        let harness = Harness(sticky: "zh-CN")
        harness.analyzers["zh-CN"] = StubAnalyzer(nil) // infra 失败
        harness.svResults = ["今日は会議がありますのでよろしくお願いします"]

        let result = await recognize(harness)
        XCTAssertEqual(result, "今日は会議がありますのでよろしくお願いします")
        XCTAssertEqual(harness.svCallCount, 1)
        XCTAssertEqual(harness.detectionScheduledCount, 0) // 前台文本在手，检测免费不走后台
        XCTAssertEqual(harness.sticky, "ja-JP")
    }

    // MARK: - sticky=senseVoice：前台本地 + 单语言句逃逸回极速

    func test06_stickySenseVoice_usesSenseVoice_escapesOnSingleLanguage() async {
        let harness = Harness(sticky: SpeechEngineConfigStore.autoStickySenseVoiceValue)
        harness.svResults = ["今日は会議がありますのでよろしくお願いします"]

        let result = await recognize(harness)
        XCTAssertEqual(result, "今日は会議がありますのでよろしくお願いします")
        XCTAssertTrue(harness.recognizerRequests.isEmpty) // 不建 SA 实例
        XCTAssertEqual(harness.sticky, "ja-JP") // 逃逸回极速
    }

    func test07_stickySenseVoice_svNil_returnsNilUntouched() async {
        // 保全判据在调用方（isReady），此处只验证 nil 透传、sticky 不动
        let harness = Harness(sticky: SpeechEngineConfigStore.autoStickySenseVoiceValue)
        harness.svResults = [nil]

        let result = await recognize(harness)
        XCTAssertNil(result)
        XCTAssertTrue(harness.stickyUpdates.isEmpty)
    }

    // MARK: - 未安装 / 无信号

    func test08_detectionTargetNotInstalled_stickyFallsToSenseVoice_andRequestsInstall() async {
        let harness = Harness(sticky: "zh-CN")
        harness.analyzers["zh-CN"] = StubAnalyzer("本句极速结果")
        harness.installed = ["zh-CN", "en-US"] // ja-JP 未安装
        harness.svResults = ["今日は会議がありますのでよろしくお願いします"]

        _ = await recognize(harness)
        await harness.drainDetections()
        XCTAssertEqual(harness.sticky, SpeechEngineConfigStore.autoStickySenseVoiceValue)
        XCTAssertEqual(harness.installRequests, ["ja-JP"], "缺失语言按需触发后台下载")
    }

    func test09_detectionNoSignal_stickyUnchanged() async {
        let harness = Harness(sticky: "zh-CN")
        harness.analyzers["zh-CN"] = StubAnalyzer("本句极速结果")
        harness.svResults = ["ok"] // latin < 4 → noSignal

        _ = await recognize(harness)
        await harness.drainDetections()
        XCTAssertTrue(harness.stickyUpdates.isEmpty)
        XCTAssertEqual(harness.sticky, "zh-CN")
    }

    func test10_analyzerNil_svEmpty_returnsEmpty_noStickyUpdate() async {
        let harness = Harness(sticky: "zh-CN")
        harness.analyzers["zh-CN"] = StubAnalyzer(nil)
        harness.svResults = [""]

        let result = await recognize(harness)
        XCTAssertEqual(result, "")
        XCTAssertTrue(harness.stickyUpdates.isEmpty)
    }

    // MARK: - 低置信度回落（2026-08-04，阈值 p10<0.6）

    /// 给 harness 注入带置信度的极速识别
    private func setConfidence(_ harness: Harness, text: String?, p10: Double?) -> AnalyzerAutoDictationContext {
        var context = harness.context()
        context.recognizeWithConfidence = { _, _, _ in
            guard let text else { return nil }
            return (text, p10)
        }
        return context
    }

    private func recognizeWithConfidence(_ harness: Harness, text: String?, p10: Double?) async -> String? {
        await AnalyzerAutoDictation.recognize(
            samples: samples, sampleRate: 16000,
            senseVoice: { await harness.senseVoice($0) },
            context: setConfidence(harness, text: text, p10: p10)
        )
    }

    func test11_lowConfidence_usesSenseVoiceText_inForeground() async {
        let harness = Harness(sticky: "zh-CN")
        harness.svResults = ["把日志级别调成调试模式就能看到完整的请求链路"]

        let result = await recognizeWithConfidence(harness, text: "把日志几倍调成调试模式", p10: 0.35)
        XCTAssertEqual(result, "把日志级别调成调试模式就能看到完整的请求链路")
        XCTAssertEqual(harness.svCallCount, 1)
        XCTAssertEqual(harness.detectionScheduledCount, 0, "前台已检测，不再走后台")
        XCTAssertEqual(harness.sticky, "zh-CN", "路由照常更新")
    }

    func test12_highConfidence_keepsAnalyzerText_backgroundDetection() async {
        let harness = Harness(sticky: "zh-CN")
        harness.svResults = ["你好世界今天天气不错我们出去走走"]

        let result = await recognizeWithConfidence(harness, text: "极速稿", p10: 0.95)
        XCTAssertEqual(result, "极速稿")
        XCTAssertEqual(harness.detectionScheduledCount, 1)
        await harness.drainDetections()
        XCTAssertEqual(harness.svCallCount, 1)
    }

    func test13_noConfidenceValue_neverFallsBack() async {
        let harness = Harness(sticky: "zh-CN")
        harness.svResults = ["你好世界今天天气不错我们出去走走"]

        let result = await recognizeWithConfidence(harness, text: "极速稿", p10: nil)
        XCTAssertEqual(result, "极速稿")
        XCTAssertEqual(harness.detectionScheduledCount, 1, "无置信度＝老行为，只走后台检测")
    }

    func test14_lowConfidence_svFails_keepsAnalyzerText() async {
        let harness = Harness(sticky: "zh-CN")
        harness.svResults = [nil]

        let result = await recognizeWithConfidence(harness, text: "极速稿", p10: 0.2)
        XCTAssertEqual(result, "极速稿", "本地失败保底极速文本")
        XCTAssertTrue(harness.stickyUpdates.isEmpty)
    }

    func test15_lowConfidence_svEmpty_keepsAnalyzerText() async {
        let harness = Harness(sticky: "zh-CN")
        harness.svResults = [""]

        let result = await recognizeWithConfidence(harness, text: "极速稿", p10: 0.2)
        XCTAssertEqual(result, "极速稿")
    }

    func test16_thresholdBoundary_atThreshold_noFallback() async {
        let harness = Harness(sticky: "zh-CN")
        harness.svResults = ["你好世界今天天气不错我们出去走走"]

        let result = await recognizeWithConfidence(
            harness, text: "极速稿", p10: AnalyzerAutoDictation.lowConfidenceP10Threshold
        )
        XCTAssertEqual(result, "极速稿", "恰好等于阈值不回落（严格小于才回落）")
        XCTAssertEqual(harness.detectionScheduledCount, 1)
    }

    func test17_confidencePath_infraFailure_fallsBackToSenseVoice() async {
        let harness = Harness(sticky: "zh-CN")
        harness.svResults = ["今日は会議がありますのでよろしくお願いします"]

        let result = await recognizeWithConfidence(harness, text: nil, p10: nil)
        XCTAssertEqual(result, "今日は会議がありますのでよろしくお願いします")
        XCTAssertEqual(harness.sticky, "ja-JP")
    }
}
