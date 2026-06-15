import Foundation

/// `PunctuationServiceProtocol` 的进程外实现。协议方法是同步的,内部走同步往返
/// (与改造前在进程内跑 CT-Transformer 阻塞时长同量级)。
/// 仅在 helper 已就绪时才发请求,避免在主线程上为 respawn+模型加载长时间阻塞;
/// 未就绪时直接返回原文(优雅退化,等识别路径把 helper 拉起后自然恢复)。
final class RemotePunctuationService: PunctuationServiceProtocol {

    private let transport: HelperTransport
    private static let requestTimeout: TimeInterval = 30

    init(transport: HelperTransport) {
        self.transport = transport
    }

    var isReady: Bool { transport.punctReady }

    func addPunctuation(to text: String) -> String {
        guard transport.punctReady else { return text }
        let payload = SpeechIPCWire.encodePunctuationRequest(text: text)
        guard let response = transport.requestSync(payload, timeout: Self.requestTimeout),
              let result = SpeechIPCWire.decodePunctuationResponse(response) else {
            return text
        }
        return result
    }
}
