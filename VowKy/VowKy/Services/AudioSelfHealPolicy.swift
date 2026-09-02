import Foundation

/// 音频层卡死后的自愈重启策略（纯逻辑，便于单测）。
///
/// 节流是硬约束：AppDelegate 的崩溃环检测阈值是「30 s 内 ≥3 次启动」，
/// 自愈每 `minInterval` 秒最多贡献 1 次启动，绝不可能把它触发。
enum AudioSelfHealPolicy {
    static let minInterval: TimeInterval = 600
    /// 决定重启到真正调用之间的缓冲：让「即将重启」的提示先被用户看见。
    static let relaunchDelay: TimeInterval = 1.5

    enum Decision: Equatable {
        case relaunch
        case throttled
    }

    /// 纯函数：从未重启过 → 重启；时钟回拨（elapsed < 0）→ 重启（宁可多重启一次也不要因为
    /// 一个坏时间戳把自愈永久卡死）；距上次不足 minInterval → 节流；否则重启。
    static func decide(now: Date, lastRelaunchAt: Date?, minInterval: TimeInterval = minInterval) -> Decision {
        guard let lastRelaunchAt else { return .relaunch }
        let elapsed = now.timeIntervalSince(lastRelaunchAt)
        if elapsed < 0 { return .relaunch }
        return elapsed < minInterval ? .throttled : .relaunch
    }
}

/// 自愈时间戳的持久化（跨进程存活，重启后仍能节流）。
enum AudioSelfHealStore {
    enum Keys {
        static let lastRelaunchAt = "audio.selfHeal.lastRelaunchAt"
    }

    static func loadLastRelaunchAt(defaults: UserDefaults = .standard) -> Date? {
        guard let raw = defaults.object(forKey: Keys.lastRelaunchAt) as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    static func saveLastRelaunchAt(_ date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: Keys.lastRelaunchAt)
    }
}
