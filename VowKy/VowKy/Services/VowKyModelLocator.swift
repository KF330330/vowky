import Foundation

enum VowKyModelLocatorError: LocalizedError, Equatable {
    case modelFilesNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelFilesNotFound(let path):
            return "VowKy model files were not found near: \(path)"
        }
    }
}

/// 从可执行文件路径上溯到所在 .app,定位 `Contents/Resources/Models/`(或 Resources/)中的模型。
/// 由 `vowky-transcribe` CLI 与常驻 `vowky-speechd` helper 共用;纯 Foundation,不依赖 ONNX。
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
        throw VowKyModelLocatorError.modelFilesNotFound(path)
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
