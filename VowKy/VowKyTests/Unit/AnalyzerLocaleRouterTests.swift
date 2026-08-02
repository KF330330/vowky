import XCTest
@testable import VowKy

/// AnalyzerLocaleRouter 纯函数判定矩阵。总纲：一切歧义倾向 keepSenseVoice（误路由单语 SA=乱码）。
final class AnalyzerLocaleRouterTests: XCTestCase {

    private let allInstalled: Set<String> = ["zh-CN", "en-US", "ja-JP", "ko-KR"]

    private func route(_ text: String, installed: Set<String>? = nil) -> AnalyzerRouteDecision {
        AnalyzerLocaleRouter.route(text: text, installedLocales: installed ?? allInstalled)
    }

    // MARK: - 单语言 → 对应 locale

    func test01_pureChinese_routesZhCN() {
        XCTAssertEqual(route("今天天气不错我们下午去公园散步吧"), .analyzer("zh-CN"))
    }

    func test02_chineseEnglishMix_routesZhCN() {
        // 用户拍板：中英夹杂不回落，zh-CN 会话原生支持
        XCTAssertEqual(route("我们今天讨论一下 roadmap 和 deadline 的安排"), .analyzer("zh-CN"))
    }

    func test03_pureEnglish_routesEnUS() {
        XCTAssertEqual(route("Let's schedule the meeting for tomorrow afternoon"), .analyzer("en-US"))
    }

    func test04_typicalJapanese_routesJaJP() {
        // 口语日语：汉字+假名，汉字占比低
        XCTAssertEqual(route("今日は会議がありますのでよろしくお願いします"), .analyzer("ja-JP"))
    }

    func test05_japaneseWithShortAcronym_routesJaJP() {
        // latin 3 字符 < 4：夹带缩写不算英语成分
        XCTAssertEqual(route("APIをテストします"), .analyzer("ja-JP"))
    }

    func test06_pureKorean_routesKoKR() {
        XCTAssertEqual(route("오늘 회의가 있습니다 잘 부탁드립니다"), .analyzer("ko-KR"))
    }

    // MARK: - 混说 → keep(mixed)

    func test07_chineseJapaneseMix_keepsMixed() {
        // 汉字为主+日语结尾：汉字占比 >0.55 → 中日混（用户核心场景）
        XCTAssertEqual(route("我们今天讨论了三个重要问题都解决了ありがとうございます"),
                       .keepSenseVoice(.mixed))
    }

    func test08_chineseKoreanMix_keepsMixed() {
        XCTAssertEqual(route("我们今天开会讨论了这个方案 오늘 회의에서 논의했습니다"),
                       .keepSenseVoice(.mixed))
    }

    func test09_japaneseKoreanMix_keepsMixed() {
        XCTAssertEqual(route("ありがとうございます 감사합니다"), .keepSenseVoice(.mixed))
    }

    func test10_threeWayMix_keepsMixed() {
        XCTAssertEqual(route("我们今天讨论了很多重要的问题 meeting のスケジュール"),
                       .keepSenseVoice(.mixed))
    }

    func test11_japaneseEnglishMix_keepsMixed() {
        // 实质英语成分 + 日语：SA 单语会话无保证
        XCTAssertEqual(route("スケジュールを education program に合わせます"),
                       .keepSenseVoice(.mixed))
    }

    // MARK: - 噪声门（SenseVoice 短段假外文字符怪癖）

    func test12_chineseWithTwoStrayHangul_routesZhCN() {
        // 「哎니哟」怪癖：1-2 个假谚文字符不构成语言成分
        XCTAssertEqual(route("哎니요我们今天下午一起出去走一走呀天气很好"), .analyzer("zh-CN"))
    }

    func test13_chineseWithSingleKana_routesZhCN() {
        XCTAssertEqual(route("我们の计划就这样定了吧大家分头行动"), .analyzer("zh-CN"))
    }

    // MARK: - 无信号 → keep(noSignal)

    func test14_emptyAndNonLetters_keepNoSignal() {
        XCTAssertEqual(route(""), .keepSenseVoice(.noSignal))
        XCTAssertEqual(route("。。。！！"), .keepSenseVoice(.noSignal))
        XCTAssertEqual(route("123 456"), .keepSenseVoice(.noSignal))
    }

    func test15_shortEnglish_keepNoSignal() {
        // latin < 4：英文过短不足以判定
        XCTAssertEqual(route("ok"), .keepSenseVoice(.noSignal))
    }

    func test16_singleHanChar_routesZhCN() {
        // 独字成句（「嗯」）：han 占比 100% 视为中文
        XCTAssertEqual(route("嗯"), .analyzer("zh-CN"))
    }

    // MARK: - 未安装 / 粤语

    func test17_japaneseNotInstalled_keepsNotInstalledWithTargetLocale() {
        XCTAssertEqual(route("今日は会議がありますのでよろしくお願いします",
                             installed: ["zh-CN", "en-US"]),
                       .keepSenseVoice(.notInstalled("ja-JP")))
    }

    func test18_cantoneseMarkers_keepLikelyCantonese() {
        XCTAssertEqual(route("佢哋喺度唔知搞乜嘢呀"), .keepSenseVoice(.likelyCantonese))
    }

    // MARK: - installed 归一化 / scriptStats

    func test19_installedComparison_isCaseAndSeparatorInsensitive() {
        XCTAssertEqual(route("今天天气不错我们下午去公园散步吧", installed: ["ZH-cn"]),
                       .analyzer("zh-CN"))
        XCTAssertEqual(route("今天天气不错我们下午去公园散步吧", installed: ["zh_CN"]),
                       .analyzer("zh-CN"))
    }

    func test20_scriptStats_countsBucketsAndSkipsNonLetters() {
        let stats = AnalyzerLocaleRouter.scriptStats(of: "Hello, 你好！こんにちは 안녕 123")
        XCTAssertEqual(stats.latin, 5)
        XCTAssertEqual(stats.han, 2)
        XCTAssertEqual(stats.kana, 5)
        XCTAssertEqual(stats.hangul, 2)
        XCTAssertEqual(stats.letters, 14)
    }
}
