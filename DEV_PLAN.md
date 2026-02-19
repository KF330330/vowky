# VowKy 开发方案

## 项目概述

基于 PRD V1.0，开发 macOS 系统级输入法 + 管理 App。单体架构，一个 Xcode 工程。

---

## 工程结构

```
VowKy/
├── VowKy.xcodeproj
├── VowKyApp/                    # 主 App（管理面板）
│   ├── App/
│   │   └── VowKyApp.swift       # App 入口
│   ├── Views/
│   │   ├── MainWindow.swift     # 主窗口（侧边栏导航）
│   │   ├── InputHistoryView.swift    # 输入历史页
│   │   ├── ClipboardHistoryView.swift # 剪贴板历史页
│   │   ├── SettingsView.swift        # 设置页
│   │   └── Components/
│   │       ├── SearchBar.swift
│   │       └── HistoryRow.swift
│   ├── Services/
│   │   ├── ClipboardMonitor.swift    # 剪贴板监听
│   │   ├── HotkeyManager.swift       # 全局快捷键
│   │   └── AudioRecorder.swift       # 录音
│   └── Resources/
│       └── Assets.xcassets
│
├── VowKyInputMethod/            # 输入法插件（Input Method bundle）
│   ├── Info.plist               # 输入法配置（IMKit 注册）
│   ├── VowKyInputController.swift   # IMKInputController 子类，核心
│   ├── CandidateWindow.swift        # 候选栏窗口
│   └── LanguageEngine/
│       ├── ChineseEngine.swift      # 拼音引擎
│       ├── EnglishEngine.swift      # 英文引擎
│       ├── JapaneseEngine.swift     # 日文引擎
│       └── LanguageRouter.swift     # 语言切换路由
│
├── Shared/                      # 主 App 和输入法共享代码
│   ├── Database/
│   │   ├── DatabaseManager.swift    # SQLite 管理（WAL 模式）
│   │   ├── InputHistoryStore.swift  # 输入历史 CRUD
│   │   └── ClipboardStore.swift     # 剪贴板历史 CRUD
│   ├── Speech/
│   │   ├── SpeechRecognizer.swift   # 语音识别统一接口
│   │   ├── WhisperAPIClient.swift   # 在线识别（Whisper API）
│   │   ├── WhisperLocal.swift       # 本地识别（whisper.cpp）
│   │   └── SpeechFallback.swift     # 在线→本地回退逻辑
│   ├── Models/
│   │   ├── InputRecord.swift
│   │   ├── ClipboardRecord.swift
│   │   └── VoiceRecord.swift
│   └── Utils/
│       ├── Deduplicator.swift       # 去重算法
│       ├── MergeEngine.swift        # 合并算法（<5秒合并）
│       └── Constants.swift
│
├── Libraries/                   # 第三方库
│   └── whisper.cpp/             # Git submodule
│
└── Tests/
    ├── DatabaseTests/
    ├── SpeechTests/
    └── DeduplicatorTests/
```

---

## 开发阶段（共4个里程碑）

### M1：基础骨架 + 语音转文字

**目标**：独立 App 内可以按快捷键语音输入，验证核心体验

**任务**：
1. 创建 Xcode 工程，配置主 App target + Input Method target
2. 集成 whisper.cpp（Git submodule，Swift bridge）
3. 实现 `WhisperAPIClient`（在线识别）+ `WhisperLocal`（本地识别）+ 回退逻辑
4. 实现 `AudioRecorder`（AVAudioEngine 录音）
5. 实现 `HotkeyManager`（Option+Space 全局快捷键，用 CGEvent tap）
6. 语音浮窗 UI（SwiftUI，录音波形 + 识别结果）
7. SQLite 数据库初始化 + `VoiceRecord` 存储

**交付物**：按住 Option+Space 说话，松开后文字显示在浮窗中，可复制

---

### M2：输入法引擎（中英日）

**目标**：系统输入法可用，支持三语切换

**任务**：
1. 配置 Input Method bundle（Info.plist，IMKit 注册）
2. 实现 `VowKyInputController`（继承 `IMKInputController`）
3. 实现 `ChineseEngine`：拼音→汉字候选（基于开源词库，如 librime 或自建拼音表）
4. 实现 `EnglishEngine`：直接输入 + 拼写建议
5. 实现 `JapaneseEngine`：罗马字→假名→汉字（基于开源词库）
6. 实现 `LanguageRouter`：Ctrl+Space 切换，候选栏显示语言标识
7. 实现 `CandidateWindow`：候选栏 UI，跟随光标

**交付物**：在系统偏好设置中添加 VowKy 输入法，可在任意 App 中打字

---

### M3：输入历史 + 剪贴板历史

**目标**：所有输入可记录、可搜索、可回溯

**任务**：
1. 输入法 hook：在 `VowKyInputController` 的 commitComposition 中写入 `InputHistoryStore`
2. 语音输入完成时写入 `InputHistoryStore`
3. 实现 `Deduplicator`（10秒去重）+ `MergeEngine`（<5秒合并）
4. 实现 `ClipboardMonitor`（NSPasteboard 轮询，0.5秒间隔）
5. 管理面板 UI：
   - `InputHistoryView`：时间线列表 + 搜索 + 筛选（语言/来源/App）
   - `ClipboardHistoryView`：列表 + 搜索 + 固定置顶
6. Cmd+Shift+H / Cmd+Shift+V 快捷键唤起
7. 密码框检测（SecureTextField）：不记录

**交付物**：完整的输入记录 + 剪贴板历史功能

---

### M4：打磨 + 分发

**目标**：可分发给其他用户使用

**任务**：
1. 首次使用引导流程（权限申请：辅助功能、麦克风、输入法激活）
2. 设置页面（语音模式切换、Whisper API Key 配置、排除 App 列表、存储上限）
3. SQLCipher 加密集成
4. App 图标 + 菜单栏图标
5. Apple Developer 签名 + 公证（notarization）
6. DMG 打包（独立分发）+ App Store 提交准备
7. 埋点数据收集（本地统计，可选上报）
8. 基础自动化测试

**交付物**：可分发的 VowKy V1.0

---

## 关键技术决策

| 决策点 | 方案 | 原因 |
|--------|------|------|
| 拼音引擎 | librime（开源）或自建轻量拼音表 | librime 成熟但体积大，自建轻量但工作量大，M2 阶段决定 |
| 日文引擎 | 基于 mozc 词库或 macOS 自带 NSSpellChecker | 需 M2 阶段评估可行性 |
| 进程间数据共享 | SQLite WAL 模式 + App Group | 输入法进程和主 App 进程共享同一数据库 |
| whisper.cpp 集成 | Swift C++ Interop 或 Objective-C bridge | Swift 5.9+ 支持直接调用 C++，优先使用 |

---

## 验证方式

- **M1**：在 App 内按 Option+Space 说中英日三语，验证识别准确率
- **M2**：在系统设置中激活 VowKy，在 TextEdit/Safari 等 App 中打字验证三语输入
- **M3**：打字后在管理面板中搜索历史记录，验证记录完整性和去重/合并逻辑
- **M4**：在另一台 Mac 上安装 DMG，完成全流程验证
