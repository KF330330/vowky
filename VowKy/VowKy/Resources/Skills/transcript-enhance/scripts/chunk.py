#!/usr/bin/env python3
"""Chunk a transcript .txt into sentences, preserving every byte.

Usage:
    chunk.py <input.txt> <outdir>

Outputs:
    <outdir>/sentences.txt   (id: text per line, newlines visualised as ⏎)
    <outdir>/sentences.json  ({"sentences": [{"id", "text", "start_byte", "end_byte"}, ...]})

Guarantees:
    ''.join(s['text'] for s in sentences) == original_text  (byte-for-byte)
"""
import argparse
import json
import os
import sys

HARD_DELIMS = set("。？！.?!\n")
SOFT_DELIMS = set("，,；;")
SOFT_THRESHOLD = 200  # split on soft delim only when current buffer ≥ this


def chunk(text):
    sentences = []
    buf = ""
    has_content = False
    start_byte = 0
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in HARD_DELIMS:
            buf += c
            i += 1
            while i < n and text[i] in HARD_DELIMS:
                buf += text[i]
                i += 1
            if has_content:
                end_byte = start_byte + len(buf.encode("utf-8"))
                sentences.append(
                    {"text": buf, "start_byte": start_byte, "end_byte": end_byte}
                )
                start_byte = end_byte
                buf = ""
                has_content = False
        elif c in SOFT_DELIMS and has_content and len(buf) >= SOFT_THRESHOLD:
            buf += c
            i += 1
            end_byte = start_byte + len(buf.encode("utf-8"))
            sentences.append(
                {"text": buf, "start_byte": start_byte, "end_byte": end_byte}
            )
            start_byte = end_byte
            buf = ""
            has_content = False
        else:
            buf += c
            if not c.isspace():
                has_content = True
            i += 1
    if buf:
        end_byte = start_byte + len(buf.encode("utf-8"))
        if sentences and not has_content:
            sentences[-1]["text"] += buf
            sentences[-1]["end_byte"] = end_byte
        else:
            sentences.append(
                {"text": buf, "start_byte": start_byte, "end_byte": end_byte}
            )
    return sentences


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("outdir")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    with open(args.input, "r", encoding="utf-8") as f:
        text = f.read()

    sents = chunk(text)
    for idx, s in enumerate(sents, start=1):
        s["id"] = idx

    recon = "".join(s["text"] for s in sents)
    if recon != text:
        sys.stderr.write("FATAL: chunker reconstruction != original\n")
        sys.exit(1)

    txt_path = os.path.join(args.outdir, "sentences.txt")
    with open(txt_path, "w", encoding="utf-8") as f:
        for s in sents:
            visible = s["text"].replace("\n", "⏎").rstrip()
            f.write(f"{s['id']}: {visible}\n")

    json_path = os.path.join(args.outdir, "sentences.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump({"sentences": sents}, f, ensure_ascii=False, indent=2)

    print(f"OK: {len(sents)} sentences, {len(text)} chars")
    print(f"  {txt_path}")
    print(f"  {json_path}")


if __name__ == "__main__":
    main()
