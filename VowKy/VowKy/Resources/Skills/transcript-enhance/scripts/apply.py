#!/usr/bin/env python3
"""Assemble final Markdown from chunked sentences + AI-generated ops + title + summary.

Subcommands:
    generate  build output.md
    verify    re-check that all sentences appear in output, in order

Generate auto-runs verify after writing.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone


def slugify(text):
    """GitHub-style heading anchor: lowercase, spaces→`-`, keep CJK + word chars."""
    s = text.lower().strip()
    s = re.sub(r"\s+", "-", s)
    s = re.sub(r"[^\w一-鿿\-]", "", s)
    s = re.sub(r"-+", "-", s)
    return s.strip("-")


def generate_toc(ops, title="目录"):
    """Build a markdown TOC (H2 + H3 only) from ops, with deduped anchors."""
    heading_ops = [op for op in ops if op.get("type") in ("h2", "h3")]
    if not heading_ops:
        return ""
    seen = {}
    lines = [f"## {title}", ""]
    for op in heading_ops:
        text = op.get("text", "").strip()
        if not text:
            continue
        base = slugify(text)
        if base in seen:
            seen[base] += 1
            anchor = f"{base}-{seen[base]}"
        else:
            seen[base] = 1
            anchor = base
        indent = "  " if op["type"] == "h3" else ""
        lines.append(f"{indent}- [{text}](#{anchor})")
    lines.append("")
    return "\n".join(lines)


def read_text(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def load_json(p):
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def yaml_scalar(s):
    s = s.strip()
    needs_quote = (
        not s
        or s.strip() != s
        or any(ch in s for ch in [":", "#", "\n", '"', "'", "{", "}", "[", "]", ",", "&", "*", "!", "|", ">", "%", "@", "`"])
        or s[0] in "-?:"
    )
    if needs_quote:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def make_frontmatter(title, summary, markdown_path, audio_path=None, duration=None):
    lines = ["---"]
    lines.append(f"title: {yaml_scalar(title)}")
    lines.append(f"summary: {yaml_scalar(summary)}")
    if audio_path:
        lines.append(f"audio_path: {yaml_scalar(audio_path)}")
    lines.append(f"markdown_path: {yaml_scalar(markdown_path)}")
    lines.append(f"generated_at: {yaml_scalar(now_iso())}")
    if duration is not None:
        lines.append(f"duration_seconds: {duration}")
    lines.append("---")
    return "\n".join(lines) + "\n"


def render_ops(ops):
    out = []
    for op in ops:
        t = op.get("type")
        if t == "h2":
            out.append(f"\n\n## {op['text'].strip()}\n\n")
        elif t == "h3":
            out.append(f"\n\n### {op['text'].strip()}\n\n")
        elif t == "h4":
            out.append(f"\n\n#### {op['text'].strip()}\n\n")
        elif t == "h1":
            out.append(f"\n\n# {op['text'].strip()}\n\n")
        elif t == "paragraph_break":
            out.append("\n\n")
        else:
            raise ValueError(f"Unknown op type: {t}")
    return out


HEADING_MAX_CHARS = 20
SUMMARY_MIN = 200
SUMMARY_MAX = 500
DENSITY_MIN = 100
DENSITY_MAX = 800
# Hard cap per paragraph (chars between two heading/paragraph_break boundaries).
# Set 350 (not 400) so reviewer-side estimate variance + CJK trailing newlines
# still leave a comfortable margin under the rubric's 400-char penalty line.
SECTION_MAX_NO_BREAK = 350
# Max H3 children allowed under one H2 (hard cap). Beyond this the section
# becomes unreadable as a flat list; upgrade the bulky sub-topic to its own H2.
MAX_H3_PER_H2 = 6
# Min H3 children to consider an H2 "well sub-structured". H2 with 0 H3 is
# allowed only if the H2 itself is short (≤300 chars between adjacent
# headings — i.e. a tight section that doesn't need sub-headings).
MIN_H3_PER_H2_IF_LONG = 1
LONG_H2_THRESHOLD = 300


def validate(sentences, ops, title, summary):
    errs = []
    t = title.strip()
    if len(t) > HEADING_MAX_CHARS:
        errs.append(f"title length {len(t)} > {HEADING_MAX_CHARS}: {t!r}")
    if not t:
        errs.append("title empty")

    s = summary.strip().replace("\r\n", "\n")
    if "\n" in s:
        errs.append("summary contains newline")
    sl = len(s)
    if sl < SUMMARY_MIN or sl > SUMMARY_MAX:
        errs.append(f"summary length {sl} not in [{SUMMARY_MIN}, {SUMMARY_MAX}]")
    bad_prefixes = ("摘要：", "概要：", "Summary:", "summary:", "摘要:", "概要:")
    if any(s.startswith(p) for p in bad_prefixes):
        errs.append(f"summary has forbidden prefix: {s[:8]!r}")

    if not ops:
        errs.append("ops list is empty")
        return errs
    first = ops[0]
    if first.get("after_id") != 0 or first.get("type") != "h2":
        errs.append(
            f"first op must be {{after_id:0,type:'h2'}}, got "
            f"{{after_id:{first.get('after_id')},type:{first.get('type')!r}}}"
        )

    h2_count = sum(1 for op in ops if op.get("type") == "h2")
    if h2_count > 12:
        errs.append(
            f"H2 count {h2_count} > 12 hard cap; structure too fragmented. "
            f"Group sub-topics under fewer H2s using H3 instead."
        )

    max_id = sentences[-1]["id"] if sentences else 0
    last_after = -1
    for op in ops:
        aid = op.get("after_id")
        t_ = op.get("type")
        if aid is None or aid < 0 or aid > max_id:
            errs.append(f"after_id out of range: {aid} (valid: 0..{max_id})")
        if aid is not None and aid < last_after:
            errs.append(f"ops not sorted by after_id: {aid} < {last_after}")
        if aid is not None:
            last_after = aid
        if t_ == "h1":
            errs.append(f"h1 not allowed (op at after_id={aid})")
        if t_ in ("h2", "h3", "h4"):
            text = op.get("text", "").strip()
            if len(text) > HEADING_MAX_CHARS:
                errs.append(f"heading length {len(text)} > {HEADING_MAX_CHARS} at after_id={aid}: {text!r}")
            if not text:
                errs.append(f"empty heading text at after_id={aid}")
            if text and (text[0] in '"\'：。、' or text[-1] in '"\'：。、'):
                errs.append(f"heading has forbidden edge punct at after_id={aid}: {text!r}")
            generic_suffixes = ("说明", "建议", "介绍", "详解", "概述", "概要",
                                "情况", "相关", "知识", "内容")
            for suf in generic_suffixes:
                if text.endswith(suf):
                    errs.append(
                        f"heading ends in generic filler {suf!r} at after_id={aid}: {text!r}; "
                        f"rewrite to name the specific topic"
                    )
                    break
            generic_whole = {"内容介绍", "功能讲解", "其他模块", "基础知识",
                             "详细说明", "产品体验", "使用感受", "整体概况",
                             "相关说明", "其他内容"}
            if text in generic_whole:
                errs.append(
                    f"heading is generic-fluff phrase at after_id={aid}: {text!r}; "
                    f"name the actual topic"
                )

    chars_by_id = {sent["id"]: len(sent["text"]) for sent in sentences}

    heading_ops = [op for op in ops if op.get("type") in ("h2", "h3")]
    heading_aids = [op["after_id"] for op in heading_ops]
    boundaries = heading_aids + [max_id]
    # Per-H2 section char totals (sum of all sentences from this H2 up to next H2)
    h2_chars = {}
    # Per-H2 H3 child counts (used for distribution validation)
    h3_per_h2 = {}
    current_h2_idx = None
    for i in range(len(heading_ops)):
        op = heading_ops[i]
        start = heading_aids[i] + 1
        end = boundaries[i + 1]
        section_chars = sum(chars_by_id.get(sid, 0) for sid in range(start, end + 1))
        if section_chars < DENSITY_MIN or section_chars > DENSITY_MAX:
            errs.append(
                f"heading density: section after heading@{heading_aids[i]} "
                f"({heading_ops[i].get('text','')!r}) covers s{start}..s{end} "
                f"= {section_chars} chars, not in [{DENSITY_MIN}, {DENSITY_MAX}]"
            )
        if op.get("type") == "h2":
            current_h2_idx = i
            h2_chars[i] = section_chars
            h3_per_h2[i] = 0
        elif op.get("type") == "h3" and current_h2_idx is not None:
            h3_per_h2[current_h2_idx] = h3_per_h2.get(current_h2_idx, 0) + 1
            # Roll the parent H2's char total to include this H3's body too,
            # because the H2's "real coverage" is everything until the next H2.
            h2_chars[current_h2_idx] = h2_chars.get(current_h2_idx, 0) + section_chars

    # H3-per-H2 distribution checks (Rubric 2.1)
    for h2_i, n_h3 in h3_per_h2.items():
        h2_text = heading_ops[h2_i].get("text", "")
        if n_h3 > MAX_H3_PER_H2:
            errs.append(
                f"H2 {h2_text!r} has {n_h3} H3 children > {MAX_H3_PER_H2} hard cap; "
                f"promote the bulkiest sub-topic(s) to its own H2 (total H2 ≤ 8 still applies), "
                f"or merge thin H3s."
            )
        # Long H2 with zero H3 — only flag if its total span is large enough to
        # warrant sub-structure. Very short H2 sections legitimately need no H3.
        if n_h3 < MIN_H3_PER_H2_IF_LONG and h2_chars.get(h2_i, 0) > LONG_H2_THRESHOLD:
            errs.append(
                f"H2 {h2_text!r} spans {h2_chars[h2_i]} chars but has 0 H3; "
                f"add 1-{MAX_H3_PER_H2} H3 sub-headings to break up the section "
                f"(or merge it with an adjacent thin H2)."
            )

    # H4 acts as a soft paragraph break for the long-run check (renders as ####
    # but does not appear in TOC and does not enter density/distribution rules).
    pb_aids = sorted(
        op["after_id"]
        for op in ops
        if op.get("type") in ("paragraph_break", "h4")
    )
    for i in range(len(heading_ops)):
        start = heading_aids[i] + 1
        end = boundaries[i + 1]
        breaks_in_section = [b for b in pb_aids if start - 1 <= b < end]
        run_start = start - 1
        run_chars = 0
        cuts = sorted([run_start] + breaks_in_section + [end])
        for j in range(len(cuts) - 1):
            a, b = cuts[j], cuts[j + 1]
            run_chars = sum(chars_by_id.get(sid, 0) for sid in range(a + 1, b + 1))
            if run_chars > SECTION_MAX_NO_BREAK:
                errs.append(
                    f"long run without paragraph_break: s{a+1}..s{b} = {run_chars} "
                    f"chars > {SECTION_MAX_NO_BREAK} (in section after heading@{heading_aids[i]})"
                )
    return errs


def apply_ops(sentences, ops):
    if not ops:
        raise ValueError("ops list is empty")
    first = ops[0]
    if first.get("after_id") != 0 or first.get("type") not in ("h2", "h1"):
        raise ValueError(
            "First operation must be a top-level heading at after_id=0 "
            f"(got after_id={first.get('after_id')}, type={first.get('type')})"
        )
    max_id = sentences[-1]["id"] if sentences else 0
    for op in ops:
        aid = op.get("after_id")
        if aid is None or aid < 0 or aid > max_id:
            raise ValueError(f"after_id out of range: {aid} (valid: 0..{max_id})")

    ops_by_after = {}
    for op in ops:
        ops_by_after.setdefault(op["after_id"], []).append(op)

    parts = []
    parts.extend(render_ops(ops_by_after.get(0, [])))
    for s in sentences:
        parts.append(s["text"])
        if s["id"] in ops_by_after:
            parts.extend(render_ops(ops_by_after[s["id"]]))
    return "".join(parts)


def cmd_generate(args):
    original = read_text(args.input)
    sents = load_json(args.sentences)["sentences"]
    recon = "".join(s["text"] for s in sents)
    if recon != original:
        sys.stderr.write("FATAL: sentences.json does not reconstruct input\n")
        sys.exit(2)

    ops_obj = load_json(args.ops)
    ops = ops_obj.get("operations", ops_obj if isinstance(ops_obj, list) else [])

    title = read_text(args.title).strip()
    summary_raw = read_text(args.summary)
    summary = summary_raw.strip().replace("\n", " ")

    if not args.no_validate:
        errs = validate(sents, ops, title, summary_raw.strip())
        if errs:
            sys.stderr.write("VALIDATION FAILED:\n")
            for e in errs:
                sys.stderr.write(f"  - {e}\n")
            sys.stderr.write(
                f"\nFix the offending field(s) and re-run. "
                f"To skip validation (NOT recommended), pass --no-validate.\n"
            )
            sys.exit(3)

    body = apply_ops(sents, ops)
    body = body.lstrip("\n")
    if not body.endswith("\n"):
        body += "\n"

    duration = float(args.duration_seconds) if args.duration_seconds else None
    fm = make_frontmatter(
        title,
        summary,
        markdown_path=os.path.abspath(args.output),
        audio_path=args.audio_path,
        duration=duration,
    )

    toc = "" if args.no_toc else generate_toc(ops)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)) or ".", exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        if toc:
            f.write(fm + "\n" + toc + "\n" + body)
        else:
            f.write(fm + "\n" + body)
    print(f"OK: wrote {args.output}" + (" (with TOC)" if toc else " (no TOC)"))

    rc = verify(args.input, args.sentences, args.output)
    if rc != 0:
        sys.exit(rc)


def verify(input_path, sentences_path, output_path):
    original = read_text(input_path)
    sents = load_json(sentences_path)["sentences"]
    recon = "".join(s["text"] for s in sents)
    if recon != original:
        sys.stderr.write("VERIFY FAIL: chunker recon != original\n")
        return 1

    body = read_text(output_path)
    if body.startswith("---\n"):
        end = body.find("\n---\n", 4)
        if end > 0:
            body = body[end + 5:]
    # Strip TOC if present: starts with `## 目录`, ends at next non-`目录` H2
    body_lines = body.split("\n")
    j = 0
    while j < len(body_lines) and not body_lines[j].strip():
        j += 1
    if j < len(body_lines) and body_lines[j].strip() == "## 目录":
        j += 1
        while j < len(body_lines):
            stripped = body_lines[j].strip()
            if stripped.startswith("## ") and stripped != "## 目录":
                break
            j += 1
        body = "\n".join(body_lines[j:])

    pos = 0
    for s in sents:
        t = s["text"]
        # Skip leading whitespace in `t` for the search, but track it.
        # We require the *visible* sentence to appear; whitespace inside is preserved.
        idx = body.find(t, pos)
        if idx < 0:
            # Try with stripped trailing newlines (sentence text may end with \n
            # which gets absorbed into inserted \n\n).
            stripped = t.rstrip("\n")
            if stripped and stripped != t:
                idx = body.find(stripped, pos)
                if idx >= 0:
                    pos = idx + len(stripped)
                    continue
            sys.stderr.write(
                f"VERIFY FAIL: sentence id={s['id']} not found in output after pos {pos}\n"
            )
            sys.stderr.write(f"  text: {t[:80]!r}...\n")
            return 1
        pos = idx + len(t)
    print(f"VERIFY OK: all {len(sents)} sentences found in order")
    return 0


def cmd_verify(args):
    sys.exit(verify(args.input, args.sentences, args.output))


def cmd_validate_only(args):
    sents = load_json(args.sentences)["sentences"]
    ops_obj = load_json(args.ops)
    ops = ops_obj.get("operations", ops_obj if isinstance(ops_obj, list) else [])
    title = read_text(args.title).strip()
    summary = read_text(args.summary).strip()
    errs = validate(sents, ops, title, summary)
    if errs:
        sys.stderr.write("VALIDATION FAILED:\n")
        for e in errs:
            sys.stderr.write(f"  - {e}\n")
        sys.exit(3)
    print(f"VALIDATE OK: {len(ops)} ops, title {len(title)} chars, summary {len(summary)} chars")
    sys.exit(0)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("generate")
    g.add_argument("--input", required=True)
    g.add_argument("--sentences", required=True)
    g.add_argument("--ops", required=True)
    g.add_argument("--title", required=True)
    g.add_argument("--summary", required=True)
    g.add_argument("--output", required=True)
    g.add_argument("--audio-path", default=None)
    g.add_argument("--duration-seconds", default=None)
    g.add_argument("--no-validate", action="store_true",
                   help="skip strict quality validation (NOT recommended)")
    g.add_argument("--no-toc", action="store_true",
                   help="skip TOC generation between frontmatter and body")
    g.set_defaults(func=cmd_generate)

    val = sub.add_parser("validate")
    val.add_argument("--sentences", required=True)
    val.add_argument("--ops", required=True)
    val.add_argument("--title", required=True)
    val.add_argument("--summary", required=True)
    val.set_defaults(func=cmd_validate_only)

    v = sub.add_parser("verify")
    v.add_argument("--input", required=True)
    v.add_argument("--sentences", required=True)
    v.add_argument("--output", required=True)
    v.set_defaults(func=cmd_verify)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
