import XCTest
@testable import VowKy

final class UpdateReminderCoordinatorTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var clock: Date!
    private var coordinator: UpdateReminderCoordinator!

    private static let oneDay: TimeInterval = 60 * 60 * 24
    private static let sevenDays: TimeInterval = 60 * 60 * 24 * 7

    override func setUp() {
        super.setUp()
        suiteName = "UpdateReminderCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator = UpdateReminderCoordinator(defaults: defaults, now: { [unowned self] in clock })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        coordinator = nil
        super.tearDown()
    }

    func testFirstAutomaticCheckOfNewVersionAllowed() {
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))
        XCTAssertEqual(defaults.integer(forKey: UpdateReminderCoordinator.storeKeyCount), 1)
        XCTAssertEqual(defaults.string(forKey: UpdateReminderCoordinator.storeKeyVersion), "20")
        XCTAssertNotNil(defaults.object(forKey: UpdateReminderCoordinator.storeKeyLastShownAt))
    }

    func testSecondCheckWithin7DaysDenied() {
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))

        // 1 天后再检查 → 仍在 7 天静默期，不弹
        clock = clock.addingTimeInterval(Self.oneDay)
        XCTAssertFalse(coordinator.shouldShowAutomatically(forVersion: "20"))
        XCTAssertEqual(defaults.integer(forKey: UpdateReminderCoordinator.storeKeyCount), 1)

        // 6 天 23 小时后 → 仍小于 7 天，不弹
        clock = clock.addingTimeInterval(Self.sevenDays - Self.oneDay - 60 * 60)
        XCTAssertFalse(coordinator.shouldShowAutomatically(forVersion: "20"))
        XCTAssertEqual(defaults.integer(forKey: UpdateReminderCoordinator.storeKeyCount), 1)
    }

    func testSecondCheckAfter7DaysAllowed() {
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))

        clock = clock.addingTimeInterval(Self.sevenDays + 1)
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))
        XCTAssertEqual(defaults.integer(forKey: UpdateReminderCoordinator.storeKeyCount), 2)
    }

    func testThirdCheckAlwaysDenied() {
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))
        clock = clock.addingTimeInterval(Self.sevenDays + 1)
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))

        // 即使 30 天后也不再弹
        clock = clock.addingTimeInterval(Self.sevenDays * 30)
        XCTAssertFalse(coordinator.shouldShowAutomatically(forVersion: "20"))
        XCTAssertEqual(defaults.integer(forKey: UpdateReminderCoordinator.storeKeyCount), 2)
    }

    func testNewVersionResetsCountAndAllowsImmediately() {
        // 版本 20 走完两次提醒
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))
        clock = clock.addingTimeInterval(Self.sevenDays + 1)
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))
        XCTAssertEqual(defaults.integer(forKey: UpdateReminderCoordinator.storeKeyCount), 2)

        // 出现版本 21，应该立刻重置并允许
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "21"))
        XCTAssertEqual(defaults.integer(forKey: UpdateReminderCoordinator.storeKeyCount), 1)
        XCTAssertEqual(defaults.string(forKey: UpdateReminderCoordinator.storeKeyVersion), "21")
    }

    func testStateMatchesFullCadence() {
        // 模拟真实节奏：检查→弹（D0）→6天后检查不弹→7天后检查弹→再检查永不弹
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))

        clock = clock.addingTimeInterval(Self.sevenDays - 1)
        XCTAssertFalse(coordinator.shouldShowAutomatically(forVersion: "20"))

        clock = clock.addingTimeInterval(2) // 跨过 7 天阈值
        XCTAssertTrue(coordinator.shouldShowAutomatically(forVersion: "20"))

        clock = clock.addingTimeInterval(Self.sevenDays * 2)
        XCTAssertFalse(coordinator.shouldShowAutomatically(forVersion: "20"))
    }
}
