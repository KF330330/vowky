import XCTest
@testable import VowKy

/// 系统声音链路的纯样本运算:下混、两流 FIFO 对齐混音、溢出放行、清尾。
final class SystemAudioMixerTests: XCTestCase {

    private func downmix(_ interleaved: [Float], frames: Int, channels: Int) -> [Float] {
        interleaved.withUnsafeBufferPointer { buffer in
            SystemAudioMixer.downmixInterleavedToMono(buffer.baseAddress!, frames: frames, channels: channels)
        }
    }

    // MARK: - downmixInterleavedToMono

    func test01_downmixMono_copiesSamples() {
        XCTAssertEqual(downmix([0.1, -0.2, 0.3], frames: 3, channels: 1), [0.1, -0.2, 0.3])
    }

    func test02_downmixStereo_averagesChannels() {
        // 帧交错:[L0,R0, L1,R1]
        let mono = downmix([1.0, 0.0, 0.5, -0.5], frames: 2, channels: 2)
        XCTAssertEqual(mono.count, 2)
        XCTAssertEqual(mono[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(mono[1], 0.0, accuracy: 1e-6)
    }

    func test03_downmixThreeChannels_averagesChannels() {
        // 虚拟音频驱动(会议软件那类)常把声道数改成 3
        let mono = downmix([0.3, 0.6, 0.9, -0.3, -0.6, -0.9], frames: 2, channels: 3)
        XCTAssertEqual(mono.count, 2)
        XCTAssertEqual(mono[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(mono[1], -0.6, accuracy: 1e-6)
    }

    func test04_downmixZeroFrames_returnsEmpty() {
        XCTAssertTrue(downmix([0.1], frames: 0, channels: 1).isEmpty)
    }

    // MARK: - averageNonInterleaved

    func test05_averageNonInterleaved_equalLengths() {
        let mono = SystemAudioMixer.averageNonInterleaved([[1.0, 0.0], [0.0, 1.0]])
        XCTAssertEqual(mono, [0.5, 0.5])
    }

    func test06_averageNonInterleaved_unequalLengths_takesMin() {
        let mono = SystemAudioMixer.averageNonInterleaved([[1.0, 1.0, 1.0], [0.0, 0.0]])
        XCTAssertEqual(mono, [0.5, 0.5])
    }

    func test07_averageNonInterleaved_singleChannel_copies() {
        XCTAssertEqual(SystemAudioMixer.averageNonInterleaved([[0.2, -0.4]]), [0.2, -0.4])
    }

    func test08_averageNonInterleaved_empty_returnsEmpty() {
        XCTAssertTrue(SystemAudioMixer.averageNonInterleaved([]).isEmpty)
        XCTAssertTrue(SystemAudioMixer.averageNonInterleaved([[], [0.1]]).isEmpty)
    }

    // MARK: - mixAndClamp

    func test09_mixAndClamp_sumsSamples() {
        let mixed = SystemAudioMixer.mixAndClamp([0.1, -0.2][0...], [0.2, -0.3][0...])
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(mixed[1], -0.5, accuracy: 1e-6)
    }

    func test10_mixAndClamp_clampsToUnitRange() {
        let mixed = SystemAudioMixer.mixAndClamp([0.9, -0.9][0...], [0.8, -0.8][0...])
        XCTAssertEqual(mixed, [1.0, -1.0])
    }

    func test11_mixAndClamp_unequalLengths_takesMin() {
        let mixed = SystemAudioMixer.mixAndClamp([0.1, 0.1, 0.1][0...], [0.2][0...])
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(mixed[0], 0.3, accuracy: 1e-6)
    }

    func test12_mixAndClamp_respectsSliceOffsets() {
        let a: [Float] = [9, 9, 0.1, 0.1]
        let b: [Float] = [0.2, 0.2]
        let mixed = SystemAudioMixer.mixAndClamp(a[2...], b[0...])
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed[0], 0.3, accuracy: 1e-6)
    }

    // MARK: - StreamFIFOMixer

    func test13_drainMixed_alignsToShorterStream_keepsRemainder() {
        let mixer = StreamFIFOMixer(streamCount: 2)
        mixer.push(streamIndex: 0, samples: Array(repeating: 0.5, count: 5))
        mixer.push(streamIndex: 1, samples: Array(repeating: 0.25, count: 3))

        let first = mixer.drainMixed()
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first[0], 0.75, accuracy: 1e-6)

        // 余量(0 路剩 2 个)留存,等 1 路补齐后再出
        XCTAssertTrue(mixer.drainMixed().isEmpty)
        mixer.push(streamIndex: 1, samples: Array(repeating: 0.25, count: 2))
        let second = mixer.drainMixed()
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second[0], 0.75, accuracy: 1e-6)
        XCTAssertTrue(mixer.drainMixed().isEmpty)
    }

    func test14_drainMixed_belowMaxDepth_waitsForOtherStream() {
        let mixer = StreamFIFOMixer(streamCount: 2, maxDepth: 10)
        mixer.push(streamIndex: 0, samples: Array(repeating: 0.5, count: 10))
        XCTAssertTrue(mixer.drainMixed().isEmpty)
    }

    func test15_drainMixed_overflow_releasesWithSilencePadding() {
        // 一路停摆(tap 死掉/设备拔出)时不能把另一路无限拖住:超过 maxDepth 直接按静音补齐放行
        let mixer = StreamFIFOMixer(streamCount: 2, maxDepth: 10)
        mixer.push(streamIndex: 0, samples: Array(repeating: 0.5, count: 11))
        let released = mixer.drainMixed()
        XCTAssertEqual(released.count, 11)
        XCTAssertEqual(released[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(released[10], 0.5, accuracy: 1e-6)
        XCTAssertTrue(mixer.drainMixed().isEmpty)
    }

    func test16_flushRemainder_padsShorterStreamWithSilence() {
        let mixer = StreamFIFOMixer(streamCount: 2)
        mixer.push(streamIndex: 0, samples: Array(repeating: 0.5, count: 4))
        mixer.push(streamIndex: 1, samples: Array(repeating: 0.25, count: 1))
        XCTAssertEqual(mixer.drainMixed().count, 1)

        let tail = mixer.flushRemainder()
        XCTAssertEqual(tail.count, 3)
        XCTAssertEqual(tail[0], 0.5, accuracy: 1e-6)
        XCTAssertTrue(mixer.flushRemainder().isEmpty)
    }

    func test17_drainMixed_clampsSummedStreams() {
        let mixer = StreamFIFOMixer(streamCount: 2)
        mixer.push(streamIndex: 0, samples: [0.9, -0.9])
        mixer.push(streamIndex: 1, samples: [0.8, -0.8])
        XCTAssertEqual(mixer.drainMixed(), [1.0, -1.0])
    }

    func test18_push_ignoresOutOfRangeStreamIndex() {
        let mixer = StreamFIFOMixer(streamCount: 2)
        mixer.push(streamIndex: 5, samples: [0.5])
        mixer.push(streamIndex: -1, samples: [0.5])
        XCTAssertTrue(mixer.flushRemainder().isEmpty)
    }
}
