import Foundation
import XCTest
@testable import VowKy

final class VowKyTranscribeCLITests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testParseRequiresOutputDirectoryAndAcceptsMultipleRelativeInputs() throws {
        let cwd = tempDir.appendingPathComponent("Project")
        let output = cwd.appendingPathComponent("Output")
        let options = try VowKyTranscribeCLIOptions.parse(
            arguments: [
                "--output-dir", "Output",
                "meeting one.mp4",
                "音频.m4a"
            ],
            currentDirectory: cwd
        )

        XCTAssertEqual(options.outputDirectory, output.standardizedFileURL)
        XCTAssertEqual(
            options.inputFiles,
            [
                cwd.appendingPathComponent("meeting one.mp4").standardizedFileURL,
                cwd.appendingPathComponent("音频.m4a").standardizedFileURL
            ]
        )
    }

    func testParseAllowsDashPrefixedFileAfterTerminator() throws {
        let options = try VowKyTranscribeCLIOptions.parse(
            arguments: ["--output-dir", tempDir.path, "--", "-lecture.mp3"],
            currentDirectory: tempDir
        )

        XCTAssertEqual(options.inputFiles, [tempDir.appendingPathComponent("-lecture.mp3").standardizedFileURL])
    }

    func testParseRejectsMissingOutputDirectory() {
        XCTAssertThrowsError(
            try VowKyTranscribeCLIOptions.parse(arguments: ["audio.mp3"], currentDirectory: tempDir)
        ) { error in
            XCTAssertEqual(error as? VowKyTranscribeCLIError, .missingOutputDirectory)
        }
    }

    func testOutputNamerUsesSourceNameAndAvoidsCollisions() throws {
        let existing = tempDir.appendingPathComponent("meeting.txt")
        try "old".write(to: existing, atomically: true, encoding: .utf8)

        var usedNames = Set<String>()
        let namer = TranscriptionOutputNamer()
        let first = namer.textFileURL(
            for: URL(fileURLWithPath: "/tmp/meeting.mp4"),
            in: tempDir,
            usedNames: &usedNames
        )
        let second = namer.textFileURL(
            for: URL(fileURLWithPath: "/tmp/meeting.mov"),
            in: tempDir,
            usedNames: &usedNames
        )

        XCTAssertEqual(first.lastPathComponent, "meeting-2.txt")
        XCTAssertEqual(second.lastPathComponent, "meeting-3.txt")
    }

    func testOutputNamerSanitizesColonAndPreservesUnicode() {
        var usedNames = Set<String>()
        let namer = TranscriptionOutputNamer()
        let output = namer.textFileURL(
            for: URL(fileURLWithPath: "/tmp/会议:第 一段.m4a"),
            in: tempDir,
            usedNames: &usedNames
        )

        XCTAssertEqual(output.lastPathComponent, "会议-第 一段.txt")
    }

    func testModelLocatorFindsModelsInAppResourcesRoot() throws {
        let appURL = tempDir.appendingPathComponent("VowKy.app")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        let helper = appURL.appendingPathComponent("Contents/Helpers/vowky-transcribe")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createRequiredModelFiles(in: resources)

        let located = try VowKyModelLocator().modelDirectory(executablePath: helper.path)

        XCTAssertEqual(located.standardizedFileURL, resources.standardizedFileURL)
    }

    func testModelLocatorPrefersModelsSubdirectoryWhenPresent() throws {
        let appURL = tempDir.appendingPathComponent("VowKy.app")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        let models = resources.appendingPathComponent("Models")
        let helper = appURL.appendingPathComponent("Contents/Helpers/vowky-transcribe")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createRequiredModelFiles(in: resources)
        try createRequiredModelFiles(in: models)

        let located = try VowKyModelLocator().modelDirectory(executablePath: helper.path)

        XCTAssertEqual(located.standardizedFileURL, models.standardizedFileURL)
    }

    private func createRequiredModelFiles(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("model.int8.onnx"))
        try Data().write(to: directory.appendingPathComponent("tokens.txt"))
    }
}
