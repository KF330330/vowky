import Foundation
import NaturalLanguage

/// 录音窗口的翻译编排：把 StreamingRecognitionUpdate 拆成段落，按「段落文本为 key」
/// 缓存译文。committed 段文本稳定 → 只译一次；切段/定稿导致文本变化 → 新 key 自然
/// cache miss → 自动重译。partial 段防抖 400ms + 取消旧任务（latest-wins）。
/// 翻译失败只标记该段，绝不阻塞转写。
@MainActor
final class TranslationCoordinator: ObservableObject {
    @Published private(set) var paragraphs: [TranscriptParagraph] = []
    /// 自动识别出的原文主语言（BCP-47）。供 Apple 引擎设定 source，免去系统弹窗手选。
    /// nil 表示文本还不够检测，交给引擎自行推断。
    @Published private(set) var detectedSourceBCP47: String?

    private(set) var target: TranslationTarget
    private let provider: TranslationProviding
    private let maxCache: Int
    private let partialDebounce: TimeInterval

    /// 译文缓存（key = 原文段落文本）+ 插入顺序（容量淘汰用）
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var skippedSameLanguage: Set<String> = []
    private var failedMessages: [String: String] = [:]

    private var committedTasks: [String: Task<Void, Never>] = [:]
    private var partialTask: Task<Void, Never>?
    /// setTarget 时自增，丢弃旧目标语言的 in-flight 结果
    private var generation = 0
    private var isShutDown = false

    /// 最近一次 ingest 的段落快照，供状态更新后重建 paragraphs
    private var committedTexts: [String] = []
    private var partialTexts: [String] = []

    init(
        provider: TranslationProviding,
        target: TranslationTarget,
        maxCache: Int = 512,
        partialDebounce: TimeInterval = 0.4
    ) {
        self.provider = provider
        self.target = target
        self.maxCache = maxCache
        self.partialDebounce = partialDebounce
    }

    // MARK: - Ingest

    func ingest(update: StreamingRecognitionUpdate) {
        guard !isShutDown else { return }
        committedTexts = Self.splitParagraphs(update.committedText)
        partialTexts = Self.splitParagraphs(update.partialText)
        updateDetectedSource()
        rebuildParagraphs()
        translatePendingCommitted()
        schedulePartialTranslation()
    }

    /// 完成阶段：最终稿（加标点后）整稿按段送译，全部视为 committed。
    func ingestFinal(text: String) {
        guard !isShutDown else { return }
        partialTask?.cancel()
        partialTask = nil
        committedTexts = Self.splitParagraphs(text)
        partialTexts = []
        updateDetectedSource()
        rebuildParagraphs()
        translatePendingCommitted()
    }

    // MARK: - Controls

    func setTarget(_ newTarget: TranslationTarget) {
        guard newTarget != target else { return }
        target = newTarget
        generation += 1
        cancelAllTasks()
        cache.removeAll()
        cacheOrder.removeAll()
        skippedSameLanguage.removeAll()
        failedMessages.removeAll()
        rebuildParagraphs()
        translatePendingCommitted()
        schedulePartialTranslation()
    }

    func retry(paragraphID: String) {
        guard let paragraph = paragraphs.first(where: { $0.id == paragraphID }) else { return }
        failedMessages[paragraph.text] = nil
        rebuildParagraphs()
        if paragraph.isPartial {
            schedulePartialTranslation()
        } else {
            translatePendingCommitted()
        }
    }

    /// 取消所有任务并停止接收新输入（窗口取消/重录时调用）。
    func shutdown() {
        isShutDown = true
        cancelAllTasks()
    }

    // MARK: - Translation scheduling

    private func translatePendingCommitted() {
        for text in committedTexts where translationState(for: text) == .pending {
            startCommittedTask(text: text)
        }
    }

