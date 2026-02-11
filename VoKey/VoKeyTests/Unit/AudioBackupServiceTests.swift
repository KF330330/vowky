import XCTest
@testable import VoKey

final class AudioBackupServiceTests: XCTestCase {

    var testDir: URL!
    var service: AudioBackupService!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vokey_test_\(UUID().uuidString)")
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
}
