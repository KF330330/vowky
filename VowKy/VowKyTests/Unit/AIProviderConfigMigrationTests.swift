import Foundation
import XCTest
@testable import VowKy

final class AIProviderConfigMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "ai-config-migration-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testLoadFromLegacySingleKindKey() {
        defaults.set("codex", forKey: AIProviderFactory.Keys.provider)

        let config = AIProviderFactory.load(defaults: defaults)

        XCTAssertEqual(config.providers.first?.kind, .codex)
        XCTAssertEqual(config.providers.first?.enabled, true)
        XCTAssertEqual(config.providers.count, AIProviderKind.allCases.count)
        for entry in config.providers.dropFirst() {
            XCTAssertFalse(entry.enabled)
        }
    }

    func testLoadFromNewProvidersJSON() throws {
        let entries: [ProviderPriorityEntry] = [
            ProviderPriorityEntry(kind: .openAICompatible, enabled: true),
            ProviderPriorityEntry(kind: .claudeCode, enabled: true),
            ProviderPriorityEntry(kind: .codex, enabled: false),
        ]
        let data = try JSONEncoder().encode(entries)
        defaults.set(String(data: data, encoding: .utf8), forKey: AIProviderFactory.Keys.providersJSON)
        // 旧 key 不存在或不一致都应被忽略
        defaults.set("codex", forKey: AIProviderFactory.Keys.provider)

        let config = AIProviderFactory.load(defaults: defaults)

        XCTAssertEqual(config.providers, entries)
        XCTAssertEqual(config.enabledKindsInPriorityOrder, [.openAICompatible, .claudeCode])
    }

    func testLoadDefaultsWhenNothingStored() {
        let config = AIProviderFactory.load(defaults: defaults)
        XCTAssertEqual(config.providers, AIProviderConfig.defaultProviders)
    }

    func testSaveWritesNewKey() throws {
        var config = AIProviderConfig.default
        config.providers = [
            ProviderPriorityEntry(kind: .codex, enabled: true),
            ProviderPriorityEntry(kind: .claudeCode, enabled: false),
            ProviderPriorityEntry(kind: .openAICompatible, enabled: false),
        ]

        AIProviderFactory.save(config, defaults: defaults)

        guard let json = defaults.string(forKey: AIProviderFactory.Keys.providersJSON),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ProviderPriorityEntry].self, from: data) else {
            XCTFail("missing or invalid providersJSON")
            return
        }
        XCTAssertEqual(decoded, config.providers)
    }
}
