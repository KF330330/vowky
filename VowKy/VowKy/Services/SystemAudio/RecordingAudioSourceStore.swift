import Foundation

/// 录音窗口的音频来源。线上会议选 .mixed：麦克风收自己的声音,系统声音收对方的声音
/// (系统声音走 Core Audio Process Tap,采的是各进程输出混音,天然绕开会议软件的回声消除)。
enum RecordingAudioSource: String, CaseIterable {
    case microphone
    case system
    case mixed

    var localizationKey: String {
        switch self {
        case .microphone: return "recording.audioSource.microphone"
        case .system:     return "recording.audioSource.system"
        case .mixed:      return "recording.audioSource.mixed"
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: return "mic"
        case .system:     return "speaker.wave.2"
        case .mixed:      return "person.wave.2"
        }
    }
}

/// 音频来源选择的持久化。系统声音依赖 macOS 14.4+ 的 process tap,
/// 低版本没有这条链路,读取时恒退回麦克风(即使偏好里存着别的值)。
enum RecordingAudioSourceStore {

    enum Keys {
        static let source = "recording.audioSource"
    }

    static func load(defaults: UserDefaults = .standard) -> RecordingAudioSource {
        guard #available(macOS 14.4, *) else { return .microphone }
        guard let raw = defaults.string(forKey: Keys.source),
              let source = RecordingAudioSource(rawValue: raw) else {
            return .microphone
        }
        return source
    }

    static func save(_ source: RecordingAudioSource, defaults: UserDefaults = .standard) {
        defaults.set(source.rawValue, forKey: Keys.source)
    }
}
