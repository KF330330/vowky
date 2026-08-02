import XCTest
@testable import VowKy

/// auto 模式文件转录包装器：抽样探测 → 路由 → 委派极速/本地；极速失败包装器内回落本地。
final class AutoRoutingFileTranscriberTests: XCTestCase {

    private final class MockProbeDecoder: MediaAudioDecoding {
        var duration: TimeInterval = 120
        private(set) var decodedRanges: [MediaAudioTimeRange] = []
        func loadInfo(url: URL) async throws -> MediaAudioInfo { MediaAudioInfo(duration: duration) }
        func decode(url: URL) async throws -> DecodedAudio {
            DecodedAudio(samples: [0.1], sampleRate: 16_000, duration: duration)
        }
        func decode(url: URL, timeRange: MediaAudioTimeRange) async throws -> DecodedAudio {
            decodedRanges.append(timeRange)
            return DecodedAudio(samples: [0.1, 0.2], sampleRate: 16_000, duration: timeRange.duration)
        }
    }

    private final class MockProbeRecognizer: SpeechRecognizerProtocol {
        var results: [String?] = []
        var isReady = true
        private(set) var callCount = 0
        func recognize(samples: [Float], sampleRate: Int) async -> String? {
            callCount += 1
            return results.isEmpty ? nil : results.removeFirst()
        }
    }

    private final class MockFileTranscriber: FileTranscribing {
        enum Outcome {
            case success(String)
            case failure(Error)
        }
        var outcome: Outcome
        private(set) var callCount = 0
        init(_ outcome: Outcome) { self.outcome = outcome }
        func transcribe(
            url: URL,
            progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
        ) async throws -> String {
            callCount += 1
            switch outcome {
            case .success(let text): return text
            case .failure(let error): throw error
            }
        }
    }

    private let url = URL(fileURLWithPath: "/tmp/vowky-tests/fake-audio.m4a")
    private let allInstalled: Set<String> = ["zh-CN", "en-US", "ja-JP", "ko-KR"]

    private func makeSUT(
        decoder: MockProbeDecoder,
        probe: MockProbeRecognizer,
        local: MockFileTranscriber,
        analyzer: MockFileTranscriber?,
        installed: Set<String>? = nil,
        onLocaleRequested: ((String) -> Void)? = nil,
        onInstallRequested: ((String) -> Void)? = nil,
        onYield: (() -> Void)? = nil
    ) -> AutoRoutingFileTranscriber {
        AutoRoutingFileTranscriber(
            decoder: decoder,
            probeRecognizer: probe,
            senseVoiceService: local,
            analyzerFactory: { locale in
                onLocaleRequested?(locale)
                return analyzer
            },
            installedLocales: { installed ?? self.allInstalled },
            requestAssetInstall: onInstallRequested,
            yieldToVoiceInput: onYield.map { yield in { yield() } }
        )
    }

    func test01_chineseProbe_delegatesToAnalyzerWithZhCN() async throws {
        let decoder = MockProbeDecoder()
        let probe = MockProbeRecognizer()
        probe.results = ["今天我们讨论第一件事", "然后是第二件事的安排", "最后总结一下今天的内容"]
        let local = MockFileTranscriber(.success("本地稿"))
        let analyzer = MockFileTranscriber(.success("极速全量稿"))
        var requestedLocales: [String] = []
        let sut = makeSUT(decoder: decoder, probe: probe, local: local, analyzer: analyzer,
                          onLocaleRequested: { requestedLocales.append($0) })

        let text = try await sut.transcribe(url: url) { _ in }

        XCTAssertEqual(text, "极速全量稿")
        XCTAssertEqual(requestedLocales, ["zh-CN"])
        XCTAssertEqual(analyzer.callCount, 1)
        XCTAssertEqual(local.callCount, 0)
        XCTAssertEqual(decoder.decodedRanges.count, 3, "120s 文件取头/中/尾三窗")
    }

    func test02_mixedProbe_delegatesToLocalService() async throws {
        let decoder = MockProbeDecoder()
        let probe = MockProbeRecognizer()
        probe.results = ["我们今天开会讨论了三个重要的问题", "全部都顺利解决了大家辛苦了", "ありがとうございます"]
        let local = MockFileTranscriber(.success("本地稿"))
        let analyzer = MockFileTranscriber(.success("不应出现"))
        var factoryCalled = false
        let sut = makeSUT(decoder: decoder, probe: probe, local: local, analyzer: analyzer,
                          onLocaleRequested: { _ in factoryCalled = true })

        let text = try await sut.transcribe(url: url) { _ in }

        XCTAssertEqual(text, "本地稿")
        XCTAssertFalse(factoryCalled, "混说不建极速转写器")
        XCTAssertEqual(analyzer.callCount, 0)
    }

