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

    // MARK: - Private

    private func closeFile() {
        writer?.close()
        writer = nil
    }
}
