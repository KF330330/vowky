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
        UpdateLogger.log("▶︎ 用户手动「检查更新」")
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
            UpdateLogger.log("appcast 评估: host build=\(hostBundleVersion), \(appcast.items.count) 项, 无更高版本可用 → 不提示")
            return nil
        }

        // 用户主动检查 → 不动我们的限频计数
        if isUserInitiatedCheck {
            UpdateLogger.log("appcast 评估(手动): host build=\(hostBundleVersion) → 命中 \(latest.versionString)")
            return latest
        }

        let willShow = shouldShowAutomatically(forVersion: latest.versionString)
        UpdateLogger.log("appcast 评估(自动): host build=\(hostBundleVersion) → 候选 \(latest.versionString), 限频判定=\(willShow ? "提示" : "本次静默")")
        return willShow ? latest : nil
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            UpdateLogger.log("更新周期结束 (check=\(updateCheck.rawValue)): \(error.localizedDescription)")
        } else {
            UpdateLogger.log("更新周期结束 (check=\(updateCheck.rawValue)): 正常")
        }
        isUserInitiatedCheck = false
    }

    /// Sparkle 即将重启 app 安装更新前,先关掉常驻语音 helper。
    /// helper 持有 app bundle 内的可执行/模型 mmap,若存活会妨碍 `/Applications/VowKy.app` 的原地替换。
    /// (applicationWillTerminate 也会兜底关闭,这里是更靠前的显式保险。)
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        UpdateLogger.log("⟳ 即将重启以完成安装 — 关闭常驻语音 helper")
        HelperTransport.shared.shutdown()
    }

    // MARK: - 仅记录日志的生命周期钩子（不改变任何更新行为）
    // 这些是 SPUUpdaterDelegate 的可选方法，只用来把整条自更新链路写进 update.log，
    // 便于发版后一眼确认「检查 → 找到 → 下载 → 安装 → 重启」每一步是否正常。

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let versions = appcast.items.map { $0.versionString }.joined(separator: ", ")
        UpdateLogger.log("appcast 加载成功: \(appcast.items.count) 项 [\(versions)]")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        UpdateLogger.log("✅ 找到有效更新: \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        UpdateLogger.log("ℹ️ 未发现可用更新: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        UpdateLogger.log("⤓ 即将安装: \(item.displayVersionString) — 主进程签名=\(UpdateLogger.selfCodeSignatureStatus())")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        UpdateLogger.log("❌ 下载更新失败: \(item.displayVersionString) — \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        UpdateLogger.log("⛔️ 更新中止: domain=\(ns.domain) code=\(ns.code) — \(ns.localizedDescription) | 主进程签名=\(UpdateLogger.selfCodeSignatureStatus())")
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        UpdateLogger.log("用户取消下载")
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
