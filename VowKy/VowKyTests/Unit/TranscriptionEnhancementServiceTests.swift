import XCTest
@testable import VowKy

// MARK: - Mock provider

private actor MockAIProvider: AIProvider {
    nonisolated let displayName: String

    struct Plan {
        var titleResult: Result<String, Error>
        var summaryResult: Result<String, Error>
        var outlineResult: Result<String, Error>
        var titleDelayMs: UInt64 = 0
        var summaryDelayMs: UInt64 = 0
        var outlineDelayMs: UInt64 = 0
    }

    private let plan: Plan
    private var calls: [String] = []
    private var concurrentInFlight: Int = 0
    private var peakInFlight: Int = 0

    init(displayName: String = "mock", plan: Plan) {
        self.displayName = displayName
        self.plan = plan
    }

    func probe() async throws -> String { "OK" }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        concurrentInFlight += 1
        peakInFlight = max(peakInFlight, concurrentInFlight)
        defer { concurrentInFlight = max(0, concurrentInFlight - 1) }

        let bucket = bucketFor(systemPrompt: request.systemPrompt)
        calls.append(bucket)

        let delayMs: UInt64
        let outcome: Result<String, Error>
        switch bucket {
        case "title":
            delayMs = plan.titleDelayMs
            outcome = plan.titleResult
        case "summary":
            delayMs = plan.summaryDelayMs
            outcome = plan.summaryResult
        case "outline":
            delayMs = plan.outlineDelayMs
            outcome = plan.outlineResult
        default:
            delayMs = 0
            outcome = .failure(AIProviderError.empty)
        }

        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }

        switch outcome {
        case .success(let s):
            return AIResponse(text: s, providerLabel: displayName, elapsed: 0)
        case .failure(let e):
            throw e
        }
    }

    func snapshot() -> (calls: [String], peak: Int) {
        (calls, peakInFlight)
    }

    private nonisolated func bucketFor(systemPrompt: String) -> String {
        let p = systemPrompt.lowercased()
        if p.contains("concise title") { return "title" }
        if p.contains("1-3 sentence summary") || p.contains("summary") { return "summary" }
        if p.contains("structure") || p.contains("insert operations") { return "outline" }
        return "unknown"
    }
}

// MARK: - Progress collector

@MainActor
private final class ProgressCollector {
    var entries: [EnhancementProgress] = []
    func append(_ p: EnhancementProgress) { entries.append(p) }
    func entries(for task: EnhancementProgress.Task) -> [EnhancementProgress] {
        entries.filter { $0.task == task }
    }
}

// MARK: - Tests

final class TranscriptionEnhancementServiceTests: XCTestCase {

    private func makeInput(_ raw: String = "原文一句。原文二句。原文三句。") -> EnhancementInput {
        EnhancementInput(
            rawText: raw,
            audioURL: URL(fileURLWithPath: "/tmp/x.wav"),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 60,
            sourceType: "recording"
        )
    }

    func testAllSucceedProducesEnhancedDoc() async {
        let outlineJSON = """
        { "version": 1, "operations": [
          { "kind": "heading", "level": 1, "text": "标题",
            "anchor": { "before": "原文一句。" } }
        ] }
        """
        let mock = MockAIProvider(plan: .init(
            titleResult: .success("会议纪要"),
            summaryResult: .success("一句话摘要。"),
            outlineResult: .success(outlineJSON)
        ))

        let collector = await ProgressCollector()
        let service = TranscriptionEnhancementService()
        let result = await service.enhance(
            input: makeInput(),
            provider: mock,
            markdownPath: "/tmp/doc.md",
            progress: { p in collector.append(p) }
        )

        XCTAssertTrue(result.titleSucceeded)
        XCTAssertTrue(result.summarySucceeded)
        XCTAssertTrue(result.outlineSucceeded)
        XCTAssertEqual(result.metadata.title, "会议纪要")
        XCTAssertEqual(result.metadata.summary, "一句话摘要。")
        XCTAssertTrue(result.fullMarkdownDocument.contains("# 标题"))
        XCTAssertTrue(result.fullMarkdownDocument.contains("title: 会议纪要"))
        XCTAssertTrue(result.metadata.aiEnhancementSucceeded)
    }

