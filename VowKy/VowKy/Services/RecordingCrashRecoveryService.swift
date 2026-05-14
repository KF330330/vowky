import Foundation

struct RecoveredRecordingArtifact: Equatable {
    let audioURL: URL
    let startedAt: Date
}

@MainActor
final class RecordingCrashRecoveryService {

    private let outputDirectory: URL
    private let fileManager: FileManager

    init(
        outputDirectory: URL = RecordingTranscriptionOutputStore.defaultOutputDirectory(),
        fileManager: FileManager = .default
    ) {
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
    }

    /// 扫描录音输出目录中的崩溃残留文件：
    /// - 找到所有 `*.wav.inprogress` 标记
    /// - 对应的 `.wav` 修复 header（让外部播放器能识别长度）
    /// - 删除 `.inprogress` 标记
    /// 返回成功恢复的录音 artifact 列表（按时间倒序）。
    func scanAndRepair() -> [RecoveredRecordingArtifact] {
        guard fileManager.fileExists(atPath: outputDirectory.path) else { return [] }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var artifacts: [RecoveredRecordingArtifact] = []
        for sidecar in entries where sidecar.pathExtension == "inprogress" {
            // <base>.wav.inprogress -> <base>.wav
            let audioURL = sidecar.deletingPathExtension()
            guard audioURL.pathExtension == "wav" else {
                // 不是预期的 sidecar，跳过
                try? fileManager.removeItem(at: sidecar)
                continue
            }

            let audioExists = fileManager.fileExists(atPath: audioURL.path)
            let audioSize: Int = {
                guard let attrs = try? fileManager.attributesOfItem(atPath: audioURL.path),
                      let size = attrs[.size] as? Int else { return 0 }
                return size
            }()

            if !audioExists || audioSize <= 44 {
                // 没采到任何样本，没有恢复价值
                try? fileManager.removeItem(at: sidecar)
                if audioExists { try? fileManager.removeItem(at: audioURL) }
                continue
            }

            let repaired = WAVSampleFileWriter.repairHeaderInPlace(at: audioURL)
            try? fileManager.removeItem(at: sidecar)
            guard repaired else { continue }

            let startedAt: Date = {
                guard let attrs = try? fileManager.attributesOfItem(atPath: audioURL.path),
                      let date = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date else {
                    return Date()
                }
                return date
            }()

            artifacts.append(RecoveredRecordingArtifact(audioURL: audioURL, startedAt: startedAt))
        }

        return artifacts.sorted { $0.startedAt > $1.startedAt }
    }
}
