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
            backlog = Array(paragraphs[(index + 1)...])
            if fresh.text != displayed.text || fresh.translation != displayed.translation {
                // 冻结切段瞬间当前句会被截短（尾巴划归下一段）：若下一段已在排队，
                // 跳过这次「回缩」上屏——屏幕保持长文，advance 后由下一段自然衔接，
                // 消除「字尾突然消失又在下一条开头出现」的闪缩。内部状态仍取 fresh 保证定位一致。
                let isShrinkIntoNext = Self.isPureShrink(from: displayed.text, to: fresh.text) && !backlog.isEmpty
                if fresh.text != displayed.text && !isShrinkIntoNext { lastContentChangeAt = Date() }
                self.displayed = fresh
                if !isShrinkIntoNext {
                    onDisplay?(fresh)
                }
            }
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
        // 自适应节奏：积压越多播得越快，保证排空速度始终高于语速，任何句子都不会被
        // 丢弃，延迟有界。下限 0.4（原 0.25 会把驻留压到 ~0.4s，快语速时读不完；
        // 0.4 × minDisplay=0.6s 的排空速率 ≈1.7句/s，仍高于任何自然语速）。
        let factor = max(0.4, 1.0 / Double(1 + backlog.count))
        let now = Date()
        // linger 不随积压压缩：内容刚变化（增长/合并演化）时新增文字至少可读 linger 秒；
        // 吞吐由 minDisplay×factor 承担（排空率 ≥1/linger ≈1.25句/s，仍高于自然语速）。
        let eligibleAt = max(
            shownAt.addingTimeInterval(minDisplay * factor),
            lastContentChangeAt.addingTimeInterval(linger)
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

    /// 允许定位结果相对 hint 向前（更早）偏移的最大条数。
    /// 段落流是冻结式追加（committed 只增不改），合法的前移只来自 partial 区
    /// 重切分的小幅波动；更早的"匹配"只可能是重复口头禅/共享前缀的误匹配。
    private static let backTolerance = 3

    /// 以上次位置为锚点就近定位 displayed：先精确匹配文本，
    /// 再用「一方是另一方前缀」匹配同句的增长/修订形态。
    /// 只在 hint 前 backTolerance 条以内搜索：若放行远古误匹配，其后全部
    /// 历史段会被重新入队并加速重放（字幕"回跳重播"bug 的根因）。
    ///
    /// 另处理预览重解码的**标点漂移**（。↔，）造成的两种形变（2026-07-04）：
    /// - 拆分：已显示大段被拆回小段 → 前缀命中的是第一片段，若照常定位会把其余
    ///   片段全部重灌 backlog 重播；此时把阅读头前移到「内容仍被已显示文本覆盖」
    ///   的最后一个连续片段。
    /// - 合并：若干已显示短句被并成一大段 → displayed 变成候选的中段子串，前缀
    ///   匹配失败；若走「跳最新」会清掉排队句（丢句）。就近命中包含它的大段，
    ///   视作同一阅读位置的演化形态。
    private func locate(_ target: TranscriptParagraph, in paragraphs: [TranscriptParagraph]) -> Int? {
        let hint = min(max(0, displayedIndexHint), paragraphs.count - 1)
        let earliest = max(0, hint - Self.backTolerance)
        let order = paragraphs.indices
            .filter { $0 >= earliest }
            .sorted { abs($0 - hint) < abs($1 - hint) }
        if let exact = order.first(where: { paragraphs[$0].text == target.text }) {
            return exact
        }
        let targetNorm = Self.normalized(target.text)
        guard !targetNorm.isEmpty else { return nil }

        if let hit = order.first(where: { isSameSentence(paragraphs[$0].text, target.text) }) {
            // 命中的是 target 的更短前缀 → 可能是大段被重新拆开，向后吞掉
            // 所有「内容已被显示过」的连续片段，从其后继续，不重播。
            if Self.normalized(paragraphs[hit].text).count < targetNorm.count {
                var index = hit
                while index + 1 < paragraphs.count {
                    let nextNorm = Self.normalized(paragraphs[index + 1].text)
                    guard !nextNorm.isEmpty, targetNorm.contains(nextNorm) else { break }
                    index += 1
                }
                return index
            }
            return hit
        }

        // 合并形态：displayed 是候选的子串（含中段）。窗口与就近序不变，回跳保护依旧。
        return order.first { Self.normalized(paragraphs[$0].text).contains(targetNorm) }
    }

    /// 标点/空白不敏感的同句判断：预览重解码会移动/增删标点
    /// （如「ありがとう。」修订为「ありがとうございました」），归一化后再比前缀。
    private func isSameSentence(_ a: String, _ b: String) -> Bool {
        let na = Self.normalized(a)
        let nb = Self.normalized(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na.hasPrefix(nb) || nb.hasPrefix(na)
    }

    /// 纯截短判定：fresh 是 displayed 的归一化前缀且更短（冻结把尾巴划给了下一段）。
    private static func isPureShrink(from displayed: String, to fresh: String) -> Bool {
        let d = normalized(displayed)
        let f = normalized(fresh)
        return !f.isEmpty && f.count < d.count && d.hasPrefix(f)
    }

    private static let ignoredCharacters = Set<Character>("。！？；…!?;.,、，：: 　")

    private static func normalized(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace && !ignoredCharacters.contains($0) })
    }
}
