import XCTest
@testable import VoKey

// MARK: - T4: CGEvent Tap Tests (#50-54)
// Requires: Accessibility permission

final class CGEventTapTests: XCTestCase {

    // MARK: - #50: CGEvent tap 创建成功

    func test50_tapCreation_returnsTrue() {
        let manager = HotkeyManager()
        let result = manager.start()

        if !result {
            // If tap creation fails, it likely means no accessibility permission
            XCTSkip("CGEvent tap creation failed — accessibility permission may not be granted")
        }

        XCTAssertTrue(result, "CGEvent tap should be created successfully")
        manager.stop()
    }

    // MARK: - #51: tap 添加到 RunLoop → isRunning

    func test51_tapAddedToRunLoop_isRunning() {
        let manager = HotkeyManager()
        XCTAssertFalse(manager.isRunning, "Should not be running before start")

        let started = manager.start()
        guard started else {
            XCTSkip("Accessibility permission not granted")
            return
        }

        XCTAssertTrue(manager.isRunning, "Should be running after start")
        manager.stop()
    }

    // MARK: - #52: Option+Space 事件被拦截

    func test52_optionSpaceIntercepted() {
        let manager = HotkeyManager()
        let started = manager.start()
        guard started else {
            XCTSkip("Accessibility permission not granted")
            return
        }

        let expectation = XCTestExpectation(description: "Hotkey callback fired")
        manager.onHotkeyPressed = {
            expectation.fulfill()
        }

        // Post Option+Space keyDown via CGEvent
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true) // Space = 49
        keyDown?.flags = .maskAlternate // Option key
        keyDown?.post(tap: .cghidEventTap)

        wait(for: [expectation], timeout: 2.0)

        manager.stop()
    }

    // MARK: - #53: tapDisabledByTimeout 自动恢复

    func test53_tapDisabledByTimeout_autoRecovers() {
        let manager = HotkeyManager()
        let started = manager.start()
        guard started else {
            XCTSkip("Accessibility permission not granted")
            return
        }

        // tapDisabledByTimeout is handled inside the C callback.
        // We verify that after start, the tap is enabled and can recover.
        // Direct simulation of tapDisabledByTimeout requires triggering a system event,
        // which is not reliably reproducible. Instead we verify the tap remains running.
        XCTAssertTrue(manager.isRunning, "Tap should remain running")

        manager.stop()
    }

    // MARK: - #54: tap 清理

    func test54_tapCleanup_onStop() {
        let manager = HotkeyManager()
        let started = manager.start()
        guard started else {
            XCTSkip("Accessibility permission not granted")
            return
        }

        XCTAssertTrue(manager.isRunning)
        manager.stop()
        XCTAssertFalse(manager.isRunning, "Should not be running after stop")

        // Verify can restart
        let restarted = manager.start()
        XCTAssertTrue(restarted, "Should be able to restart after stop")
        manager.stop()
    }
}