    private func startCommittedTask(text: String, isRetryAttempt: Bool = false) {
        guard committedTasks[text] == nil else { return }
        let gen = generation
        committedTasks[text] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.resolve(text: text)
            guard !Task.isCancelled, self.generation == gen, !self.isShutDown else { return }
            self.committedTasks[text] = nil
            switch outcome {
            case .translated(let translation):
                self.store(translation: translation, for: text)
            case .skipped:
                self.skippedSameLanguage.insert(text)
            case .failed(let message, let retryable):
                if retryable, !isRetryAttempt {
                    // 网络类错误自动重试一次（800ms 退避），避免重试风暴
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, self.generation == gen, !self.isShutDown else { return }
                    self.startCommittedTask(text: text, isRetryAttempt: true)
                    return
                }
                self.failedMessages[text] = message
            }
            self.rebuildParagraphs()
        }
    }

    private func schedulePartialTranslation() {
        partialTask?.cancel()
        let pending = partialTexts.filter { translationState(for: $0) == .pending }
        guard !pending.isEmpty else {
            partialTask = nil
            return
        }
        let gen = generation
        let debounceNs = UInt64(partialDebounce * 1_000_000_000)
        partialTask = Task { [weak self] in
            if debounceNs > 0 {
                try? await Task.sleep(nanoseconds: debounceNs)
            }
            guard let self, !Task.isCancelled, self.generation == gen, !self.isShutDown else { return }
            for text in pending {
                guard !Task.isCancelled else { return }
                let outcome = await self.resolve(text: text)
                guard !Task.isCancelled, self.generation == gen, !self.isShutDown else { return }
                switch outcome {
                case .translated(let translation):
                    self.store(translation: translation, for: text)
                case .skipped:
                    self.skippedSameLanguage.insert(text)
                case .failed:
                    // partial 文本马上会被下一次预览更新替换，失败静默跳过
                    break
                }
                self.rebuildParagraphs()
            }
        }
    }

    private enum TranslationOutcome {
        case translated(String)
        case skipped
        case failed(message: String, retryable: Bool)
    }

    private func resolve(text: String) async -> TranslationOutcome {
        // 纯标点/数字段（如识别噪声产生的单个"."）不送翻译
        if Self.isTrivialText(text) {
            return .skipped
        }
        if Self.isSameLanguage(text: text, target: target) {
            return .skipped
        }
        // 引擎语言对固定（Apple session）且整体源语言≈目标语言时，
        // 混合/短小段（单段检测不出或检测成外语）一并跳过——送出去必失败（如 zh→zh）。
        // LLM 引擎无此约束，照常翻译混合句。
        if provider.requiresDistinctSourceLanguage,
           let source = detectedSourceBCP47,
           Self.bcp47SameLanguage(source, target.bcp47) {
            return .skipped
        }
        do {
            let translation = try await provider.translate(text, to: target)
            return .translated(translation)
        } catch let error as TranslationError {
            let retryable: Bool
            switch error {
            case .notConfigured, .invalidBaseURL, .emptyResult:
                retryable = false
            case .sessionInvalidated, .http, .timeout, .underlying:
                retryable = true
            }
            return .failed(message: error.errorDescription ?? "翻译失败", retryable: retryable)
        } catch is CancellationError {
            return .failed(message: "已取消", retryable: false)
        } catch {
            return .failed(message: error.localizedDescription, retryable: true)
        }
    }

    // MARK: - State / cache

    private func translationState(for text: String) -> ParagraphTranslationState {
        if let translation = cache[text] { return .translated(translation) }
        if skippedSameLanguage.contains(text) { return .skippedSameLanguage }
        if let message = failedMessages[text] { return .failed(message) }
        return .pending
    }

    private func store(translation: String, for text: String) {
        if cache[text] == nil {
            cacheOrder.append(text)
            if cacheOrder.count > maxCache {
                let evicted = cacheOrder.removeFirst()
                cache[evicted] = nil
            }
        }
        cache[text] = translation
        failedMessages[text] = nil
    }

    private func rebuildParagraphs() {
        var result: [TranscriptParagraph] = []
        result.reserveCapacity(committedTexts.count + partialTexts.count)
        for (index, text) in committedTexts.enumerated() {
            result.append(TranscriptParagraph(
                id: "c-\(index)",
                text: text,
                isPartial: false,
                translation: translationState(for: text)
            ))
        }
        for (index, text) in partialTexts.enumerated() {
            result.append(TranscriptParagraph(
                id: "p-\(index)",
                text: text,
                isPartial: true,
                translation: translationState(for: text)
            ))
        }
        paragraphs = result
    }

    private func cancelAllTasks() {
        for task in committedTasks.values { task.cancel() }
        committedTasks.removeAll()
        partialTask?.cancel()
        partialTask = nil
    }

    // MARK: - Helpers

    /// 用全部累计文本检测原文主语言，文本越长越准。检测不出时保留上次结果（不清空）。
    private func updateDetectedSource() {
        let combined = (committedTexts + partialTexts).joined(separator: " ")
        guard combined.count >= 8 else { return }
        guard let bcp47 = Self.detectLanguage(combined) else { return }
        if bcp47 != detectedSourceBCP47 {
            detectedSourceBCP47 = bcp47
        }
    }

    /// 返回 NLLanguageRecognizer 检测出的主语言 BCP-47（置信度足够时），否则 nil。
    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        if let confidence = hypotheses[dominant], confidence < 0.5 { return nil }
        return dominant.rawValue
    }

    /// 先按 "\n" 分段，再按句切分（字幕浮窗与双语对照都以「一句」为最小段落单位）。
    static func splitParagraphs(_ text: String) -> [String] {
        text.split(separator: "\n")
            .flatMap { SentenceSplitter.splitSentences(String($0)) }
    }

    /// 原文主语言 == 目标语言时跳过翻译。检测不出（文本太短）→ 照译，交给引擎兜底。
    static func isSameLanguage(text: String, target: TranslationTarget) -> Bool {
        guard let dominant = NLLanguageRecognizer.dominantLanguage(for: text) else { return false }
        return bcp47SameLanguage(dominant.rawValue, target.bcp47)
    }

    /// 两个 BCP-47 标识是否同一语言。中文区分简繁（zh-Hans/zh-Hant 精确比较，
    /// 简→繁是合法翻译），其它语言只比主语言子标签。
    static func bcp47SameLanguage(_ a: String, _ b: String) -> Bool {
        if a.hasPrefix("zh") || b.hasPrefix("zh") {
            return a == b
        }
        let pa = a.split(separator: "-").first.map(String.init) ?? a
        let pb = b.split(separator: "-").first.map(String.init) ?? b
        return pa == pb
    }

    /// 全文不含任何字母（纯标点/数字/空白）→ 无翻译价值。
    static func isTrivialText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}
