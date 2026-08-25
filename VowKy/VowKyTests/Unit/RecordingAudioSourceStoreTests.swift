import XCTest
@testable import VowKy

/// 录音来源偏好的存取。用独立 suite 的 UserDefaults,不碰用户真实偏好。
final class RecordingAudioSourceStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.vowky.tests.audioSource.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test01_unset_defaultsToMicrophone() {
        XCTAssertEqual(RecordingAudioSourceStore.load(defaults: defaults), .microphone)
    }

    func test02_invalidValue_defaultsToMicrophone() {
        defaults.set("loopback", forKey: RecordingAudioSourceStore.Keys.source)
        XCTAssertEqual(RecordingAudioSourceStore.load(defaults: defaults), .microphone)
    }

    func test03_nonStringValue_defaultsToMicrophone() {
        defaults.set(42, forKey: RecordingAudioSourceStore.Keys.source)
        XCTAssertEqual(RecordingAudioSourceStore.load(defaults: defaults), .microphone)
    }

    func test04_saveLoadRoundTrip_allCases() {
        for source in RecordingAudioSource.allCases {
            RecordingAudioSourceStore.save(source, defaults: defaults)
            XCTAssertEqual(RecordingAudioSourceStore.load(defaults: defaults), source)
        }
    }

    func test05_rawValuesArePersistenceContract() {
        // rawValue 直接落 UserDefaults,改名会让老用户的偏好静默失效
        XCTAssertEqual(RecordingAudioSource.microphone.rawValue, "microphone")
        XCTAssertEqual(RecordingAudioSource.system.rawValue, "system")
        XCTAssertEqual(RecordingAudioSource.mixed.rawValue, "mixed")
        XCTAssertEqual(RecordingAudioSourceStore.Keys.source, "recording.audioSource")
    }

    func test06_localizationKeysAndSymbols() {
        XCTAssertEqual(RecordingAudioSource.allCases.count, 3)
        XCTAssertEqual(RecordingAudioSource.microphone.localizationKey, "recording.audioSource.microphone")
        XCTAssertEqual(RecordingAudioSource.system.localizationKey, "recording.audioSource.system")
        XCTAssertEqual(RecordingAudioSource.mixed.localizationKey, "recording.audioSource.mixed")
        XCTAssertFalse(RecordingAudioSource.microphone.symbolName.isEmpty)
        XCTAssertFalse(RecordingAudioSource.system.symbolName.isEmpty)
        XCTAssertFalse(RecordingAudioSource.mixed.symbolName.isEmpty)
    }
}