    func testTitleFailureFallsBackToRawPrefix() async {
        let mock = MockAIProvider(plan: .init(
            titleResult: .failure(AIProviderError.timeout),
            summaryResult: .success("摘"),
            outlineResult: .success("{ \"version\": 1, \"operations\": [] }")
        ))

        let collector = await ProgressCollector()
        let service = TranscriptionEnhancementService()
        let result = await service.enhance(
            input: makeInput("短文。"),
            provider: mock,
            markdownPath: "/tmp/x.md",
            progress: { p in collector.append(p) }
        )

        XCTAssertFalse(result.titleSucceeded)
        XCTAssertTrue(result.summarySucceeded)
        // 摘要成功 → metadata.aiEnhancementSucceeded == true
        XCTAssertTrue(result.metadata.aiEnhancementSucceeded)
        // 标题降级到原文前缀
        XCTAssertEqual(result.metadata.title, "短文。")
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("标题生成失败") }))
    }

    func testAllThreeFailuresStillReturnsValidResult() async {
        let mock = MockAIProvider(plan: .init(
            titleResult: .failure(AIProviderError.timeout),
            summaryResult: .failure(AIProviderError.httpError(status: 500, body: "boom")),
            outlineResult: .failure(AIProviderError.empty)
        ))

        let collector = await ProgressCollector()
        let service = TranscriptionEnhancementService()
        let result = await service.enhance(
            input: makeInput("正文。"),
            provider: mock,
            markdownPath: "/tmp/x.md",
            progress: { p in collector.append(p) }
        )

        XCTAssertFalse(result.titleSucceeded)
        XCTAssertFalse(result.summarySucceeded)
        XCTAssertFalse(result.outlineSucceeded)
        XCTAssertFalse(result.metadata.aiEnhancementSucceeded)
        // 仍然产出 markdown，body 是原文。ai_enhancement 字段已从 frontmatter 移除。
        XCTAssertTrue(result.fullMarkdownDocument.contains("正文。"))
        XCTAssertFalse(result.fullMarkdownDocument.contains("ai_enhancement"))
        XCTAssertGreaterThanOrEqual(result.warnings.count, 3)
    }

    func testOutlineNonJSONIsDegraded() async {
        let mock = MockAIProvider(plan: .init(
            titleResult: .success("T"),
            summaryResult: .success("S"),
            outlineResult: .success("not a json at all")
        ))

        let collector = await ProgressCollector()
        let service = TranscriptionEnhancementService()
        let result = await service.enhance(
            input: makeInput(),
            provider: mock,
            markdownPath: "/tmp/x.md",
            progress: { p in collector.append(p) }
        )

        XCTAssertTrue(result.titleSucceeded)
        XCTAssertFalse(result.outlineSucceeded)
        // Markdown body 应该等同于原文（无 heading）
        XCTAssertTrue(result.fullMarkdownDocument.contains("原文一句。原文二句。原文三句。"))
        XCTAssertFalse(result.fullMarkdownDocument.contains("\n# "))
    }

    func testTasksRunConcurrently() async {
        // 每个任务 sleep 150ms；若串行则 ~450ms，若并行则 ~150ms。
        let mock = MockAIProvider(plan: .init(
            titleResult: .success("T"),
            summaryResult: .success("S"),
            outlineResult: .success("{ \"version\": 1, \"operations\": [] }"),
            titleDelayMs: 150,
            summaryDelayMs: 150,
            outlineDelayMs: 150
        ))

        let service = TranscriptionEnhancementService()
        let collector = await ProgressCollector()
        let start = Date()
        _ = await service.enhance(
            input: makeInput(),
            provider: mock,
            markdownPath: "/tmp/x.md",
            progress: { p in collector.append(p) }
        )
        let elapsed = Date().timeIntervalSince(start)

        // 给 CI 留余量，但应远低于串行的 450ms
        XCTAssertLessThan(elapsed, 0.35, "got \(elapsed)s — expected concurrent execution")

        let snap = await mock.snapshot()
        XCTAssertEqual(snap.peak, 3, "expected peak in-flight = 3 (all three concurrent)")
        XCTAssertEqual(Set(snap.calls), Set(["title", "summary", "outline"]))
    }

    func testProgressEmitsRunningAndTerminalForEachTask() async {
        let mock = MockAIProvider(plan: .init(
            titleResult: .success("T"),
            summaryResult: .failure(AIProviderError.timeout),
            outlineResult: .success("{ \"version\": 1, \"operations\": [] }")
        ))

        let collector = await ProgressCollector()
        let service = TranscriptionEnhancementService()
        _ = await service.enhance(
            input: makeInput(),
            provider: mock,
            markdownPath: "/tmp/x.md",
            progress: { p in collector.append(p) }
        )

        for task in [EnhancementProgress.Task.title, .summary, .outline] {
            let entries = await collector.entries(for: task)
            XCTAssertTrue(entries.contains(where: { $0.status == .running }), "task \(task.rawValue): no running")
            XCTAssertTrue(entries.contains(where: {
                switch $0.status {
                case .succeeded, .failed: return true
                case .running: return false
                }
            }), "task \(task.rawValue): no terminal status")
        }
    }
}
