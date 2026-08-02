import XCTest
@testable import VowKy

/// SpeechAnalyzer 真机路径集成测试。依赖系统语音资产（首次需联网下载）与 macOS 26+，
/// 不进默认单测：`VOWKY_SA_E2E=1` 才跑。
/// 运行：VOWKY_SA_E2E=1 xcodebuild test ... -only-testing:VowKyTests/SpeechAnalyzerE2ETests
final class SpeechAnalyzerE2ETests: XCTestCase {

    func test_realFileTranscription_producesChineseText() async throws {
        guard ProcessInfo.processInfo.environment["VOWKY_SA_E2E"] == "1" else {
            throw XCTSkip("需 VOWKY_SA_E2E=1（依赖系统语音资产与联网）")
        }
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("需 macOS 26+")
        }
        guard let wavURL = Self.asset("test-four-speakers-zh.wav") else {
            throw XCTSkip("E2E 素材缺失")
        }

        let transcriber = SpeechAnalyzerFileTranscriber(localeIdentifier: "zh-CN")
        var updates: [FileTranscriptionProgress] = []
        let text = try await transcriber.transcribe(url: wavURL) { update in
            updates.append(update)
        }

        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(updates.last?.phase, .finishing)
        // 关键短语粗断言（四人音频内容;SpeechAnalyzer 措辞可能与 SenseVoice 有差异,只断言高置信词）
        let normalized = text.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(normalized.contains("测试"), "应含「测试」：\(normalized)")
        // 怪癖清理生效:不应出现 CJK 标点前空格
        XCTAssertNil(text.range(of: #"\s[，。！？]"#, options: .regularExpression),
                     "CJK 标点前不应有空格：\(text)")
        #else
        throw XCTSkip("当前工具链不含 SpeechAnalyzer（需 Xcode 26）")
        #endif
    }

    /// 听写适配器（SpeechAnalyzerSpeechRecognizer）真机路径：内存样本单发识别出中文。
    func test_dictationRecognizer_memorySamples_producesText() async throws {
        guard ProcessInfo.processInfo.environment["VOWKY_SA_E2E"] == "1" else {
            throw XCTSkip("需 VOWKY_SA_E2E=1（依赖系统语音资产与联网）")
        }
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("需 macOS 26+")
        }
        guard let wavURL = Self.asset("test-four-speakers-zh.wav"),
              let audio = WAVSampleFileWriter.readMonoSamplesAsFloat32(from: wavURL) else {
            throw XCTSkip("E2E 素材缺失")
        }

        let recognizer = SpeechAnalyzerSpeechRecognizer(localeIdentifier: "zh-CN")
        // 取前 10s：听写场景就是短音频单发
        let slice = Array(audio.samples.prefix(audio.sampleRate * 10))
        let text = await recognizer.recognize(samples: slice, sampleRate: audio.sampleRate)

        let recognized = try XCTUnwrap(text, "资产已装时不应返回 nil（nil=基础设施失败契约）")
        XCTAssertFalse(recognized.isEmpty, "10s 真实语音应识别出文本")
        XCTAssertTrue(recognizer.isReady, "识别成功后资产就绪缓存应为 true")
        #else
        throw XCTSkip("当前工具链不含 SpeechAnalyzer（需 Xcode 26）")
        #endif
    }

    private static func asset(_ name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = Bundle(for: SpeechAnalyzerE2ETests.self).url(
            forResource: base, withExtension: ext, subdirectory: "TestAudio"
        ) {
            return url
        }
        if let url = Bundle(for: SpeechAnalyzerE2ETests.self).url(forResource: base, withExtension: ext) {
            return url
        }
        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/TestAudio/\(name)")
        return FileManager.default.fileExists(atPath: repoURL.path) ? repoURL : nil
    }
}
