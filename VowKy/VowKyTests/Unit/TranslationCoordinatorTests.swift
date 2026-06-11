import XCTest
@testable import VowKy

@MainActor
final class TranslationCoordinatorTests: XCTestCase {

    private let english = TranslationTarget(bcp47: "en")
    private let chinese = TranslationTarget.zhHans

    private func makeCoordinator(
        provider: MockTranslationProvider,
        target: TranslationTarget = TranslationTarget.zhHans,
        debounce: TimeInterval = 0.02
    ) -> TranslationCoordinator {
        TranslationCoordinator(provider: provider, target: target, partialDebounce: debounce)
    }

    /// 轮询等待异步翻译回填
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func update(committed: String, partial: String) -> StreamingRecognitionUpdate {
        StreamingRecognitionUpdate(committedText: committed, partialText: partial, isFinal: false)
    }

    // MARK: - 基础翻译与段落结构

    func test01_committedParagraphs_translated() async {
        let provider = MockTranslationProvider()
        provider.results["Hello everyone."] = "大家好。"
        let coordinator = makeCoordinator(provider: provider)

        coordinator.ingest(update: update(committed: "Hello everyone.", partial: ""))

        await waitUntil { coordinator.paragraphs.first?.translation == .translated("大家好。") }
        XCTAssertEqual(coordinator.paragraphs.count, 1)
        XCTAssertEqual(coordinator.paragraphs[0].id, "c-0")
        XCTAssertFalse(coordinator.paragraphs[0].isPartial)
    }

    func test02_partialParagraph_translatedAfterDebounce() async {
        let provider = MockTranslationProvider()
        provider.results["This is a draft sentence."] = "这是草稿句。"
        let coordinator = makeCoordinator(provider: provider)

        coordinator.ingest(update: update(committed: "", partial: "This is a draft sentence."))
        XCTAssertEqual(coordinator.paragraphs.first?.id, "p-0")
        XCTAssertTrue(coordinator.paragraphs.first?.isPartial ?? false)

        await waitUntil { coordinator.paragraphs.first?.translation == .translated("这是草稿句。") }
        XCTAssertEqual(coordinator.paragraphs.first?.translation, .translated("这是草稿句。"))
    }

    // MARK: - 缓存

    func test03_cacheHit_noDuplicateRequest() async {
        let provider = MockTranslationProvider()
        let coordinator = makeCoordinator(provider: provider)

        coordinator.ingest(update: update(committed: "Stable paragraph one.", partial: ""))
        await waitUntil { coordinator.paragraphs.first?.translation == .translated("译:Stable paragraph one.") }

        // 同一 committed 段再次 ingest（预览更新会反复携带全部 committed 段）
        coordinator.ingest(update: update(committed: "Stable paragraph one.", partial: "More speech coming."))
        await waitUntil { coordinator.paragraphs.count == 2 }

        let requestCount = provider.requestedTexts.filter { $0 == "Stable paragraph one." }.count
        XCTAssertEqual(requestCount, 1, "committed 段命中缓存，不应重复请求")
    }

    func test04_textReplaced_triggersRetranslation() async {
        let provider = MockTranslationProvider()
        let coordinator = makeCoordinator(provider: provider)

        coordinator.ingest(update: update(committed: "Preview quality text.", partial: ""))
        await waitUntil { coordinator.paragraphs.first?.translation == .translated("译:Preview quality text.") }

        // 模拟切段定稿：同一段位置文本被高质量结果替换 → 新 key 必须重译
        coordinator.ingest(update: update(committed: "Final quality text.", partial: ""))
        await waitUntil { coordinator.paragraphs.first?.translation == .translated("译:Final quality text.") }
        XCTAssertTrue(provider.requestedTexts.contains("Final quality text."))
    }

    // MARK: - partial latest-wins

    func test05_partialLatestWins_staleDropped() async {
        let provider = MockTranslationProvider()
        provider.delayNanoseconds = 30_000_000
        let coordinator = makeCoordinator(provider: provider, debounce: 0.05)

        coordinator.ingest(update: update(committed: "", partial: "First dra"))
        // debounce 窗口内立刻被新预览替换
        coordinator.ingest(update: update(committed: "", partial: "First draft sentence done."))

        await waitUntil { coordinator.paragraphs.first?.translation == .translated("译:First draft sentence done.") }
        XCTAssertFalse(
            provider.requestedTexts.contains("First dra"),
            "被替换的旧 partial 不应发出请求（debounce 取消）"
        )
    }

