import Foundation

enum TranslationError: Error, Equatable, LocalizedError {
    /// Apple TranslationSession 因配置变更/视图销毁而失效，调用方可重试
    case sessionInvalidated
    case http(Int)
    case timeout
    case emptyResult
    /// LLM 引擎缺少 baseURL/model/key
    case notConfigured
    case invalidBaseURL
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .sessionInvalidated: return "翻译会话已失效"
        case .http(let code): return "翻译服务返回 HTTP \(code)"
        case .timeout: return "翻译请求超时"
        case .emptyResult: return "翻译结果为空"
        case .notConfigured: return "请先在设置中填写 LLM 翻译的 API 地址、模型和密钥"
        case .invalidBaseURL: return "API 地址无效"
        case .underlying(let message): return message
        }
    }
}

protocol TranslationProviding: AnyObject {
    func translate(_ text: String, to target: TranslationTarget) async throws -> String

    /// 引擎是否要求源语言 ≠ 目标语言。Apple Translation 的 session 是固定语言对，
    /// 源≈目标（如 zh→zh）时所有请求都会失败；LLM 无此约束。
    var requiresDistinctSourceLanguage: Bool { get }
}

extension TranslationProviding {
    var requiresDistinctSourceLanguage: Bool { false }
}
