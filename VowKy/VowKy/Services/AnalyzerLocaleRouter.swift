import Foundation

/// auto 模式的语言路由决策。
/// 总纲（错判代价不对称）：误路由到单语 SA 会话=乱码，误留 SenseVoice=现状质量——一切歧义倾向 keepSenseVoice。
enum AnalyzerRouteDecision: Equatable {
    /// 单一语言（或中英夹杂）→ 用该 locale 的 SpeechAnalyzer
    case analyzer(String)
    case keepSenseVoice(KeepReason)

    enum KeepReason: Equatable {
        /// 无字母类内容（纯标点/数字），或英文过短不足以判定
        case noSignal
        /// 含 ≥2 个 CJK 语言成分，或日/韩与英语混——SA 单语会话无保证
        case mixed
        /// 粤语高频字命中（书面粤语与 zh 不可分是 v1 已知局限）
        case likelyCantonese
        /// 目标 locale 资产未安装（携带目标 locale，供按需后台自动下载）
        case notInstalled(String)
    }
}

/// 按 SenseVoice 识别文本判定「极速引擎该用哪个语言」的纯函数路由器。
/// 不编译门控：不触碰任何 SpeechAnalyzer 符号，16.2 工具链同样编译与测试。
enum AnalyzerLocaleRouter {

    /// 字符 script 分桶（只数字母类 scalar，空白/标点/数字/符号全跳过）。internal 供单测直验。
    struct ScriptStats: Equatable {
        var han = 0
        var kana = 0
        var hangul = 0
        var latin = 0
        var letters: Int { han + kana + hangul + latin }
    }

    static func scriptStats(of text: String) -> ScriptStats {
        var stats = ScriptStats()
        for scalar in text.unicodeScalars {
            guard scalar.properties.isAlphabetic else { continue }
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                stats.kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                stats.hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                stats.han += 1
            case ...0xFF:
                stats.latin += 1
            default:
                break // 其他文字系统不参与判定
            }
        }
        return stats
    }

    static func route(text: String, installedLocales: Set<String>) -> AnalyzerRouteDecision {
        let stats = scriptStats(of: text)
        let letters = Double(stats.letters)
        guard letters > 0 else { return .keepSenseVoice(.noSignal) }

        // 噪声门：SenseVoice 短段偶出 1-2 个假韩/日字符（「哎니哟」怪癖），
        // kana/hangul 须 ≥3 字符且占比 ≥5% 才算语言成分；latin 须 ≥4 且 ≥10%（挡夹带缩写/单位）；
        // han 须 ≥2，或独字成句（「嗯」）。
        let kanaPresent   = stats.kana   >= 3 && Double(stats.kana)   / letters >= 0.05
        let hangulPresent = stats.hangul >= 3 && Double(stats.hangul) / letters >= 0.05
        let enPresent     = stats.latin  >= 4 && Double(stats.latin)  / letters >= 0.10
        let hanPresent    = stats.han >= 2 || (stats.han >= 1 && Double(stats.han) / letters >= 0.5)

        var langs = Set<String>()
        if hangulPresent { langs.insert("ko") }
        if kanaPresent {
            // Han 归属歧义：纯日语（汉字+假名）vs 中日混说。口语日语转写假名密（は/が/です/ます），
            // 汉字占比通常 ≤0.55；更重的按中日混处理（安全方向——误路由 ja-JP 会把中文段变乱码，
            // 误判混说只是回落本地质量）。不用 NLLanguageRecognizer tiebreak：它对「中文为主+日语结尾」
            // 的混说句可能高置信误判纯日语，恰好错向危险侧。
            let cjk = Double(stats.han + stats.kana)
            let hanRatio = Double(stats.han) / cjk
            if hanRatio <= 0.55 {
                langs.insert("ja")
            } else {
                langs.insert("zh")
                langs.insert("ja")
            }
        } else if hanPresent {
            if cantoneseMarkerCount(in: text) >= 2 {
                return .keepSenseVoice(.likelyCantonese)
            }
            langs.insert("zh")
        }
        if enPresent { langs.insert("en") }

        guard !langs.isEmpty else { return .keepSenseVoice(.noSignal) }

        // 判定表：{zh}/{zh,en}→zh-CN（中英夹杂不回落，zh-CN 会话原生支持）；
        // {en}/{ja}/{ko} 各归各；其余组合（≥2 CJK、日/韩+英）→混说回落本地。
        let target: String?
        switch langs {
        case ["zh"], ["zh", "en"]: target = "zh-CN"
        case ["en"]:               target = "en-US"
        case ["ja"]:               target = "ja-JP"
        case ["ko"]:               target = "ko-KR"
        default:                   target = nil
        }
        guard let locale = target else { return .keepSenseVoice(.mixed) }
        guard isInstalled(locale, in: installedLocales) else { return .keepSenseVoice(.notInstalled(locale)) }
        return .analyzer(locale)
    }

    // MARK: - 私有

    /// 粤语口语高频字（普通话文本基本不出现）；命中 ≥2 视为粤语。
    private static let cantoneseMarkers: Set<Character> = [
        "嘅", "唔", "喺", "嚟", "啲", "佢", "哋", "乜", "嘢", "咁", "噉", "咗",
        "冇", "睇", "諗", "谂", "啱", "嗰", "俾", "畀", "嗌", "攞",
    ]

    private static func cantoneseMarkerCount(in text: String) -> Int {
        text.reduce(0) { cantoneseMarkers.contains($1) ? $0 + 1 : $0 }
    }

    /// bcp47 宽松归一化比对（大小写、_/- 分隔差异均容忍）。
    private static func isInstalled(_ locale: String, in installed: Set<String>) -> Bool {
        let target = normalize(locale)
        return installed.contains { normalize($0) == target }
    }

    private static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
