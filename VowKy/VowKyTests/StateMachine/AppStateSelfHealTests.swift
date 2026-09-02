import XCTest
@testable import VowKy

// MARK: - 音频卡死自愈接线（AppState 侧）
// Mock classes are in Mocks/TestMocks.swift

@MainActor
final class AppStateSelfHealTests: XCTestCase {

    var mockRecognizer: MockSpeechRecognizer!
    var mockRecorder: MockAudioRecorder!
    var mockPermission: MockPermissionChecker!
    var appState: AppState!
    var suiteName: String!
    var defaults: UserDefaults!

    @MainActor
    override func setUp() {
        super.setUp()
        mockRecognizer = MockSpeechRecognizer()
        mockRecorder = MockAudioRecorder()
        mockPermission = MockPermissionChecker()
        appState = AppState(
            speechRecognizer: mockRecognizer,
            audioRecorder: mockRecorder,
            permissionChecker: mockPermission
        )
        suiteName = "selfheal.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // 绝不碰真实 UserDefaults：节流时间戳会污染用户机器上的自愈状态
        appState.selfHealDefaults = defaults
        appState.selfHealRelaunch = { XCTFail("未注入的重启不应发生") }
    }

    @MainActor
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        appState = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - (a) 空闲时卡死 → 提示即将重启 + 真的重启 + 时间戳落盘

    func test01_idleWedge_showsRelaunchingMessage_thenRelaunches() {
        let relaunched = expectation(description: "relaunch called")
        appState.selfHealRelaunch = { relaunched.fulfill() }

        appState.handleAudioWedged(phase: "start")

        XCTAssertEqual(appState.errorMessage, L("appState.error.audioWedgedRelaunching"))
        XCTAssertTrue(appState.pendingSelfHeal)

        wait(for: [relaunched], timeout: 3.0)

        XCTAssertNotNil(AudioSelfHealStore.loadLastRelaunchAt(defaults: defaults),
                        "重启前必须先把节流时间戳落盘")
        XCTAssertFalse(appState.pendingSelfHeal)
    }

    // MARK: - (b) 10 分钟内第二次 → 节流，只提示手动重启

    func test02_throttledWithinInterval_showsManualRestart_doesNotRelaunch() {
        AudioSelfHealStore.saveLastRelaunchAt(Date().addingTimeInterval(-10), defaults: defaults)

        let mustNotRelaunch = expectation(description: "relaunch must not happen")
        mustNotRelaunch.isInverted = true
        appState.selfHealRelaunch = { mustNotRelaunch.fulfill() }

        appState.handleAudioWedged(phase: "start")

        XCTAssertEqual(appState.errorMessage, L("appState.error.audioWedgedManualRestart"))
        XCTAssertFalse(appState.pendingSelfHeal)

        wait(for: [mustNotRelaunch], timeout: 2.5)
    }

    // MARK: - (c) 干活中卡死 → 等回到空闲再重启（不能把用户说的话弄丢）

    func test03_wedgeWhileBusy_defersRelaunchUntilIdle() {
        appState.state = .recognizing

        let mustNotRelaunchYet = expectation(description: "no relaunch while busy")
        mustNotRelaunchYet.isInverted = true
        appState.selfHealRelaunch = { mustNotRelaunchYet.fulfill() }

        appState.handleAudioWedged(phase: "stop")
        XCTAssertTrue(appState.pendingSelfHeal)
        wait(for: [mustNotRelaunchYet], timeout: 2.5)

        let relaunched = expectation(description: "relaunch after idle")
        appState.selfHealRelaunch = { relaunched.fulfill() }
        appState.state = .idle
        wait(for: [relaunched], timeout: 3.0)
    }

    // MARK: - (d) 录音转写进行中同样推迟，结束后补上

    func test04_wedgeDuringRecordingTranscription_defersUntilEnd() {
        XCTAssertNil(appState.beginRecordingTranscription())

        let mustNotRelaunchYet = expectation(description: "no relaunch during transcription")
        mustNotRelaunchYet.isInverted = true
        appState.selfHealRelaunch = { mustNotRelaunchYet.fulfill() }

        appState.handleAudioWedged(phase: "start")
        XCTAssertTrue(appState.pendingSelfHeal)
        wait(for: [mustNotRelaunchYet], timeout: 2.5)

        let relaunched = expectation(description: "relaunch after transcription ends")
        appState.selfHealRelaunch = { relaunched.fulfill() }
        appState.endRecordingTranscription()
        wait(for: [relaunched], timeout: 3.0)
    }

    // MARK: - (d2) 后台文件转录进行中同样推迟，结束后补上

    func test06_fileTranscriptionInProgress_defersRelaunchUntilEnd() {
        XCTAssertNil(appState.beginFileTranscription())

        let mustNotRelaunchYet = expectation(description: "no relaunch during file transcription")
        mustNotRelaunchYet.isInverted = true
        appState.selfHealRelaunch = { mustNotRelaunchYet.fulfill() }

        appState.handleAudioWedged(phase: "start")
        XCTAssertTrue(appState.pendingSelfHeal)
        wait(for: [mustNotRelaunchYet], timeout: 2.5)

        let relaunched = expectation(description: "relaunch after file transcription ends")
        relaunched.expectedFulfillmentCount = 1
        relaunched.assertForOverFulfill = true
        appState.selfHealRelaunch = { relaunched.fulfill() }
        appState.endFileTranscription()
        wait(for: [relaunched], timeout: 3.0)
    }

    // MARK: - (e) 同一次卡死重复上报只重启一次

    func test05_repeatedWedgeReports_relaunchOnlyOnce() {
        let relaunched = expectation(description: "relaunch called once")
        relaunched.expectedFulfillmentCount = 1
        relaunched.assertForOverFulfill = true
        appState.selfHealRelaunch = { relaunched.fulfill() }

        appState.handleAudioWedged(phase: "start")
        appState.handleAudioWedged(phase: "stop")
        appState.handleAudioWedged(phase: "start")

        wait(for: [relaunched], timeout: 3.0)
    }
}
