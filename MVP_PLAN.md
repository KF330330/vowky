# VowKy MVP 实现方案 - 语音转文字 macOS 菜单栏应用

> 创建时间：2026-02-06
> 文档版本：V1.1（验证方案 V4.1）

## Context

VowKy 是一款 macOS 智能输入法产品，完整产品包含中英日三语键盘输入、语音转文字、输入历史记录和剪贴板管理。本方案聚焦 **最小可行产品 (MVP)**，核心功能为 **语音转文字输入**。

用户按住快捷键说话，松开后识别结果自动粘贴到光标位置。完全本地运行，无需网络。

---

## 一、语音识别方案调研结论

### 1.1 方案对比总表

#### 第一梯队：中文准确率最高

| 方案 | 中文 CER (AISHELL-1) | 延迟 | 价格 | 流式 | 部署方式 |
|------|:---:|------|------|:---:|------|
| **FunASR Paraformer-large** | **1.95%** | RTF 0.0076 | 免费 | 有流式版 | 本地 |
| **FunASR SenseVoice-Small** | 2.96% | 70ms/10s音频 | 免费 | 否(批处理) | 本地 |
| **阿里 Qwen3-ASR-Flash** | 3.97% | 实时流式 | 1.19 元/时 | 是 | 云端API |

#### 第二梯队：海外 API

| 方案 | 中文准确率 | 延迟 | 价格 | 流式 |
|------|------|------|------|:---:|
| **Groq Whisper-v3** | ~5% CER | **30-60ms/10s** (最快) | **$0.03/时** (最便宜) | 否 |
| **OpenAI gpt-4o-mini-transcribe** | 比Whisper低35% WER | ~500ms-1s | $0.18/时 | 是 |
| **Deepgram Nova-3** | 5-10% WER | <300ms流式 | $4.6/时 | 是 |

#### 第三梯队：国内云 API

| 方案 | 价格 | 特点 |
|------|------|------|
| **讯飞** | ~2.5-5 元/时 | 方言最全(23种)，国内金标准 |
| **百度** | 0.2-3 元/时 | 促销价便宜 |
| **腾讯云** | 1.5-3.2 元/时 | 微信级稳定 |
| **火山引擎** | 1.2-3.5 元/时 | 抖音音频优化 |

### 1.2 FunASR vs Whisper 中文对比

| 数据集 | Whisper-Large-V3 | FunASR Paraformer-large | FunASR SenseVoice-Small |
|--------|:---:|:---:|:---:|
| AISHELL-1 | 5.14% | **1.95%** | 2.96% |
| AISHELL-2 | 4.96% | **2.85%** | 3.80% |
| WenetSpeech (会议) | 18.87% | **6.97%** | 7.44% |
| 真实噪音环境 (平均) | 19.19% | -- | **7.60%** |

**结论：FunASR 对中文错误率比 Whisper 低 2.5 倍，噪音环境差距更大。**

### 1.3 FunASR 模型选择

| 模型 | 参数量 | AISHELL-1 CER | 流式 | 速度 | 推荐场景 |
|------|------|:---:|:---:|------|------|
| **Paraformer-large** | 220M | **1.95%** | 否 | 快 | 离线转写最准 |
| **Paraformer-zh-streaming** | ~220M | ~3-4% | **是** | 实时 | 实时听写 |
| **SenseVoice-Small** | 234M | 2.96% | 否 | **超快**(70ms/10s) | 快速离线多语言 |
| **Fun-ASR-Nano** | 800M | 1.22%(WER) | 是 | 实时 | 新一代流式 |

### 1.4 最终选择

**MVP 方案：sherpa-onnx + FunASR Paraformer-zh（本地离线）**

理由：
- 中文准确率最高（1.95% CER）
- 完全免费开源（MIT License）
- 本地运行，无需网络，隐私安全
- 模型仅 220M，比 Whisper-Large 的 1.5GB 小
- sherpa-onnx 提供原生 Swift API，可直接集成到 macOS 应用
- Apple Silicon 原生支持

---

## 二、MVP 功能定义

### 用户选择
- **语音引擎**：FunASR 本地优先（sherpa-onnx + Paraformer）
- **输出方式**：自动粘贴到光标位置
- **App 形态**：菜单栏 App（不占 Dock）

### 核心交互流程
1. App 常驻菜单栏，显示麦克风图标
2. 用户按住 `Option+Space` → 开始录音，屏幕出现录音浮窗
3. 用户说话（中文），浮窗显示音量波形
4. 用户松开 `Option+Space` → 停止录音，开始识别
5. 识别完成 → 文字自动粘贴到当前光标位置
6. 浮窗短暂显示结果后消失

