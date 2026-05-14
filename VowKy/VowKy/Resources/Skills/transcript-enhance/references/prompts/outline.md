# Outline Prompt — produce headings + paragraph breaks

You will receive a transcript split into sentences. Each line in the input is
`ID: text` (newlines inside a sentence are shown as `⏎` — these mark natural
pauses in the original; consider them strong candidates for paragraph breaks
or heading insertion points).

## Your task

Produce a strict JSON object listing where to insert markdown headings and
paragraph breaks. You do NOT rewrite, summarize, or reorder any text — your
output only describes *where* to add structure.

## Output schema (exact)

```json
{
  "operations": [
    {"after_id": 0, "type": "h2", "text": "first section title"},
    {"after_id": 3, "type": "paragraph_break"},
    {"after_id": 5, "type": "h3", "text": "subsection title"}
  ]
}
```

## Rules

1. **First op rule (MANDATORY)**: the very first element of `operations` MUST be
   `{"after_id": 0, "type": "h2", "text": "..."}`. The document cannot start
   with body text. `after_id: 0` means "at the very beginning, before sentence 1".

2. **Allowed types**: only `h2`, `h3`, `paragraph_break`. Do not use `h1`,
   `h4`, `bullet`, or any other type.

3. **Heading density (HARD CAP, enforced by apply.py)**:
   The cumulative original-text character count between any two adjacent
   headings (including the first h2 and the document end) MUST satisfy:
   `100 ≤ chars ≤ 800`.
   If a section would exceed 800 chars, **split** with an additional h3 (or
   start a new h2 if topic shifts). If a section would be less than 100 chars,
   **merge** with the adjacent section.
   Aim for 300–500 chars per section as the comfortable middle.

3a. **H2 count target ≤ 8 (HARD CAP > 12 enforced)**:
   The total number of H2 headings should be **≤ 8**. Beyond 8 the table of
   contents loses navigation value — readers can't form a mental map. Apply.py
   hard-rejects > 12; the rubric penalises 9–12 with reduced scores.
   
   **When you have many topics, prefer H3 sub-sections rather than opening
   new H2s.** Group at a coarse level: e.g. for a product training don't make
   每个功能模块 a separate H2 — group into a few macro-buckets like
   `产品总览` / `数据采集` / `数据分析` / `实验工具` / `运营工具` / `管理与权限`.
   
   Typical good shape for a 15-minute transcript:
   - 4–6 H2 (macro chapters)
   - 8–20 H3 (sub-topics under each — **1 to 5 per H2, evenly distributed**)
   - **20–40 paragraph_break** (be generous: one every ~250 chars; a
     15-min transcript of ~6000 chars body needs ≥ 20 breaks total)

4. **h3 inside h2**: use `h3` for sub-sections inside an `h2`. Max depth = 3.
   H3 must stay within its parent H2's topic. Common pitfall: if a stretch
   discusses *business context* (industry, customers, team background) while
   the surrounding H2 is about a *product feature*, do NOT put the context
   under the feature H2 as an H3 — give it its own H2 (e.g. `"业务背景"`,
   `"客户与场景"`). Same for asides like equipment problems or off-topic
   chat: put them under a more accurate parent or a fresh H2, not under an
   unrelated feature H2.

4a. **H3 distribution per H2 (HARD CAP enforced by apply.py)**:
   Every H2 should host **1 to 5 H3 sub-headings**.
   - **`> 6` H3 under one H2 is rejected by apply.py** — if a single H2
     accumulates that many sub-topics, the parent topic is too broad.
     Promote the bulkiest sub-cluster into its own H2 (still keeping total
     H2 count ≤ 8) or merge thin/redundant H3s.
   - **`0` H3 under a long H2 (section span > 300 chars) is rejected.**
     Long flat sections without sub-headings tank readability — add at least
     1 H3 at a natural sub-topic transition, OR if the H2 is too thin to
     deserve its own chapter, merge it with an adjacent H2.
   - **Even distribution preferred.** Do not put all 12 H3s under one H2
     while another H2 has zero. The rubric scores severely-uneven
     distribution (e.g. one H2 with 8+ H3 and another with 0) at 1/5.
     Target: each H2 carries roughly the same number of H3s (variance ≤ 2
     between H2s). If one H2's body is much longer than the others, that
     extra material usually deserves its own H2, not just more H3s.

