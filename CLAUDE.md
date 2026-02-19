# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

This is a monorepo for **VowKy**, a macOS menu bar voice input tool.

- `VowKy/` — Native macOS app (Swift, XcodeGen). Has its own `CLAUDE.md` with detailed build commands, architecture, and gotchas. **Read `VowKy/CLAUDE.md` before working on the app.**
- `website/` — Landing page (`index.html`, single-file HTML/CSS/JS). Supports Chinese/English via i18n system.
- `PRD_VowKy_*.md` — Product requirement documents (V1.0, V1.1).

## Quick Commands

```bash
# === macOS App (run from VowKy/ directory) ===
cd VowKy
xcodegen generate                    # Regenerate Xcode project from project.yml
xcodebuild -project VowKy.xcodeproj -scheme VowKy -configuration Debug build
xcodebuild test -project VowKy.xcodeproj -scheme VowKy -configuration Debug
open ~/Library/Developer/Xcode/DerivedData/VowKy-*/Build/Products/Debug/VowKy.app

# === Website ===
open website/index.html              # Preview in browser
```

## What VowKy Does

Press Option+Space → speak → press again → text appears at cursor position in any app. Fully offline (Sherpa-ONNX), no clipboard, no internet, privacy-first.

## Key Naming Convention

The product was renamed from **VoKey → VowKy**. All code, configs, and docs now use "VowKy" / "vowky". If you find any remaining "VoKey" references, they are stale and should be updated.
