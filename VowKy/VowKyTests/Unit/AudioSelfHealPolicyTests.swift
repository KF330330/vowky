import XCTest
@testable import VowKy

// MARK: - 音频卡死自愈策略

final class AudioSelfHealPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func test01_neverRelaunched_relaunches() {
        XCTAssertEqual(AudioSelfHealPolicy.decide(now: now, lastRelaunchAt: nil), .relaunch)
    }

    func test02_justBelowMinInterval_throttled() {
        let last = now.addingTimeInterval(-599)
        XCTAssertEqual(AudioSelfHealPolicy.decide(now: now, lastRelaunchAt: last), .throttled)
    }

    func test03_exactlyMinInterval_relaunches() {
        let last = now.addingTimeInterval(-600)
        XCTAssertEqual(AudioSelfHealPolicy.decide(now: now, lastRelaunchAt: last), .relaunch)
    }

    func test04_clockWentBackwards_relaunches() {
        // 时间戳在未来（时钟回拨/改时区）：宁可多重启一次，也不能让自愈被坏时间戳永久卡死
        let last = now.addingTimeInterval(100)
        XCTAssertEqual(AudioSelfHealPolicy.decide(now: now, lastRelaunchAt: last), .relaunch)
    }

    func test05_minInterval_farAboveCrashLoopWindow() {
        // AppDelegate 崩溃环窗口是 30 s / 3 次；自愈间隔必须远大于它
        XCTAssertGreaterThanOrEqual(AudioSelfHealPolicy.minInterval, 60)
        XCTAssertEqual(AudioSelfHealPolicy.minInterval, 600)
    }

    func test06_relaunchDelay() {
        XCTAssertEqual(AudioSelfHealPolicy.relaunchDelay, 1.5)
    }

    func test07_storeKey() {
        XCTAssertEqual(AudioSelfHealStore.Keys.lastRelaunchAt, "audio.selfHeal.lastRelaunchAt")
    }

    func test08_saveLoadRoundTrip() throws {
        let suite = "selfheal.policy.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(AudioSelfHealStore.loadLastRelaunchAt(defaults: defaults))

        AudioSelfHealStore.saveLastRelaunchAt(now, defaults: defaults)
        let loaded = try XCTUnwrap(AudioSelfHealStore.loadLastRelaunchAt(defaults: defaults))
        XCTAssertEqual(loaded.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func test09_customMinInterval_respected() {
        let last = now.addingTimeInterval(-30)
        XCTAssertEqual(AudioSelfHealPolicy.decide(now: now, lastRelaunchAt: last, minInterval: 10), .relaunch)
        XCTAssertEqual(AudioSelfHealPolicy.decide(now: now, lastRelaunchAt: last, minInterval: 60), .throttled)
    }
}
