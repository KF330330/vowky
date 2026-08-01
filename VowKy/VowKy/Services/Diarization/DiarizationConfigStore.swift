import Foundation

/// 说话人分离开关的持久化。两条链路(文件转录/录音)独立记忆,默认都关。
enum DiarizationConfigStore {

    enum Keys {
        static let fileEnabled      = "diarization.file.enabled"
        static let recordingEnabled = "diarization.recording.enabled"
    }

    static func isFileEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Keys.fileEnabled) as? Bool ?? false
    }

    static func setFileEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.fileEnabled)
    }

    static func isRecordingEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Keys.recordingEnabled) as? Bool ?? false
    }

    static func setRecordingEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.recordingEnabled)
    }
}
