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
}
