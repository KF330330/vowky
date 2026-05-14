import Foundation

struct VowKyTranscribeCLIOptions: Equatable {
    let outputDirectory: URL
    let inputFiles: [URL]

    static func parse(
        arguments: [String],
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> VowKyTranscribeCLIOptions {
        var outputDirectory: URL?
        var inputFiles: [URL] = []
        var index = 0
        var treatsRemainingAsFiles = false

        while index < arguments.count {
            let argument = arguments[index]

            if treatsRemainingAsFiles {
                inputFiles.append(resolvePath(argument, currentDirectory: currentDirectory))
                index += 1
                continue
            }

            switch argument {
            case "--output-dir":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw VowKyTranscribeCLIError.missingValue("--output-dir")
                }
                outputDirectory = resolvePath(arguments[valueIndex], currentDirectory: currentDirectory)
                index += 2
            case "--":
                treatsRemainingAsFiles = true
                index += 1
            case "-h", "--help":
                throw VowKyTranscribeCLIError.helpRequested
            default:
                if argument.hasPrefix("-") {
                    throw VowKyTranscribeCLIError.unknownOption(argument)
                }
                inputFiles.append(resolvePath(argument, currentDirectory: currentDirectory))
                index += 1
            }
        }

        guard let outputDirectory else {
            throw VowKyTranscribeCLIError.missingOutputDirectory
        }
        guard !inputFiles.isEmpty else {
            throw VowKyTranscribeCLIError.missingInputFiles
        }

        return VowKyTranscribeCLIOptions(
            outputDirectory: outputDirectory.standardizedFileURL,
            inputFiles: inputFiles.map(\.standardizedFileURL)
        )
    }

    private static func resolvePath(_ path: String, currentDirectory: URL) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return currentDirectory.appendingPathComponent(expandedPath)
    }
}

enum VowKyTranscribeCLIError: LocalizedError, Equatable {
    case helpRequested
    case missingOutputDirectory
    case missingInputFiles
    case missingValue(String)
    case unknownOption(String)
    case outputDirectoryUnavailable(String)
    case modelFilesNotFound(String)
    case modelLoadFailed
    case inputFileNotFound(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .missingOutputDirectory:
            return "Missing required --output-dir."
        case .missingInputFiles:
            return "No audio or video files were provided."
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        case .outputDirectoryUnavailable(let path):
            return "Output directory is not available: \(path)"
        case .modelFilesNotFound(let path):
            return "VowKy model files were not found near: \(path)"
        case .modelLoadFailed:
            return "Failed to load the VowKy speech model."
        case .inputFileNotFound(let path):
            return "Input file does not exist: \(path)"
        case .writeFailed(let path):
            return "Failed to write transcript: \(path)"
        }
    }
}

struct VowKyTranscribeCLI {
    private let fileManager: FileManager
    private let stderr: TextOutput
    private let stdout: TextOutput

    init(
        fileManager: FileManager = .default,
        stdout: TextOutput = FileHandle.standardOutput,
        stderr: TextOutput = FileHandle.standardError
    ) {
        self.fileManager = fileManager
        self.stdout = stdout
        self.stderr = stderr
    }

