import XCTest
@testable import VowKy

final class AudioBackupServiceTests: XCTestCase {

    var testDir: URL!
    var service: AudioBackupService!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vowky_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        service = AudioBackupService(backupDirectory: testDir)
    }

    override func tearDown() {
        service.deleteBackup()
        try? FileManager.default.removeItem(at: testDir)
        service = nil
        testDir = nil
        super.tearDown()
    }

    // 1. startBackup 后 hasBackup == true
    func testStartBackup_createsFile() throws {
        XCTAssertFalse(service.hasBackup)
        try service.startBackup()
        XCTAssertTrue(service.hasBackup, "Backup file should exist after startBackup")
    }

    // 2. startBackup → appendSamples → recover → 验证数据一致
    func testAppendAndRecover_roundTrip() throws {
        let samples: [Float] = [0.1, 0.2, 0.3, -0.5, 1.0]
        try service.startBackup()
        service.appendSamples(samples)

        let recovered = service.recoverSamples()
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.count, samples.count)
        if let recovered = recovered {
            for i in 0..<samples.count {
                XCTAssertEqual(recovered[i], samples[i], accuracy: 1e-6,
                    "Sample \(i) mismatch")
            }
        }
    }

    // 3. finalizeAndDelete 后 hasBackup == false
    func testFinalizeAndDelete_removesFile() throws {
        try service.startBackup()
        service.appendSamples([0.1, 0.2])
        XCTAssertTrue(service.hasBackup)

        service.finalizeAndDelete()
        XCTAssertFalse(service.hasBackup, "Backup should be removed after finalizeAndDelete")
    }

    // 4. deleteBackup 后 hasBackup == false
    func testDeleteBackup_removesFile() throws {
        try service.startBackup()
        XCTAssertTrue(service.hasBackup)

        service.deleteBackup()
        XCTAssertFalse(service.hasBackup, "Backup should be removed after deleteBackup")
    }

    // 5. 初始状态 hasBackup == false
    func testHasBackup_falseInitially() {
        XCTAssertFalse(service.hasBackup, "No backup should exist initially")
    }

    // 6. 无备份时 recoverSamples 返回 nil
    func testRecoverSamples_noBackup_returnsNil() {
        XCTAssertNil(service.recoverSamples(), "Should return nil when no backup exists")
    }

    // 7. 多次 append 后 recover 拿到所有数据
    func testMultipleAppends_allRecovered() throws {
        let batch1: [Float] = [0.1, 0.2, 0.3]
        let batch2: [Float] = [0.4, 0.5]
        let batch3: [Float] = [-1.0, 0.0, 1.0, 0.7]
        let allSamples = batch1 + batch2 + batch3

        try service.startBackup()
        service.appendSamples(batch1)
        service.appendSamples(batch2)
        service.appendSamples(batch3)

        let recovered = service.recoverSamples()
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.count, allSamples.count,
            "Should recover all \(allSamples.count) samples from 3 appends")
        if let recovered = recovered {
            for i in 0..<allSamples.count {
                XCTAssertEqual(recovered[i], allSamples[i], accuracy: 1e-6,
                    "Sample \(i) mismatch")
            }
        }
    }

    // MARK: - preserveBackup（识别失败时保全音频；目标一律用 temp 目录，绝不写真实用户目录）

    // 8. preserveBackup 移走文件、修好 header、清理 sidecar
    func testPreserveBackup_movesFileWithValidHeader() throws {
        let samples: [Float] = Array(repeating: 0.25, count: 1600) // 0.1s
        try service.startBackup()
        service.appendSamples(samples)

        let destDir = testDir.appendingPathComponent("preserved")
        let preserved = service.preserveBackup(to: destDir, baseName: "VowKy 未识别")

        XCTAssertNotNil(preserved)
        XCTAssertFalse(service.hasBackup, "原备份应已被移走")
        XCTAssertTrue(preserved!.lastPathComponent.hasPrefix("VowKy 未识别 "))
        XCTAssertEqual(preserved!.pathExtension, "wav")
        // finalize 应已清理原备份位置的 .inprogress sidecar
        let originalBackup = testDir.appendingPathComponent("vowky_recording_backup.wav")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: WAVSampleFileWriter.inProgressSidecarURL(for: originalBackup).path))

        // header 已 finalize：dataSize 字段应等于实际 PCM 字节数（外部播放器才能读出时长）
        let data = try Data(contentsOf: preserved!)
        XCTAssertEqual(data.count, 44 + samples.count * 4)
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: dataSize)), samples.count * 4,
            "WAV header dataSize 应已回写为实际数据长度")

        // 保全后的文件应能读回全部样本
        let readBack = WAVSampleFileWriter.readFloat32Samples(from: preserved!)
        XCTAssertEqual(readBack?.count, samples.count)
    }

    // 9. 无备份时 preserveBackup 返回 nil
    func testPreserveBackup_noBackup_returnsNil() {
        XCTAssertNil(service.preserveBackup(to: testDir, baseName: "VowKy 未识别"))
    }

    // 10. 目标重名时追加 -2 后缀，不覆盖已有文件
    func testPreserveBackup_duplicateName_appendsSuffix() throws {
        let destDir = testDir.appendingPathComponent("preserved")

        try service.startBackup()
        service.appendSamples([0.1, 0.2])
        let first = service.preserveBackup(to: destDir, baseName: "VowKy 未识别")
        XCTAssertNotNil(first)

        // 同一秒内再保全一次 → 时间戳相同 → 必须走 -2 后缀
        try service.startBackup()
        service.appendSamples([0.3, 0.4])
        let second = service.preserveBackup(to: destDir, baseName: "VowKy 未识别")
        XCTAssertNotNil(second)

        XCTAssertNotEqual(first, second, "重名时不能覆盖已保全的文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second!.path))
    }

    // 11. 无 writer（模拟崩溃遗留备份）时也能修 header 并保全
    func testPreserveBackup_withoutWriter_repairsHeaderInPlace() throws {
        let samples: [Float] = [0.5, -0.5, 0.25]
        try service.startBackup()
        service.appendSamples(samples)
        _ = service.recoverSamples() // recoverSamples 会 close writer，模拟启动恢复场景

        let destDir = testDir.appendingPathComponent("preserved")
        let preserved = service.preserveBackup(to: destDir, baseName: "VowKy 未识别")

        XCTAssertNotNil(preserved)
        let data = try Data(contentsOf: preserved!)
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: dataSize)), samples.count * 4,
            "无 writer 时应走 repairHeaderInPlace 修好 header")
    }
}
