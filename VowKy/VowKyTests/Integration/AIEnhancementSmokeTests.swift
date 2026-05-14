import XCTest
@testable import VowKy

/// 一次性真实文件 smoke 测试。会真的调用用户配置的 AI provider（当前是 claude CLI）。
/// 不做 XCTAssert，结果写到 ~/Desktop/<原文件名>.enhanced.md，验收靠用户人工看输出。
/// 验证完毕可以删掉此文件。
final class AIEnhancementSmokeTests: XCTestCase {

    func testEnhanceLiliziTxt() async throws {
        let inputPath = "/Users/rl/Nutstore_Files/my_nutstore/900-工作/PTMIND/公司介绍/莉莉姐培训.txt"
        let outputURL = URL(fileURLWithPath: NSString("~/Desktop/莉莉姐培训.enhanced.md").expandingTildeInPath)

        guard let rawText = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
            throw XCTSkip("源文件不存在或读取失败：\(inputPath)")
        }
        print("[smoke] 读到原文 \(rawText.count) 字符")

        var config = AIProviderFactory.load()
        // CLI 启动 + LLM 生成偶尔超 60s，拉到 180s 兜底
        config.timeoutSeconds = max(config.timeoutSeconds, 180)
        let firstKind = config.enabledKindsInPriorityOrder.first ?? .openAICompatible
        print("[smoke] firstEnabledProvider=\(firstKind.rawValue), timeout=\(config.timeoutSeconds)s")

        let provider = AIProviderFactory.makeProvider(kind: firstKind, config: config)
        let service = TranscriptionEnhancementService(provider: provider)
        let input = EnhancementInput(
            rawText: rawText,
            audioURL: nil,
            startedAt: Date(),
            durationSeconds: nil,
            sourceType: "file"
        )

        let started = Date()
        let result = await service.enhance(
            input: input,
            markdownPath: outputURL.path
        ) { progress in
            print("[smoke] \(progress.task.rawValue) → \(progress.status)")
        }
        let elapsed = Date().timeIntervalSince(started)

        try result.fullMarkdownDocument.write(to: outputURL, atomically: true, encoding: .utf8)

        print("====================")
        print("[smoke] 完成耗时 \(String(format: "%.1f", elapsed))s")
        print("[smoke] 输出文件 \(outputURL.path)")
        print("[smoke] 文档字符数 \(result.fullMarkdownDocument.count)")
        print("[smoke] title 成功: \(result.titleSucceeded) → \(result.metadata.title)")
        print("[smoke] summary 成功: \(result.summarySucceeded) → \(result.metadata.summary)")
        print("[smoke] outline 成功: \(result.outlineSucceeded)")
        if !result.warnings.isEmpty {
            print("[smoke] warnings:")
            for w in result.warnings { print("  - \(w)") }
        }
        print("====================")
    }
}
