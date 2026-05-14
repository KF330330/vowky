import XCTest
@testable import VowKy

final class WAVSampleFileWriterTests: XCTestCase {
    func testFinalizeUpdatesHeaderAndPreservesSamples() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_wav_writer_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples: [Float] = [0.1, -0.2, 0.3]
        let writer = try WAVSampleFileWriter(url: url, sampleRate: 16_000)
        writer.appendSamples(samples)
        writer.finalize()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + samples.count * MemoryLayout<Float>.size)
        XCTAssertEqual(readUInt32LE(data, offset: 4), UInt32(36 + samples.count * MemoryLayout<Float>.size))
        XCTAssertEqual(readUInt32LE(data, offset: 40), UInt32(samples.count * MemoryLayout<Float>.size))

        let recovered = try XCTUnwrap(WAVSampleFileWriter.readFloat32Samples(from: url))
        XCTAssertEqual(recovered.count, samples.count)
        for index in samples.indices {
            XCTAssertEqual(recovered[index], samples[index], accuracy: 0.000001)
        }
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
