import Foundation

/// Lightweight, privacy-friendly app analytics.
/// All data is anonymous (random UUID, no hardware ID, no user content).
/// Requests are fire-and-forget: failures are silently ignored.
final class AnalyticsService {
    static let shared = AnalyticsService()

    private let endpoint = URL(string: "https://analytics.vowky.com/api/app/event")!
    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "com.vowky.analytics.state")
    private var dauDateInFlight: String?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Device ID (anonymous UUID, generated once)

    private var deviceId: String {
        let key = "analytics_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: - Public API

    /// Call once at app launch. Only sends on the very first launch.
    func trackInstall() {
        let key = "analytics_install_sent"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        send([
            "event": "install",
            "device_id": deviceId,
        ]) { success in
            if success {
                UserDefaults.standard.set(true, forKey: key)
            }
        }
    }

    /// Call at every app launch. Only sends once per calendar day.
    func trackDAU() {
        let key = "analytics_last_dau_date"
        let today = Self.todayString()
        let shouldSend = stateQueue.sync { () -> Bool in
            guard UserDefaults.standard.string(forKey: key) != today else { return false }
            guard dauDateInFlight != today else { return false }
            dauDateInFlight = today
            return true
        }
        guard shouldSend else { return }

        send([
            "event": "dau",
            "device_id": deviceId,
        ]) { success in
            self.stateQueue.async {
                if success {
                    UserDefaults.standard.set(today, forKey: key)
                }
                if self.dauDateInFlight == today {
                    self.dauDateInFlight = nil
                }
            }
        }
    }

    /// Call after each successful recognition.
    func trackRecognition() {
        trackActiveUse()
        send([
            "event": "recognition",
            "device_id": deviceId,
        ])
    }

    // MARK: - Private

    private func send(_ body: [String: Any], completion: ((Bool) -> Void)? = nil) {
        var enrichedBody = body
        enrichedBody["app_version"] = enrichedBody["app_version"] ?? appVersion
        enrichedBody["os_version"] = enrichedBody["os_version"] ?? osVersion

        guard let data = try? JSONSerialization.data(withJSONObject: enrichedBody) else {
            completion?(false)
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        session.dataTask(with: request) { _, response, error in
            let success = error == nil &&
                (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            completion?(success)
        }.resume()
    }

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: Date())
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private func trackActiveUse() {
        trackDAU()
    }
}

// MARK: - UsageTrackerProtocol

extension AnalyticsService: UsageTrackerProtocol {
    func trackVoiceStart() {
        trackActiveUse()
        send(["event": "voice_start", "device_id": deviceId])
    }

    func trackVoiceComplete(durationMs: Int, charCount: Int) {
        trackActiveUse()
        send([
            "event": "voice_complete",
            "device_id": deviceId,
            "data": ["duration_ms": durationMs, "char_count": charCount],
        ])
    }

    func trackVoiceCancel() {
        trackActiveUse()
        send(["event": "voice_cancel", "device_id": deviceId])
    }

    func trackVoiceFailure() {
        trackActiveUse()
        send(["event": "voice_failure", "device_id": deviceId])
    }

    func trackRecovery() {
        trackActiveUse()
        send(["event": "recovery", "device_id": deviceId])
    }

    func trackHotkeyChange() {
        trackActiveUse()
        send(["event": "hotkey_change", "device_id": deviceId])
    }

    func trackHistorySearch() {
        trackActiveUse()
        send(["event": "history_search", "device_id": deviceId])
    }

    func trackHistoryCopy() {
        trackActiveUse()
        send(["event": "history_copy", "device_id": deviceId])
    }
}
