import Foundation

struct TranscriptionOutputNamer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func textFileURL(
        for sourceURL: URL,
        in outputDirectory: URL,
        usedNames: inout Set<String>
    ) -> URL {
        let rawBaseName = (sourceURL.lastPathComponent as NSString).deletingPathExtension
        let baseName = sanitizedFileName(rawBaseName.isEmpty ? "VowKy-transcript" : rawBaseName)

        var candidateName = "\(baseName).txt"
        var suffix = 2
        while usedNames.contains(candidateName)
            || fileManager.fileExists(atPath: outputDirectory.appendingPathComponent(candidateName).path) {
            candidateName = "\(baseName)-\(suffix).txt"
            suffix += 1
        }

        usedNames.insert(candidateName)
        return outputDirectory.appendingPathComponent(candidateName)
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "VowKy-transcript" : cleaned
    }
}
