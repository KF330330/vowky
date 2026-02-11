import Foundation

final class AudioBackupService: AudioBackupProtocol {

    private let backupURL: URL
    private var fileHandle: FileHandle?
    private var sampleCount: Int = 0
    private let sampleRate: Int = 16000

    init(backupDirectory: URL? = nil) {
        let dir = backupDirectory ?? FileManager.default.temporaryDirectory
        backupURL = dir.appendingPathComponent("vokey_recording_backup.wav")
    }

    var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    func startBackup() throws {
        // 删除旧备份
        deleteBackup()
        sampleCount = 0

        // 创建文件并写入 WAV header (44 bytes, float32 PCM, 16kHz, mono)
        FileManager.default.createFile(atPath: backupURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: backupURL)
        let header = createWAVHeader(dataSize: 0)
        handle.write(header)
        self.fileHandle = handle
        print("[VoKey][Backup] Started backup at \(backupURL.path)")
    }

    func appendSamples(_ samples: [Float]) {
        guard let handle = fileHandle, !samples.isEmpty else { return }
        let floatData = Data(bytes: samples, count: samples.count * MemoryLayout<Float>.size)
        handle.seekToEndOfFile()
        handle.write(floatData)
        sampleCount += samples.count
    }

    func finalizeAndDelete() {
        updateWAVHeader()
        closeFile()
        deleteBackup()
        print("[VoKey][Backup] Finalized and deleted backup")
    }

    func recoverSamples() -> [Float]? {
        guard hasBackup else { return nil }
        closeFile()

        guard let data = try? Data(contentsOf: backupURL) else { return nil }
        guard data.count > 44 else { return nil } // Must have header + data

        let pcmData = data.dropFirst(44) // Skip WAV header
        let floatCount = pcmData.count / MemoryLayout<Float>.size
        guard floatCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: floatCount)
        pcmData.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            for i in 0..<floatCount {
                samples[i] = floatBuffer[i]
            }
        }

        print("[VoKey][Backup] Recovered \(samples.count) samples")
        return samples
    }

    func deleteBackup() {
        closeFile()
        try? FileManager.default.removeItem(at: backupURL)
        sampleCount = 0
    }

    // MARK: - Private

    private func closeFile() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func updateWAVHeader() {
        guard let handle = fileHandle else { return }
        let dataSize = UInt32(sampleCount * MemoryLayout<Float>.size)
        let fileSize = dataSize + 36

        // Update RIFF chunk size (bytes 4-7)
        handle.seek(toFileOffset: 4)
        var fileSizeLE = fileSize.littleEndian
        handle.write(Data(bytes: &fileSizeLE, count: 4))

        // Update data chunk size (bytes 40-43)
        handle.seek(toFileOffset: 40)
        var dataSizeLE = dataSize.littleEndian
        handle.write(Data(bytes: &dataSizeLE, count: 4))
    }

    private func createWAVHeader(dataSize: UInt32) -> Data {
        var header = Data(capacity: 44)
        let channels: UInt16 = 1
        let sampleRate: UInt32 = UInt32(self.sampleRate)
        let bitsPerSample: UInt16 = 32 // float32
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let audioFormat: UInt16 = 3 // IEEE float

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        var chunkSize: UInt32 = (dataSize + 36).littleEndian
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        var subchunk1Size: UInt32 = 16
        subchunk1Size = subchunk1Size.littleEndian
        header.append(Data(bytes: &subchunk1Size, count: 4))
        var fmt = audioFormat.littleEndian
        header.append(Data(bytes: &fmt, count: 2))
        var ch = channels.littleEndian
        header.append(Data(bytes: &ch, count: 2))
        var sr = sampleRate.littleEndian
        header.append(Data(bytes: &sr, count: 4))
        var br = byteRate.littleEndian
        header.append(Data(bytes: &br, count: 4))
        var ba = blockAlign.littleEndian
        header.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample.littleEndian
        header.append(Data(bytes: &bps, count: 2))

        // data sub-chunk
        header.append(contentsOf: "data".utf8)
        var dataChunkSize: UInt32 = dataSize.littleEndian
        header.append(Data(bytes: &dataChunkSize, count: 4))

        return header
    }
}
