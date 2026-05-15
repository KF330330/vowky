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
            ProviderPriorityEntry(kind: .codex, enabled: true),
            ProviderPriorityEntry(kind: .claudeCode, enabled: false),
        ]
        let data = try JSONEncoder().encode(entries)
        defaults.set(String(data: data, encoding: .utf8), forKey: AIProviderFactory.Keys.providersJSON)
        defaults.set("claudeCode", forKey: AIProviderFactory.Keys.provider) // 旧 key 应被忽略

        let config = AIProviderFactory.load(defaults: defaults)

        XCTAssertEqual(config.providers, entries)
        XCTAssertEqual(config.enabledKindsInPriorityOrder, [.codex])
    }

    func testLoadFromLegacyOpenAIKeyFallsBackToDefaults() {
        defaults.set("openAICompatible", forKey: AIProviderFactory.Keys.provider)

        let config = AIProviderFactory.load(defaults: defaults)

        // OpenAI 已废弃,旧 ai.provider=openAICompatible 应迁移成新默认（claude+codex 都启用）
        XCTAssertEqual(config.providers, AIProviderConfig.defaultProviders)
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
