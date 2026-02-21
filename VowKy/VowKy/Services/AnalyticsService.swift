import Foundation

/// Lightweight, privacy-friendly app analytics.
/// All data is anonymous (random UUID, no hardware ID, no user content).
/// Requests are fire-and-forget: failures are silently ignored.
final class AnalyticsService {
    static let shared = AnalyticsService()

    private let endpoint = URL(string: "https://analytics.vowky.com/api/app/event")!
    private let session: URLSession

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

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        send([
            "event": "install",
            "device_id": deviceId,
            "app_version": appVersion,
            "os_version": osVersion,
        ])

        UserDefaults.standard.set(true, forKey: key)
    }

    /// Call at every app launch. Only sends once per calendar day.
    func trackDAU() {
        let key = "analytics_last_dau_date"
        let today = Self.todayString()
        guard UserDefaults.standard.string(forKey: key) != today else { return }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        send([
            "event": "dau",
            "device_id": deviceId,
            "app_version": appVersion,
        ])

        UserDefaults.standard.set(today, forKey: key)
    }

    /// Call after each successful recognition.
    func trackRecognition() {
        send([
            "event": "recognition",
            "device_id": deviceId,
        ])
    }

    // MARK: - Private

    private func send(_ body: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: Date())
    }
}
