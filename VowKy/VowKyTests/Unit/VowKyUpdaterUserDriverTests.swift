import XCTest
import Sparkle
@testable import VowKy

/// VowKyUpdaterUserDriver 进度接管测试:progressSink 注入后各覆盖回调只发事件、
/// 不触碰 Sparkle 原生状态窗;闭包载荷(取消/就绪回复)原样透传。
///
/// 边界说明:`SPUUserUpdateState` init 不可用,`showUpdateFound` 的关检查窗行为
/// (T1 双弹窗修复)无法单测,只能真机验证;sink 为 nil 的回退分支会创建真实
/// Sparkle 窗口,同样不在单测覆盖(结构上 guard-else 直通 super,一目了然)。
final class VowKyUpdaterUserDriverTests: XCTestCase {

    /// 事件的可断言形态(剥离闭包载荷)
    private enum EventKind: Equatable {
        case downloadStarted
        case downloadExpectedLength(UInt64)
        case downloadReceived(UInt64)
        case extractStarted
        case extractProgress(Double)
        case readyToRelaunch
        case installing
        case dismiss
    }

    private var driver: VowKyUpdaterUserDriver!
    private var events: [EventKind]!
    private var capturedCancel: (() -> Void)?
    private var capturedReadyReply: ((SPUUserUpdateChoice) -> Void)?

    override func setUp() {
        super.setUp()
        driver = VowKyUpdaterUserDriver(hostBundle: .main, delegate: nil)
        events = []
        driver.progressSink = { [unowned self] event in
            switch event {
            case .downloadStarted(let cancel):
                capturedCancel = cancel
                events.append(.downloadStarted)
            case .downloadExpectedLength(let bytes):
                events.append(.downloadExpectedLength(bytes))
            case .downloadReceived(let bytes):
                events.append(.downloadReceived(bytes))
            case .extractStarted:
                events.append(.extractStarted)
            case .extractProgress(let progress):
                events.append(.extractProgress(progress))
            case .readyToRelaunch(let reply):
                capturedReadyReply = reply
                events.append(.readyToRelaunch)
            case .installing:
                events.append(.installing)
            case .dismiss:
                events.append(.dismiss)
            }
        }
    }

    override func tearDown() {
        driver = nil
        events = nil
        capturedCancel = nil
        capturedReadyReply = nil
        super.tearDown()
    }

    func testDownloadLifecycleForwardsEventsInOrder() {
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(1_000)
        driver.showDownloadDidReceiveData(ofLength: 400)
        driver.showDownloadDidReceiveData(ofLength: 600)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.5)
        driver.showReady(toInstallAndRelaunch: { _ in })

        XCTAssertEqual(events, [
            .downloadStarted,
            .downloadExpectedLength(1_000),
            .downloadReceived(400),
            .downloadReceived(600),
            .extractStarted,
            .extractProgress(0.5),
            .readyToRelaunch,
        ])
    }

    func testCancellationClosurePassedThroughIntact() {
        var cancelled = false
        driver.showDownloadInitiated(cancellation: { cancelled = true })

        XCTAssertNotNil(capturedCancel)
        capturedCancel?()
        XCTAssertTrue(cancelled)
    }

    func testReadyReplyClosurePassedThroughIntact() {
        var received: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { received = $0 })

        XCTAssertNotNil(capturedReadyReply)
        capturedReadyReply?(.install)
        XCTAssertEqual(received, .install)
    }

    func testInstallingForwardsEventWithoutTouchingRetryHandler() {
        var retried = false
        driver.showInstallingUpdate(
            withApplicationTerminated: false,
            retryTerminatingApplication: { retried = true }
        )

        XCTAssertEqual(events, [.installing])
        XCTAssertFalse(retried)
    }

    func testDismissUpdateInstallationForwardsDismiss() {
        driver.dismissUpdateInstallation()

        XCTAssertEqual(events, [.dismiss])
    }
}
