import Foundation

/// `SpeechRecognizerProtocol` 的进程外实现:把音频发给常驻 helper,回收识别结果。
/// 任何 IPC 失败都返回 nil,与原 `LocalSpeechRecognizer` 的优雅退化一致。
final class RemoteSpeechRecognizer: SpeechRecognizerProtocol {

    private let transport: HelperTransport

    /// 超时随音频时长伸缩：解码约 0.17x 实时，0.5x + 30s 留 ~3x 余量。
    /// 短音频退化为 60s 下限（文件转写/录音引擎的分段请求行为不变）；上限 30 分钟防极端录音。
    static func requestTimeout(sampleCount: Int, sampleRate: Int) -> TimeInterval {
        let duration = Double(sampleCount) / Double(max(sampleRate, 1))
        return min(max(60, duration * 0.5 + 30), 1800)
    }

    init(transport: HelperTransport) {
        self.transport = transport
    }

    /// 缓存自 handshake 的就绪标志(不做每次往返)。helper 未起/加载中时为 false,
    /// 驱动 AppState 现有「模型加载中…」守卫。
    var isReady: Bool { transport.speechReady }

    /// app 启动时预热:spawn helper 并等模型加载完成。
    func warmUp() async {
        await transport.ensureStarted()
    }

    func recognize(samples: [Float], sampleRate: Int) async -> String? {
        // 不预先 gate readyState:request 内部会按需 (re)spawn,helper 崩溃后下一次调用自愈。
        let payload = SpeechIPCWire.encodeRecognizeRequest(detailed: false, samples: samples, sampleRate: sampleRate)
        let timeout = Self.requestTimeout(sampleCount: samples.count, sampleRate: sampleRate)
        guard let response = await transport.request(payload, timeout: timeout) else { return nil }
        return SpeechIPCWire.decodeRecognizeResponse(response)
    }

    func recognizeDetailed(samples: [Float], sampleRate: Int) async -> DetailedRecognition? {
        let payload = SpeechIPCWire.encodeRecognizeRequest(detailed: true, samples: samples, sampleRate: sampleRate)
        let timeout = Self.requestTimeout(sampleCount: samples.count, sampleRate: sampleRate)
        guard let response = await transport.request(payload, timeout: timeout) else { return nil }
        return SpeechIPCWire.decodeDetailedResponse(response)
    }
}