    // MARK: - 同语言跳过

    func test06_sameLanguage_skipped() async {
        let provider = MockTranslationProvider()
        let coordinator = makeCoordinator(provider: provider, target: chinese)

        coordinator.ingest(update: update(committed: "大家好，今天我们讨论新的方案细节。", partial: ""))

        await waitUntil { coordinator.paragraphs.first?.translation == .skippedSameLanguage }
        XCTAssertEqual(coordinator.paragraphs.first?.translation, .skippedSameLanguage)
        XCTAssertTrue(provider.requestedTexts.isEmpty)
    }

    func test07_isSameLanguage_detection() {
        XCTAssertTrue(TranslationCoordinator.isSameLanguage(
            text: "今天天气很好，我们出去走走吧。", target: chinese
        ))
        XCTAssertFalse(TranslationCoordinator.isSameLanguage(
            text: "Hello everyone, this is an English sentence.", target: chinese
        ))
        XCTAssertTrue(TranslationCoordinator.isSameLanguage(
            text: "Hello everyone, this is an English sentence.", target: english
        ))
    }

    // MARK: - 失败与重试

    func test08_nonRetryableFailure_marksFailed_andRetryWorks() async {
        let provider = MockTranslationProvider()
        provider.errors["Needs LLM config."] = .notConfigured
        let coordinator = makeCoordinator(provider: provider)

        coordinator.ingest(update: update(committed: "Needs LLM config.", partial: ""))
        await waitUntil {
            if case .failed = coordinator.paragraphs.first?.translation { return true }
            return false
        }
        guard case .failed = coordinator.paragraphs.first?.translation else {
            return XCTFail("应进入 failed 状态，实际 \(String(describing: coordinator.paragraphs.first?.translation))")
        }

        // 修好后重试
        provider.errors.removeAll()
        coordinator.retry(paragraphID: "c-0")
        await waitUntil { coordinator.paragraphs.first?.translation == .translated("译:Needs LLM config.") }
        XCTAssertEqual(coordinator.paragraphs.first?.translation, .translated("译:Needs LLM config."))
    }

    // MARK: - ingestFinal 与目标切换

    func test09_ingestFinal_replacesParagraphsAsCommitted() async {
        let provider = MockTranslationProvider()
        let coordinator = makeCoordinator(provider: provider)

        coordinator.ingest(update: update(committed: "Old preview.", partial: "Tail piece"))
        coordinator.ingestFinal(text: "Final sentence one.\nFinal sentence two.")

        XCTAssertEqual(coordinator.paragraphs.map(\.id), ["c-0", "c-1"])
        XCTAssertTrue(coordinator.paragraphs.allSatisfy { !$0.isPartial })
        await waitUntil {
            coordinator.paragraphs.allSatisfy {
                if case .translated = $0.translation { return true }
                return false
            }
        }
        XCTAssertEqual(coordinator.paragraphs[1].translation, .translated("译:Final sentence two."))
    }

    func test10_setTarget_clearsCacheAndRetranslates() async {
        let provider = MockTranslationProvider()
        let coordinator = makeCoordinator(provider: provider)

        coordinator.ingest(update: update(committed: "Switch target test.", partial: ""))
        await waitUntil { coordinator.paragraphs.first?.translation == .translated("译:Switch target test.") }

        coordinator.setTarget(TranslationTarget(bcp47: "ja"))
        XCTAssertEqual(coordinator.target.bcp47, "ja")
        await waitUntil {
            provider.requestedTexts.filter { $0 == "Switch target test." }.count >= 2
        }
        XCTAssertGreaterThanOrEqual(
            provider.requestedTexts.filter { $0 == "Switch target test." }.count, 2,
            "切换目标语言后应清缓存重译"
        )
    }

    func test11_shutdown_stopsIngest() async {
        let provider = MockTranslationProvider()
        let coordinator = makeCoordinator(provider: provider)

        coordinator.shutdown()
        coordinator.ingest(update: update(committed: "After shutdown.", partial: ""))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(coordinator.paragraphs.isEmpty)
        XCTAssertTrue(provider.requestedTexts.isEmpty)
    }

