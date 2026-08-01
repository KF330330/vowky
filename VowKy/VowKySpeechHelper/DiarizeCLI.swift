import Darwin
import Foundation

// vowky-speechd --diarize <wav路径> [--num-speakers N]
//
// 一次性说话人分离子进程:只加载 pyannote(分段)+CAM++(声纹),绝不加载 SenseVoice。
// 输入必须是 canonical 16k mono Float32 WAV(WAVSampleFileWriter 写出的格式)。
// 结果经真实 stdout 行协议输出(见 DiarizeSubprocessProtocol),完成即退出,内存瞬态释放。
enum DiarizeCLI {

    /// 分离模型线程数。与识别器同基准(2026-07-31 实测 4 线程)。
    private static let numThreads = 4

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
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--num-speakers" {
                guard index + 1 < arguments.count, let n = Int(arguments[index + 1]), n > 0 else {
                    return fail("invalid --num-speakers")
                }
                numSpeakers = n
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
        let clusteringConfig = sherpaOnnxFastClusteringConfig(numClusters: numSpeakers)
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

        var lastEmit = Date.distantPast
        let segments = diarizer.process(samples: samples) { processed, total in
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= progressThrottleInterval || processed == total {
                lastEmit = now
                emit(.progress(processed: processed, total: total))
            }
        }

        let dtos = segments.map {
            DiarizeSegmentDTO(s: Double($0.start), e: Double($0.end), spk: $0.speaker)
        }
        NSLog("[VowKy][DiarizeCLI] done: \(dtos.count) segments")
        emit(.result(dtos))
        return 0
    }
}
