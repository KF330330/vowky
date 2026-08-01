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
}
