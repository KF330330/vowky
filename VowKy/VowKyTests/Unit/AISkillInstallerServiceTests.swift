import Foundation
import XCTest
@testable import VowKy

final class AISkillInstallerServiceTests: XCTestCase {
    private var tempDir: URL!
    private var homeDir: URL!
    private var helperURL: URL!
    private var jobRoot: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky-skill-tests-\(UUID().uuidString)")
        homeDir = tempDir.appendingPathComponent("home")
        jobRoot = tempDir.appendingPathComponent("vowky-transcribe-jobs")
        helperURL = tempDir
            .appendingPathComponent("VowKy.app")
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("vowky-transcribe")

        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/bash
        set -euo pipefail
        output_dir=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output-dir)
              output_dir="$2"
              shift 2
              ;;
            --)
              shift
              break
              ;;
            *)
              shift
              ;;
          esac
        done
        mkdir -p "$output_dir"
        for input in "$@"; do
          base="$(basename "$input")"
          name="${base%.*}"
          transcript="$output_dir/$name.txt"
          printf 'fake transcript\\n' > "$transcript"
          printf 'WROTE\\t%s\\n' "$transcript"
        done
        exit 0
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        homeDir = nil
        helperURL = nil
        jobRoot = nil
    }

    func testInstallCreatesCodexAndClaudeSkills() throws {
        let codexHome = tempDir.appendingPathComponent("codex-home")
        let service = makeService(environment: ["CODEX_HOME": codexHome.path])

        let installed = try service.install(platforms: [.codex, .claudeCode])

        XCTAssertEqual(Set(installed.map(\.standardizedFileURL.path)), [
            codexHome.appendingPathComponent("skills").appendingPathComponent("vowky-transcribe").standardizedFileURL.path,
            homeDir.appendingPathComponent(".claude").appendingPathComponent("skills").appendingPathComponent("vowky-transcribe").standardizedFileURL.path
        ])

        for directory in installed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".vowky-managed").path))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("scripts/vowky-transcribe.sh").path))
            let skill = try String(contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
            XCTAssertTrue(skill.contains("name: vowky-transcribe"))
            XCTAssertTrue(skill.contains("--background --output-dir \"$PWD\""))
            XCTAssertTrue(skill.contains("--output-dir \"$PWD\""))
        }

        XCTAssertEqual(service.status(for: .codex).state, .installed(version: AISkillInstallerService.skillVersion))
        XCTAssertEqual(service.status(for: .claudeCode).state, .installed(version: AISkillInstallerService.skillVersion))
    }

    func testInstallOverwritesExistingManagedSkill() throws {
        let service = makeService()
        _ = try service.install(platforms: [.codex])
        let directory = service.skillDirectory(for: .codex)
        try "stale".write(to: directory.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)

        _ = try service.install(platforms: [.codex])

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stale.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path))
    }

    func testInstallRefusesUnmanagedSameNameSkill() throws {
        let service = makeService()
        let directory = service.skillDirectory(for: .codex)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingSkill = directory.appendingPathComponent("SKILL.md")
        try "user skill".write(to: existingSkill, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.install(platforms: [.codex])) { error in
            XCTAssertEqual(error as? AISkillInstallerError, .unmanagedSkillExists(directory.path))
        }
        XCTAssertEqual(try String(contentsOf: existingSkill, encoding: .utf8), "user skill")
        XCTAssertEqual(service.status(for: .codex).state, .blockedByUnmanagedSkill)
    }

    func testInstallRefusesUnmanagedSameNameDirectoryWithoutSkillFile() throws {
        let service = makeService()
        let directory = service.skillDirectory(for: .codex)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingFile = directory.appendingPathComponent("notes.txt")
        try "do not overwrite".write(to: existingFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.install(platforms: [.codex])) { error in
            XCTAssertEqual(error as? AISkillInstallerError, .unmanagedSkillExists(directory.path))
        }
        XCTAssertEqual(try String(contentsOf: existingFile, encoding: .utf8), "do not overwrite")
        XCTAssertEqual(service.status(for: .codex).state, .blockedByUnmanagedSkill)
    }

    func testUninstallRemovesOnlyManagedSkill() throws {
        let service = makeService()
        _ = try service.install(platforms: [.claudeCode])
        let directory = service.skillDirectory(for: .claudeCode)

        let result = try service.uninstall(platforms: [.claudeCode])

        XCTAssertEqual(result.removedSkillDirectories.map(\.standardizedFileURL.path), [directory.standardizedFileURL.path])
        XCTAssertEqual(result.removedCompletedJobCaches, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(service.status(for: .claudeCode).state, .notInstalled)
    }

    func testUninstallRemovesFinishedJobCachesAndPreservesActiveOrUnknownCaches() throws {
        let service = makeService()
        _ = try service.install(platforms: [.codex])
        let transcript = tempDir.appendingPathComponent("meeting.txt")
        try "keep me\n".write(to: transcript, atomically: true, encoding: .utf8)
        let succeededJob = try makeJobDirectory(
            named: "succeeded-job",
            statusText: """
            state=succeeded
            wrote=\(transcript.path)
            """
        )
        let failedJob = try makeJobDirectory(
            named: "failed-job",
            statusText: """
            state=failed
            failed=/tmp/audio.mp3\tdecode failed
            """
        )
        let runningJob = try makeJobDirectory(
            named: "running-job",
            statusText: """
            state=running
            """
        )
        let unknownJob = try makeJobDirectory(
            named: "unknown-job",
            statusText: """
            state=paused
            """
        )
        let malformedJob = try makeJobDirectory(
            named: "malformed-job",
            statusText: """
            job_id=no-state
            """
        )
        let missingStatusJob = try makeJobDirectory(named: "missing-status-job", statusText: nil)

        let result = try service.uninstall(platforms: [.codex])

        XCTAssertEqual(result.removedCompletedJobCaches, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: succeededJob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedJob.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runningJob.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownJob.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedJob.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingStatusJob.path))
        XCTAssertEqual(try String(contentsOf: transcript, encoding: .utf8), "keep me\n")
    }

    func testUninstallRefusesUnmanagedSkillWithoutCleaningJobCaches() throws {
        let service = makeService()
        _ = try service.install(platforms: [.claudeCode])
        let managedDirectory = service.skillDirectory(for: .claudeCode)
        let unmanagedDirectory = service.skillDirectory(for: .codex)
        try FileManager.default.createDirectory(at: unmanagedDirectory, withIntermediateDirectories: true)
        try "user skill".write(
            to: unmanagedDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let finishedJob = try makeJobDirectory(
            named: "finished-job",
            statusText: """
            state=succeeded
            """
        )

        XCTAssertThrowsError(try service.uninstall(platforms: [.codex, .claudeCode])) { error in
            XCTAssertEqual(error as? AISkillInstallerError, .unmanagedSkillExists(unmanagedDirectory.path))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: managedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanagedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finishedJob.path))
    }

    func testInstalledLauncherRunsTranscriptionInBackgroundAndReportsStatus() throws {
        let service = makeService()
        _ = try service.install(platforms: [.codex])
        let directory = service.skillDirectory(for: .codex)
        let launcher = directory.appendingPathComponent("scripts/vowky-transcribe.sh")
        let outputDir = tempDir.appendingPathComponent("Project With Spaces")

        let start = try runProcess(
            launcher,
            arguments: [
                "--background",
                "--output-dir", outputDir.path,
                "--",
                "音频 test.mp3"
            ]
        )

        XCTAssertEqual(start.exitCode, 0)
        XCTAssertTrue(start.stdout.contains("STARTED\t"))
        guard let statusPath = lineValue(prefix: "STATUS\t", in: start.stdout) else {
            XCTFail("Expected launcher output to include a STATUS line. Output: \(start.stdout)")
            return
        }

        let statusFile = URL(fileURLWithPath: statusPath)
        let deadline = Date().addingTimeInterval(5)
        var finalStatus = ""
        repeat {
            let status = try runProcess(launcher, arguments: ["--status", statusFile.path])
            finalStatus = status.stdout
            if finalStatus.contains("DONE\t") {
                break
            }
            usleep(100_000)
        } while Date() < deadline

        let expectedTranscript = outputDir
            .appendingPathComponent("音频 test.txt")
            .resolvingSymlinksInPath()

        XCTAssertTrue(finalStatus.contains("DONE\t"), "Expected done status, got: \(finalStatus)")
        XCTAssertTrue(finalStatus.contains("WROTE\t"), "Expected written transcript path, got: \(finalStatus)")
        XCTAssertTrue(finalStatus.contains(expectedTranscript.lastPathComponent), "Expected written transcript filename, got: \(finalStatus)")
        XCTAssertEqual(
            try String(contentsOf: expectedTranscript, encoding: .utf8),
            "fake transcript\n"
        )
    }

    func testInstallReportsMissingHelper() {
        let service = AISkillInstallerService(
            homeDirectory: homeDir,
            environment: [:],
            appBundleURL: tempDir,
            helperURLOverride: missingHelperURL
        )

        XCTAssertThrowsError(try service.install(platforms: [.codex])) { error in
            XCTAssertEqual(
                error as? AISkillInstallerError,
                .helperMissing(missingHelperURL.path)
            )
        }
    }

    private func makeService(environment: [String: String] = [:]) -> AISkillInstallerService {
        AISkillInstallerService(
            homeDirectory: homeDir,
            environment: environment,
            appBundleURL: tempDir.appendingPathComponent("VowKy.app"),
            helperURLOverride: helperURL,
            transcriptionJobsRootOverride: jobRoot
        )
    }

    private var missingHelperURL: URL {
        tempDir.appendingPathComponent("missing-helper")
    }

    private func runProcess(_ executableURL: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func lineValue(prefix: String, in text: String) -> String? {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func makeJobDirectory(named name: String, statusText: String?) throws -> URL {
        let jobDirectory = jobRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        if let statusText {
            try statusText.write(
                to: jobDirectory.appendingPathComponent("status.env"),
                atomically: true,
                encoding: .utf8
            )
        }
        return jobDirectory
    }
}
