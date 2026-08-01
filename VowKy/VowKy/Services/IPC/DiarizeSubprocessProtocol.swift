import Foundation

// 主 app 与 `vowky-speechd --diarize` 一次性子进程之间的 stdout 行协议。
// 同一份文件编进两端,保证编解码完全一致。
//
// 行格式(UTF-8,每行一条):
//   PROGRESS <processed> <total>   分离进度(来自 C 回调,helper 侧节流后输出)
//   RESULT <单行JSON>              成功终态,JSON 为 {"segments":[{"s":秒,"e":秒,"spk":簇id}]}
//   ERROR <message>                失败终态(进程随后以非零码退出)

struct DiarizeSegmentDTO: Codable, Equatable {
    /// 段起点(秒)
    let s: Double
    /// 段终点(秒)
    let e: Double
    /// 原始说话人簇 id(引擎输出,未重编号)
    let spk: Int
}

enum DiarizeSubprocessLine: Equatable {
    case progress(processed: Int, total: Int)
    case result([DiarizeSegmentDTO])
    case error(String)

    private struct ResultDTO: Codable {
        let segments: [DiarizeSegmentDTO]
    }

    /// 编码为一行(不含换行符)。RESULT 的 JSON 编码失败时降级为 ERROR 行,绝不返回 nil。
    var encoded: String {
        switch self {
        case .progress(let processed, let total):
            return "PROGRESS \(processed) \(total)"
        case .result(let segments):
            let dto = ResultDTO(segments: segments)
            guard let data = try? JSONEncoder().encode(dto),
                  let json = String(data: data, encoding: .utf8) else {
                return "ERROR result encoding failed"
            }
            return "RESULT \(json)"
        case .error(let message):
            // 消息压成单行,防多行错误破坏行协议
            let flattened = message
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return "ERROR \(flattened)"
        }
    }

    /// 解析一行。无法识别的行返回 nil(调用方应忽略,容忍库残留输出)。
    static func parse(_ line: String) -> DiarizeSubprocessLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("PROGRESS ") {
            let parts = trimmed.dropFirst("PROGRESS ".count).split(separator: " ")
            guard parts.count == 2,
                  let processed = Int(parts[0]),
                  let total = Int(parts[1]),
                  processed >= 0, total >= 0 else { return nil }
            return .progress(processed: processed, total: total)
        }
        if trimmed.hasPrefix("RESULT ") {
            let json = String(trimmed.dropFirst("RESULT ".count))
            guard let data = json.data(using: .utf8),
                  let dto = try? JSONDecoder().decode(ResultDTO.self, from: data) else { return nil }
            return .result(dto.segments)
        }
        if trimmed.hasPrefix("ERROR") {
            let message = String(trimmed.dropFirst("ERROR".count)).trimmingCharacters(in: .whitespaces)
            return .error(message)
        }
        return nil
    }
}
