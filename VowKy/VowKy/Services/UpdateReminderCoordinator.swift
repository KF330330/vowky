import Foundation
import Sparkle

/// 控制 Sparkle 自动更新弹窗的频率：每个版本最多自动提醒 2 次，
/// 第 1 次在发现新版当天弹出，第 2 次必须距上次 ≥ 7 天才会弹，之后只能通过菜单手动触发。
///
/// 用户主动从菜单点击 Check for Updates 不计入这个限制。
final class UpdateReminderCoordinator: NSObject, SPUUpdaterDelegate {

    // MARK: - Persistence Keys

    static let storeKeyVersion = "vowky.updateReminder.version"
    static let storeKeyCount = "vowky.updateReminder.count"
    static let storeKeyLastShownAt = "vowky.updateReminder.lastShownAt"

    /// Sparkle 在用户点「跳过这个版本」时写入的 UserDefaults key，这里只用于读取。
    static let sparkleSkippedVersionKey = "SUSkippedVersion"

    // MARK: - Reminder Cadence

    static let firstReminderDelay: TimeInterval = 60 * 60 * 24          // 1 天
    static let secondReminderDelay: TimeInterval = 60 * 60 * 24 * 7     // 7 天
    static let maxReminderCount = 2

    // MARK: - State

    private let defaults: UserDefaults
    private let now: () -> Date
    private var isUserInitiatedCheck = false

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        super.init()
    }

    // MARK: - Public API

    /// 用户从菜单点击 Check for Updates 时调用，避免计入"自动提醒"次数。
    func userInitiatedCheck(updater: SPUUpdater) {
        isUserInitiatedCheck = true
        updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let comparator = SUStandardVersionComparator.default
        let hostBundleVersion = (updater.hostBundle.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        let skippedVersion = defaults.string(forKey: Self.sparkleSkippedVersionKey)

        let candidates: [SUAppcastItem] = appcast.items.filter { item in
            // 严格高于当前 host
            guard comparator.compareVersion(hostBundleVersion, toVersion: item.versionString) == .orderedAscending else {
                return false
            }
            // 用户主动跳过的版本永不提醒（手动 Check 也会过滤，与 Sparkle 默认一致）
            if let skippedVersion, skippedVersion == item.versionString {
                return false
            }
            return true
        }

        guard let latest = candidates.max(by: { a, b in
            comparator.compareVersion(a.versionString, toVersion: b.versionString) == .orderedAscending
        }) else {
            return nil
        }

        // 用户主动检查 → 不动我们的限频计数
        if isUserInitiatedCheck {
            return latest
        }

        return shouldShowAutomatically(forVersion: latest.versionString) ? latest : nil
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        isUserInitiatedCheck = false
    }

    // MARK: - Decision Logic (testable)

    /// 判断后台自动检查是否应该把"发现新版"的弹窗递给用户。
    /// 返回 `true` 时会同步把 count++ 与 lastShownAt 写回 UserDefaults。
    @discardableResult
    func shouldShowAutomatically(forVersion version: String) -> Bool {
        let storedVersion = defaults.string(forKey: Self.storeKeyVersion)

        // 新版本到达 → 重置计数
        if storedVersion != version {
            defaults.set(version, forKey: Self.storeKeyVersion)
            defaults.set(0, forKey: Self.storeKeyCount)
            defaults.removeObject(forKey: Self.storeKeyLastShownAt)
        }

        let count = defaults.integer(forKey: Self.storeKeyCount)
        let lastShownAt = defaults.object(forKey: Self.storeKeyLastShownAt) as? Date

        if count >= Self.maxReminderCount {
            return false
        }

        let currentTime = now()
        if let lastShownAt {
            let elapsed = currentTime.timeIntervalSince(lastShownAt)
            if count == 1 && elapsed < Self.secondReminderDelay {
                return false
            }
            if count == 0 && elapsed < Self.firstReminderDelay {
                return false
            }
        }

        defaults.set(count + 1, forKey: Self.storeKeyCount)
        defaults.set(currentTime, forKey: Self.storeKeyLastShownAt)
        return true
    }
}
