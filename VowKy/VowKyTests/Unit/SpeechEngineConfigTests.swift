import XCTest
@testable import VowKy

final class SpeechEngineConfigTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "vowky.tests.speechEngineConfig"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - load/save

    func test01_load_defaultsToSenseVoice() {
        XCTAssertEqual(SpeechEngineConfigStore.load(defaults: defaults).engine, .senseVoice)
    }

    func test02_saveLoad_roundTrip() {
        var config = SpeechEngineConfig()
        config.analyzerLocale = "ja-JP"
        SpeechEngineConfigStore.save(config, defaults: defaults)
        let loaded = SpeechEngineConfigStore.load(defaults: defaults)
        XCTAssertEqual(loaded.engine, .senseVoice)
        XCTAssertEqual(loaded.analyzerLocale, "ja-JP")
    }

    func test03_load_storedSpeechAnalyzerFallsBackWhenRuntimeUnavailable() {
        defaults.set(SpeechEngineKind.speechAnalyzer.rawValue, forKey: SpeechEngineConfigStore.Keys.engine)
        let loaded = SpeechEngineConfigStore.load(defaults: defaults)
        if SpeechEngineConfigStore.speechAnalyzerRuntimeAvailable {
            XCTAssertEqual(loaded.engine, .speechAnalyzer)
        } else {
            // 16.2 工具链或 macOS <26：强制回落
            XCTAssertEqual(loaded.engine, .senseVoice)
        }
    }

    func test04_load_garbageEngineValueFallsBackToSenseVoice() {
        defaults.set("whisper", forKey: SpeechEngineConfigStore.Keys.engine)
        XCTAssertEqual(SpeechEngineConfigStore.load(defaults: defaults).engine, .senseVoice)
    }

    // MARK: - resolve 纯函数

    func test05_resolve_diarizationOnForcesSenseVoice() {
        XCTAssertEqual(
            SpeechEngineConfigStore.resolve(stored: .speechAnalyzer, speechAnalyzerAvailable: true, diarizationOn: true),
            .senseVoice
        )
    }

    func test06_resolve_unavailableFallsBack() {
        XCTAssertEqual(
            SpeechEngineConfigStore.resolve(stored: .speechAnalyzer, speechAnalyzerAvailable: false, diarizationOn: false),
            .senseVoice
        )
    }

    func test07_resolve_availableAndNoDiarizationKeepsChoice() {
        XCTAssertEqual(
            SpeechEngineConfigStore.resolve(stored: .speechAnalyzer, speechAnalyzerAvailable: true, diarizationOn: false),
            .speechAnalyzer
        )
        XCTAssertEqual(
            SpeechEngineConfigStore.resolve(stored: .senseVoice, speechAnalyzerAvailable: true, diarizationOn: false),
            .senseVoice
        )
    }

    // MARK: - locale 默认映射

    func test08_defaultAnalyzerLocale_followsAppLanguage() {
        XCTAssertEqual(SpeechEngineConfigStore.defaultAnalyzerLocale(appLanguage: .zhHans), "zh-CN")
        XCTAssertEqual(SpeechEngineConfigStore.defaultAnalyzerLocale(appLanguage: .en), "en-US")
    }

    // MARK: - auto 模式（哨兵 + mode 访问器）

    func test09_autoSentinel_roundTripAndMode() {
        var config = SpeechEngineConfig()
        config.analyzerLocale = SpeechEngineConfigStore.analyzerLocaleAutoValue
        SpeechEngineConfigStore.save(config, defaults: defaults)
        let loaded = SpeechEngineConfigStore.load(defaults: defaults)
        XCTAssertEqual(loaded.analyzerLocale, "auto")
        XCTAssertEqual(loaded.analyzerLocaleMode, .auto)
    }

    func test10_concreteLocale_modeIsFixed_backwardCompatible() {
        // 存量用户 defaults 里是具体 bcp47 → 行为不变（fixed），auto 纯 opt-in
        defaults.set("ja-JP", forKey: SpeechEngineConfigStore.Keys.analyzerLocale)
        let loaded = SpeechEngineConfigStore.load(defaults: defaults)
        XCTAssertEqual(loaded.analyzerLocaleMode, .fixed("ja-JP"))
        // 未存 locale → 默认值也是 fixed
        XCTAssertEqual(SpeechEngineConfig().analyzerLocaleMode,
                       .fixed(SpeechEngineConfigStore.defaultAnalyzerLocale()))
    }

    // MARK: - auto sticky store

    func test11_autoStickyLocale_defaultAndRoundTrip() {
        // 未存 → 回落 defaultAnalyzerLocale()
        XCTAssertEqual(SpeechEngineConfigStore.autoStickyLocale(defaults: defaults),
                       SpeechEngineConfigStore.defaultAnalyzerLocale())
        // 四候选 locale 合法
        SpeechEngineConfigStore.saveAutoStickyLocale("ja-JP", defaults: defaults)
        XCTAssertEqual(SpeechEngineConfigStore.autoStickyLocale(defaults: defaults), "ja-JP")
        // "senseVoice" 哨兵合法（下一句直接用本地引擎）
        SpeechEngineConfigStore.saveAutoStickyLocale(
            SpeechEngineConfigStore.autoStickySenseVoiceValue, defaults: defaults)
        XCTAssertEqual(SpeechEngineConfigStore.autoStickyLocale(defaults: defaults),
                       SpeechEngineConfigStore.autoStickySenseVoiceValue)
    }

    func test12_autoStickyLocale_garbageValueFallsBack() {
        defaults.set("fr-FR", forKey: SpeechEngineConfigStore.Keys.autoStickyLocale)
        XCTAssertEqual(SpeechEngineConfigStore.autoStickyLocale(defaults: defaults),
                       SpeechEngineConfigStore.defaultAnalyzerLocale())
        defaults.set("auto", forKey: SpeechEngineConfigStore.Keys.autoStickyLocale)
        XCTAssertEqual(SpeechEngineConfigStore.autoStickyLocale(defaults: defaults),
                       SpeechEngineConfigStore.defaultAnalyzerLocale())
    }

    // MARK: - 引擎速度模式策略（2026-08-04：默认标准速度，快速 opt-in）

    func test13_autoPolicyActive_fastModeFollowsRuntimeAndDiarizationInterlock() {
        // 用户选快速模式（只读新 speech.mode，不读遗留 speech.engine）
        SpeechEngineConfigStore.saveSpeedMode(.fast, defaults: defaults)
        // 分离开启恒 false（互锁复用 resolve）
        XCTAssertFalse(SpeechEngineConfigStore.autoPolicyActive(diarizationOn: true, defaults: defaults))
        // 分离关时只看运行时可用性
        XCTAssertEqual(
            SpeechEngineConfigStore.autoPolicyActive(diarizationOn: false, defaults: defaults),
            SpeechEngineConfigStore.speechAnalyzerRuntimeAvailable
        )
    }

    func test14_speedMode_defaultIsStandard_garbageFallsBack_roundTrip() {
        // 未存 → standard（2026-08-04 拍板：默认恒本地，准确率优先）
        XCTAssertEqual(SpeechEngineConfigStore.loadSpeedMode(defaults: defaults), .standard)
        // 垃圾值 → standard
        defaults.set("turbo", forKey: SpeechEngineConfigStore.Keys.speedMode)
        XCTAssertEqual(SpeechEngineConfigStore.loadSpeedMode(defaults: defaults), .standard)
        // save/load 往返
        SpeechEngineConfigStore.saveSpeedMode(.fast, defaults: defaults)
        XCTAssertEqual(SpeechEngineConfigStore.loadSpeedMode(defaults: defaults), .fast)
        SpeechEngineConfigStore.saveSpeedMode(.standard, defaults: defaults)
        XCTAssertEqual(SpeechEngineConfigStore.loadSpeedMode(defaults: defaults), .standard)
    }

    func test15_resolveAutoPolicy_standardAlwaysLocal() {
        // 标准速度模式恒本地——即使 SA 可用且分离关
        XCTAssertFalse(SpeechEngineConfigStore.resolveAutoPolicy(
            mode: .standard, speechAnalyzerAvailable: true, diarizationOn: false))
    }

    func test16_resolveAutoPolicy_fastFollowsAvailabilityAndInterlock() {
        XCTAssertTrue(SpeechEngineConfigStore.resolveAutoPolicy(
            mode: .fast, speechAnalyzerAvailable: true, diarizationOn: false))
        XCTAssertFalse(SpeechEngineConfigStore.resolveAutoPolicy(
            mode: .fast, speechAnalyzerAvailable: false, diarizationOn: false))
        XCTAssertFalse(SpeechEngineConfigStore.resolveAutoPolicy(
            mode: .fast, speechAnalyzerAvailable: true, diarizationOn: true))
    }

    func test17_autoPolicyActive_defaultStandardAlwaysFalse() {
        // 未存 speech.mode（新装/存量升级用户）→ 默认标准速度 → 策略恒关，不受运行时可用性影响
        XCTAssertFalse(SpeechEngineConfigStore.autoPolicyActive(diarizationOn: false, defaults: defaults))
        defaults.set(SpeechSpeedMode.standard.rawValue, forKey: SpeechEngineConfigStore.Keys.speedMode)
        XCTAssertFalse(SpeechEngineConfigStore.autoPolicyActive(diarizationOn: false, defaults: defaults))
    }

    func test18_saveSpeedModeFast_clearsSenseVoiceStickySentinelOnly() {
        // sticky 停在「恒本地」哨兵 → 切快速时清掉（回落默认 locale）
        SpeechEngineConfigStore.saveAutoStickyLocale(
            SpeechEngineConfigStore.autoStickySenseVoiceValue, defaults: defaults)
        SpeechEngineConfigStore.saveSpeedMode(.fast, defaults: defaults)
        XCTAssertEqual(SpeechEngineConfigStore.autoStickyLocale(defaults: defaults),
                       SpeechEngineConfigStore.defaultAnalyzerLocale())
        // sticky 是语言记忆 → 保留
        SpeechEngineConfigStore.saveAutoStickyLocale("ja-JP", defaults: defaults)
        SpeechEngineConfigStore.saveSpeedMode(.fast, defaults: defaults)
        XCTAssertEqual(SpeechEngineConfigStore.autoStickyLocale(defaults: defaults), "ja-JP")
        // 切标准不清 sticky
        SpeechEngineConfigStore.saveAutoStickyLocale(
            SpeechEngineConfigStore.autoStickySenseVoiceValue, defaults: defaults)
        SpeechEngineConfigStore.saveSpeedMode(.standard, defaults: defaults)
        XCTAssertEqual(SpeechEngineConfigStore.autoStickyLocale(defaults: defaults),
                       SpeechEngineConfigStore.autoStickySenseVoiceValue)
    }
}
