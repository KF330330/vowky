#!/usr/bin/env python3
"""Append structured AI-call entries to a log file.

Subcommands:
    reset    delete log + journal
    append   add an entry with prompt + response + metadata
    summary  append a summary block listing every step from the journal
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone

SEP = "=" * 64
SUB = "-" * 16


def read_file(path):
    if not path:
        return ""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return f"<read error: {e}>"


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def journal_path(log_path):
    return log_path + ".journal.jsonl"


def cmd_append(args):
    prompt_text = read_file(args.prompt_file) if args.prompt_file else args.prompt_text
    response_text = read_file(args.response_file) if args.response_file else args.response_text
    ts = now_iso()
    block = (
        f"{SEP}\n"
        f"[{ts}] step={args.step} duration={args.duration}s status={args.status}\n"
        f"{SUB} PROMPT {SUB}\n"
        f"{prompt_text}\n"
        f"{SUB} RESPONSE {SUB}\n"
        f"{response_text}\n"
        f"{SEP}\n\n"
    )
    os.makedirs(os.path.dirname(os.path.abspath(args.log_path)) or ".", exist_ok=True)
    with open(args.log_path, "a", encoding="utf-8") as f:
        f.write(block)
    with open(journal_path(args.log_path), "a", encoding="utf-8") as f:
        f.write(
            json.dumps(
                {
                    "step": args.step,
                    "status": args.status,
                    "duration": args.duration,
                    "ts": ts,
                },
                ensure_ascii=False,
            )
            + "\n"
        )
    print(f"logged step={args.step} status={args.status}")


def cmd_summary(args):
    entries = []
    jp = journal_path(args.log_path)
    if os.path.exists(jp):
        with open(jp, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    entries.append(json.loads(line))

    lines = [SEP, f"[{now_iso()}] SUMMARY"]
    total = 0.0
    ok = 0
    for e in entries:
        lines.append(
            f"  step={e['step']:<10} status={e['status']:<6} duration={e['duration']}s  ts={e['ts']}"
        )
        try:
            total += float(e["duration"])
        except (TypeError, ValueError):
            pass
        if e["status"] == "ok":
            ok += 1
    lines.append(f"  --- total entries={len(entries)} ok={ok} total_duration={total:.2f}s ---")
    lines.append(SEP)
    with open(args.log_path, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n\n")
    print(f"summary appended: {len(entries)} entries, total {total:.2f}s")


def cmd_reset(args):
    for p in [args.log_path, journal_path(args.log_path)]:
        if os.path.exists(p):
            os.remove(p)
    print(f"reset: {args.log_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log_path")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("append")
    a.add_argument("--step", required=True)
    a.add_argument("--prompt-file", default=None)
    a.add_argument("--response-file", default=None)
    a.add_argument("--prompt-text", default="")
    a.add_argument("--response-text", default="")
    a.add_argument("--status", default="ok")
    a.add_argument("--duration", default="0")
    a.set_defaults(func=cmd_append)

    s = sub.add_parser("summary")
    s.set_defaults(func=cmd_summary)

    r = sub.add_parser("reset")
    r.set_defaults(func=cmd_reset)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
