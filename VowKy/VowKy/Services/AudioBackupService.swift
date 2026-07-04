import Foundation

final class AudioBackupService: AudioBackupProtocol {

    private let backupURL: URL
    private var writer: WAVSampleFileWriter?
    private let sampleRate: Int = 16000
    private var sampleCount: Int { writer?.sampleCount ?? 0 }
    /// 备份上限：1 小时（防止异常情况下文件无限增长导致启动卡死）
    private let maxSampleCount: Int = 57_600_000 // 16000 * 3600

    init(backupDirectory: URL? = nil) {
        let dir = backupDirectory ?? FileManager.default.temporaryDirectory
        backupURL = dir.appendingPathComponent("vowky_recording_backup.wav")
    }

    var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    func startBackup() throws {
        // 删除旧备份
        deleteBackup()

        // 创建文件并写入 WAV header (44 bytes, float32 PCM, 16kHz, mono)
        writer = try WAVSampleFileWriter(url: backupURL, sampleRate: sampleRate)
        print("[VowKy][Backup] Started backup at \(backupURL.path)")
    }

    func appendSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard sampleCount < maxSampleCount else { return }
        writer?.appendSamples(samples)
    }

    func finalizeAndDelete() {
        writer?.finalize()
        writer = nil
        deleteBackup()
        print("[VowKy][Backup] Finalized and deleted backup")
    }

    func recoverSamples() -> [Float]? {
        guard hasBackup else { return nil }
        closeFile()

        guard let data = try? Data(contentsOf: backupURL) else { return nil }
        guard data.count > 44 else { return nil } // Must have header + data

        // 备份文件超过上限（1小时 ≈ 230MB），直接删除不恢复
        let maxDataSize = maxSampleCount * MemoryLayout<Float>.size + 44
        if data.count > maxDataSize {
            print("[VowKy][Backup] Backup too large (\(data.count) bytes), deleting")
            deleteBackup()
            return nil
        }

        guard let samples = WAVSampleFileWriter.readFloat32Samples(from: backupURL),
              !samples.isEmpty else { return nil }

        print("[VowKy][Backup] Recovered \(samples.count) samples")
        return samples
    }

    func deleteBackup() {
        closeFile()
        try? FileManager.default.removeItem(at: backupURL)
    }

    func preserveBackup(to directory: URL, baseName: String) -> URL? {
        guard hasBackup else { return nil }

        // 先修 WAV header（fileSize/dataSize 只在 finalize 时回写），否则外部播放器认为时长为 0
        if let writer {
            writer.finalize()
            self.writer = nil
        } else {
            // 无 writer（如启动恢复场景的遗留备份）：原地修 header + 清理崩溃遗留的 sidecar
            WAVSampleFileWriter.repairHeaderInPlace(at: backupURL)
            try? FileManager.default.removeItem(at: WAVSampleFileWriter.inProgressSidecarURL(for: backupURL))
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("[VowKy][Backup] preserveBackup: cannot create directory: \(error)")
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = "\(baseName) \(formatter.string(from: Date()))"
        var candidate = stem
        var suffix = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent("\(candidate).wav").path) {
            candidate = "\(stem)-\(suffix)"
            suffix += 1
        }
        let destination = directory.appendingPathComponent("\(candidate).wav")

        do {
            try fileManager.moveItem(at: backupURL, to: destination)
        } catch {
            do {
                try fileManager.copyItem(at: backupURL, to: destination)
                try? fileManager.removeItem(at: backupURL)
            } catch {
                print("[VowKy][Backup] preserveBackup failed: \(error)")
                return nil
            }
        }
        print("[VowKy][Backup] Preserved backup at \(destination.path)")
        return destination
    }

    // MARK: - Private

    private func closeFile() {
        writer?.close()
        writer = nil
    }
}