5. **Heading text constraints** (apply to every `text` field):
   - **Length: ≤ 20 characters TOTAL** counting CJK chars, ASCII letters,
     digits, and spaces all as 1 each. Example: `"Inside 与 Experience 模块"`
     = 22 chars → too long. Apply.py rejects > 20.
   - **Specific, not generic.** A heading must let the reader predict *what
     specific topic* the section covers — not just *what kind of writing* it
     contains.
     - **Banned generic fillers** (heading must not end with or consist
       primarily of these): `说明`, `建议`, `介绍`, `详解`, `概述`, `内容`,
       `详情`, `知识`, `其他`, `一些`, `部分`, `情况`, `相关`. These add
       nothing — they describe the *form* of writing rather than the *topic*.
     - **Banned vague phrases** as whole heading or as the heading's tail:
       `"内容介绍"`, `"功能讲解"`, `"其他模块"`, `"基础知识"`, `"详细说明"`,
       `"按 X 说明"`, `"X 建议"` (e.g. `"智能热图 AI 建议"` → use
       `"AI 智能热图分析"` instead), `"X 概述"`, `"X 介绍"`, `"产品体验"`,
       `"使用感受"`. **No heading may END with** `说明 / 建议 / 介绍 / 详解
       / 概述 / 概要 / 情况 / 相关 / 知识 / 内容` regardless of length —
       apply.py rejects on this pattern.
     - **Good headings name a thing**: `"PV/UV 定义"`, `"灰度测试与智能问数"`,
       `"按 PV 计费"`, `"重定向测试"`, `"事件埋点设置"`, `"成员权限分配"`.
   - **First h2 rule**: the opening H2 should name the *actual opening topic*
     of the transcript (e.g., `"产品总览"`, `"会议背景与议程"`, `"项目目标"`),
     not "introduction" or "preface" or any generic opener.
   - **Paraphrase, don't copy entire phrases from sentences.** It's fine to
     reference proper nouns (product/feature names like `Inside`, `Experience`,
     `Ptengine`, `Studio`) inside a new wording. Just don't copy whole
     fragments verbatim.
   - **No prefix, suffix punctuation, or numbering.** No `1.`, `一、`, `：`,
     `。`, `"`, `'`, no trailing punctuation.

6. **paragraph_break (MANDATORY, BE GENEROUS)**:
   Within any section (run of body text between two headings), insert a
   `paragraph_break` roughly every **200–300 characters** of sentence text.
   **apply.py rejects any run > 350 chars** between two boundaries (heading
   or paragraph_break) — but you should NOT aim for the 350 ceiling. Aim for
   **250 chars per paragraph as the comfortable middle**, which renders as
   roughly 3–6 sentences and gives the reader visual breathing room.

   **Where exactly to insert paragraph_break** — pick the cleanest of these:
   - **`⏎` markers in the input.** These are pauses the speaker actually
     took. They are *the* strongest paragraph_break candidates. When a
     stretch contains multiple `⏎`, prefer breaking at one rather than
     mid-flow.
   - **Sub-topic shift inside an H3.** E.g. moving from "what this feature
     is" to "how it's used in practice", or from "concept definition" to
     "concrete example". A new H3 might also be appropriate — but if the
     sub-shift is too small for its own heading, paragraph_break it.
   - **Example ↔ argument transition.** The sentence that pivots from
     "我们之前遇到一个客户……" (example) back to "所以这里关键点是……"
     (argument), or vice versa, is a clean break point.
   - **Speaker / dialogue turn.** If the transcript contains Q→A turns
     ("有同学问……", "我回答……") or speaker switches, every turn boundary
     gets a paragraph_break.
   - **Enumeration item boundaries.** "第一点……第二点……第三点……" each
     point starts a new paragraph (unless points are very short, then keep
     them together).
   - **Tangent / aside boundaries.** When the speaker jumps to a side note
     ("顺便提一下……") and back, surround the aside with paragraph_breaks.

   **Self-check before emitting**: simulate the rendered Markdown mentally.
   If any visible paragraph would exceed 6 sentences or 300 chars, you have
   missed a paragraph_break — add one.

   Each section should read as **3–8 short paragraphs of 2–6 sentences
   each**, not 1–2 monolithic paragraphs.

