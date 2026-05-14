import Foundation
import XCTest
@testable import VowKy

final class CLIPathResolverTests: XCTestCase {
    private var tempDir: URL!
    private var homeDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-path-resolver-tests-\(UUID().uuidString)")
        homeDir = tempDir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil; homeDir = nil
    }

    func testIncludesStaticDirectories() {
        let dirs = CLIPathResolver.candidateDirectories(homeDirectory: homeDir)
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
        XCTAssertTrue(dirs.contains("/usr/local/bin"))
        XCTAssertTrue(dirs.contains("\(homeDir.path)/.cargo/bin"))
        XCTAssertTrue(dirs.contains("\(homeDir.path)/.volta/bin"))
    }

    func testIncludesNvmVersionedBinDirectories() throws {
        let nvmBin = homeDir
            .appendingPathComponent(".nvm/versions/node/v20.0.0/bin")
        try FileManager.default.createDirectory(at: nvmBin, withIntermediateDirectories: true)

        let dirs = CLIPathResolver.candidateDirectories(homeDirectory: homeDir)

        XCTAssertTrue(dirs.contains(nvmBin.path), "Expected nvm bin path in candidates: \(dirs)")
    }

    func testHandlesMissingVersionManagerRootsGracefully() {
        // homeDir 完全为空，没有 .nvm / .fnm / .nodenv / .asdf
        let dirs = CLIPathResolver.candidateDirectories(homeDirectory: homeDir)
        // 至少包含静态路径
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
        // 没有任何 nvm/fnm/nodenv/asdf 路径
        XCTAssertFalse(dirs.contains(where: { $0.contains("/.nvm/versions/node/") }))
        XCTAssertFalse(dirs.contains(where: { $0.contains("/.fnm/node-versions/") }))
        XCTAssertFalse(dirs.contains(where: { $0.contains("/.nodenv/versions/") }))
        XCTAssertFalse(dirs.contains(where: { $0.contains("/.asdf/installs/nodejs/") }))
    }

    func testMultipleNodeVersionsOrderedNewestFirst() throws {
        let root = homeDir.appendingPathComponent(".nvm/versions/node")
        for ver in ["v18.0.0", "v20.0.0", "v22.0.0"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(ver).appendingPathComponent("bin"),
                withIntermediateDirectories: true
            )
        }

        let dirs = CLIPathResolver.candidateDirectories(homeDirectory: homeDir)

        let nvmPaths = dirs.filter { $0.contains("/.nvm/versions/node/") }
        XCTAssertEqual(nvmPaths, [
            "\(root.path)/v22.0.0/bin",
            "\(root.path)/v20.0.0/bin",
            "\(root.path)/v18.0.0/bin",
        ])
    }

    func testFnmRootScanned() throws {
        let fnmBin = homeDir.appendingPathComponent(".fnm/node-versions/v22.0.0/installation/bin")
        try FileManager.default.createDirectory(at: fnmBin, withIntermediateDirectories: true)

        let dirs = CLIPathResolver.candidateDirectories(homeDirectory: homeDir)
        XCTAssertTrue(dirs.contains(fnmBin.path))
    }
}
