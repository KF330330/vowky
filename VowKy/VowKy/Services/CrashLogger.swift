import Foundation

enum CrashLogger {

    private static let maxFileSize = 50 * 1024 // 50KB

    private static var logURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VowKy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vowky_debug.log")
    }()

    static func logLaunch() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let separator = "\n=== VowKy Launch v\(version) (\(build)) \(timestamp()) ===\n"
        appendToFile(separator)
    }

    static func log(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        appendToFile(line)
    }

    // MARK: - Private

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func appendToFile(_ text: String) {
        let url = logURL
        let data = Data(text.utf8)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }

        // Truncate if too large: keep the last half
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxFileSize {
            truncateFile(at: url, keepBytes: maxFileSize / 2)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.synchronize()
        try? handle.close()
    }

    private static func truncateFile(at url: URL, keepBytes: Int) {
        guard let data = try? Data(contentsOf: url) else { return }
        let start = max(0, data.count - keepBytes)
        let kept = data[start...]
        try? kept.write(to: url)
    }
}
