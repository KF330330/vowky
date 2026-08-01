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

    /// 读 canonical WAV(本类写出的 44 字节头格式)头部声明的采样率。
    static func readHeaderSampleRate(from url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 44), data.count == 44 else { return nil }
        let bytes = [UInt8](data[24..<28])
        let rate = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Int(rate)
    }

    /// 读简单布局(44 字节头,fmt 后紧跟 data)的单声道 WAV 为 Float32 样本。
    /// 支持两种编码:Float32(format 3/32bit,本类 canonical 输出)与 Int16 PCM(format 1/16bit,常见外部素材)。
    /// 非单声道或其他编码返回 nil。
    static func readMonoSamplesAsFloat32(from url: URL) -> (samples: [Float], sampleRate: Int)? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }

        func u16(_ offset: Int) -> Int {
            Int(data[offset]) | (Int(data[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> Int {
            u16(offset) | (u16(offset + 2) << 16)
        }
        guard data.prefix(4).elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8),
              data[36..<40].elementsEqual("data".utf8) else { return nil }

        let audioFormat = u16(20)
        let channels = u16(22)
        let sampleRate = u32(24)
        let bitsPerSample = u16(34)
        guard channels == 1, sampleRate > 0 else { return nil }

        let pcmData = data.dropFirst(44)
        switch (audioFormat, bitsPerSample) {
        case (3, 32):
            let count = pcmData.count / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            var samples = [Float](repeating: 0, count: count)
            pcmData.withUnsafeBytes { rawBuffer in
                let floatBuffer = rawBuffer.bindMemory(to: Float.self)
                for index in 0..<count {
                    samples[index] = floatBuffer[index]
                }
            }
            return (samples, sampleRate)
        case (1, 16):
            let count = pcmData.count / MemoryLayout<Int16>.size
            guard count > 0 else { return nil }
            var samples = [Float](repeating: 0, count: count)
            pcmData.withUnsafeBytes { rawBuffer in
                let intBuffer = rawBuffer.bindMemory(to: Int16.self)
                for index in 0..<count {
                    samples[index] = Float(Int16(littleEndian: intBuffer[index])) / 32768.0
                }
            }
            return (samples, sampleRate)
        default:
            return nil
        }
    }

    /// 按样本区间读取(半开区间,自动 clamp 到文件实际样本数)。区间无效或 IO 失败返回 nil。
    static func readFloat32Samples(from url: URL, sampleRange: Range<Int>) -> [Float]? {
        guard sampleRange.lowerBound >= 0 else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let totalSize = attributes[.size] as? Int,
              totalSize > 44 else { return nil }
        let totalSamples = (totalSize - 44) / MemoryLayout<Float>.size
        let start = min(sampleRange.lowerBound, totalSamples)
        let end = min(sampleRange.upperBound, totalSamples)
        guard end > start else { return [] }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(44 + start * MemoryLayout<Float>.size))
            let byteCount = (end - start) * MemoryLayout<Float>.size
            guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else { return nil }
            var samples = [Float](repeating: 0, count: end - start)
            data.withUnsafeBytes { rawBuffer in
                let floatBuffer = rawBuffer.bindMemory(to: Float.self)
                for index in 0..<samples.count {
                    samples[index] = floatBuffer[index]
                }
            }
            return samples
        } catch {
            return nil
        }
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
