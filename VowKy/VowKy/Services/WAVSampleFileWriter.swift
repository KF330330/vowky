import Foundation

final class WAVSampleFileWriter {
    let url: URL
    let sampleRate: Int

    private var fileHandle: FileHandle?
    private(set) var sampleCount: Int = 0

    init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        handle.write(Self.createWAVHeader(dataSize: 0, sampleRate: sampleRate))
        self.fileHandle = handle

        // 写一个 sidecar 标记文件，正常 finalize 时会删除；崩溃留下来供启动扫描识别
        FileManager.default.createFile(atPath: Self.inProgressSidecarURL(for: url).path, contents: nil)
    }

    deinit {
        close()
    }

    func appendSamples(_ samples: [Float]) {
        guard let handle = fileHandle, !samples.isEmpty else { return }
        let floatData = Data(bytes: samples, count: samples.count * MemoryLayout<Float>.size)
        handle.seekToEndOfFile()
        handle.write(floatData)
        sampleCount += samples.count
    }

    func finalize() {
        updateHeader()
        close()
        try? FileManager.default.removeItem(at: Self.inProgressSidecarURL(for: url))
    }

    static func inProgressSidecarURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("inprogress")
    }

    /// 启动恢复时调用：基于 wav 文件的真实字节数回写 header 中的 fileSize/dataSize，
    /// 让外部播放器（QuickTime/Finder 预览）能正确识别长度。
    @discardableResult
    static func repairHeaderInPlace(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let totalSize = attributes[.size] as? Int,
              totalSize > 44 else {
            return false
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }

        let dataSize = UInt32(totalSize - 44)
        let fileSize = UInt32(totalSize - 8)

        do {
            try handle.seek(toOffset: 4)
            var fileSizeLE = fileSize.littleEndian
            try handle.write(contentsOf: Data(bytes: &fileSizeLE, count: 4))

            try handle.seek(toOffset: 40)
            var dataSizeLE = dataSize.littleEndian
            try handle.write(contentsOf: Data(bytes: &dataSizeLE, count: 4))
            return true
        } catch {
            return false
        }
    }

    func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    static func readFloat32Samples(from url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let pcmData = data.dropFirst(44)
        let floatCount = pcmData.count / MemoryLayout<Float>.size
        guard floatCount > 0 else { return [] }

        var samples = [Float](repeating: 0, count: floatCount)
        pcmData.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            for index in 0..<floatCount {
                samples[index] = floatBuffer[index]
            }
        }
        return samples
    }

    private func updateHeader() {
        guard let handle = fileHandle else { return }
        let dataSize = UInt32(sampleCount * MemoryLayout<Float>.size)
        let fileSize = dataSize + 36

        handle.seek(toFileOffset: 4)
        var fileSizeLE = fileSize.littleEndian
        handle.write(Data(bytes: &fileSizeLE, count: 4))

        handle.seek(toFileOffset: 40)
        var dataSizeLE = dataSize.littleEndian
        handle.write(Data(bytes: &dataSizeLE, count: 4))
    }

    private static func createWAVHeader(dataSize: UInt32, sampleRate: Int) -> Data {
        var header = Data(capacity: 44)
        let channels: UInt16 = 1
        let sampleRateValue: UInt32 = UInt32(sampleRate)
        let bitsPerSample: UInt16 = 32
        let byteRate: UInt32 = sampleRateValue * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let audioFormat: UInt16 = 3

        header.append(contentsOf: "RIFF".utf8)
        var chunkSize: UInt32 = (dataSize + 36).littleEndian
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append(contentsOf: "WAVE".utf8)

        header.append(contentsOf: "fmt ".utf8)
        var subchunk1Size: UInt32 = 16
        subchunk1Size = subchunk1Size.littleEndian
        header.append(Data(bytes: &subchunk1Size, count: 4))
        var fmt = audioFormat.littleEndian
        header.append(Data(bytes: &fmt, count: 2))
        var ch = channels.littleEndian
        header.append(Data(bytes: &ch, count: 2))
        var sr = sampleRateValue.littleEndian
        header.append(Data(bytes: &sr, count: 4))
        var br = byteRate.littleEndian
        header.append(Data(bytes: &br, count: 4))
        var ba = blockAlign.littleEndian
        header.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample.littleEndian
        header.append(Data(bytes: &bps, count: 2))

        header.append(contentsOf: "data".utf8)
        var dataChunkSize: UInt32 = dataSize.littleEndian
        header.append(Data(bytes: &dataChunkSize, count: 4))

        return header
    }
}
