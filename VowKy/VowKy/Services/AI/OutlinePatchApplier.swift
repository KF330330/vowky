import Foundation

// MARK: - Public models

struct OutlineAnchor: Equatable {
    let before: String
    let occurrence: Int
}

enum OutlineOperationKind: String, Equatable {
    case heading
    case paragraphBreak
}

struct OutlineOperation: Equatable {
    let kind: OutlineOperationKind
    let level: Int?
    let text: String?
    let anchor: OutlineAnchor
}

struct OutlinePatch: Equatable {
    let version: Int
    let operations: [OutlineOperation]
}

struct OutlinePatchResult: Equatable {
    let markdown: String
    let warnings: [String]
    /// 实际成功落点的 operation 数量。
    let appliedCount: Int
}

// MARK: - Applier

enum OutlinePatchApplier {

    /// 把 AI 的 JSON 指令应用到 rawText 上，得到带 heading / 段落分隔的 Markdown。
    /// 任何错误都不抛出，统一以 warnings + 降级原文返回。
    static func apply(rawText: String, aiResponse: String) -> OutlinePatchResult {
        var warnings: [String] = []

        let stripped = stripMarkdownFence(aiResponse)
        guard let patch = decodePatch(stripped, warnings: &warnings) else {
            return OutlinePatchResult(
                markdown: rawText,
                warnings: warnings,
                appliedCount: 0
            )
        }
        guard !patch.operations.isEmpty else {
            return OutlinePatchResult(
                markdown: rawText,
                warnings: warnings,
                appliedCount: 0
            )
        }

        var pending: [PendingInsertion] = []
        var headingPositions: Set<String.Index> = []

        for (order, op) in patch.operations.enumerated() {
            guard let insertion = locate(op, in: rawText, order: order, warnings: &warnings) else {
                continue
            }
            if insertion.priority == .heading, headingPositions.contains(insertion.index) {
                warnings.append("同位置出现多个 heading，已保留第一个")
                continue
            }
            if insertion.priority == .heading {
                headingPositions.insert(insertion.index)
            }
            pending.append(insertion)
        }

        // 同位置时希望最终顺序是：paragraph_break 在前、heading 在后。
        // 因为我们从后往前 insert，所以"高优先级先插"反而会被后续插入挤到右边。
        // 因此：same index 时，heading（priority 较高）先插，paragraph_break 后插 → 最终 break 在前。
        let sorted = pending.sorted { lhs, rhs in
            if lhs.index != rhs.index { return lhs.index > rhs.index }
            return lhs.priority.rawValue > rhs.priority.rawValue
        }

        var result = rawText
        for insertion in sorted {
            result.insert(contentsOf: insertion.content, at: insertion.index)
        }

        result = collapseExcessNewlines(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return OutlinePatchResult(
            markdown: result,
            warnings: warnings,
            appliedCount: sorted.count
        )
    }

    // MARK: - Markdown fence strip

    /// 去掉 ```json ... ``` 或 ``` ... ``` 围栏。
    static func stripMarkdownFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        guard let firstNewline = trimmed.firstIndex(of: "\n") else {
            return trimmed
        }
        let afterHeader = trimmed[trimmed.index(after: firstNewline)...]

        if let closing = afterHeader.range(of: "```", options: .backwards) {
            return String(afterHeader[..<closing.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterHeader).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Decode (lossy)

    /// 用 JSONSerialization 逐条解析，单条失败丢弃 + warning，不阻塞其他 operation。
    private static func decodePatch(_ json: String, warnings: inout [String]) -> OutlinePatch? {
        guard !json.isEmpty else {
            warnings.append("AI 返回空")
            return nil
        }
        guard let data = json.data(using: .utf8) else {
            warnings.append("JSON 字节解码失败")
            return nil
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            warnings.append("JSON 解析失败：\(error.localizedDescription)")
            return nil
        }
        guard let root = raw as? [String: Any] else {
            warnings.append("JSON 顶层不是对象")
            return nil
        }

        let version = root["version"] as? Int ?? 1
        let opsRaw = root["operations"] as? [[String: Any]] ?? []
        var operations: [OutlineOperation] = []
        for opDict in opsRaw {
            if let op = parseOperation(opDict, warnings: &warnings) {
                operations.append(op)
            }
        }
        return OutlinePatch(version: version, operations: operations)
    }

    private static func parseOperation(
        _ dict: [String: Any],
        warnings: inout [String]
    ) -> OutlineOperation? {
        guard let kindRaw = dict["kind"] as? String else {
            warnings.append("operation 缺 kind，已丢弃")
            return nil
        }
        let kind: OutlineOperationKind
        switch kindRaw {
        case "heading":
            kind = .heading
        case "paragraph_break", "paragraphBreak":
            kind = .paragraphBreak
        default:
            warnings.append("未知 operation kind '\(kindRaw)'，已丢弃")
            return nil
        }

        guard let anchorDict = dict["anchor"] as? [String: Any],
              let before = anchorDict["before"] as? String else {
            warnings.append("operation 缺 anchor.before，已丢弃")
            return nil
        }
        let occurrence = max(1, (anchorDict["occurrence"] as? Int) ?? 1)
        let anchor = OutlineAnchor(before: before, occurrence: occurrence)

        let level = dict["level"] as? Int
        let text = dict["text"] as? String

        return OutlineOperation(kind: kind, level: level, text: text, anchor: anchor)
    }

    // MARK: - Locate

    private enum InsertionPriority: Int {
        case paragraphBreak = 0
        case heading        = 1
    }

    private struct PendingInsertion {
        let index: String.Index
        let priority: InsertionPriority
        let order: Int
        let content: String
    }

    private static func locate(
        _ op: OutlineOperation,
        in rawText: String,
        order: Int,
        warnings: inout [String]
    ) -> PendingInsertion? {
        let priority: InsertionPriority
        let content: String

        switch op.kind {
        case .heading:
            guard let levelRaw = op.level, (1...3).contains(levelRaw),
                  let rawTitle = op.text else {
                warnings.append("heading 缺 level / text，已丢弃")
                return nil
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                warnings.append("heading 标题为空，已丢弃")
                return nil
            }
            let hashes = String(repeating: "#", count: levelRaw)
            content = "\n\n\(hashes) \(title)\n\n"
            priority = .heading

        case .paragraphBreak:
            content = "\n\n"
            priority = .paragraphBreak
        }

        let index: String.Index
        if op.anchor.before.isEmpty {
            index = rawText.startIndex
        } else if let upper = rawText.nthOccurrenceUpperBound(
            of: op.anchor.before,
            occurrence: op.anchor.occurrence
        ) {
            index = upper
        } else {
            // occurrence 找不到，但 occurrence > 1 时尝试回退到第 1 次
            if op.anchor.occurrence > 1,
               let fallback = rawText.nthOccurrenceUpperBound(of: op.anchor.before, occurrence: 1) {
                warnings.append("anchor.before 第 \(op.anchor.occurrence) 次出现未找到，回退到第 1 次")
                index = fallback
            } else {
                let preview = op.anchor.before.prefix(40)
                warnings.append("anchor.before 未找到：\(preview)…")
                return nil
            }
        }

        return PendingInsertion(
            index: index,
            priority: priority,
            order: order,
            content: content
        )
    }

    // MARK: - Cleanup

    /// 把连续 3+ 个 \n 合并为 \n\n。
    static func collapseExcessNewlines(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var newlineRun = 0
        for ch in text {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun <= 2 { result.append(ch) }
            } else {
                newlineRun = 0
                result.append(ch)
            }
        }
        return result
    }
}

// MARK: - String helper

extension String {
    /// 查找 substring 的第 occurrence 次出现，返回该次匹配的 upperBound（不重叠搜索）。
    /// occurrence 从 1 开始；occurrence < 1 或 substring 空时返回 nil。
    func nthOccurrenceUpperBound(of substring: String, occurrence: Int) -> String.Index? {
        guard occurrence >= 1, !substring.isEmpty else { return nil }
        var searchStart = startIndex
        var lastUpper: String.Index?
        for _ in 1...occurrence {
            guard let range = range(
                of: substring,
                options: .literal,
                range: searchStart..<endIndex
            ) else {
                return nil
            }
            lastUpper = range.upperBound
            searchStart = range.upperBound
        }
        return lastUpper
    }
}
