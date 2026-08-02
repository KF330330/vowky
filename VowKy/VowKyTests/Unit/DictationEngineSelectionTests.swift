import XCTest
@testable import VowKy

// 听写引擎选择（引擎切换全局化，2026-08-02）：
// 极速引擎（SpeechAnalyzer）经 analyzerDictationRecognizerProvider 注入缝生效；
// 返回契约：nil = 基础设施失败 → 回落 SenseVoice；"" = 成功无语音 → 按无内容处理。
// 音频保全红线：只由 SenseVoice transport 的 isReady 驱动，SA 单独失败绝不触发。

@MainActor
final class DictationEngineSelectionTests: XCTestCase {

    var mockSenseVoice: MockSpeechRecognizer!
    var mockAnalyzer: MockSpeechRecognizer!
    var mockRecorder: MockAudioRecorder!
    var mockPermission: MockPermissionChecker!
    var mockBackup: MockAudioBackupService!
    var appState: AppState!

    @MainActor
    override func setUp() {
        super.setUp()
        mockSenseVoice = MockSpeechRecognizer()
        mockAnalyzer = MockSpeechRecognizer()
        mockRecorder = MockAudioRecorder()
        mockPermission = MockPermissionChecker()
        mockBackup = MockAudioBackupService()
    }

    @MainActor
    override func tearDown() {
        appState = nil
        mockSenseVoice = nil
        mockAnalyzer = nil
        mockRecorder = nil
        mockPermission = nil
        mockBackup = nil
        super.tearDown()
    }

    /// provider 返回 mockAnalyzer（= 引擎裁决为 SpeechAnalyzer）；passNil 模拟裁决为 SenseVoice。
    private func makeAppState(analyzerProvided: Bool) {
        let analyzer: MockSpeechRecognizer? = analyzerProvided ? mockAnalyzer : nil
        appState = AppState(
            speechRecognizer: mockSenseVoice,
            audioRecorder: mockRecorder,
            permissionChecker: mockPermission,
            backupService: mockBackup,
            analyzerDictationRecognizerProvider: { analyzer }
        )
    }

    private func dictateOnce() async throws {
        appState.handleHotkeyToggle() // idle → recording
        appState.handleHotkeyToggle() // recording → recognizing
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func test01_analyzerSuccess_usesAnalyzerText_senseVoiceUntouched() async throws {
        makeAppState(analyzerProvided: true)
        mockAnalyzer.recognizeResult = "极速引擎结果"
        mockSenseVoice.recognizeResult = "本地引擎结果"

        try await dictateOnce()

        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(appState.lastResult, "极速引擎结果")
        XCTAssertEqual(mockAnalyzer.recognizeCallCount, 1)
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 0, "SA 成功时 SenseVoice 不应被调用")
        XCTAssertEqual(mockBackup.finalizeAndDeleteCallCount, 1)
        XCTAssertEqual(mockBackup.preserveBackupCallCount, 0)
    }

