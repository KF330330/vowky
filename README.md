<p align="center">
  <img src="website/icon.png" width="128" height="128" alt="VowKy icon">
</p>

<h1 align="center">VowKy</h1>

<p align="center">
  <b>macOS 菜单栏语音输入工具</b><br>
  按下快捷键，说话，文字直达光标。完全离线，隐私至上。
</p>

<p align="center">
  <a href="https://vowky.com">官网</a> ·
  <a href="https://vowky.com/downloads/VowKy-latest.dmg">下载</a> ·
  <a href="#功能特性">功能</a> ·
  <a href="#从源码构建">构建</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013.0%2B-green" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
  <img src="https://img.shields.io/badge/offline-100%25-brightgreen" alt="100% Offline">
  <img src="https://img.shields.io/badge/price-free-orange" alt="Free">
</p>

---

## 它做什么

> **Option + Space** → 说话 → 再按一次 → 文字出现在光标位置。

就这么简单。在任何应用的任何输入框中使用 —— 浏览器、编辑器、微信、备忘录，无处不在。

**所有语音识别在你的 Mac 上完成，不经过任何服务器。**

## 功能特性

- **完全离线** — 基于 [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx) Paraformer 模型，断网也能用
- **隐私至上** — 零网络请求，零数据上传，你的声音不离开这台电脑
- **全局输入** — 通过 CGEvent 键盘模拟直接输入文字，不占用剪贴板
- **即时响应** — 本地推理，毫秒级延迟
- **自动标点** — CT-Transformer 模型自动补全标点符号
- **极简设计** — 菜单栏常驻，不占 Dock，自定义快捷键，Escape 随时取消
- **历史记录** — SQLite 存储所有识别结果，随时回顾
- **自动更新** — 内置 [Sparkle](https://sparkle-project.org/) 自动更新

## 技术栈

| 组件 | 技术 |
|------|------|
| 语音识别 | Sherpa-ONNX Paraformer |
| 标点恢复 | Sherpa-ONNX CT-Transformer |
| 音频采集 | AVAudioEngine (16kHz mono Float32) |
| 文字输出 | CGEvent 键盘模拟 |
| 全局快捷键 | CGEvent Tap |
| 数据存储 | SQLite3 C API |
| 自动更新 | Sparkle 2 |
| UI | SwiftUI MenuBarExtra |
| 构建工具 | XcodeGen |

## 从源码构建

### 前置条件

- macOS 13.0 Ventura 或更高版本
- Xcode 16.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`

### 构建步骤

```bash
# 1. 克隆仓库
git clone https://github.com/KF330330/vowky.git
cd vowky/VowKy

# 2. 在 project.yml 中设置你的 Apple Developer Team ID
#    找到 DEVELOPMENT_TEAM: "" 并填入你的 Team ID

# 3. 生成 Xcode 项目
xcodegen generate

# 4. 构建
xcodebuild -project VowKy.xcodeproj -scheme VowKy -configuration Debug build

# 5. 运行
open ~/Library/Developer/Xcode/DerivedData/VowKy-*/Build/Products/Debug/VowKy.app
```

### 运行测试

```bash
cd VowKy
xcodegen generate
xcodebuild test -project VowKy.xcodeproj -scheme VowKy -configuration Debug
```

## 项目结构

```
vowky/
├── VowKy/                    # macOS 原生应用
│   ├── project.yml           # XcodeGen 项目配置
│   ├── VowKy/
│   │   ├── VowKyApp.swift    # 入口，依赖注入
│   │   ├── AppState.swift    # 状态机（idle → recording → recognizing → idle）
│   │   ├── Services/         # 业务服务（协议 + 实现）
│   │   ├── Views/            # SwiftUI 视图
│   │   ├── SherpaOnnx/       # Sherpa-ONNX 桥接
│   │   └── Resources/        # 模型文件、图标、音频
│   ├── VowKyTests/           # 单元测试 & 集成测试
│   └── Libraries/            # Sherpa-ONNX 原生库 (Git LFS)
├── website/                  # 官网 (单文件 HTML)
│   └── index.html
├── deploy/                   # 部署脚本
└── Makefile                  # 快捷命令
```

## 官网

官网源码在 [`website/index.html`](website/index.html)，是一个单文件 HTML/CSS/JS 页面，支持中英文切换。

在线访问：**[vowky.com](https://vowky.com)**

本地预览：

```bash
open website/index.html
```

## 交流

扫码加微信，一起聊聊 VowKy：

<p align="center">
  <img src="wechat-qr.jpg" width="200" alt="WeChat QR Code">
</p>

## 许可证

[MIT](LICENSE)

## 致谢

- [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx) — 离线语音识别引擎
- [Sparkle](https://github.com/sparkle-project/Sparkle) — macOS 自动更新框架
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — Xcode 项目生成器
