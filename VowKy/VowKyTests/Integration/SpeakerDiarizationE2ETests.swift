import XCTest
@testable import VowKy

/// 端到端：真实 pyannote+CAM++ 分离 + 真实 SenseVoice 逐段识别，对照基准断言。
/// 固化 2026-07-31 调研报告 3.5 节「分离与 ASR 解耦、归属全对」的端到端结论。
/// 注意：基准文件是无 padding 产物，±0.25s padding 会让段边界词略有差异，
/// 因此文本只断言关键短语，不做逐字对比；说话人序列与人数为严格断言。
final class SpeakerDiarizationE2ETests: XCTestCase {

    func test_fourSpeakerAudio_matchesExpectedSpeakerSequenceAndKeyPhrases() async throws {
        guard let wavURL = Self.asset("test-four-speakers-zh.wav"),
              let expectedURL = Self.asset("expected-diar-transcript.txt") else {
            throw XCTSkip("E2E 素材缺失（VowKyTests/Resources/TestAudio/）")
        }
        guard let segmentationModel = Bundle.main.path(
                forResource: "pyannote-segmentation-3-0", ofType: "onnx"),
              let embeddingModel = Bundle.main.path(
                forResource: "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced", ofType: "onnx") else {
            throw XCTSkip("分离模型缺失（app bundle）")
        }

        // 1) 真实分离（与 DiarizeCLI 相同的配置：4 线程、自动估计人数）
        let segmentationConfig = sherpaOnnxOfflineSpeakerSegmentationModelConfig(
            pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: segmentationModel),
            numThreads: 4
        )
        let embeddingConfig = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: embeddingModel, numThreads: 4)
        var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: segmentationConfig,
            embedding: embeddingConfig,
            clustering: sherpaOnnxFastClusteringConfig(threshold: DiarizationTuning.clusteringThreshold)
        )
        let diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
        try XCTSkipIf(diarizer.impl == nil, "分离器创建失败")

        let (samples, sampleRate) = try XCTUnwrap(WAVSampleFileWriter.readMonoSamplesAsFloat32(from: wavURL))
        XCTAssertEqual(sampleRate, diarizer.sampleRate)
        let raw = diarizer.process(samples: samples).map {
            SpeakerSegment(start: Double($0.start), end: Double($0.end), speaker: $0.speaker)
        }
        XCTAssertFalse(raw.isEmpty, "分离应产出说话段")

        // 2) 说话人序列严格断言（双方都按首次出现归一化）
        let expectedLines = try String(contentsOf: expectedURL, encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let expectedSpeakers = Self.normalizeByFirstAppearance(expectedLines.compactMap { line -> Int? in
            guard let range = line.range(of: "：") else { return nil }
            return Int(line[..<range.lowerBound].replacingOccurrences(of: "speaker_", with: ""))
        })

        let totalDuration = Double(samples.count) / Double(sampleRate)
        let segments = SpeakerSegmentComposer.renumberByFirstAppearance(
            SpeakerSegmentComposer.padAndClip(raw, totalDuration: totalDuration)
        )
        XCTAssertEqual(SpeakerSegmentComposer.distinctSpeakerCount(segments), 4, "自动估计说话人数应为 4")
        XCTAssertEqual(segments.map(\.speaker), expectedSpeakers, "说话人归属序列应与基准一致")

        // 3) 逐段真实 SenseVoice 识别 → 关键短语断言
        let recognizer = LocalSpeechRecognizer()
        recognizer.loadModel()
        try XCTSkipIf(!recognizer.isReady, "SenseVoice 模型缺失")
        var pieces: [String] = []
        for segment in segments {
            let startSample = max(0, Int(segment.start * Double(sampleRate)))
            let endSample = min(samples.count, Int(segment.end * Double(sampleRate)))
            guard endSample > startSample else { continue }
            if let text = await recognizer.recognize(
                samples: Array(samples[startSample..<endSample]), sampleRate: sampleRate
            ) {
                pieces.append(text)
            }
        }
        let normalizedAll = Self.normalize(pieces.joined())
        for phrase in ["测试说话人日志", "阳台上吹吹风", "灯火明明暗暗", "坚持到底",
                       "雷军", "年度演讲", "五大往事", "非凡的追求"] {
            XCTAssertTrue(normalizedAll.contains(phrase), "识别全文应含关键短语：\(phrase)，实际：\(normalizedAll)")
        }
    }

    // MARK: - Helpers

    /// 测试素材定位：优先测试 bundle 资源；兜底按 #filePath 从仓库定位。
    private static func asset(_ name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = Bundle(for: SpeakerDiarizationE2ETests.self).url(
            forResource: base, withExtension: ext, subdirectory: "TestAudio"
        ) {
            return url
        }
        if let url = Bundle(for: SpeakerDiarizationE2ETests.self).url(forResource: base, withExtension: ext) {
            return url
        }
        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Integration/
            .deletingLastPathComponent()   // VowKyTests/
            .appendingPathComponent("Resources/TestAudio/\(name)")
        return FileManager.default.fileExists(atPath: repoURL.path) ? repoURL : nil
    }

    private static func normalizeByFirstAppearance(_ ids: [Int]) -> [Int] {
        var mapping: [Int: Int] = [:]
        return ids.map { id in
            if let existing = mapping[id] { return existing }
            let renumbered = mapping.count + 1
            mapping[id] = renumbered
            return renumbered
        }
    }

    /// 去掉空白/标点/符号，只留文字，避免标点抖动导致脆断言。
    private static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            let char = Character(scalar)
            return !(char.isWhitespace || char.isPunctuation || char.isSymbol)
        }.map(Character.init))
    }
}
