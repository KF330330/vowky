---
name: transcript-enhance
description: |
  Convert a transcript .txt into structured Markdown (frontmatter + headings +
  paragraphs) WITHOUT changing a single character of the original text.
  Trigger when:
  (1) user provides a .txt transcript path and asks to enhance / structure / 加标题 / 分段
  (2) user says "转录稿增强", "transcript enhance", "/transcript-enhance"
  (3) user has meeting / training / podcast text and wants a clean Markdown version
  Workflow: chunker splits sentences with ids → AI emits "insert X after sentence N"
  ops → Python applies ops on top of original text. AI never touches the body.
---

# transcript-enhance

Convert a `.txt` transcript into structured Markdown while preserving the
original text byte-for-byte. The AI only produces *structure operations*
(where to insert headings and paragraph breaks); a Python script applies them.

## Inputs

User provides:
- **Required**: path to input `.txt`
- **Optional**: path to output `.md` (default: same dir, basename + `.enhanced.md`)
- **Optional**: `audio_path` if linked to an audio file
- **Optional**: `duration_seconds` if known

## Hard constraints (RED LINES)

1. **Never modify the original text.** AI emits ops; a script applies them.
2. **First op must be H2 at after_id=0.** Body cannot start the document.
3. **Frontmatter is strictly limited** to: `title`, `summary`, `audio_path` (opt),
   `markdown_path`, `generated_at`, `duration_seconds` (opt). Nothing else.
4. **No external APIs.** Python stdlib only.

## Workflow

Throughout the steps:
- `SKILL_DIR` = the directory containing this `SKILL.md`
- `INPUT` = user-provided `.txt` path
- `OUTPUT` = resolved output path (default `${INPUT%.txt}.enhanced.md`)
- `WORK` = `/tmp/transcript-enhance-<sanitized-basename>`
- `LOG` = `<dir of OUTPUT>/.ai-log.txt`

### Step 0 — Setup

```bash
mkdir -p "$WORK"
python3 "$SKILL_DIR/scripts/ai_log.py" "$LOG" reset
```

### Step 1 — Chunk sentences

```bash
python3 "$SKILL_DIR/scripts/chunk.py" "$INPUT" "$WORK"
```

Outputs:
- `$WORK/sentences.txt` — `id: text` lines for AI consumption
- `$WORK/sentences.json` — sentences with byte offsets for `apply.py`

Chunker verifies byte-for-byte reconstruction internally; non-zero exit = abort.

### Step 2 — Outline (AI → ops.json)

1. Read `$SKILL_DIR/references/prompts/outline.md`.
2. Read `$WORK/sentences.txt`.
3. Reason carefully and produce a strict JSON object matching the schema in
   the prompt. Output it to `$WORK/ops.json`.
4. Pre-flight checks before continuing:
   - `operations[0].after_id == 0` and `type == "h2"`
   - all `after_id` values are in `[0, max_id]`
   - operations sorted by `after_id` ascending
5. Log:
   ```bash
   python3 "$SKILL_DIR/scripts/ai_log.py" "$LOG" append \
     --step outline \
     --prompt-file "$WORK/sentences.txt" \
     --response-file "$WORK/ops.json" \
     --status ok --duration <seconds>
   ```
   (Record actual wall-clock duration using `date +%s` before/after the
   reasoning step.)

### Step 3 — Build sample for title/summary

Create `$WORK/sample.txt` from `$INPUT`:
- If file ≤ 4500 chars: use full text
- Else: first 3000 chars + `\n\n...(中间略)...\n\n` + last 1500 chars

A short Python one-liner works:
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("$INPUT").read_text(encoding="utf-8")
out = p if len(p) <= 4500 else p[:3000] + "\n\n...(中间略)...\n\n" + p[-1500:]
pathlib.Path("$WORK/sample.txt").write_text(out, encoding="utf-8")
PY
```

### Step 4 — Title (AI → title.txt)

1. Read `$SKILL_DIR/references/prompts/title.md`.
2. Read `$WORK/sample.txt`.
3. Produce a single-line title (≤ 20 chars, plain text, no prefix). Write to
   `$WORK/title.txt`.
4. Log with `--step title`.

### Step 5 — Summary (AI → summary.txt)

1. Read `$SKILL_DIR/references/prompts/summary.md`.
2. Read `$WORK/sample.txt`.
3. Produce a single-line summary (3–6 sentences, 200–500 chars). Write to
   `$WORK/summary.txt`.
4. Log with `--step summary`.

### Step 6 — Validate ops/title/summary before assembling

```bash
python3 "$SKILL_DIR/scripts/apply.py" validate \
  --sentences "$WORK/sentences.json" \
  --ops "$WORK/ops.json" \
  --title "$WORK/title.txt" \
  --summary "$WORK/summary.txt"
