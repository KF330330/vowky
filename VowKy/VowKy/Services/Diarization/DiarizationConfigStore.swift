import Foundation

/// 说话人分离开关的持久化。两条链路(文件转录/录音)独立记忆,默认都关。
enum DiarizationConfigStore {

    enum Keys {
        static let fileEnabled           = "diarization.file.enabled"
        static let recordingEnabled      = "diarization.recording.enabled"
        static let fileSpeakerCount      = "diarization.file.speakerCount"
        static let recordingSpeakerCount = "diarization.recording.speakerCount"
    }

    /// 说话人数：0 = 自动估计；≥2 = 强制聚成 N 类（已知人数时比自动估计准得多）。
    static func fileSpeakerCount(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: Keys.fileSpeakerCount)
    }

    static func setFileSpeakerCount(_ count: Int, defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: Keys.fileSpeakerCount)
    }

    static func recordingSpeakerCount(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: Keys.recordingSpeakerCount)
    }

    static func setRecordingSpeakerCount(_ count: Int, defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: Keys.recordingSpeakerCount)
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
