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
        case .sessionInvalidated: return LL("translation.error.sessionInvalidated")
        case .http(let code): return LL("translation.error.http", code)
        case .timeout: return LL("translation.error.timeout")
        case .emptyResult: return LL("translation.error.emptyResult")
        case .notConfigured: return LL("translation.error.notConfigured")
        case .invalidBaseURL: return LL("translation.error.invalidBaseURL")
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
