import XCTest
@testable import VowKy

/// 识别请求超时随音频时长伸缩（修复：10 分钟语音在固定 60s 超时下必失败且音频被删）
final class RemoteSpeechRecognizerTimeoutTests: XCTestCase {

    // 短音频退化为 60s 下限：文件转写/录音引擎的分段请求行为不变
    func testShortAudio_usesFloorOf60s() {
        // 10s 音频 → 0.5x + 30 = 35s < 60s 下限
        XCTAssertEqual(
            RemoteSpeechRecognizer.requestTimeout(sampleCount: 160_000, sampleRate: 16_000),
            60
        )
        XCTAssertEqual(
            RemoteSpeechRecognizer.requestTimeout(sampleCount: 0, sampleRate: 16_000),
            60
        )
    }

    // 触发本次 bug 的真实场景：586s 录音 → 323s 超时（解码约需 ~100s，留 ~3x 余量）
    func testLongAudio_scalesWithDuration() {
        let timeout = RemoteSpeechRecognizer.requestTimeout(sampleCount: 9_377_360, sampleRate: 16_000)
        XCTAssertEqual(timeout, 586.085 * 0.5 + 30, accuracy: 0.1)
        XCTAssertGreaterThan(timeout, 300, "10 分钟音频的超时必须远大于旧的固定 60s")
    }

    // 上限 30 分钟，防极端录音把超时推到不合理的量级
    func testExtremeAudio_cappedAt1800s() {
        // 2 小时音频
        XCTAssertEqual(
            RemoteSpeechRecognizer.requestTimeout(sampleCount: 16_000 * 7200, sampleRate: 16_000),
            1800
        )
    }

    // 非法 sampleRate 不除零
    func testZeroSampleRate_doesNotCrash() {
        let timeout = RemoteSpeechRecognizer.requestTimeout(sampleCount: 16_000, sampleRate: 0)
        XCTAssertGreaterThanOrEqual(timeout, 60)
        XCTAssertLessThanOrEqual(timeout, 1800)
    }
}
