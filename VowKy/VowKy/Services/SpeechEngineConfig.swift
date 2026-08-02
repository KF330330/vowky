import Foundation

/// 语音识别引擎。三场景全局生效（2026-08-02 用户拍板）：热键听写、录音转文字、文件/链接转录。
/// 例外：说话人分离开启的操作恒 SenseVoice（互锁）；录音实时预览/字幕恒 SenseVoice
/// （冻结分段依赖 token 时间戳，SpeechAnalyzer 提供不了），极速引擎只负责录音终稿。
enum SpeechEngineKind: String, Codable, CaseIterable {
    /// 内置 SenseVoice-Small int8（默认）：速度/ITN/体积综合最优
    case senseVoice
    /// Apple SpeechAnalyzer（macOS 26+）：极快（约 10 倍），但数字/专有名词较弱、需手动选语言
    case speechAnalyzer
}

struct SpeechEngineConfig: Equatable {
    var engine: SpeechEngineKind = .senseVoice
    /// SpeechAnalyzer 转录语言（bcp47），或哨兵值 "auto"（自动检测切换）。
    /// SpeechTranscriber 无自动语言检测，「自动」由 AnalyzerLocaleRouter 按识别文本自造。
    var analyzerLocale: String = SpeechEngineConfigStore.defaultAnalyzerLocale()

    /// 类型化访问：mode 与 locale 同存一个 key，杜绝双 key 失同步。
    var analyzerLocaleMode: AnalyzerLocaleMode {
        analyzerLocale == SpeechEngineConfigStore.analyzerLocaleAutoValue
            ? .auto : .fixed(analyzerLocale)
    }
}

/// analyzer 转录语言的两种模式：固定 locale 或自动检测（lazy sticky，见 AnalyzerAutoEngine）。
enum AnalyzerLocaleMode: Equatable {
    case auto
    case fixed(String)
}

enum SpeechEngineConfigStore {

    enum Keys {
        static let engine           = "speech.engine"
        static let analyzerLocale   = "speech.analyzer.locale"
        /// auto 模式的 sticky 状态（运行时状态，非用户意图，故不进 SpeechEngineConfig）
        static let autoStickyLocale = "speech.analyzer.autoLastLocale"
    }

    /// analyzerLocale 的「自动」哨兵值。生产消费点一律经 analyzerLocaleMode 分流，绝不直接进 Locale 构造。
    static let analyzerLocaleAutoValue = "auto"

    /// sticky 的特殊值：下一句听写直接用本地 SenseVoice（上一句检测到混说/粤语/目标未安装）。
    static let autoStickySenseVoiceValue = "senseVoice"

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
    /// 分离开启时恒 SenseVoice；其余场景（听写/录音终稿/文件转录）按存储值+可用性裁决。
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

    /// 默认全自动策略（2026-08-02 用户拍板：设置页不再暴露引擎/语言选择，一切默认自动）：
    /// SA 运行时可用且分离关 → auto 模式（极速+本地混合，lazy sticky/终稿路由/文件抽样）；否则本地引擎。
    /// 存量 speech.engine / speech.analyzer.locale 视为遗留值，live 层不再读取（sticky 键继续使用）。
    /// 复用 resolve 保住分离互锁语义。
    static func autoPolicyActive(diarizationOn: Bool) -> Bool {
        resolve(
            stored: .speechAnalyzer,
            speechAnalyzerAvailable: speechAnalyzerRuntimeAvailable,
            diarizationOn: diarizationOn
        ) == .speechAnalyzer
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

    /// auto 模式可路由的候选 locale（= 设置页四选项的 bcp47 列）。
    static var autoRoutableLocales: [String] { analyzerLocaleChoices.map(\.bcp47) }

    /// auto 模式听写的 sticky locale：四候选 locale 或 autoStickySenseVoiceValue；
    /// 非法值/未存 → defaultAnalyzerLocale()。
    static func autoStickyLocale(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: Keys.autoStickyLocale),
           stored == autoStickySenseVoiceValue || autoRoutableLocales.contains(stored) {
            return stored
        }
        return defaultAnalyzerLocale()
    }

    static func saveAutoStickyLocale(_ value: String, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: Keys.autoStickyLocale)
    }
}
