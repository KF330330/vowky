import Foundation

/// 常驻语音 helper 的请求循环:启动即加载模型,然后逐帧读取请求、派发、回写响应。
/// 单线程严格串行(与主 app 侧的串行传输对应)。
final class SpeechIPCServer: @unchecked Sendable {

    private let inputFD: Int32
    private let outputFD: Int32
    private let recognizer = LocalSpeechRecognizer()
    private let punctuation = PunctuationService()

    init(inputFD: Int32, outputFD: Int32) {
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    func run() -> Never {
        loadModels()
        while let frame = SpeechIPCWire.readFrame(fd: inputFD, deadline: nil) {
            let response = handle(frame)
            if !SpeechIPCWire.writeFrame(fd: outputFD, payload: response) {
                break // 管道断裂(父进程已退出)
            }
        }
        // stdin EOF —— 父进程关闭了写端(正常退出 / 更新前关闭),干净退出。
        Darwin.exit(0)
    }

    // MARK: - 模型加载

    private func loadModels() {
        let exe = CommandLine.arguments.first
        guard let dir = try? VowKyModelLocator().modelDirectory(executablePath: exe) else {
            NSLog("[vowky-speechd] ERROR: model directory not found near \(exe ?? "?")")
            return
        }
        recognizer.loadModel(
            modelPath: dir.appendingPathComponent("model.int8.onnx").path,
            tokensPath: dir.appendingPathComponent("tokens.txt").path
        )
        let punctModel = dir.appendingPathComponent("punct-model.onnx")
        if FileManager.default.fileExists(atPath: punctModel.path) {
            punctuation.loadModel(modelPath: punctModel.path)
        }
        NSLog("[vowky-speechd] models loaded: speech=\(recognizer.isReady) punct=\(punctuation.isReady)")
    }

    // MARK: - 请求派发

    private func handle(_ frame: Data) -> Data {
        guard let op = SpeechIPCWire.opcode(of: frame) else {
            return Data([0]) // 不可解析:回 1 字节,客户端解码为 nil → 优雅退化
        }
        switch op {
        case .handshake:
            return SpeechIPCWire.encodeHandshakeResponse(
                speechReady: recognizer.isReady,
                punctReady: punctuation.isReady
            )
        case .recognize, .recognizeDetailed:
            guard let req = SpeechIPCWire.decodeRecognizeRequest(frame) else {
                return op == .recognizeDetailed
                    ? SpeechIPCWire.encodeDetailedResponse(nil)
                    : SpeechIPCWire.encodeRecognizeResponse(text: nil)
            }
            if req.detailed {
                let detailed = blockingAwait {
                    await self.recognizer.recognizeDetailed(samples: req.samples, sampleRate: req.sampleRate)
                }
                return SpeechIPCWire.encodeDetailedResponse(detailed)
            } else {
                let text = blockingAwait {
                    await self.recognizer.recognize(samples: req.samples, sampleRate: req.sampleRate)
                }
                return SpeechIPCWire.encodeRecognizeResponse(text: text)
            }
        case .addPunctuation:
            let text = SpeechIPCWire.decodePunctuationRequest(frame) ?? ""
            let result = punctuation.addPunctuation(to: text)
            return SpeechIPCWire.encodePunctuationResponse(text: result)
        }
    }

    // MARK: - async → 同步桥接(请求循环本身是同步的)

    private func blockingAwait<T>(_ body: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
