# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What VowKy Does

macOS menu bar voice input tool. Press hotkey (default Option+Space) → speak → press again → text appears at cursor position in any app. Fully offline (Sherpa-ONNX), no clipboard, no internet, privacy-first.

## Repository Structure

Monorepo with three main areas:

- **`VowKy/`** — Native macOS app (Swift, XcodeGen). Has its own `AGENTS.md` with detailed build commands, architecture, and gotchas. **Read `VowKy/AGENTS.md` before working on the app.**
- **`_local/`** — Gitignored local-only files, each subdirectory has independent git. Contains:
  - `_local/analytics/` — Self-hosted analytics backend (FastAPI + SQLite, deployed to `analytics.vowky.com`)
  - `_local/docs/` — PRDs, dev plans, code reviews
  - `_local/website/` — Landing page source (single-file HTML/CSS/JS with i18n)
- **`deploy/`** — Build, sign, notarize, deploy to vowky.com, and create GitHub Release

## Quick Commands

```bash
# === 开发构建（推荐，从 repo root 运行） ===
make run             # xcodegen + 构建 + 杀旧进程 + 启动（一条命令搞定）
make dev             # 只构建不启动

# === macOS App（从 VowKy/ 目录运行） ===
cd VowKy
xcodegen generate                    # Regenerate Xcode project from project.yml
xcodebuild -project VowKy.xcodeproj -scheme VowKy -configuration Debug build
xcodebuild test -project VowKy.xcodeproj -scheme VowKy -configuration Debug

# Run a single test class
xcodebuild test -project VowKy.xcodeproj -scheme VowKy -only-testing:VowKyTests/AppStateTests

# Run a single test method
xcodebuild test -project VowKy.xcodeproj -scheme VowKy -only-testing:VowKyTests/AppStateTests/test26_initialState_isIdle

# Launch built app
open ~/Library/Developer/Xcode/DerivedData/VowKy-*/Build/Products/Debug/VowKy.app

# === Deploy (from repo root) ===
make preflight       # 部署前环境预检
make deploy          # 构建 + 签名 + 公证 + 部署到 vowky.com + GitHub Release
make verify          # 验证部署结果
make bump-patch      # 版本号 patch +1
make bump-minor      # 版本号 minor +1
```

## 开发测试纪律（TCC 权限相关）

VowKy 依赖辅助功能权限（Accessibility）和麦克风权限，macOS TCC 按代码签名身份授权。开发时必须遵守以下纪律：

### 必须做的
- `project.yml` 中 `DEVELOPMENT_TEAM` 必须填 `"M7T6PJ8YJZ"`，不能为空（为空会退化为 ad-hoc 签名，TCC 永远不会授权）
- **启动 dev 版之前，先 `pkill -x VowKy` 关闭所有正在运行的 VowKy（包括正式版）**，避免同时运行多个实例导致快捷键冲突和混淆（`make run` 已内置此步骤）
- 用 `make run` 从 DerivedData 原地启动 Debug 版，首次需授权辅助功能+麦克风，后续不需要重新授权
- 遇到权限异常（如识别乱码/单字）时先执行 `tccutil reset Microphone com.vowky.app`，再重新授权

### 绝对不要做的
- **不要传 `CODE_SIGN_IDENTITY="-"`** — ad-hoc 签名无法获得 TCC 权限
- **不要替换 /Applications/VowKy.app** — 会搞乱 TCC 缓存，破坏正式版的权限状态
- **不要改 bundle ID 试图隔离测试版** — TCC 不看 bundle ID，改了只会引入新问题
- **不要随意 `tccutil reset Accessibility`** — 会清掉正式版和所有构建版本的辅助功能授权

### 为什么
2026-03-29 因 `DEVELOPMENT_TEAM` 为空导致 ad-hoc 签名，然后连续错误操作（改 bundle ID、替换正式版、多次 tccutil reset）浪费 1+ 小时，最终把正式版权限也搞坏了。根因就一行配置。

## Release Workflow

1. `make bump-patch` (or `bump-minor`) — updates `Info.plist` version + build number
2. Commit the version bump
3. `git push origin master`
4. `make deploy` — builds archive → signs (Developer ID) → notarizes → creates DMG → uploads website → uploads DMG to server + GitHub Releases → generates signed appcast.xml → creates GitHub Release

**Sparkle EdDSA signing**: `deploy.sh` uses `sign_update` to generate `sparkle:edSignature` for appcast.xml. The tool is at `~/Library/Developer/Xcode/DerivedData/VowKy-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`. If not found, deploy continues without signature (but auto-update verification will fail for users).

## Distribution

- **DMG downloads**: Hosted on GitHub Releases (primary). Server backup at `vowky.com/downloads/`
- **Sparkle appcast**: `vowky.com/appcast.xml` — enclosure URLs point to GitHub Releases. Auto-update checks every hour (`updateCheckInterval = 3600`).
- **Website download buttons**: Use permanent link `github.com/KF330330/vowky/releases/latest/download/VowKy.dmg`. `deploy.sh` uploads both versioned (`VowKy-{VERSION}.dmg`) and unversioned (`VowKy.dmg`) assets to each release, so **website links never need manual updates** when bumping version.

## Infrastructure

- **Server**: 阿里云 Hong Kong (8.210.146.28), nginx serves `/var/www/vowky/prod/site/`
- **Website**: `vowky.com` → static files from `_local/website/`
- **Analytics**: `analytics.vowky.com` → FastAPI app on port 8100, deployed via `_local/analytics/deploy.sh`. Dashboard credentials: admin / vowky-stats-2026
- **Deploy secrets**: `deploy/config.local.sh` (gitignored), template at `deploy/config.local.sh.example`
- **Server access**: See `_local/` or `1SERVER_INFO.md` (parent directory, gitignored)

## Website i18n

`_local/website/index.html` uses `data-i18n` attributes on HTML elements and a JS translation dictionary (zh/en). When editing website text, update both the HTML default text (Chinese) and both language entries in the JS `translations` object.

## Git LFS

`.onnx` model files and `.a` static libraries are tracked by Git LFS (see `.gitattributes`). Run `git lfs pull` after clone.

## Entitlements

Entitlements are defined in `VowKy/project.yml` under `entitlements.properties`. **XcodeGen regenerates `VowKy.entitlements` on every `xcodegen generate`**, so always edit `project.yml` — direct edits to the `.entitlements` file will be overwritten.

Current entitlements:
- `com.apple.security.cs.allow-unsigned-executable-memory` — required for ONNX runtime
- `com.apple.security.device.audio-input` — required for microphone access (without this, TCC silently denies and recognition outputs garbage)

## Key Naming Convention

Renamed **VoKey → VowKy**. All code, configs, and docs now use "VowKy" / "vowky". Any remaining "VoKey" references are stale.

## Note on AGENTS.md Files

Both `AGENTS.md` and `VowKy/AGENTS.md` are gitignored — they are local-only files, not committed to the repo.
