#if canImport(Translation)
import Foundation
import Translation

/// Apple 系统离线翻译（macOS 15+）。`TranslationSession` 只能存活在 SwiftUI
/// `.translationTask` 闭包内，因此用「泵」模式：`translate()` 把请求入队等待，
/// `handleSession(_:)` 在闭包里循环消费队列。目标语言变更时 SwiftUI 会取消旧
/// task 并以新 session 重新调用 `handleSession`，in-flight 请求以
/// `.sessionInvalidated` 失败（调用方自动重试一次即可命中新 session）。
/// 注意：session 的目标语言由外层 configuration 决定，`translate(_:to:)` 的
/// target 参数在本实现中不参与请求（仅满足协议）。
@available(macOS 15.0, *)
actor AppleTranslationProvider: TranslationProviding {

    /// Apple session 是固定语言对，源≈目标（如 zh→zh）时所有请求必失败，
    /// coordinator 据此对源语言与目标相同的内容优雅跳过。
    nonisolated var requiresDistinctSourceLanguage: Bool { true }

    private struct PendingRequest {
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private var queue: [PendingRequest] = []
    private var wakeWaiter: CheckedContinuation<Void, Never>?

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(PendingRequest(id: id, text: text, continuation: continuation))
                wake()
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    /// 在 `.translationTask` 闭包内调用，泵循环直到该闭包的 Task 被取消
    /// （configuration 变更或视图销毁）。
    func handleSession(_ session: TranslationSession) async {
        while !Task.isCancelled {
            guard let request = dequeue() else {
                await waitForWork()
                continue
            }
            do {
                let response = try await session.translate(request.text)
                request.continuation.resume(returning: response.targetText)
            } catch is CancellationError {
                request.continuation.resume(throwing: TranslationError.sessionInvalidated)
                break
            } catch {
                request.continuation.resume(throwing: TranslationError.underlying(error.localizedDescription))
            }
        }
    }

    /// 让所有排队中的请求立即失败（引擎切换/窗口销毁时由外层调用，防止悬挂）。
    func invalidateSession() {
        let pending = queue
        queue.removeAll()
        for request in pending {
            request.continuation.resume(throwing: TranslationError.sessionInvalidated)
        }
        wake()
    }

    // MARK: - Private

    private func dequeue() -> PendingRequest? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    private func cancelRequest(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
    }

    private func waitForWork() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !queue.isEmpty || Task.isCancelled {
                    continuation.resume()
                    return
                }
                wakeWaiter = continuation
            }
        } onCancel: {
            Task { await self.wake() }
        }
    }

    private func wake() {
        wakeWaiter?.resume()
        wakeWaiter = nil
    }
}
#endif
