import Foundation

// 主 app(客户端)与 vowky-speechd(常驻 helper)之间的线协议。
// 同一份文件编进两端,保证编解码完全一致。
//
// 帧:  [UInt32 大端 长度 N][N 字节 payload]
// payload: [UInt8 opcode][op 专属 body...]
// 音频以原始 Float32 字节(host 序)直拷,不走 JSON/base64;两端同机同架构,安全。
//
// 设计为严格「单请求/单响应」串行(传输层保证一次只有一个在途请求),
// 因此不需要 request id —— 响应必然对应刚发出的请求。

enum SpeechIPCOpcode: UInt8 {
    case handshake = 0x01
    case recognize = 0x02
    case recognizeDetailed = 0x03
    case addPunctuation = 0x04
}

enum SpeechIPCWire {

    /// 帧长度上限,防止失步时狂分配内存。
    static let maxFrameBytes = 64 * 1024 * 1024

    // MARK: - 帧 IO(POSIX,长度前缀)

    /// 写一帧。任何 IO 错误返回 false。
    static func writeFrame(fd: Int32, payload: Data) -> Bool {
        var frame = Data(capacity: payload.count + 4)
        let len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: len) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return writeAll(fd: fd, data: frame)
    }

    /// 读一帧。deadline 为 nil 表示无限阻塞(helper 侧等下一个请求)。
    /// EOF / 超时 / 错误 / 超长 → 返回 nil。
    static func readFrame(fd: Int32, deadline: Date?) -> Data? {
        guard let header = readExactly(fd: fd, count: 4, deadline: deadline) else { return nil }
        let len = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8) | UInt32(header[3])
        guard len > 0, len <= UInt32(maxFrameBytes) else { return nil }
        guard let body = readExactly(fd: fd, count: Int(len), deadline: deadline) else { return nil }
        return Data(body)
    }

    // MARK: - 请求编码(客户端)

    static func encodeHandshakeRequest() -> Data {
        Data([SpeechIPCOpcode.handshake.rawValue])
    }

    static func encodeRecognizeRequest(detailed: Bool, samples: [Float], sampleRate: Int) -> Data {
        var w = Writer()
        w.u8((detailed ? SpeechIPCOpcode.recognizeDetailed : .recognize).rawValue)
        w.u32(UInt32(truncatingIfNeeded: sampleRate))
        w.u32(UInt32(samples.count))
        w.floats(samples)
        return w.data
    }

    static func encodePunctuationRequest(text: String) -> Data {
        var w = Writer()
        w.u8(SpeechIPCOpcode.addPunctuation.rawValue)
        let bytes = Array(text.utf8)
        w.u32(UInt32(bytes.count))
        w.bytes(bytes)
        return w.data
    }

    // MARK: - 请求解码(helper)

    struct RecognizeRequest { let detailed: Bool; let samples: [Float]; let sampleRate: Int }

    /// 解出 opcode,并按需返回 body 解析结果。
    static func opcode(of payload: Data) -> SpeechIPCOpcode? {
        guard let first = payload.first else { return nil }
        return SpeechIPCOpcode(rawValue: first)
    }

    static func decodeRecognizeRequest(_ payload: Data) -> RecognizeRequest? {
        var r = Reader(payload)
        guard let op = r.u8(), let opcode = SpeechIPCOpcode(rawValue: op),
              opcode == .recognize || opcode == .recognizeDetailed,
              let sr = r.u32(), let count = r.u32(),
              let samples = r.floats(Int(count)) else { return nil }
        return RecognizeRequest(detailed: opcode == .recognizeDetailed, samples: samples, sampleRate: Int(sr))
    }

    static func decodePunctuationRequest(_ payload: Data) -> String? {
        var r = Reader(payload)
        guard let op = r.u8(), op == SpeechIPCOpcode.addPunctuation.rawValue,
              let len = r.u32(), let text = r.string(Int(len)) else { return nil }
        return text
    }

    // MARK: - 响应编码(helper)

    static func encodeHandshakeResponse(speechReady: Bool, punctReady: Bool) -> Data {
        var bits: UInt8 = 0
        if speechReady { bits |= 0b01 }
        if punctReady { bits |= 0b10 }
        return Data([bits])
    }

    /// status: 1 = 有文本, 0 = nil
    static func encodeRecognizeResponse(text: String?) -> Data {
        var w = Writer()
        if let text {
            w.u8(1)
            let bytes = Array(text.utf8)
            w.u32(UInt32(bytes.count))
            w.bytes(bytes)
        } else {
            w.u8(0)
        }
        return w.data
    }

    static func encodeDetailedResponse(_ d: DetailedRecognition?) -> Data {
        var w = Writer()
        guard let d else { w.u8(0); return w.data }
        w.u8(1)
        let textBytes = Array(d.text.utf8)
        w.u32(UInt32(textBytes.count)); w.bytes(textBytes)
        w.u32(UInt32(d.tokens.count))
        for token in d.tokens {
            let tb = Array(token.utf8)
            w.u16(UInt16(truncatingIfNeeded: tb.count)); w.bytes(tb)
        }
        w.u32(UInt32(d.timestamps.count))
        w.floats(d.timestamps)
        return w.data
    }

    static func encodePunctuationResponse(text: String) -> Data {
        var w = Writer()
        let bytes = Array(text.utf8)
        w.u32(UInt32(bytes.count)); w.bytes(bytes)
        return w.data
    }

    // MARK: - 响应解码(客户端)

    static func decodeHandshakeResponse(_ data: Data) -> (speech: Bool, punct: Bool)? {
        guard let bits = data.first else { return nil }
        return ((bits & 0b01) != 0, (bits & 0b10) != 0)
    }

    static func decodeRecognizeResponse(_ data: Data) -> String? {
        var r = Reader(data)
        guard let status = r.u8() else { return nil }
        guard status == 1, let len = r.u32(), let text = r.string(Int(len)) else { return nil }
        return text.isEmpty ? nil : text
    }

    static func decodeDetailedResponse(_ data: Data) -> DetailedRecognition? {
        var r = Reader(data)
        guard let status = r.u8() else { return nil }
        guard status == 1 else { return nil }
        guard let textLen = r.u32(), let text = r.string(Int(textLen)), !text.isEmpty,
              let tokCount = r.u32() else { return nil }
        var tokens: [String] = []
        tokens.reserveCapacity(Int(tokCount))
        for _ in 0..<tokCount {
            guard let tl = r.u16(), let t = r.string(Int(tl)) else { return nil }
            tokens.append(t)
        }
        guard let tsCount = r.u32(), let timestamps = r.floats(Int(tsCount)) else { return nil }
        return DetailedRecognition(text: text, tokens: tokens, timestamps: timestamps)
    }

    static func decodePunctuationResponse(_ data: Data) -> String? {
        var r = Reader(data)
        guard let len = r.u32(), let text = r.string(Int(len)) else { return nil }
        return text
    }

    // MARK: - 字节游标

    private struct Reader {
        private let b: [UInt8]
        private var i = 0
        init(_ data: Data) { b = [UInt8](data) }

        mutating func u8() -> UInt8? {
            guard i < b.count else { return nil }
            defer { i += 1 }
            return b[i]
        }
        mutating func u16() -> UInt16? {
            guard i + 2 <= b.count else { return nil }
            let v = (UInt16(b[i]) << 8) | UInt16(b[i + 1]); i += 2; return v
        }
        mutating func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            let v = (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
            i += 4; return v
        }
        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard n >= 0, i + n <= b.count else { return nil }
            defer { i += n }
            return Array(b[i..<i + n])
        }
        mutating func string(_ n: Int) -> String? {
            guard let by = bytes(n) else { return nil }
            return String(decoding: by, as: UTF8.self)
        }
        mutating func floats(_ n: Int) -> [Float]? {
            guard n >= 0, let by = bytes(n * 4) else { return nil }
            if n == 0 { return [] }
            var out = [Float](repeating: 0, count: n)
            out.withUnsafeMutableBytes { dst in
                by.withUnsafeBytes { src in dst.copyMemory(from: src) }
            }
            return out
        }
    }

    private struct Writer {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) {
            data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff))
        }
        mutating func u32(_ v: UInt32) {
            data.append(UInt8(v >> 24)); data.append(UInt8((v >> 16) & 0xff))
            data.append(UInt8((v >> 8) & 0xff)); data.append(UInt8(v & 0xff))
        }
        mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
        mutating func floats(_ f: [Float]) {
            guard !f.isEmpty else { return }
            f.withUnsafeBytes { data.append(contentsOf: $0) }
        }
    }

    // MARK: - 低层读写

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var ptr = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n > 0 {
                    ptr = ptr.advanced(by: n); remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func readExactly(fd: Int32, count: Int, deadline: Date?) -> [UInt8]? {
        if count == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        let ok = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            while got < count {
                if let deadline {
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining <= 0 { return false }
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ms = Int32(min(remaining * 1000.0, Double(Int32.max - 1)))
                    let pr = poll(&pfd, 1, ms)
                    if pr == 0 { return false }       // 超时
                    if pr < 0 { if errno == EINTR { continue }; return false }
                }
                let n = read(fd, base.advanced(by: got), count - got)
                if n > 0 { got += n }
                else if n == 0 { return false }       // EOF
                else { if errno == EINTR { continue }; return false }
            }
            return true
        }
        return ok ? buf : nil
    }
}