### 不做的功能（MVP 范围外）
- 三语键盘输入（M2 阶段）
- 输入历史记录（M3 阶段）
- 剪贴板管理（M3 阶段）
- 流式实时识别（后续优化）
- 云端 API 备用（后续添加）
- 设置自定义快捷键（后续添加）

---

## 三、技术架构

### 3.1 技术栈

| 组件 | 技术方案 | 说明 |
|------|----------|------|
| 开发语言 | Swift | macOS 原生开发 |
| UI 框架 | SwiftUI + AppKit | 菜单栏用 MenuBarExtra，浮窗用 NSPanel |
| 语音识别 | sherpa-onnx + Paraformer-zh ONNX | 本地离线识别 |
| 音频采集 | AVAudioEngine | 系统麦克风录音 |
| 全局快捷键 | CGEvent tap | 系统级按键监听 |
| 文字输出 | NSPasteboard + CGEvent | 模拟 Cmd+V 粘贴 |

### 3.2 项目结构

```
VowKy/
├── VowKy.xcodeproj
├── VowKy/
│   ├── VowKyApp.swift                # @main App 入口，MenuBarExtra
│   ├── AppDelegate.swift             # NSApplicationDelegate，权限检查
│   ├── AppState.swift                # 全局状态管理 (ObservableObject)
│   ├── Info.plist                    # LSUIElement=YES, 麦克风权限描述
│   ├── VowKy.entitlements
│   ├── Views/
│   │   ├── MenuBarView.swift         # 菜单栏下拉菜单内容
│   │   ├── RecordingPanel.swift      # 录音浮窗 (NSPanel + SwiftUI)
│   │   └── SettingsView.swift        # 基础设置页面
│   ├── Services/
│   │   ├── HotkeyManager.swift       # 全局快捷键 (CGEvent tap)
│   │   ├── AudioRecorder.swift       # 录音服务 (AVAudioEngine)
│   │   ├── SpeechRecognizer.swift    # 语音识别协议 + 本地实现 (sherpa-onnx)
│   │   ├── TextOutputService.swift   # 文字输出 (剪贴板+模拟粘贴)
│   │   └── APIClient.swift           # 预留：云端 API 客户端
│   ├── SherpaOnnx/
│   │   ├── SherpaOnnx.swift          # sherpa-onnx Swift API (从仓库复制)
│   │   └── SherpaOnnx-Bridging-Header.h
│   └── Resources/
│       └── Models/
│           ├── model.int8.onnx       # Paraformer 模型文件 (~217MB)
│           └── tokens.txt            # 词表文件
└── Libraries/
    ├── sherpa-onnx.xcframework       # 编译好的静态库
    └── libonnxruntime.dylib          # ONNX Runtime 动态库
```

### 3.3 数据流

```
Option+Space 按下
    → HotkeyManager.onHotkeyDown
    → AppState.startRecording()
    → AudioRecorder.startRecording() (AVAudioEngine → 16kHz mono Float32)
    → RecordingPanel 显示

Option+Space 松开
    → HotkeyManager.onHotkeyUp
    → AppState.stopRecordingAndRecognize()
    → AudioRecorder.stopRecording() → [Float] 音频数据
    → SpeechRecognizer.recognize(samples) (后台线程，sherpa-onnx Paraformer)
    → 识别结果文字
    → TextOutputService.outputText(text) (写入剪贴板 → 模拟 Cmd+V)
    → RecordingPanel 短暂显示结果后隐藏
```

---

## 四、实现步骤

### Phase 0：环境准备

> **执行前验证**：以下命令和链接基于 2024-03 版本，执行前请先确认：
> - sherpa-onnx 仓库最新 release 版本和构建脚本名称
> - Paraformer 模型最新版本下载地址
> - 检查方式：`gh release list -R k2-fsa/sherpa-onnx --limit 5`

#### 0.1 编译 sherpa-onnx macOS 静态库

```bash
mkdir -p ~/open-source && cd ~/open-source
git clone https://github.com/k2-fsa/sherpa-onnx
cd sherpa-onnx
./build-swift-macos.sh
```

产出：
- `build-swift-macos/sherpa-onnx.xcframework`
- `build-swift-macos/install/lib/libonnxruntime.dylib`

#### 0.2 下载 Paraformer 中文模型

```bash
cd ~/open-source
wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-paraformer-zh-2024-03-09.tar.bz2
tar xvf sherpa-onnx-paraformer-zh-2024-03-09.tar.bz2
```

需要的文件：`model.int8.onnx`（~217MB）、`tokens.txt`

