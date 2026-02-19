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

## Deploy Commands

```bash
make preflight       # 部署前环境预检
make deploy-dev      # 构建 + 部署到 dev.vowky.com
make verify-dev      # 验证 dev 环境
make deploy-prod     # 构建 + 签名 + 公证 + 部署到 vowky.com
make verify-prod     # 验证生产环境
make bump-patch      # 版本号 patch +1
make bump-minor      # 版本号 minor +1
```

Deploy 私密配置在 `deploy/config.local.sh`（已 gitignore），模板见 `deploy/config.local.sh.example`。

## TODO

- [ ] **Prod 部署公证**：Apple timestamp 服务暂时不可用（2026-02-19），导致 `codesign --timestamp` 失败，prod 构建无法完成公证。Dev 部署已正常工作。等 Apple 服务恢复后运行 `make deploy-prod` 完成生产环境首次部署。
- [ ] **安装 Sparkle 工具**：`brew install sparkle`，安装后 `sign_update` 可自动从 Keychain 读取 EdDSA 私钥签名 DMG，使 Sparkle 自动更新的签名验证完整工作。

## Key Naming Convention

The product was renamed from **VoKey → VowKy**. All code, configs, and docs now use "VowKy" / "vowky". If you find any remaining "VoKey" references, they are stale and should be updated.
