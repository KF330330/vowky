# Title Prompt — produce a one-line document title

You will receive a transcript sample (front + tail of the original text).

## Your task

Produce **one single-line title** that captures the core topic of the document.

## Rules

- **Length: ≤ 20 characters TOTAL**, counting CJK chars, ASCII letters, digits,
  and spaces all as 1 each. Example: `"Ptengine 产品全模块培训"` = 14 chars OK.
  `"Ptengine 全功能产品培训说明"` = 17 chars OK. Apply.py rejects > 20.
- Plain text only. No quotes, no markdown, no leading prefix like `Title:` or
  `1.`. No trailing punctuation.
- **Specific, not generic.** Bad: `"演讲笔记"`, `"会议记录"`, `"内容分享"`,
  `"功能讲解"`. Good headings name the actual subject: a product, a topic,
  a process, an event.
- One line, no line breaks, no trailing newline beyond a single final `\n`.

## Output

Just the title text. Nothing else.
