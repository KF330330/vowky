import Foundation

/// 文件/链接转录的识别引擎。热键听写与录音不受此选项影响（用户拍板：极速引擎仅文件/链接转录）。
enum SpeechEngineKind: String, Codable, CaseIterable {
    /// 内置 SenseVoice-Small int8（默认）：速度/ITN/体积综合最优
    case senseVoice
    /// Apple SpeechAnalyzer（macOS 26+）：极快（约 10 倍），但数字/专有名词较弱、需手动选语言
    case speechAnalyzer
}

struct SpeechEngineConfig: Equatable {
    var engine: SpeechEngineKind = .senseVoice
    /// SpeechAnalyzer 转录语言（bcp47）。SpeechTranscriber 无自动语言检测，必须显式指定。
    var analyzerLocale: String = SpeechEngineConfigStore.defaultAnalyzerLocale()
}

enum SpeechEngineConfigStore {

    enum Keys {
        static let engine         = "speech.engine"
        static let analyzerLocale = "speech.analyzer.locale"
    }

    static func load(defaults: UserDefaults = .standard) -> SpeechEngineConfig {
        var engine = defaults.string(forKey: Keys.engine)
            .flatMap(SpeechEngineKind.init(rawValue:)) ?? .senseVoice
        // 旧系统/迁移机器上存了 speechAnalyzer → 强制回落（照 TranslationConfigStore 先例）
        if engine == .speechAnalyzer, !speechAnalyzerRuntimeAvailable {
            engine = .senseVoice
        }
        let locale = defaults.string(forKey: Keys.analyzerLocale) ?? defaultAnalyzerLocale()
        return SpeechEngineConfig(engine: engine, analyzerLocale: locale)
    }

    static func save(_ config: SpeechEngineConfig, defaults: UserDefaults = .standard) {
        defaults.set(config.engine.rawValue, forKey: Keys.engine)
        defaults.set(config.analyzerLocale, forKey: Keys.analyzerLocale)
    }

    /// SpeechAnalyzer 运行时可用性：系统 ≥ macOS 26 且构建工具链已含该 API。
    /// （Xcode 16.2 回退构建时 compiler(<6.2)，功能整体编译排除。）
    static var speechAnalyzerRuntimeAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// 纯函数引擎裁决，供单测（#available 不可 mock）：
    /// 分离开启时恒 SenseVoice（引擎选择只影响未开分离的文件/链接转录）。
    static func resolve(
        stored: SpeechEngineKind,
        speechAnalyzerAvailable: Bool,
        diarizationOn: Bool
    ) -> SpeechEngineKind {
        if diarizationOn { return .senseVoice }
        if stored == .speechAnalyzer, !speechAnalyzerAvailable { return .senseVoice }
        return stored
    }

    /// 生产入口：按当前系统与分离开关裁决实际引擎。
    static func resolvedEngine(diarizationOn: Bool, defaults: UserDefaults = .standard) -> SpeechEngineKind {
        resolve(
            stored: load(defaults: defaults).engine,
            speechAnalyzerAvailable: speechAnalyzerRuntimeAvailable,
            diarizationOn: diarizationOn
        )
    }

    /// 默认转录语言：跟随 app 界面语言映射。
    static func defaultAnalyzerLocale(appLanguage: AppLanguage = LanguagePreferenceStore.load()) -> String {
        switch appLanguage {
        case .zhHans: return "zh-CN"
        case .en: return "en-US"
        }
    }

    /// 设置里可选的转录语言（渲染时再经 SpeechTranscriber.supportedLocales 过滤不可用项）。
    static let analyzerLocaleChoices: [(bcp47: String, displayKey: String)] = [
        ("zh-CN", "settings.model.analyzerLocale.zhCN"),
        ("en-US", "settings.model.analyzerLocale.enUS"),
        ("ja-JP", "settings.model.analyzerLocale.jaJP"),
        ("ko-KR", "settings.model.analyzerLocale.koKR"),
    ]
}
