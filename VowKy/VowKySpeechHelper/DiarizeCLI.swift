import Darwin
import Foundation

// vowky-speechd --diarize <wav路径> [--num-speakers N] [--threshold T]
//
// 一次性说话人分离子进程:只加载 pyannote(分段)+CAM++(声纹),绝不加载 SenseVoice。
// 输入必须是 canonical 16k mono Float32 WAV(WAVSampleFileWriter 写出的格式)。
// 结果经真实 stdout 行协议输出(见 DiarizeSubprocessProtocol),完成即退出,内存瞬态释放。
enum DiarizeCLI {

    /// 分离模型线程数。与识别器同基准(2026-07-31 实测 4 线程);
    /// VOWKY_DIARIZE_THREADS 环境变量可覆盖(线程调参实验用,生产不设=默认)。
    /// 覆盖值夹取 1...16:越界/非法一律回退默认,防 Int32 转换 trap(codex 三审)。
    private static let numThreads: Int = {
        guard let raw = ProcessInfo.processInfo.environment["VOWKY_DIARIZE_THREADS"],
              let value = Int(raw), (1...16).contains(value) else { return 4 }
        return value
    }()

    /// PROGRESS 行最小间隔,防刷屏。
    private static let progressThrottleInterval: TimeInterval = 0.5

    static func run(arguments: [String], outputFD: Int32) -> Int32 {
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)

        func emit(_ line: DiarizeSubprocessLine) {
            if let data = (line.encoded + "\n").data(using: .utf8) {
                output.write(data)
            }
        }

        func fail(_ message: String) -> Int32 {
            NSLog("[VowKy][DiarizeCLI] ERROR: \(message)")
            emit(.error(message))
            return 1
        }