    func run(arguments: [String], executablePath: String?) async -> Int32 {
        let options: VowKyTranscribeCLIOptions
        do {
            options = try VowKyTranscribeCLIOptions.parse(arguments: arguments)
        } catch VowKyTranscribeCLIError.helpRequested {
            stdout.writeLine(Self.usage)
            return 0
        } catch {
            stderr.writeLine((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            stderr.writeLine(Self.usage)
            return 2
        }

        do {
            try ensureOutputDirectory(options.outputDirectory)
            let runner = try makeRunner(executablePath: executablePath)
            return await transcribe(options: options, runner: runner)
        } catch {
            stderr.writeLine((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return 1
        }
    }

    private func transcribe(options: VowKyTranscribeCLIOptions, runner: VowKyTranscriptionRunning) async -> Int32 {
        var usedNames = Set<String>()
        let namer = TranscriptionOutputNamer(fileManager: fileManager)
        var failureCount = 0

        for inputFile in options.inputFiles {
            guard fileManager.fileExists(atPath: inputFile.path) else {
                stderr.writeLine("FAILED\t\(inputFile.path)\t\(VowKyTranscribeCLIError.inputFileNotFound(inputFile.path).localizedDescription)")
                failureCount += 1
                continue
            }

            let outputFile = namer.textFileURL(
                for: inputFile,
                in: options.outputDirectory,
                usedNames: &usedNames
            )

            do {
                let transcript = try await runner.transcribe(url: inputFile) { _ in }
                do {
                    try transcript.write(to: outputFile, atomically: true, encoding: .utf8)
                    stdout.writeLine("WROTE\t\(outputFile.path)")
                } catch {
                    stderr.writeLine("FAILED\t\(inputFile.path)\t\(VowKyTranscribeCLIError.writeFailed(outputFile.path).localizedDescription)")
                    failureCount += 1
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                stderr.writeLine("FAILED\t\(inputFile.path)\t\(message)")
                failureCount += 1
            }
        }

        return failureCount == 0 ? 0 : 1
    }

    private func ensureOutputDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw VowKyTranscribeCLIError.outputDirectoryUnavailable(url.path)
            }
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VowKyTranscribeCLIError.outputDirectoryUnavailable(url.path)
        }
    }

    private func makeRunner(executablePath: String?) throws -> VowKyTranscriptionRunning {
        let locator = VowKyModelLocator(fileManager: fileManager)
        let modelDirectory = try locator.modelDirectory(executablePath: executablePath)

        let recognizer = LocalSpeechRecognizer()
        recognizer.loadModel(
            modelPath: modelDirectory.appendingPathComponent("model.int8.onnx").path,
            tokensPath: modelDirectory.appendingPathComponent("tokens.txt").path
        )
        guard recognizer.isReady else {
            throw VowKyTranscribeCLIError.modelLoadFailed
        }

        let punctuation = PunctuationService()
        let punctuationModel = modelDirectory.appendingPathComponent("punct-model.onnx")
        if fileManager.fileExists(atPath: punctuationModel.path) {
            punctuation.loadModel(modelPath: punctuationModel.path)
        }

        let service = FileTranscriptionService(
            speechRecognizer: recognizer,
            punctuationService: punctuation.isReady ? punctuation : nil
        )
        return VowKyFileTranscriptionRunner(service: service)
    }

    static let usage = """
    Usage: vowky-transcribe --output-dir <directory> <audio-or-video> [more-files...]

    Writes one .txt transcript per input file into the output directory.
    """
}

protocol VowKyTranscriptionRunning {
    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String
}

private struct VowKyFileTranscriptionRunner: VowKyTranscriptionRunning {
    let service: FileTranscribing

    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String {
        try await service.transcribe(url: url, progress: progress)
    }
}

struct VowKyModelLocator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func modelDirectory(executablePath: String?) throws -> URL {
        let searchBases = modelSearchBases(executablePath: executablePath)

        for base in searchBases {
            for modelDirectory in appModelDirectories(for: base) {
                if hasRequiredModelFiles(in: modelDirectory) {
                    return modelDirectory
                }
            }
        }

        for modelDirectory in bundleModelDirectories() {
            if hasRequiredModelFiles(in: modelDirectory) {
                return modelDirectory
            }
        }

        let path = executablePath ?? Bundle.main.bundlePath
        throw VowKyTranscribeCLIError.modelFilesNotFound(path)
    }

    private func modelSearchBases(executablePath: String?) -> [URL] {
        var bases: [URL] = []

        if let executablePath {
            var url = URL(fileURLWithPath: executablePath).standardizedFileURL
            while url.path != "/" {
                if url.pathExtension == "app" {
                    bases.append(url)
                    break
                }
                url.deleteLastPathComponent()
            }
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        if bundleURL.pathExtension == "app" {
            bases.append(bundleURL)
        }

        return bases
    }

    private func appModelDirectories(for appURL: URL) -> [URL] {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        return [
            resources.appendingPathComponent("Models"),
            resources
        ]
    }

    private func bundleModelDirectories() -> [URL] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return [
            resources.appendingPathComponent("Models"),
            resources
        ]
    }

    private func hasRequiredModelFiles(in directory: URL) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent("model.int8.onnx").path)
            && fileManager.fileExists(atPath: directory.appendingPathComponent("tokens.txt").path)
    }
}

protocol TextOutput {
    func writeLine(_ line: String)
}

extension FileHandle: TextOutput {
    func writeLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        write(data)
    }
}
