import Foundation
import XCTest
@testable import VowKy

final class ProviderUsabilityCheckerTests: XCTestCase {
    private var tempDir: URL!
    private var homeDir: URL!
    private var binDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-usability-tests-\(UUID().uuidString)")
        homeDir = tempDir.appendingPathComponent("home")
        binDir = tempDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil; homeDir = nil; binDir = nil
    }

    // MARK: - codex / claude

    func testCodexCliNotFound() {
        let checker = makeChecker()
        let config = AIProviderConfig(
            enabled: true, autoTrigger: false,
            providers: AIProviderConfig.defaultProviders,
            codex: CLIConfig(binaryPath: tempDir.appendingPathComponent("does-not-exist").path),
            claude: .empty,
            timeoutSeconds: 90
        )
        XCTAssertEqual(
            checker.unusableReason(for: .codex, config: config),
            .cliNotFound(commandName: "codex")
        )
    }

    func testClaudeSkillNotInstalledEvenWhenCliFound() throws {
        // 准备 fake claude binary
        let fakeClaude = binDir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 1.0".write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let checker = makeChecker()
        let config = AIProviderConfig(
            enabled: true, autoTrigger: false,
            providers: AIProviderConfig.defaultProviders,
            codex: .empty,
            claude: CLIConfig(binaryPath: fakeClaude.path),
            timeoutSeconds: 90
        )
        XCTAssertEqual(
            checker.unusableReason(for: .claudeCode, config: config),
            .skillNotInstalled(platform: .claudeCode)
        )
    }

    func testClaudeFullyUsable() throws {
        // fake binary
        let fakeClaude = binDir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 1.0".write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        // fake skill
        let skillDir = homeDir
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
            .appendingPathComponent("transcript-enhance")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "SKILL".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let checker = makeChecker()
        let config = AIProviderConfig(
            enabled: true, autoTrigger: false,
            providers: AIProviderConfig.defaultProviders,
            codex: .empty,
            claude: CLIConfig(binaryPath: fakeClaude.path),
            timeoutSeconds: 90
        )
        XCTAssertNil(checker.unusableReason(for: .claudeCode, config: config))
    }

    // MARK: - Helpers

    private func makeChecker() -> ProviderUsabilityChecker {
        ProviderUsabilityChecker(
            fileManager: .default,
            homeDirectory: homeDir,
            environment: ["HOME": homeDir.path]   // 注：自动探测时只跑用户填的路径分支
        )
    }
}