    func test13_detectsSourceLanguage() async {
        let provider = MockTranslationProvider()
        let coordinator = makeCoordinator(provider: provider, target: chinese)

        coordinator.ingest(update: update(
            committed: "Hello everyone, today we will discuss the new product plan.",
            partial: ""
        ))
        await waitUntil { coordinator.detectedSourceBCP47 != nil }
        XCTAssertEqual(coordinator.detectedSourceBCP47, "en")
    }

    func test14_detectLanguage_helper() {
        XCTAssertEqual(TranslationCoordinator.detectLanguage("Hello everyone, this is clearly English text."), "en")
        XCTAssertEqual(TranslationCoordinator.detectLanguage("今天天气非常好，我们一起出去散步吧。"), "zh-Hans")
    }

    func test12_splitParagraphs_trimsAndDropsEmpty() {
        XCTAssertEqual(
            TranslationCoordinator.splitParagraphs("  a  \n\n b\n"),
            ["a", "b"]
        )
        XCTAssertEqual(TranslationCoordinator.splitParagraphs(""), [])
    }

    // MARK: - 混合语言/琐碎文本优雅跳过

    func test15_trivialText_skippedWithoutRequest() async {
        let provider = MockTranslationProvider()
        let coordinator = makeCoordinator(provider: provider)

        coordinator.ingest(update: update(committed: ".", partial: ""))
        await waitUntil { coordinator.paragraphs.first?.translation == .skippedSameLanguage }
        XCTAssertEqual(coordinator.paragraphs.first?.translation, .skippedSameLanguage)
        XCTAssertTrue(provider.requestedTexts.isEmpty, "纯标点段不应发出翻译请求")
    }

    func test16_distinctSourceEngine_mixedParagraphSkipped_whenSourceMatchesTarget() async {
        let provider = MockTranslationProvider()
        provider.requiresDistinctSourceLanguage = true  // 模拟 Apple 引擎
        let coordinator = makeCoordinator(provider: provider, target: chinese)

        // 第一段确立整体源语言为中文（与目标相同），第二段是夹英文的混合内容
        coordinator.ingest(update: update(
            committed: "今天我们讨论一下方案的整体设计，大家有什么想法都可以提。\nAnd then merge.",
            partial: ""
        ))
        await waitUntil {
            coordinator.paragraphs.count == 2
                && coordinator.paragraphs.allSatisfy { $0.translation == .skippedSameLanguage }
        }
        XCTAssertTrue(
            provider.requestedTexts.isEmpty,
            "源≈目标时混合段应跳过，不应送给引擎（送了必失败）；实际请求：\(provider.requestedTexts)"
        )
    }

    func test17_llmEngine_stillTranslatesMixedParagraph() async {
        let provider = MockTranslationProvider()  // requiresDistinct 默认 false（LLM）
        provider.results["And then merge."] = "然后合并。"
        let coordinator = makeCoordinator(provider: provider, target: chinese)

        coordinator.ingest(update: update(
            committed: "今天我们讨论一下方案的整体设计，大家有什么想法都可以提。\nAnd then merge.",
            partial: ""
        ))
        await waitUntil {
            coordinator.paragraphs.count == 2
                && coordinator.paragraphs[1].translation == .translated("然后合并。")
        }
        XCTAssertEqual(coordinator.paragraphs[0].translation, .skippedSameLanguage)
        XCTAssertEqual(coordinator.paragraphs[1].translation, .translated("然后合并。"))
    }

    func test18_bcp47SameLanguage() {
        XCTAssertTrue(TranslationCoordinator.bcp47SameLanguage("zh-Hans", "zh-Hans"))
        XCTAssertFalse(TranslationCoordinator.bcp47SameLanguage("zh-Hans", "zh-Hant"), "简→繁是合法翻译")
        XCTAssertTrue(TranslationCoordinator.bcp47SameLanguage("en-US", "en"))
        XCTAssertFalse(TranslationCoordinator.bcp47SameLanguage("en", "ja"))
    }

    func test19_isTrivialText() {
        XCTAssertTrue(TranslationCoordinator.isTrivialText("."))
        XCTAssertTrue(TranslationCoordinator.isTrivialText("123, 456!"))
        XCTAssertFalse(TranslationCoordinator.isTrivialText("a."))
        XCTAssertFalse(TranslationCoordinator.isTrivialText("啊。"))
    }
}