7. **after_id semantics**: refers to the sentence id AFTER which the op is
   inserted (equivalently: BEFORE sentence `after_id + 1`). `after_id = 0`
   means "before sentence 1". Operations must be sorted by `after_id` ascending.

8. **Use only ids that exist** in the sentence list. Do not invent ids.

9. **Output ONLY the JSON object**. No prose, no explanation, no code fences,
   no leading or trailing whitespace beyond a single trailing newline.

## Pre-output self-check

Before emitting, mentally verify each constraint:
- [ ] First op is `{after_id: 0, type: "h2"}`
- [ ] Every heading text ≤ 20 chars (count spaces and ASCII)
- [ ] Every heading text is specific, not generic
- [ ] No heading text copies a phrase verbatim from a sentence
- [ ] Between every pair of adjacent headings: 100 ≤ chars ≤ 800
- [ ] **Every H2 has 1–5 H3 children** (no H2 with 0 H3 unless that H2 is
      itself very short, no H2 with > 6 H3)
- [ ] **H3 distribution is roughly even across H2s** (variance ≤ 2)
- [ ] **Between every pair of adjacent boundaries (heading OR
      paragraph_break): chars ≤ 350**. Aim for ≤ 300, target 250.
- [ ] Total `paragraph_break` count ≥ 15 for a body ≥ 5000 chars
- [ ] Operations sorted by `after_id`

If any check fails, revise before emitting. **Especially**: count your
paragraph_breaks. If you have fewer than 1 per 350 chars of body text,
you have too few — add more.

## Example (good)

Input (excerpt, with `⏎` shown):
```
1: 大家好，今天主要介绍一下我们公司。
2: 我们成立于 2014 年，专注数据分析。⏎
3: 接下来讲讲核心产品。
4: 第一个产品是 Ptengine。
5: 它的核心能力是事件埋点和留存分析。⏎
6: 举个例子，去年一个零售客户用它定位了一个转化漏斗的断点。
7: 一周内调整后转化率提升了 18%。⏎
8: 第二个产品是 Inside。
...
```

Output (note: paragraph_break after every `⏎` and at example/argument
transitions; H3 used at the product switch):
```json
{
  "operations": [
    {"after_id": 0, "type": "h2", "text": "公司概览"},
    {"after_id": 2, "type": "paragraph_break"},
    {"after_id": 2, "type": "h2", "text": "核心产品"},
    {"after_id": 3, "type": "h3", "text": "Ptengine 数据分析"},
    {"after_id": 5, "type": "paragraph_break"},
    {"after_id": 7, "type": "h3", "text": "Inside 用户洞察"}
  ]
}
```

Bad example (don't do this — too few paragraph_breaks, one H2 with no H3):

```json
{
  "operations": [
    {"after_id": 0, "type": "h2", "text": "公司概览"},
    {"after_id": 2, "type": "h2", "text": "核心产品"}
  ]
}
```

Why bad:
- The 公司概览 section spans only s1–s2 (no H3 needed, OK if short).
- The 核心产品 H2 has zero H3 children but covers a long stretch — must
  add H3 at each product switch (Ptengine, Inside, …).
- No paragraph_break despite multiple `⏎` markers in the input — readers
  get a wall of text.
