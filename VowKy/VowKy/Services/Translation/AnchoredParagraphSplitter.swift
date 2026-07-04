import Foundation

/// 锚定式段落切分：挡住「重解码标点漂移把已显示短句并成大段」的稳定层。
///
/// 预览每 ~1.5s 重解码一次，句读会漂移（。↔，）。若每次都全量重切，
/// 已经按句号切开显示过的短句会在漂移周期里被并成一个大段，字幕上已读内容整段重现。
/// 本工具改为「锚定 + 增量」：
/// - 已输出且视为终结的句子晋升为「锚」。每次切分先按归一化内容（忽略标点/空白，
///   与 SubtitlePacer 的同句判定同语义）对锚做前缀匹配消费，命中则原样复用首次成句的
///   文本——段落流只追加、不合并、不回改；
/// - 锚定终点之后的新文本才走 fresh 切分。partial 区最后一条无终止标点的句子是
///   「边界句」，不晋升，随后续解码自由长大/终结；
/// - 词级漂移（归一化内容对不上）做有界重同步：容忍锚前少量插入字符（句首幻听
///   「嗯/啊」）、跳过内容真变了的「死锚」（其覆盖的新内容按 gap 原位重切输出），
///   后面的锚继续存活——一句漂移不拖垮后续所有已稳定句子；重同步失败才截断剩余锚，
///   剩余文本退回全量切分（兜底=旧行为）。
///
/// TranslationCoordinator（翻译开）与 RecordingTranscriptionViewModel（翻译关）各持
/// 一个实例，互斥使用。
@MainActor
final class AnchoredParagraphSplitter {
    struct Output: Equatable {
        var committed: [String]
        var partial: [String]
    }

    /// 已锚定句：保留首次成句的原文，一经锚定不再改（与冻结式架构「只追加不回改」同构）。
    private var anchored: [String] = []

    func reset() {
        anchored = []
    }