#### 0.3 复制 Swift API 文件

从 sherpa-onnx 仓库复制：
- `swift-api-examples/SherpaOnnx.swift`
- `swift-api-examples/SherpaOnnx-Bridging-Header.h`

### Phase 1：Xcode 项目搭建

#### 1.1 创建项目
- macOS > App，Product name: VowKy，Interface: SwiftUI，Language: Swift
- 保存到项目 `VowKy/` 目录

#### 1.2 配置为菜单栏 App
- Info.plist 添加 `LSUIElement = YES`

#### 1.3 集成 sherpa-onnx
- 拖入 `sherpa-onnx.xcframework`（静态库，Do Not Embed）
- 拖入 `libonnxruntime.dylib`（Embed & Sign）
- 设置 Bridging Header 路径
- Other Linker Flags 添加 `-lc++`
- 添加 `SherpaOnnx.swift` 和 Bridging Header 到项目

#### 1.4 打包模型文件
- 创建 `Resources/Models` 组
- 添加 `model.int8.onnx` 和 `tokens.txt` 到 Copy Bundle Resources

#### 1.5 权限配置
- Info.plist: `NSMicrophoneUsageDescription` = "VowKy 需要麦克风权限用于语音输入"
- Entitlements: `com.apple.security.device.audio-input = YES`
- 开发阶段**关闭 App Sandbox**（CGEvent tap 需要辅助功能权限，与沙箱冲突）

### Phase 2：核心服务实现（自底向上）

#### 2.1 SpeechRecognizer.swift - 语音识别服务

**架构设计（预留云端扩展）**：

```swift
protocol SpeechRecognizerProtocol {
    func recognize(samples: [Float], sampleRate: Int) async -> String?
    var isReady: Bool { get }
}

class LocalSpeechRecognizer: SpeechRecognizerProtocol { ... }   // MVP: sherpa-onnx 本地
class CloudSpeechRecognizer: SpeechRecognizerProtocol { ... }   // 未来: 云端 API
```

核心逻辑：
- 初始化时加载 Paraformer ONNX 模型（耗时 1-3 秒）
- 接收 16kHz mono Float32 音频数据
- 调用 sherpa-onnx 离线识别，返回文字结果
- 识别在后台线程运行
- 模型路径从配置读取（不硬编码，为未来模型下载预留）

关键配置：
- `modelConfig.paraformer.model` → `model.int8.onnx` 路径
- `modelConfig.tokens` → `tokens.txt` 路径
- `modelConfig.numThreads = 2`（Apple Silicon 推荐）
- `featConfig.sampleRate = 16000`

**注意事项**：C 字符串指针生命周期问题，Swift String 必须作为实例属性保持存活。

#### 2.2 AudioRecorder.swift - 录音服务

核心逻辑：
- 使用 AVAudioEngine 捕获麦克风输入
- 系统默认 48kHz 立体声 → 需转换为 16kHz 单声道 Float32
- 使用 AVAudioConverter 做格式转换
- 录音过程中累积样本到缓冲区
- 提供实时音量 Level 用于 UI 显示
- 最大录音时长 60 秒

**注意事项**：
- 音频回调在音频线程执行，UI 更新需回主线程
- 音频格式不匹配会导致识别结果为乱码或崩溃

#### 2.3 HotkeyManager.swift - 全局快捷键

核心逻辑：
- CGEvent.tapCreate 创建系统级事件监听
- 监听 keyDown/keyUp 事件
- 检测 Option+Space（keyCode=49 + maskAlternate）
- 区分首次按下和按键重复（检查 keyboardEventAutorepeat）
- 按下时触发 onHotkeyDown，松开时触发 onHotkeyUp
- 返回 nil 吞掉事件，防止 Space 被输入到目标应用

**注意事项**：
- 回调是 C 函数指针，通过 Unmanaged 传递 self
- 需处理 tapDisabledByTimeout，重新启用 tap
- 需要辅助功能权限（Accessibility），首次运行需引导用户开启
- 权限检查：`AXIsProcessTrustedWithOptions`

#### 2.4 TextOutputService.swift - 文字输出

核心逻辑：
1. 保存当前剪贴板内容
2. 将识别文字写入剪贴板
3. 模拟 Cmd+V 按键（CGEvent）
4. 延迟 100ms 后恢复原剪贴板内容

**注意事项**：
- 使用 `.cgAnnotatedSessionEventTap` 发送事件
- 恢复剪贴板前检查 changeCount，避免覆盖用户新复制的内容
- NSPanel 必须使用 nonactivatingPanel，否则焦点会被抢走导致粘贴到错误的应用