```

This enforces (exit 3 with detailed errors on failure):
- title ≤ 20 chars
- summary length 200–500, single line, no `摘要：`/`概要：`/`Summary:` prefix
- first op = `{after_id:0, type:"h2"}`; ops sorted by after_id; no `h1`
- every heading text ≤ 20 chars, no edge punctuation
- 100 ≤ chars between any pair of adjacent headings ≤ 800
- **no run > 350 chars** without a `paragraph_break` (hard cap; aim for ≤ 300)
- **each H2 has ≤ 6 H3 children** (hard cap)
- **no long H2 (> 300 chars span) with 0 H3 children**

**On failure**: read the error lines, fix the offending file(s) in `$WORK/`,
re-run validate. Do NOT bypass with `--no-validate`. Common fixes:
- Heading > 20 chars → rewrite in `ops.json`
- Density < 100 → drop the redundant heading
- Density > 800 → add an intermediate h3 to split
- Run > 350 chars → add `paragraph_break` op at sub-topic transition
- H2 has > 6 H3 → promote bulkiest sub-cluster to its own H2 (if total H2 still ≤ 8),
  or merge thin H3s
- Long H2 with 0 H3 → add 1–5 H3 sub-headings at sub-topic transitions
- Title/summary out of range → rewrite `title.txt` or `summary.txt`

Re-run validate until exit 0.

### Step 7 — Assemble Markdown

```bash
python3 "$SKILL_DIR/scripts/apply.py" generate \
  --input "$INPUT" \
  --sentences "$WORK/sentences.json" \
  --ops "$WORK/ops.json" \
  --title "$WORK/title.txt" \
  --summary "$WORK/summary.txt" \
  --output "$OUTPUT"
```

Generate re-runs validate internally plus byte-for-byte verify. Add
`--audio-path <path>` or `--duration-seconds <N>` if applicable.

The output structure is:

```
---
title: ...
summary: ...
markdown_path: ...
generated_at: ...
---

## 目录

- [H2 title](#h2-anchor)
  - [H3 title](#h3-anchor)
- [H2 title](#h2-anchor)
  ...

## (first real H2)

(body)
```

The `## 目录` table of contents (H2 + H3, GitHub-style anchors) is generated
by `apply.py` directly from `ops.json` — **not by AI**. Pass `--no-toc` to
omit it.

### Step 8 — Log summary

```bash
python3 "$SKILL_DIR/scripts/ai_log.py" "$LOG" summary
```

## Verification checklist

Before reporting success:
- [ ] `head -1 "$OUTPUT"` shows `---`
- [ ] Frontmatter contains only: `title`, `summary`, `markdown_path`,
      `generated_at` (and optionally `audio_path`, `duration_seconds`)
- [ ] First body line after frontmatter starts with `## `
- [ ] `apply.py verify` returns 0
- [ ] `$LOG` contains entries for `outline`, `title`, `summary` plus a summary block

## Error handling

- **Chunker mismatch**: re-run; if persists, the input has unusual encoding —
  surface to user, do not silently mutate.
- **First-op violation**: regenerate `ops.json` with the constraint reminded.
- **Title > 20 chars**: shorten and rewrite `title.txt`.
- **Verify fail**: surface the diff to the user. Do NOT silently retry or
  "fix" by editing the output.

## Files

- `SKILL.md` — this file
- `scripts/chunk.py` — sentence splitter with byte-offset map
- `scripts/apply.py` — Markdown assembler with verify mode
- `scripts/ai_log.py` — structured log appender
- `references/prompts/outline.md` — AI prompt for ops generation
- `references/prompts/title.md` — AI prompt for title
- `references/prompts/summary.md` — AI prompt for summary