    func split(committed committedText: String, partial partialText: String) -> Output {
        let committedMap = Self.contentMap(committedText)
        let partialMap = Self.contentMap(partialText)
        let committedCount = committedMap.count
        let totalCount = committedCount + partialMap.count

        func contentChar(at pos: Int) -> Character {
            pos < committedCount ? committedMap[pos].char : partialMap[pos - committedCount].char
        }

        var pos = 0
        var committedPieces: [String] = []
        var partialPieces: [String] = []
        var newAnchors: [String] = []

        func matches(_ norm: [Character], at start: Int) -> Bool {
            guard start >= 0, start + norm.count <= totalCount else { return false }
            for offset in 0..<norm.count where contentChar(at: start + offset) != norm[offset] {
                return false
            }
            return true
        }
        /// 在 [from, from+slack] 范围内找 norm 的起点（有界前向搜索，防远处误匹配）。
        func findAhead(_ norm: [Character], from: Int, slack: Int) -> Int? {
            guard !norm.isEmpty, from + norm.count <= totalCount else { return nil }
            let lastStart = min(from + slack, totalCount - norm.count)
            for candidate in from...lastStart where matches(norm, at: candidate) {
                return candidate
            }
            return nil
        }
        /// 内容末字符落在 committed 区内才算已定；跨边界（切段切在句中）仍归 partial。
        func emit(_ piece: String, contentEnd: Int) {
            if contentEnd < committedCount {
                committedPieces.append(piece)
            } else {
                partialPieces.append(piece)
            }
        }
        /// 内容区间 [a, b) 的原文按区域重切后原位输出（死锚被词级漂移取代后的新内容）。
        func emitGap(fromContent a: Int, toContent b: Int) {
            guard a < b else { return }
            if a < committedCount {
                let end = min(b, committedCount)
                let upper = end < committedCount ? committedMap[end].index : committedText.endIndex
                for piece in TranslationCoordinator.splitParagraphs(String(committedText[committedMap[a].index..<upper])) {
                    committedPieces.append(piece)
                    if !Self.normalizedChars(piece).isEmpty { newAnchors.append(piece) }
                }
            }
            if b > committedCount {
                let start = max(a, committedCount) - committedCount
                let end = b - committedCount
                let upper = end < partialMap.count ? partialMap[end].index : partialText.endIndex
                for piece in TranslationCoordinator.splitParagraphs(String(partialText[partialMap[start].index..<upper])) {
                    partialPieces.append(piece)
                    if !Self.normalizedChars(piece).isEmpty { newAnchors.append(piece) }
                }
            }
        }

        // 1. 锚定消费：按序做归一化前缀匹配，允许跨 committed/partial 边界
        //    （交接期多行冻结句并成一行 committed、切段切在句中都靠这个吃掉）。
        //    直接失配时做有界重同步：容忍锚前 ≤insertSlack 个插入内容字符（句首幻听），
        //    并允许跳过 ≤maxDeadAnchors 条内容真变了的死锚（gap 原位重切输出），
        //    让后面的锚继续存活；重同步失败才截断剩余锚。
        var anchorIndex = 0
        consumption: while anchorIndex < anchored.count {
            let norm = Self.normalizedChars(anchored[anchorIndex])
            guard !norm.isEmpty else {
                anchorIndex += 1
                continue
            }
            if matches(norm, at: pos) {
                emit(anchored[anchorIndex], contentEnd: pos + norm.count - 1)
                newAnchors.append(anchored[anchorIndex])
                pos += norm.count
                anchorIndex += 1
                continue
            }
            var slack = Self.insertSlack
            var candidate = anchorIndex
            while candidate < anchored.count, candidate <= anchorIndex + Self.maxDeadAnchors {
                let candNorm = Self.normalizedChars(anchored[candidate])
                if let start = findAhead(candNorm, from: pos, slack: slack) {
                    emitGap(fromContent: pos, toContent: start)
                    emit(anchored[candidate], contentEnd: start + candNorm.count - 1)
                    newAnchors.append(anchored[candidate])
                    pos = start + candNorm.count
                    anchorIndex = candidate + 1
                    continue consumption
                }
                slack += candNorm.count
                candidate += 1
            }
            break  // 大改写：重同步失败，截断剩余锚，尾部退回全量切分
        }

        // 2. 尾部 fresh 切分。锚后紧邻的标点/空白是已消费句的漂移边界，跳到下一个
        //    内容字符再取原文（避免切出「，第二点」这类残句）；一个锚都没消费时保持
        //    全量原文（纯标点段等旧行为不变）。
        let committedTail: String
        let partialTail: String
        if pos == 0 {
            committedTail = committedText
            partialTail = partialText
        } else if pos < committedCount {
            committedTail = String(committedText[committedMap[pos].index...])
            partialTail = partialText
        } else {
            committedTail = ""
            let partialPos = pos - committedCount
            partialTail = partialPos < partialMap.count
                ? String(partialText[partialMap[partialPos].index...])
                : ""
        }
        let committedFresh = TranslationCoordinator.splitParagraphs(committedTail)
        let partialFresh = TranslationCoordinator.splitParagraphs(partialTail)

        // 3. 晋升为新锚：committed 尾全部（committed 永不回改）；partial 尾除
        //    「最后一条且无终止标点」的边界句外全部。归一化为空的纯标点句不晋升
        //    （零宽锚会原地空转）。
        for piece in committedFresh where !Self.normalizedChars(piece).isEmpty {
            newAnchors.append(piece)
        }
        for (index, piece) in partialFresh.enumerated() {
            if index == partialFresh.count - 1, !SentenceSplitter.endsWithTerminator(piece) { continue }
            if Self.normalizedChars(piece).isEmpty { continue }
            newAnchors.append(piece)
        }
        anchored = newAnchors

        return Output(
            committed: committedPieces + committedFresh,
            partial: partialPieces + partialFresh
        )
    }

    // MARK: - 重同步参数

    /// 锚前可容忍的插入内容字符数（重解码在句首幻听出「嗯/啊」一类填充）。
    private static let insertSlack = 6
    /// 一次重同步最多跳过的死锚条数（句内词级漂移导致整句内容变了）。
    private static let maxDeadAnchors = 2

    // MARK: - 归一化（与 SubtitlePacer.normalized 同语义；pacer 刚定稿不动它，这里自带一份）

    private static let ignoredCharacters = Set<Character>("。！？；…!?;.,、，：: 　")

    private static func isIgnored(_ ch: Character) -> Bool {
        ch.isWhitespace || ignoredCharacters.contains(ch)
    }

    private static func normalizedChars(_ text: String) -> [Character] {
        Array(text.filter { !isIgnored($0) })
    }

    /// 原文中每个「内容字符」及其原始位置，标点/空白（含换行）对匹配不可见。
    private static func contentMap(_ text: String) -> [(char: Character, index: String.Index)] {
        var result: [(char: Character, index: String.Index)] = []
        var i = text.startIndex
        while i < text.endIndex {
            if !isIgnored(text[i]) {
                result.append((text[i], i))
            }
            i = text.index(after: i)
        }
        return result
    }
}