    func test02_analyzerNil_fallsBackToSenseVoice_noPreserve() async throws {
        makeAppState(analyzerProvided: true)
        mockAnalyzer.recognizeResult = nil // SA 基础设施失败
        mockSenseVoice.recognizeResult = "回落成功"

        try await dictateOnce()

        XCTAssertEqual(appState.lastResult, "回落成功")
        XCTAssertEqual(mockAnalyzer.recognizeCallCount, 1)
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 1)
        XCTAssertEqual(mockBackup.preserveBackupCallCount, 0, "SA 单独失败绝不触发音频保全")
        XCTAssertEqual(mockBackup.finalizeAndDeleteCallCount, 1)
    }

    func test03_bothEnginesDown_preservesBackup() async throws {
        makeAppState(analyzerProvided: true)
        mockAnalyzer.recognizeResult = nil
        mockSenseVoice.recognizeResult = nil
        mockSenseVoice.isReady = false // transport 失败路径会同步清 readyState

        try await dictateOnce()

        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 2, "SenseVoice infra 失败仍重试一次")
        XCTAssertEqual(mockBackup.preserveBackupCallCount, 1, "双引擎皆挂必须保全音频")
        XCTAssertEqual(mockBackup.deleteBackupCallCount, 0)
    }

    func test04_analyzerEmptyString_noSpeech_deletesBackup_noFallback() async throws {
        makeAppState(analyzerProvided: true)
        mockAnalyzer.recognizeResult = "" // SA 成功但无语音
        mockSenseVoice.recognizeResult = "不应出现"

        try await dictateOnce()

        XCTAssertNil(appState.lastResult)
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 0, "SA 明确说无语音，不回落")
        XCTAssertEqual(mockBackup.deleteBackupCallCount, 1)
        XCTAssertEqual(mockBackup.preserveBackupCallCount, 0)
    }

    func test05_providerNil_senseVoicePathUnchanged() async throws {
        makeAppState(analyzerProvided: false)
        mockSenseVoice.recognizeResult = "本地引擎结果"

        try await dictateOnce()

        XCTAssertEqual(appState.lastResult, "本地引擎结果")
        XCTAssertEqual(mockAnalyzer.recognizeCallCount, 0)
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 1)
    }

    // MARK: - auto 模式（lazy sticky，语言=「自动」）

    /// 后台检测由测试捕获后显式 drain，消除竞态。
    private final class AutoHarness {
        var sticky: String
        private(set) var stickyUpdates: [String] = []
        private var pendingDetections: [() async -> Void] = []
        init(sticky: String) { self.sticky = sticky }

        func context(analyzer: MockSpeechRecognizer?) -> AnalyzerAutoDictationContext {
            AnalyzerAutoDictationContext(
                recognizerForLocale: { _ in analyzer },
                stickyLocale: { self.sticky },
                updateStickyLocale: {
                    self.stickyUpdates.append($0)
                    self.sticky = $0
                },
                installedLocales: { ["zh-CN", "en-US", "ja-JP", "ko-KR"] },
                scheduleDetection: { self.pendingDetections.append($0) }
            )
        }

        func drainDetections() async {
            while !pendingDetections.isEmpty {
                await pendingDetections.removeFirst()()
            }
        }
    }

    private func makeAppState(autoContext: AnalyzerAutoDictationContext) {
        appState = AppState(
            speechRecognizer: mockSenseVoice,
            audioRecorder: mockRecorder,
            permissionChecker: mockPermission,
            backupService: mockBackup,
            analyzerAutoDictationProvider: { autoContext }
        )
    }

    func test06_autoMode_stickyHit_insertsAnalyzerText_detectionOnlyAffectsNext() async throws {
        let harness = AutoHarness(sticky: "zh-CN")
        makeAppState(autoContext: harness.context(analyzer: mockAnalyzer))
        mockAnalyzer.recognizeResult = "极速稿"
        mockSenseVoice.recognizeResult = "今日は会議がありますのでよろしくお願いします"

        try await dictateOnce()

        XCTAssertEqual(appState.lastResult, "极速稿", "极速出字不等本地引擎")
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 0)
        XCTAssertEqual(mockBackup.finalizeAndDeleteCallCount, 1)
        XCTAssertEqual(mockBackup.preserveBackupCallCount, 0)

        // drain 后台检测：本地识别出日语 → sticky 切到 ja-JP（只影响下一句）
        await harness.drainDetections()
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 1)
        XCTAssertEqual(harness.sticky, "ja-JP")
        XCTAssertEqual(appState.lastResult, "极速稿", "本句结果不重识别不重插")
    }

    func test07_autoMode_analyzerNil_fallsBackToSenseVoice_noPreserve() async throws {
        let harness = AutoHarness(sticky: "zh-CN")
        makeAppState(autoContext: harness.context(analyzer: mockAnalyzer))
        mockAnalyzer.recognizeResult = nil // SA infra 失败
        mockSenseVoice.recognizeResult = "回落成功这里是一段中文结果"

        try await dictateOnce()

        XCTAssertEqual(appState.lastResult, "回落成功这里是一段中文结果")
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 1)
        XCTAssertEqual(mockBackup.preserveBackupCallCount, 0, "SA 单独失败绝不触发音频保全")
        XCTAssertEqual(mockBackup.finalizeAndDeleteCallCount, 1)
        XCTAssertEqual(harness.stickyUpdates, ["zh-CN"], "回落文本在手，前台顺手路由")
    }

    func test08_autoMode_bothInfraDown_preservesBackup() async throws {
        let harness = AutoHarness(sticky: "zh-CN")
        makeAppState(autoContext: harness.context(analyzer: mockAnalyzer))
        mockAnalyzer.recognizeResult = nil
        mockSenseVoice.recognizeResult = nil
        mockSenseVoice.isReady = false // transport 失败路径会同步清 readyState

        try await dictateOnce()

        XCTAssertEqual(appState.state, .idle)
        XCTAssertEqual(mockSenseVoice.recognizeCallCount, 2, "SenseVoice infra 失败仍重试一次")
        XCTAssertEqual(mockBackup.preserveBackupCallCount, 1, "双引擎皆挂必须保全音频（红线回归）")
        XCTAssertEqual(mockBackup.deleteBackupCallCount, 0)
        XCTAssertTrue(harness.stickyUpdates.isEmpty)
    }

    func test09_autoMode_stickySenseVoice_usesSenseVoice_escapesOnSingleLanguage() async throws {
        let harness = AutoHarness(sticky: SpeechEngineConfigStore.autoStickySenseVoiceValue)
        makeAppState(autoContext: harness.context(analyzer: mockAnalyzer))
        mockSenseVoice.recognizeResult = "今日は会議がありますのでよろしくお願いします"

        try await dictateOnce()

        XCTAssertEqual(appState.lastResult, "今日は会議がありますのでよろしくお願いします")
        XCTAssertEqual(mockAnalyzer.recognizeCallCount, 0, "sticky=senseVoice 不建 SA 会话")
        XCTAssertEqual(harness.sticky, "ja-JP", "单语言句检测后逃逸回极速（下一句生效）")
    }
}