        // 参数解析:第一个非选项参数 = wav 路径
        var wavPath: String?
        var numSpeakers = -1  // -1 = 自动估计(阈值聚类)
        var threshold = DiarizationTuning.clusteringThreshold
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--num-speakers" {
                guard index + 1 < arguments.count, let n = Int(arguments[index + 1]), n > 0 else {
                    return fail("invalid --num-speakers")
                }
                numSpeakers = n
                index += 2
            } else if arg == "--threshold" {
                guard index + 1 < arguments.count, let t = Float(arguments[index + 1]), t > 0 else {
                    return fail("invalid --threshold")
                }
                threshold = t
                index += 2
            } else if wavPath == nil {
                wavPath = arg
                index += 1
            } else {
                return fail("unexpected argument: \(arg)")
            }
        }
        guard let wavPath else { return fail("missing wav path") }
        guard FileManager.default.fileExists(atPath: wavPath) else {
            return fail("wav file not found: \(wavPath)")
        }

        // 模型定位(分离模型非必需资源,找不到不 fatalError,出 ERROR 行退出)
        let executablePath = CommandLine.arguments.first
        guard let modelPaths = VowKyModelLocator().diarizationModelPaths(executablePath: executablePath) else {
            return fail("diarization models not found")
        }

        // 构造分离器(先建再读 WAV,尽早暴露模型问题)
        let segmentationConfig = sherpaOnnxOfflineSpeakerSegmentationModelConfig(
            pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: modelPaths.segmentation),
            numThreads: numThreads
        )
        let embeddingConfig = sherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: modelPaths.embedding,
            numThreads: numThreads
        )
        let clusteringConfig = sherpaOnnxFastClusteringConfig(numClusters: numSpeakers, threshold: threshold)
        var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: segmentationConfig,
            embedding: embeddingConfig,
            clustering: clusteringConfig
        )
        let diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
        guard diarizer.impl != nil else {
            return fail("failed to create diarizer")
        }

        // 读 WAV(canonical Float32 或 Int16 PCM 单声道)并校验采样率
        guard let (samples, sampleRate) = WAVSampleFileWriter.readMonoSamplesAsFloat32(from: URL(fileURLWithPath: wavPath)),
              !samples.isEmpty else {
            return fail("failed to read samples from wav (mono Float32/Int16 only)")
        }
        guard sampleRate == diarizer.sampleRate else {
            return fail("unsupported wav sample rate \(sampleRate) (expected \(diarizer.sampleRate))")
        }

        NSLog("[VowKy][DiarizeCLI] start: \(samples.count) samples, numSpeakers=\(numSpeakers)")

        // 进度节流 + 多遍映射:自动模式预留两遍空间(第一遍 [0,50%],第二遍 [50%,100%]),
        // 保证 app 侧看到的分数单调不回退;强制人数模式单遍,按原始值输出。
        let isAuto = numSpeakers <= 0
        let totalPasses = isAuto ? 2 : 1
        var lastEmit = Date.distantPast
        var chunkTotal = 0
        func makeProgressHandler(pass: Int) -> (Int, Int) -> Void {
            { processed, total in
                chunkTotal = total
                let now = Date()
                guard now.timeIntervalSince(lastEmit) >= progressThrottleInterval || processed == total else { return }
                lastEmit = now
                emit(.progress(processed: (pass - 1) * total + processed, total: totalPasses * total))
            }
        }

        var segments = diarizer.process(samples: samples, onProgress: makeProgressHandler(pass: 1))
        var dtos = segments.map {
            DiarizeSegmentDTO(s: Double($0.start), e: Double($0.end), spk: $0.speaker)
        }

        // 自动模式两遍策略:第一遍阈值聚类后数「可靠簇」得 N(见 SpeakerCountEstimator);
        // N 少于第一遍簇数时,强制 num_clusters=N 整体重跑归属(引擎无重聚类 API)。
        // N 与第一遍簇数一致时跳过第二遍,结果与单遍完全相同(四人基准即此路径)。
        // 估计器的质心合并/小簇保护需要声纹嵌入:此处注入 CAM++ 提取
        // (一次性子进程,双载 embedding 模型的内存瞬态可接受)。
        if isAuto {
            // 短音频估计器不启用质心合并(与地板同 60s 门槛,语音并集 ≤ 音频时长),
            // 不必双载 embedding 模型
            let audioSeconds = Double(samples.count) / Double(sampleRate)
            var embeddingForRanges: (([(Double, Double)]) -> [Float]?)?
            if audioSeconds >= SpeakerCountEstimator.durationFloorActivation {
                var extractorConfig = sherpaOnnxSpeakerEmbeddingExtractorConfig(
                    model: modelPaths.embedding,
                    numThreads: numThreads
                )
                let extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &extractorConfig)
                embeddingForRanges = { ranges in
                    guard extractor.impl != nil else { return nil }
                    var concatenated: [Float] = []
                    for (start, end) in ranges {
                        let lower = max(0, Int(start * Double(sampleRate)))
                        let upper = min(samples.count, Int(end * Double(sampleRate)))
                        guard upper > lower else { continue }
                        concatenated.append(contentsOf: samples[lower..<upper])
                    }
                    guard !concatenated.isEmpty else { return nil }
                    let stream = extractor.createStream()
                    stream.acceptWaveform(samples: concatenated, sampleRate: sampleRate)
                    stream.inputFinished()
                    let embedding = extractor.compute(stream: stream)
                    return embedding.isEmpty ? nil : embedding
                }
            }
            let pass1Clusters = Set(dtos.map(\.spk)).count
            if let estimated = SpeakerCountEstimator.estimate(
                   segments: dtos,
                   embeddingForRanges: embeddingForRanges,
                   log: { NSLog("[VowKy][DiarizeCLI][estimator] \($0)") }
               ),
               estimated < pass1Clusters {
                NSLog("[VowKy][DiarizeCLI] two-pass: pass1 clusters=\(pass1Clusters), reliable=\(estimated), rerunning")
                var pass2Config = sherpaOnnxOfflineSpeakerDiarizationConfig(
                    segmentation: segmentationConfig,
                    embedding: embeddingConfig,
                    clustering: sherpaOnnxFastClusteringConfig(numClusters: estimated, threshold: threshold)
                )
                diarizer.setConfig(config: &pass2Config)
                segments = diarizer.process(samples: samples, onProgress: makeProgressHandler(pass: 2))
                dtos = segments.map {
                    DiarizeSegmentDTO(s: Double($0.start), e: Double($0.end), spk: $0.speaker)
                }
            } else if chunkTotal > 0 {
                // 跳过第二遍:补一条满进度,让 UI 干净收尾在 100%
                emit(.progress(processed: totalPasses * chunkTotal, total: totalPasses * chunkTotal))
            }
        }

        NSLog("[VowKy][DiarizeCLI] done: \(dtos.count) segments")
        emit(.result(dtos))
        return 0
    }
}
