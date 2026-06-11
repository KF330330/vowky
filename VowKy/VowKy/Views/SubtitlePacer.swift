import Foundation

/// 字幕调度器：把段落流转成「不跳句」的字幕节奏。
/// 预览每 ~1.5s 才更新一次，一个周期内可能同时完成多句；直接镜像最新段会跳句。
/// 这里让新句子排队按序上屏：每句最少展示 minDisplay，内容定稿后驻留 linger
/// 让人读完译文。**绝不丢句**：积压越多播放节奏自动越快（下限约 minDisplay/4），
/// 排空速度快于任何语速，延迟有界。
@MainActor
final class SubtitlePacer {
    private let minDisplay: TimeInterval
    private let linger: TimeInterval

    var onDisplay: ((TranscriptParagraph) -> Void)?

    private(set) var displayed: TranscriptParagraph?
    private var shownAt = Date.distantPast
    private var lastContentChangeAt = Date.distantPast
    private var backlog: [TranscriptParagraph] = []
    private var advanceTask: Task<Void, Never>?
    /// displayed 在上次段落列表中的大致下标，用于在重复文本间就近定位
    private var displayedIndexHint = 0

    init(minDisplay: TimeInterval = 1.5, linger: TimeInterval = 0.8) {
        self.minDisplay = minDisplay
        self.linger = linger
    }

    func ingest(_ paragraphs: [TranscriptParagraph]) {
        advanceTask?.cancel()
        advanceTask = nil
        // 空列表（刚开始/重建瞬间）保持现状，不闪空
        guard !paragraphs.isEmpty else { return }

        if let displayed, let index = locate(displayed, in: paragraphs) {
            displayedIndexHint = index
            let fresh = paragraphs[index]
            if fresh.text != displayed.text || fresh.translation != displayed.translation {
                if fresh.text != displayed.text { lastContentChangeAt = Date() }
                self.displayed = fresh
                onDisplay?(fresh)
            }
            backlog = Array(paragraphs[(index + 1)...])
        } else {
            // 首条，或重解码/定稿大改写导致当前句无法定位 → 跳到最新，不回放历史
            displayedIndexHint = paragraphs.count - 1
            show(paragraphs[paragraphs.count - 1])
            backlog = []
        }

        tryAdvance()
    }

    func reset() {
        advanceTask?.cancel()
        advanceTask = nil
        displayed = nil
        backlog = []
        shownAt = .distantPast
        lastContentChangeAt = .distantPast
        displayedIndexHint = 0
    }

    // MARK: - Private

    private func show(_ paragraph: TranscriptParagraph) {
        displayed = paragraph
        let now = Date()
        shownAt = now
        lastContentChangeAt = now
        onDisplay?(paragraph)
    }

    private func tryAdvance() {
        guard !backlog.isEmpty else { return }
        // 自适应节奏：积压越多播得越快（下限 1/4），保证排空速度始终高于语速，
        // 任何句子都不会被丢弃，延迟有界。
        let factor = max(0.25, 1.0 / Double(1 + backlog.count))
        let now = Date()
        let eligibleAt = max(
            shownAt.addingTimeInterval(minDisplay * factor),
            lastContentChangeAt.addingTimeInterval(linger * factor)
        )
        if now >= eligibleAt {
            displayedIndexHint += 1
            show(backlog.removeFirst())
            tryAdvance()
            return
        }
        let delay = eligibleAt.timeIntervalSince(now)
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.tryAdvance()
        }
    }

    /// 以上次位置为锚点就近定位 displayed：先精确匹配文本，
    /// 再用「一方是另一方前缀」匹配同句的增长/修订形态。
    private func locate(_ target: TranscriptParagraph, in paragraphs: [TranscriptParagraph]) -> Int? {
        let hint = min(max(0, displayedIndexHint), paragraphs.count - 1)
        let order = Array(paragraphs.indices).sorted { abs($0 - hint) < abs($1 - hint) }
        if let exact = order.first(where: { paragraphs[$0].text == target.text }) {
            return exact
        }
        return order.first { isSameSentence(paragraphs[$0].text, target.text) }
    }

    /// 标点/空白不敏感的同句判断：预览重解码会移动/增删标点
    /// （如「ありがとう。」修订为「ありがとうございました」），归一化后再比前缀。
    private func isSameSentence(_ a: String, _ b: String) -> Bool {
        let na = Self.normalized(a)
        let nb = Self.normalized(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na.hasPrefix(nb) || nb.hasPrefix(na)
    }

    private static let ignoredCharacters = Set<Character>("。！？；…!?;.,、，：: 　")

    private static func normalized(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace && !ignoredCharacters.contains($0) })
    }
}