### Phase 3：UI 实现

#### 3.1 VowKyApp.swift - App 入口
- 使用 `MenuBarExtra`（macOS 13+）创建菜单栏图标
- 图标根据状态切换（待机=mic / 录音中=mic.fill 红色）
- 集成 Settings scene

#### 3.2 AppState.swift - 全局状态
- 组合所有 Service，协调录音→识别→输出流程
- 管理 UI 状态：isRecording / isRecognizing / lastRecognizedText
- setup() 中初始化所有服务并绑定回调
- 通过 SpeechRecognizerProtocol 协议引用识别引擎（方便未来切换）

#### 3.3 MenuBarView.swift - 菜单栏下拉菜单
- 显示当前状态（就绪 / 录音中 / 识别中）
- 显示上次识别结果
- Settings / Quit 按钮

#### 3.4 RecordingPanel.swift - 录音浮窗
- NSPanel + nonactivatingPanel 样式（不抢焦点）
- .floating 层级，始终在最上层
- 屏幕上方居中显示
- 录音中：脉动麦克风图标 + 音量条
- 识别中：旋转指示器
- 毛玻璃背景，圆角矩形

#### 3.5 SettingsView.swift - 设置页面
- MVP 阶段仅显示信息：当前快捷键、模型名称
- 权限状态显示和引导按钮
- 开机自启开关

### Phase 4：集成与串联

将所有组件在 AppState.setup() 中串联：
1. App 启动 → 加载模型 → 启动快捷键监听
2. 首次启动检查权限（辅助功能、麦克风）
3. 绑定快捷键回调 → 录音 → 识别 → 输出 完整流程

### Phase 5：测试验证

详见 [MVP_VERIFICATION.md](./MVP_VERIFICATION.md)，包含 90 个验证点的完整分层测试方案（T1-T6）。

简要验证目标：
- 模型加载 <3s，5秒语音识别 <1s（Apple Silicon）
- Option+Space 说"你好"→ 文字出现在 TextEdit

---

## 五、关键注意事项

1. **sherpa-onnx 无 SPM 支持**，必须手动编译 xcframework
2. **音频格式必须转换**为 16kHz mono Float32，否则识别失败
3. **按键重复要过滤**，检查 keyboardEventAutorepeat 字段
4. **浮窗必须 nonactivatingPanel**，否则焦点被抢走粘贴到错误应用
5. **辅助功能权限需手动开启**，App 应检测并引导用户
6. **关闭 App Sandbox** 用于开发（CGEvent tap 与沙箱冲突）
7. **C 字符串生命周期**：Swift String 传给 C API 时需保持引用存活
8. **剪贴板恢复**：粘贴后等 100ms 再恢复，检查 changeCount
9. **Option+Space 可能与系统快捷键冲突**：macOS "键盘设置 > 输入法" 中可能将 Option+Space 绑定为切换输入法。App 应在首次启动时检测冲突并提示用户修改系统设置，或提供备选快捷键（如 Ctrl+Space 或自定义）
10. **中文语音中的英文词汇**：Paraformer-zh 对中文夹杂的常见英文词（App、iPhone、OK 等）有一定识别能力，但不保证准确。MVP 阶段记录为已知限制，后续可考虑切换 SenseVoice-Small（原生多语言支持）

---

## 六、云端部署与分发规划

> MVP 阶段本地运行，但架构设计需预留云端扩展能力，为未来分发给其他用户做准备。

### 6.1 架构预留：识别引擎抽象层

MVP 中 SpeechRecognizer 设计为协议/接口（见 Phase 2.1），AppState 通过协议引用识别引擎，后续添加云端引擎无需改动核心流程。

### 6.2 云端语音识别服务方案

未来分发给其他用户时，需要云端识别服务（用户不需要下载 217MB 模型）：

**方案 A：自建 FunASR 服务（推荐）**

| 项目 | 方案 |
|------|------|
| 部署方式 | Docker 容器（FunASR 官方提供 `registry.cn-hangzhou.aliyuncs.com/funasr_repo/funasr`） |
| 服务协议 | WebSocket（FunASR 内置 real-time server） |
| 服务器 | 阿里云 ECS（GPU 实例用于高并发，CPU 实例用于低并发） |
| 模型 | Paraformer-zh（与本地同模型，保证一致性） |
| 成本估算 | CPU 实例 ~200 元/月（低并发），GPU 实例 ~1000 元/月（高并发） |
| 优势 | 免费模型无 API 费用，完全可控，中文最准 |

