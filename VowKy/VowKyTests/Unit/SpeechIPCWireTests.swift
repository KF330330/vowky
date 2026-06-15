import XCTest
@testable import VowKy

/// 进程外语音 helper 的线协议编解码 + 帧 IO 往返测试。
/// 这是 ONNX 移出主进程后新增的关键正确性面,必须有覆盖。
final class SpeechIPCWireTests: XCTestCase {

    // MARK: - 编解码往返

    func testRecognizeRequestRoundTrip() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.123456, -0.987654]
        let payload = SpeechIPCWire.encodeRecognizeRequest(detailed: false, samples: samples, sampleRate: 16000)
        XCTAssertEqual(SpeechIPCWire.opcode(of: payload), .recognize)
        guard let req = SpeechIPCWire.decodeRecognizeRequest(payload) else {
            return XCTFail("decode failed")
        }
        XCTAssertFalse(req.detailed)
        XCTAssertEqual(req.sampleRate, 16000)
        XCTAssertEqual(req.samples, samples)
    }

    func testRecognizeDetailedRequestRoundTrip() {
        let samples = (0..<2048).map { Float($0) / 2048.0 - 0.5 }
        let payload = SpeechIPCWire.encodeRecognizeRequest(detailed: true, samples: samples, sampleRate: 8000)
        XCTAssertEqual(SpeechIPCWire.opcode(of: payload), .recognizeDetailed)
        guard let req = SpeechIPCWire.decodeRecognizeRequest(payload) else {
            return XCTFail("decode failed")
        }
        XCTAssertTrue(req.detailed)
        XCTAssertEqual(req.sampleRate, 8000)
        XCTAssertEqual(req.samples, samples)
    }

    func testRecognizeRequestEmptySamples() {
        let payload = SpeechIPCWire.encodeRecognizeRequest(detailed: false, samples: [], sampleRate: 16000)
        guard let req = SpeechIPCWire.decodeRecognizeRequest(payload) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(req.samples, [])
        XCTAssertEqual(req.sampleRate, 16000)
    }

    func testRecognizeResponseTextRoundTrip() {
        let payload = SpeechIPCWire.encodeRecognizeResponse(text: "你好，世界 hello")
        XCTAssertEqual(SpeechIPCWire.decodeRecognizeResponse(payload), "你好，世界 hello")
    }

    func testRecognizeResponseNilRoundTrip() {
        let payload = SpeechIPCWire.encodeRecognizeResponse(text: nil)
        XCTAssertNil(SpeechIPCWire.decodeRecognizeResponse(payload))
    }

    func testRecognizeResponseEmptyStringDecodesNil() {
        // 空文本视为无结果(与 LocalSpeechRecognizer 一致)
        let payload = SpeechIPCWire.encodeRecognizeResponse(text: "")
        XCTAssertNil(SpeechIPCWire.decodeRecognizeResponse(payload))
    }

    func testDetailedResponseRoundTrip() {
        let detailed = DetailedRecognition(
            text: "今天天气不错",
            tokens: ["今天", "天气", "不错", "🎤"],
            timestamps: [0.0, 0.42, 1.1, 2.0]
        )
        let payload = SpeechIPCWire.encodeDetailedResponse(detailed)
        guard let decoded = SpeechIPCWire.decodeDetailedResponse(payload) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.text, detailed.text)
        XCTAssertEqual(decoded.tokens, detailed.tokens)
        XCTAssertEqual(decoded.timestamps, detailed.timestamps)
    }

    func testDetailedResponseEmptyTokensAndTimestamps() {
        let detailed = DetailedRecognition(text: "纯文本无时间戳", tokens: [], timestamps: [])
        let payload = SpeechIPCWire.encodeDetailedResponse(detailed)
        guard let decoded = SpeechIPCWire.decodeDetailedResponse(payload) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.text, "纯文本无时间戳")
        XCTAssertTrue(decoded.tokens.isEmpty)
        XCTAssertTrue(decoded.timestamps.isEmpty)
    }

    func testDetailedResponseNil() {
        let payload = SpeechIPCWire.encodeDetailedResponse(nil)
        XCTAssertNil(SpeechIPCWire.decodeDetailedResponse(payload))
    }

    func testPunctuationRoundTrip() {
        let req = SpeechIPCWire.encodePunctuationRequest(text: "我们都是木头人不会说话")
        XCTAssertEqual(SpeechIPCWire.opcode(of: req), .addPunctuation)
        XCTAssertEqual(SpeechIPCWire.decodePunctuationRequest(req), "我们都是木头人不会说话")

        let resp = SpeechIPCWire.encodePunctuationResponse(text: "我们都是木头人，不会说话。")
        XCTAssertEqual(SpeechIPCWire.decodePunctuationResponse(resp), "我们都是木头人，不会说话。")
    }

    func testHandshakeResponseBits() {
        XCTAssertEqual(SpeechIPCWire.decodeHandshakeResponse(SpeechIPCWire.encodeHandshakeResponse(speechReady: true, punctReady: true)).map { [$0.speech, $0.punct] }, [true, true])
        XCTAssertEqual(SpeechIPCWire.decodeHandshakeResponse(SpeechIPCWire.encodeHandshakeResponse(speechReady: true, punctReady: false)).map { [$0.speech, $0.punct] }, [true, false])
        XCTAssertEqual(SpeechIPCWire.decodeHandshakeResponse(SpeechIPCWire.encodeHandshakeResponse(speechReady: false, punctReady: true)).map { [$0.speech, $0.punct] }, [false, true])
        XCTAssertEqual(SpeechIPCWire.decodeHandshakeResponse(SpeechIPCWire.encodeHandshakeResponse(speechReady: false, punctReady: false)).map { [$0.speech, $0.punct] }, [false, false])
    }

    // MARK: - 异常输入优雅退化

    func testTruncatedRecognizeRequestReturnsNil() {
        var payload = SpeechIPCWire.encodeRecognizeRequest(detailed: false, samples: [1, 2, 3], sampleRate: 16000)
        payload.removeLast(4) // 砍掉最后一个 float 的一部分
        XCTAssertNil(SpeechIPCWire.decodeRecognizeRequest(payload))
    }

    func testEmptyDataDecodesGracefully() {
        XCTAssertNil(SpeechIPCWire.opcode(of: Data()))
        XCTAssertNil(SpeechIPCWire.decodeRecognizeResponse(Data()))
        XCTAssertNil(SpeechIPCWire.decodeDetailedResponse(Data()))
        XCTAssertNil(SpeechIPCWire.decodeHandshakeResponse(Data()))
    }

    // MARK: - 帧 IO 往返(真实管道)

    func testFrameRoundTripOverPipe() {
        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        let readFD = pipe.fileHandleForReading.fileDescriptor

        let payload = SpeechIPCWire.encodeRecognizeRequest(detailed: true, samples: [0.1, 0.2, 0.3], sampleRate: 16000)
        XCTAssertTrue(SpeechIPCWire.writeFrame(fd: writeFD, payload: payload))

        guard let received = SpeechIPCWire.readFrame(fd: readFD, deadline: Date().addingTimeInterval(2)) else {
            return XCTFail("readFrame returned nil")
        }
        XCTAssertEqual(received, payload)

        // 解出来内容一致
        let req = SpeechIPCWire.decodeRecognizeRequest(received)
        XCTAssertEqual(req?.samples, [0.1, 0.2, 0.3])
    }

    func testReadFrameTimesOutWhenNoData() {
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        // 没有写入任何东西 → 应在 deadline 后返回 nil(不永久阻塞)
        let frame = SpeechIPCWire.readFrame(fd: readFD, deadline: Date().addingTimeInterval(0.2))
        XCTAssertNil(frame)
    }

    func testReadFrameEOFReturnsNil() {
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        try? pipe.fileHandleForWriting.close() // 立即 EOF
        let frame = SpeechIPCWire.readFrame(fd: readFD, deadline: Date().addingTimeInterval(2))
        XCTAssertNil(frame)
    }
}