    func test03_analyzerThrows_fallsBackToLocalService() async throws {
        let decoder = MockProbeDecoder()
        let probe = MockProbeRecognizer()
        probe.results = ["今天我们讨论第一件事", "然后是第二件事的安排", "最后总结一下"]
        let local = MockFileTranscriber(.success("本地兜底稿"))
        let analyzer = MockFileTranscriber(.failure(FileTranscriptionError.noRecognizedText))
        let sut = makeSUT(decoder: decoder, probe: probe, local: local, analyzer: analyzer)

        let text = try await sut.transcribe(url: url) { _ in }

        XCTAssertEqual(text, "本地兜底稿", "极速失败包装器内回落本地，绝不丢转录")
        XCTAssertEqual(analyzer.callCount, 1)
        XCTAssertEqual(local.callCount, 1)
    }

    func test04_shortFile_probesSingleFullWindow() async throws {
        let decoder = MockProbeDecoder()
        decoder.duration = 20
        let probe = MockProbeRecognizer()
        probe.results = ["短文件的中文内容在这里"]
        let local = MockFileTranscriber(.success("本地稿"))
        let analyzer = MockFileTranscriber(.success("极速稿"))
        let sut = makeSUT(decoder: decoder, probe: probe, local: local, analyzer: analyzer)

        _ = try await sut.transcribe(url: url) { _ in }

        XCTAssertEqual(decoder.decodedRanges, [MediaAudioTimeRange(start: 0, duration: 20)])
        XCTAssertEqual(probe.callCount, 1)
    }

    func test05_yieldGateCalledBeforeEachProbeWindow() async throws {
        let decoder = MockProbeDecoder()
        let probe = MockProbeRecognizer()
        probe.results = ["今天我们讨论第一件事", "然后是第二件事的安排", "最后总结一下"]
        let local = MockFileTranscriber(.success("本地稿"))
        let analyzer = MockFileTranscriber(.success("极速稿"))
        var yieldCount = 0
        let sut = makeSUT(decoder: decoder, probe: probe, local: local, analyzer: analyzer,
                          onYield: { yieldCount += 1 })

        _ = try await sut.transcribe(url: url) { _ in }

        XCTAssertEqual(yieldCount, 3, "每个探测窗前过礼让闸")
    }

    func test06_probeTargetNotInstalled_delegatesToLocal_andRequestsInstall() async throws {
        let decoder = MockProbeDecoder()
        let probe = MockProbeRecognizer()
        probe.results = ["今日は会議があります", "よろしくお願いします", "それでは始めましょう"]
        let local = MockFileTranscriber(.success("本地稿"))
        let analyzer = MockFileTranscriber(.success("不应出现"))
        var installRequests: [String] = []
        let sut = makeSUT(decoder: decoder, probe: probe, local: local, analyzer: analyzer,
                          installed: ["zh-CN", "en-US"], // ja-JP 未安装
                          onInstallRequested: { installRequests.append($0) })

        let text = try await sut.transcribe(url: url) { _ in }

        XCTAssertEqual(text, "本地稿")
        XCTAssertEqual(analyzer.callCount, 0)
        XCTAssertEqual(installRequests, ["ja-JP"], "缺失语言按需触发后台下载")
    }

    func test07_probeWindows_layout() {
        // 长文件：头/中/尾三窗互不重叠
        XCTAssertEqual(AutoRoutingFileTranscriber.probeWindows(duration: 120), [
            MediaAudioTimeRange(start: 0, duration: 10),
            MediaAudioTimeRange(start: 55, duration: 10),
            MediaAudioTimeRange(start: 110, duration: 10),
        ])
        // 略超短文件阈值：中/尾窗贴边 clamp 后去重叠
        XCTAssertEqual(AutoRoutingFileTranscriber.probeWindows(duration: 36), [
            MediaAudioTimeRange(start: 0, duration: 10),
            MediaAudioTimeRange(start: 13, duration: 10),
            MediaAudioTimeRange(start: 26, duration: 10),
        ])
        // 短文件：整段单窗
        XCTAssertEqual(AutoRoutingFileTranscriber.probeWindows(duration: 20),
                       [MediaAudioTimeRange(start: 0, duration: 20)])
        XCTAssertEqual(AutoRoutingFileTranscriber.probeWindows(duration: 0), [])
    }
}