自建服务启动命令：
```bash
docker run -p 10095:10095 -it \
  registry.cn-hangzhou.aliyuncs.com/funasr_repo/funasr:latest \
  --model-dir paraformer-zh \
  --vad-dir fsmn-vad \
  --punc-dir ct-punc
```

客户端通过 WebSocket 连接 `ws://your-server:10095`，发送音频数据，接收文字结果。

**方案 B：第三方云 API（备选）**

| 服务 | 价格 | 适用场景 |
|------|------|----------|
| 阿里云 Qwen3-ASR-Flash | 1.19 元/时 | 不想自建服务器，按量付费 |
| Groq Whisper | $0.03/时 | 海外用户，最便宜 |

### 6.3 模型分发策略

分发给其他用户时，217MB 模型不应打包在 App 内：

| 策略 | 说明 |
|------|------|
| **首次启动下载** | App 首次打开时从 CDN 下载模型，显示进度条。用户体验好，App 体积小 |
| **模型 CDN** | 将模型文件上传到阿里云 OSS / CloudFlare R2，通过 CDN 加速分发 |
| **版本管理** | 模型文件带版本号，App 可检测新模型并提示更新 |
| **备用方案** | 模型下载失败时，自动切换到云端识别（需要网络） |

### 6.4 App 分发方式

| 渠道 | 要求 | 说明 |
|------|------|------|
| **官网 DMG 直接下载** | Apple Developer 账号 + 公证 (Notarization) | 用户下载即用，不受 App Store 审核限制 |
| **Mac App Store** | App Sandbox（需要调整快捷键实现方式） | 用户信任度高，自动更新 |
| **Homebrew Cask** | DMG 托管 + cask 配方 | 开发者用户偏好 |

**注意**：App Store 要求 App Sandbox，CGEvent tap 在沙箱中不可用。如需上架 App Store，全局快捷键需改用以下方案之一：
- `NSEvent.addGlobalMonitorForEvents`（功能受限，无法拦截事件）
- 申请辅助功能 entitlement（需要向 Apple 申请特殊权限）
- 改为输入法模式（通过 IMKit 注册，输入法不受沙箱限制）

**推荐路线**：MVP 先做 DMG 直接分发，后续 M2 阶段实现输入法引擎后可考虑上架 App Store。

### 6.5 用户账户与配置同步（未来）

| 功能 | 实现方案 |
|------|----------|
| 用户认证 | Apple Sign In / 邮箱注册 |
| 配置同步 | iCloud CloudKit（设置项、快捷键偏好） |
| 使用统计 | 本地统计 + 可选上报（隐私优先） |
| 付费模式 | 本地识别免费，云端识别按量/订阅制 |

### 6.6 MVP 中需要做的准备（不增加开发量，只是设计预留）

1. **SpeechRecognizer 用协议定义**，方便后续添加 CloudSpeechRecognizer
2. **模型路径不硬编码**，从配置读取，为首次下载模式预留
3. **网络层预留**，在 Services 目录预留 `APIClient.swift` 空文件
4. **App 签名**，从开始就配置 Developer ID 签名，避免后期迁移
5. **Info.plist 中设置合理的 Bundle Identifier**（如 `com.vowky.app`）

---

## 七、实现顺序与工作量估算

| 序号 | 步骤 | 预估时间 | 前置依赖 |
|:---:|------|:---:|------|
| 1 | Phase 0: 编译 sherpa-onnx + 下载模型 | 30 min | 无 |
| 2 | Phase 1: Xcode 项目搭建 + 框架集成 | 1-2 h | Phase 0 |
| 3 | SpeechRecognizer 实现 + T1 测试 | 1-2 h | Phase 1 |
| 4 | AudioRecorder 实现 + T1 测试 | 1-2 h | Phase 1 |
| 5 | HotkeyManager 实现 + T1 测试 | 1-2 h | Phase 1 |
| 6 | TextOutputService 实现 + T1 测试 | 30 min | Phase 1 |
| 7 | AppState 状态机 + T2 测试 | 1-2 h | Step 3-6 |
| 8 | T3 组件接线测试 | 1 h | Step 7 |
| 9 | App 入口 + MenuBarView | 1 h | Step 7 |
| 10 | RecordingPanel 浮窗 | 1-2 h | Step 9 |
| 11 | 全流程串联 | 1 h | All above |
| 12 | T4 系统权限测试 | 1 h | Step 11 |
| 13 | T5 冒烟 + T6 验收 | 1 h | Step 11 |
| 14 | SettingsView | 30 min | Step 11 |

**总计预估：13-19 小时**

---

> 验证方案详见 [MVP_VERIFICATION.md](./MVP_VERIFICATION.md)（90 个验证点，T1-T6 六层分层测试）
