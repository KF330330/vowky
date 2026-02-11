# VoKey MVP 验证方案

> 创建时间：2026-02-06
> 文档版本：V4.1（自动化改进）
> 关联文档：[MVP_PLAN.md](./MVP_PLAN.md)

> 设计原则：**诚实分层，明确置信度**。不追求虚假的 100% 自动化覆盖率，而是对每一层验证的能力边界和残留风险如实标注。

---

## 一、审计演进

### 1.0 原方案问题诊断

初版方案声称"38 个验证点，100% 全自动"，经架构级审计发现以下结构性问题：

1. **用代理测试制造虚假覆盖率** — `textView.paste(nil)` 和 `CGEvent.post(Cmd+V)` 走完全不同的系统路径（前者是 Cocoa 进程内方法调用，后者是 WindowServer 级事件注入），用前者替代后者不是"等价测试"而是"不同东西的测试"
2. **只有单元测试，没有系统测试** — 每个组件单独测试通过，但组件之间的接线（回调链、线程调度、状态流转）零覆盖
3. **只有正向路径，没有异常路径** — 录音中再按快捷键？识别失败？模型缺失？麦克风被占用？全部未考虑
4. **忽略了最高风险的生产故障** — CGEvent tap 被系统超时禁用（`tapDisabledByTimeout`）是此类 App 最常见的故障模式，完全未测
5. **4 个线程之间的竞态条件零测试** — CGEvent RunLoop 线程、音频线程、识别后台线程、主线程

### 1.1 验证完备性的元定义

> **先回答一个更根本的问题：什么是"完备"？完备的验证方案不等于"测试点最多"或"维度最全"，而是在给定约束下，对产品质量风险的覆盖达到了合理的边际收益平衡点。**

#### 完备性的三个层次

| 层次 | 定义 | 状态 |
|------|------|:---:|
| **L1 结构完备** | 不用假测试、不自欺欺人、测试层级合理 | ✅ V2 已解决 |
| **L2 维度完备** | 从多个正交维度系统检查覆盖，不遗漏整个类别 | ✅ V3 已解决 |
| **L3 来源完备** | 需求的提取来源本身是否完整？是否遗漏了整类需求？ | ❌ 本轮要解决 |

V2 解决了 L1（不用 `textView.paste(nil)` 假冒 `CGEvent.post`）。V3 解决了 L2（7 维度框架 + 需求追溯矩阵）。但 V3 有一个结构性盲点：**R1-R9 仅从第二节"核心交互流程"6 个步骤中提取，遗漏了其他三类需求来源。**

#### V3 的自我评价陷阱

V3 定义了 7 维度框架，然后用同一框架评估自身，宣布"6/7 维度全覆盖 ✅"。这是**自己出题自己答卷**——框架本身没问题，但提取需求时的盲点被框架继承了：

- **第二节**只定义了 6 步交互流程 → R1-R9，这是"功能需求"
- **第五节**定义了 8 条关键注意事项 → 这是"技术约束需求"，大部分没追溯
- **Phase 5**定义了性能目标 → 这是"非功能需求"，完全没追溯
- **隐含需求** → 产品形态决定的质量属性（如启动速度、内存占用）

#### 四类需求来源（完整版）

| 来源 | 类别 | 数量 | V3 覆盖 |
|------|------|:---:|:---:|
| 第二节：核心交互流程 | 功能需求 | 9 条 (R1-R9) | ✅ 9/9 |
| 第五节：关键注意事项 | 技术约束需求 | 8 条 (C1-C8) | 🟡 5/8 |
| Phase 5：性能目标 | 非功能需求 | 3 条 (P1-P3) | 🟡 2/3 |
| 产品形态隐含 | 质量属性需求 | ~3 条 (Q1-Q3) | ❌ 0/3 |

### 1.2 维度框架

| 维度 | 核心问题 | 验证方法 | MVP 优先级 |
|------|----------|----------|:---:|
| **D1 需求追溯** | 每条产品需求都有对应测试吗？ | 需求↔测试双向追溯矩阵 | **必须** |
| **D2 故障模式** | 每个组件可能的故障都有应对测试吗？ | FMEA 式枚举 | **必须** |
| **D3 状态空间** | 状态机的每个状态和转换都被覆盖了吗？ | 状态转换表全覆盖 | **必须** |
| **D4 数据流** | 每个数据变换的边界条件都被测了吗？ | 边界值分析 | 重要 |
| **D5 运行环境** | 不同硬件/OS 版本都能工作吗？ | 环境矩阵 | MVP 不做 |
| **D6 时间维度** | 启动→稳态→长期运行→关闭各阶段都验证了吗？ | 生命周期测试 | 重要 |
| **D7 安全隐私** | 产品的安全/隐私承诺都被验证了吗？ | 安全检查清单 | 重要 |

**关键洞察**：当前 78 点方案是 100% **自底向上**（从代码组件出发设计测试），从未做过**自顶向下**（从产品需求出发追溯测试）。底层覆盖良好，但顶层追溯缺失意味着可能存在"所有组件都正确但产品功能不完整"的风险。

### 1.3 全量需求→验证追溯矩阵

> 以下为 V4 最终状态。V3 遗漏的缺口已由补充测试填补。

#### 功能需求（来源：第二节核心交互流程）— V3 已覆盖

| ID | 需求 | 对应测试 | 状态 |
|:---:|------|------|:---:|
| R1 | App 常驻菜单栏，显示麦克风图标 | T5 #69 | ✅ |
| R2 | 按住 Option+Space → 开始录音，出现录音浮窗 | T4 #52, T6 #70-71 | ✅ |
| R3 | 说话时浮窗显示音量波形 | #79 (V3补充) | ✅ |
| R4 | 松开 Option+Space → 停止录音，开始识别 | T2 #28, T4 #52, T6 | ✅ |
| R5 | 识别完成 → 文字自动粘贴到当前光标位置 | T4 #55, T6 #70-75 | ✅ |
| R6 | 浮窗短暂显示结果后消失 | T3 #42, T6 #71 | ✅ |
| R7 | 菜单栏 App，不占 Dock | T5 #68 | ✅ |
| R8 | 完全本地运行，无需网络 | #80 (V3补充) | ✅ |
| R9 | 中文语音识别准确 | T1 #2-3, #7 | ✅ |

#### 技术约束需求（来源：第五节关键注意事项）— V3 遗漏

| ID | 约束 | 对应测试 | 状态 |
|:---:|------|------|:---:|
| C1 | sherpa-onnx 无 SPM，需手动编译 xcframework | 构建配置，非运行时可测 | ➖ N/A |
| C2 | 音频格式必须 16kHz mono Float32 | T1 #13-14 | ✅ |
| C3 | 按键重复要过滤（keyboardEventAutorepeat） | T1 #17 | ✅ |
| C4 | 浮窗必须 nonactivatingPanel | T4 #61-64 | ✅ |
| C5 | 辅助功能权限需检测并引导 | #86 (V3补充) | ✅ |
| C6 | 关闭 App Sandbox | 构建配置，非运行时可测 | ➖ N/A |
| C7 | C 字符串生命周期：Swift String 传给 C API 时需保持引用存活 | #87 (V4补充) | ✅ |
| C8 | 剪贴板恢复：100ms 延迟 + changeCount 检查 | T1 #22, #25 | ✅ |

**C7 是实际的崩溃风险**：sherpa-onnx 的 C API 接收 `const char*` 指针，Swift 临时 String 传入后可能在 C 代码使用前被释放，导致野指针崩溃。这在开发中不一定复现（取决于内存回收时机），但在生产中会偶发 crash。

#### 非功能需求（来源：Phase 5 性能目标）— V3 遗漏

| ID | 性能指标 | 对应测试 | 状态 |
|:---:|------|------|:---:|
| P1 | 模型加载 <3s (Apple Silicon) | T1 #6 (measure) | ✅ |
| P2 | 5秒语音识别 <1s | T1 #7 | ✅ |
| P3 | App 内存占用合理（模型 217MB） | #88 (V4补充) | ✅ |

#### 质量属性需求（隐含于产品形态）— V3 完全遗漏

| ID | 质量属性 | 对应测试 | 状态 |
|:---:|------|------|:---:|
| Q1 | App 启动到可用 <5s（菜单栏 App 用户期望快速可用） | #89 (V4补充) | ✅ |
| Q2 | 录音→识别→粘贴端到端延迟用户可接受（<3s for 5s audio） | #90 (V4补充) | ✅ |
| Q3 | App 退出干净（无残留进程、无 CGEvent tap 泄漏） | T4 #54 (tap 清理) | ✅ |

### 1.4 V4 Gap 汇总

**V3 → V4 新发现的缺口：**

| # | 缺口 | 严重性 | 说明 |
|:---:|------|:---:|------|
| G1 | C7 C 字符串生命周期无测试 | **高** | sherpa-onnx 集成最常见的崩溃原因，偶发且难调试 |
| G2 | P3 内存占用无基线 | 中 | 217MB 模型 + 音频缓冲区，需确认总 RSS 在合理范围 |
| G3 | Q1 启动到可用延迟无测试 | 中 | 用户按下快捷键前必须等模型加载完成 |
| G4 | Q2 端到端延迟无测试 | 中 | 从松开按键到文字出现的总时间，用户体验的核心指标 |

与前几轮对比：
- V1→V2 修复了 **结构性问题**（假测试、缺分层）：影响巨大
- V2→V3 修复了 **维度盲区**（缺需求追溯、缺状态覆盖）：影响显著
- **V3→V4 修复的是 需求来源遗漏**（技术约束+非功能+质量属性）：影响收敛

**边际收益判断**：V4 新增 4 个缺口中，G1（C 字符串崩溃）是真实高风险，其余 3 个是锦上添花。**这是最后一轮有实质价值的审计。**

### 1.5 有意不测试的范围（MVP 取舍）

以下经评估后决定 **MVP 阶段不做**，记录为已知限制：

| 范围 | 原因 | 后续计划 |
|------|------|----------|
| D5 环境矩阵（Intel Mac、macOS 12-、外接音频） | 开发者只有一台 Apple Silicon Mac，无法真实测试 | M4 阶段用 GitHub Actions macOS matrix 覆盖 |
| 睡眠/唤醒后 CGEvent tap 恢复 | 需要物理操作，无法自动化 | 记录到 T6 验收清单作为可选项 |
| 内存泄漏长期监测（数小时级） | 需要 Instruments profiling，不适合 XCTest | M4 阶段添加 Instruments 自动化 |

### 1.6 何时停止审计（边际收益判断）

> **验证方案的"完备"不是绝对状态，而是边际收益的拐点。**

```
审计收益
  ▲
  │  ★ V2: 修复假测试（结构性问题）
  │    ＼
  │      ★ V3: 补需求追溯（维度盲区）
  │        ＼
  │          ★ V4: 补技术约束+非功能需求（来源遗漏）
  │            ＼
  │              ─── 收益递减，进入代码阶段更有价值
  │
  └──────────────────────────────────────→ 审计轮次
```

**停止标准**：当新一轮审计发现的缺口都是"锦上添花"（中/低严重性）且不影响 MVP 核心流程时，转入实现阶段。在实现中发现的真实问题比规划中的假设性问题更有价值。

**V4 判定：除 G1（C 字符串崩溃）外，其余缺口均为中低优先级。建议将 G1-G4 补入后，结束验证规划，进入实现。**

---

## 二、测试架构

### 2.0 验证分层

| 层级 | 名称 | 验证什么 | 方式 | 自动化 | 置信度 |
|:---:|------|------|------|:---:|:---:|
| **T1** | 单元测试 | 各组件独立逻辑正确 | XCTest，无需权限 | 全自动 | 高 |
| **T2** | 状态机 & 异常路径 | AppState 状态转换 + 错误处理 + 权限被拒 | XCTest，无需权限 | 全自动 | 高 |
| **T3** | 组件接线测试 | 回调链、线程调度 | XCTest，mock 外部依赖 | 全自动 | 中高 |
| **T4** | 系统权限测试 | CGEvent tap/post、真实录音、静默/连按 | XCTest，需要辅助功能+麦克风权限 | 半自动（首次需授权） | 高 |
| **T5** | App 级冒烟测试 | 启动、菜单栏、离线运行 | Bash 脚本 + sandbox-exec | 全自动/半自动 | 中 |
| **T6** | 真实场景验收 | 跨 App 粘贴、浮窗视觉 | AppleScript 脚本 + 手动视觉确认 | 可脚本化/手动 | 最高 |

### 2.1 测试资源

Paraformer 模型包自带测试 WAV：
- `test_wavs/0.wav` → "我做了介绍啊那么我想说的是呢大家如果对我的研究感兴趣呢你"
- `test_wavs/1.wav` → "重点呢想谈三个问题首先呢就是这一轮全球金融动荡的表现"

添加到 XCTest target 的 Bundle Resources。

### 2.2 测试 Target 结构

```
VoKeyTests/
├── Unit/
│   ├── SpeechRecognizerTests.swift      # T1: 语音识别核心
│   ├── AudioFormatTests.swift           # T1: 音频格式转换
│   ├── HotkeyLogicTests.swift           # T1: 快捷键纯逻辑
│   ├── ClipboardTests.swift             # T1: 剪贴板操作
│   └── ModelFailureTests.swift          # T1: 模型加载异常
├── StateMachine/
│   ├── AppStateTransitionTests.swift    # T2: 状态机正向+异常转换
│   └── ErrorRecoveryTests.swift         # T2: 各组件错误恢复
├── Integration/
│   ├── CallbackChainTests.swift         # T3: 回调链接线验证
│   ├── ThreadSafetyTests.swift          # T3: 并发竞态测试
│   └── PipelineTests.swift             # T3: 音频→识别→输出管道
├── System/
│   ├── CGEventTapTests.swift            # T4: 真实 CGEvent tap 创建+生命周期
│   ├── CGEventPasteTests.swift          # T4: 真实 CGEvent post Cmd+V
│   ├── AudioCaptureTests.swift          # T4: 真实麦克风录音
│   └── PanelFocusTests.swift            # T4: NSPanel 焦点行为
└── Resources/
    └── TestAudio/
        ├── test_zh_0.wav
        └── test_zh_1.wav
```

---

## 三、测试详情（T1-T6）

### 3.1 T1：单元测试（全自动，无需权限）

#### 语音识别 — SpeechRecognizerTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 1 | 模型加载成功 | `isReady == true` |
| 2 | 中文识别准确 | test_zh_0.wav 包含"介绍""研究" |
| 3 | 第二段音频 | test_zh_1.wav 包含"金融" |
| 4 | 空音频不崩溃 | `recognize(samples: [])` |
| 5 | 静音不崩溃 | 0.5秒全零样本 |
| 6 | 模型加载性能 | `measure {}` |
| 7 | 识别延迟 <2s | 5秒音频 |

#### 模型异常 — ModelFailureTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 8 | 模型文件不存在 | 指向不存在路径，`isReady == false`，不崩溃 |
| 9 | tokens 文件不存在 | 只有 model 没有 tokens，不崩溃 |
| 10 | 模型路径为空字符串 | 边界条件 |

#### 音频格式 — AudioFormatTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 11 | WAV 加载样本数 >0 | loadWAVAsFloat32 基本功能 |
| 12 | 样本值范围 [-1,1] | 不溢出 |
| 13 | 48kHz→16kHz 转换 | AVAudioConverter 验证 |
| 14 | 转换后样本数正确 | ±100 容差 |

#### 快捷键纯逻辑 — HotkeyLogicTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 15 | Option+Space 识别 | `evaluateEvent()` 纯函数 |
| 16 | 普通 Space 不触发 | 无 modifier |
| 17 | 按键重复过滤 | `isRepeat=true` 时不触发 |
| 18 | keyUp 正确触发 | |
| 19 | Cmd+Space 不误触 | 其他 modifier |
| 20 | Option+A 不误触 | 其他 keyCode |

#### 剪贴板 — ClipboardTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 21 | 写入读回 | 基本 NSPasteboard 操作 |
| 22 | 保存→替换→恢复 | saveClipboard + restoreClipboard |
| 23 | 空文字不写入 | changeCount 不变 |
| 24 | Unicode 中文 | 包含各种标点 |
| 25 | changeCount 防覆盖 | 恢复前检查 changeCount 变化 |

**T1 小计：25 + 5 补充(#81,85,87,88,90) = 30 个验证点，全自动。**

---

### 3.2 T2：状态机 & 异常路径（全自动，无需权限）

#### AppState 状态转换 — AppStateTransitionTests

AppState 管理一个核心状态机：`idle → recording → recognizing → outputting → idle`

| # | 验证点 | 说明 |
|:---:|------|------|
| 26 | 初始状态正确 | idle, 未录音, 未识别 |
| 27 | idle→recording | startRecording() 后 isRecording=true |
| 28 | recording→recognizing | stopAndRecognize() 后 isRecognizing=true |
| 29 | **录音中重复 startRecording** | 应忽略（幂等），不创建第二个录音会话 |
| 30 | **idle 时 stopRecording** | 应忽略，不崩溃 |
| 31 | **识别中 startRecording** | 应忽略或排队，不打断当前识别 |
| 32 | **快速连按** | 200ms 内 start→stop→start→stop，状态不混乱 |
| 33 | 识别返回 nil 时的处理 | 不粘贴空文字，显示提示，状态回 idle |
| 34 | 识别返回空字符串 | 同上 |

#### 错误恢复 — ErrorRecoveryTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 35 | 录音启动失败 | mock AudioRecorder 抛错，状态回 idle，UI 显示错误 |
| 36 | 识别过程异常 | mock SpeechRecognizer 抛错，状态回 idle |
| 37 | 连续错误后仍可用 | 失败一次后再次按快捷键，正常工作 |

#### 权限被拒 — PermissionDeniedTests

> 覆盖 #86（首次启动权限引导）的核心逻辑，通过协议注入 mock 实现全自动化。

| # | 验证点 | 说明 |
|:---:|------|------|
| 91 | 辅助功能权限被拒时的行为 | mock `PermissionChecker.isAccessibilityGranted()` 返回 false → 显示引导 UI、不崩溃、不卡死、不开始录音 |

**T2 小计：12 + 3 补充(#82,83,84) + 1 自动化改进(#91) = 16 个验证点，全自动。使用 mock/protocol 注入模拟异常。**

---

### 3.3 T3：组件接线测试（全自动，无需权限）

> 验证组件之间的回调链和线程调度是否正确。使用 mock 替换外部依赖（硬件、系统权限），只测接线逻辑。

#### 回调链 — CallbackChainTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 38 | HotkeyDown → AppState.startRecording 被调用 | 回调接线验证 |
| 39 | HotkeyUp → AppState.stopAndRecognize 被调用 | |
| 40 | AudioRecorder.stop → 样本传给 SpeechRecognizer | |
| 41 | SpeechRecognizer 结果 → TextOutputService.outputText | |
| 42 | outputText → RecordingPanel 显示结果 | |
| 43 | 完整链路：Down→录音→Up→识别→输出→面板隐藏 | 用 mock 走完全流程 |

#### 线程安全 — ThreadSafetyTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 44 | 识别回调在后台线程，UI 更新回主线程 | `XCTAssertTrue(Thread.isMainThread)` in UI callback |
| 45 | 音频缓冲区线程安全 | 模拟音频线程写入 + 主线程读取，不崩溃 |
| 46 | 并发 startRecording 调用 | 两个线程同时调用，只有一个生效 |

#### 管道测试 — PipelineTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 47 | 音频文件→识别→写入剪贴板 | 真实 recognizer + 真实 clipboard |
| 48 | 60秒录音限制 | mock AudioRecorder 模拟超时，自动停止 |
| 49 | 内存稳定性 | 连续 10 次识别，内存增长 <50MB |

**T3 小计：12 + 1 补充(#79) = 13 个验证点，全自动。**

---

### 3.4 T4：系统权限测试（半自动，首次需授权）

> **诚实声明**：以下测试需要辅助功能权限和麦克风权限。首次运行需用户在系统设置中授权，授权后可反复自动运行。这是 macOS 安全模型的硬约束，无法绕过。

#### CGEvent tap — CGEventTapTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 50 | CGEvent tap 创建成功 | `CGEvent.tapCreate()` 返回非 nil |
| 51 | tap 添加到 RunLoop | `CFMachPortCreateRunLoopSource` + `CFRunLoopAddSource` |
| 52 | Option+Space 事件被拦截 | 发送 CGEvent → 回调被调用 |
| 53 | **tapDisabledByTimeout 恢复** | 模拟 tap 被禁用 → 检测到 → 重新启用 |
| 54 | tap 清理 | deinit 时 tap 被移除，不泄漏 |

#### CGEvent paste — CGEventPasteTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 55 | CGEvent Cmd+V 发送到自身窗口 | 创建 NSWindow + NSTextView，发送 CGEvent，验证文字出现 |
| 56 | 粘贴后剪贴板恢复 | 100ms 延迟后恢复，验证 changeCount |

#### 真实录音 — AudioCaptureTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 57 | AVAudioEngine 启动成功 | 不崩溃 |
| 58 | 录音 1 秒获得 ~16000 样本 | 验证格式转换管道 |
| 59 | 样本非全零 | 确认真的在录音（环境噪声） |
| 60 | 停止后 engine 状态正确 | isRunning == false |

#### 浮窗焦点 — PanelFocusTests

| # | 验证点 | 说明 |
|:---:|------|------|
| 61 | RecordingPanel 显示不改变 keyWindow | `NSApp.keyWindow` 不变 |
| 62 | Panel 显示不改变 mainWindow | `NSApp.mainWindow` 不变 |
| 63 | Panel 为 floating 级别 | `panel.level == .floating` |
| 64 | Panel 为 nonactivatingPanel | 样式验证 |

#### 端到端按键模拟 — CGEventSimulationTests

> 以下两个验证点原属 T6 手动验收，改为 CGEvent 模拟全自动化。测试真实 CGEvent 路径，不降低要求。

| # | 验证点 | 说明 |
|:---:|------|------|
| 76 | 静默松开 → 不卡死 | CGEvent 模拟 Option+Space keyDown→0.3s→keyUp（不说话），验证状态回 idle、无错误、无输出 |
| 77 | 连续快按 → 状态正确 | CGEvent 模拟 3 轮快速 down→0.5s→up，每轮验证状态回 idle，App 持续响应 |

**T4 小计：15 + 2 = 17 个验证点，需要权限（首次授权后自动运行）。**

运行方式：
```bash
# 首次运行前：在系统设置中授予 VoKeyTests 辅助功能权限和麦克风权限
xcodebuild test \
  -project VoKey.xcodeproj \
  -scheme VoKey \
  -destination 'platform=macOS' \
  -only-testing:VoKeyTests/System \
  2>&1 | grep -E "(Test Case|passed|failed)"
```

---

### 3.5 T5：App 级冒烟测试（Bash 脚本）

```bash
#!/bin/bash
# verify_app.sh

set -e
echo "=== VoKey App 验证 ==="

# 1. 编译
echo "[T5-1] 编译项目..."
xcodebuild build -project VoKey.xcodeproj -scheme VoKey \
  -destination 'platform=macOS' -configuration Debug 2>&1 | tail -3

# 2. 运行 T1-T3 自动测试
echo "[T5-2] 运行自动化测试..."
xcodebuild test -project VoKey.xcodeproj -scheme VoKey \
  -destination 'platform=macOS' \
  -skip-testing:VoKeyTests/System \
  2>&1 | grep -E "(Test Suite|passed|failed)" | tail -10

# 3. 启动 App
echo "[T5-3] 启动 App..."
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "VoKey.app" -path "*/Debug/*" | head -1)
open "$APP_PATH"
sleep 5  # 给模型加载留够时间

# 4. 验证进程存活
if pgrep -x "VoKey" > /dev/null; then
  echo "PASS: App 启动成功"
else
  echo "FAIL: App 崩溃"; exit 1
fi

# 5. 验证无 Dock 图标（LSUIElement）
DOCK_CHECK=$(osascript -e '
  tell application "System Events"
    return name of every process whose visible is true
  end tell' 2>/dev/null)
if echo "$DOCK_CHECK" | grep -q "VoKey"; then
  echo "FAIL: VoKey 出现在 Dock 中（LSUIElement 配置错误）"
else
  echo "PASS: 无 Dock 图标"
fi

# 6. 验证菜单栏图标
MENU_CHECK=$(osascript -e '
  tell application "System Events"
    tell process "VoKey"
      return exists menu bar item 1 of menu bar 2
    end tell
  end tell' 2>/dev/null || echo "false")
if [ "$MENU_CHECK" = "true" ]; then
  echo "PASS: 菜单栏图标存在"
else
  echo "WARN: 无法验证菜单栏图标"
fi

# 清理
pkill -x "VoKey" 2>/dev/null || true
echo "=== 冒烟测试完成 ==="
```

| # | 验证点 | 说明 |
|:---:|------|------|
| 65 | 编译通过 | BUILD SUCCEEDED |
| 66 | T1-T3 测试全部通过 | |
| 67 | App 启动不崩溃 | pgrep 5 秒后存活 |
| 68 | 无 Dock 图标 | LSUIElement 生效 |
| 69 | 菜单栏图标存在 | |

**T5 小计：5 + 3 补充(#80,86,89) = 8 个验证点。其中 #80 已改为 sandbox-exec 全自动方案，#86 核心逻辑已由 T2 #91 自动覆盖（手动测试保留为可选）。**

---

### 3.6 T6：真实场景验收（可脚本化/手动，~5 分钟）

> **为什么需要验收**：CGEvent post 到第三方 App 的行为取决于 WindowServer 事件路由和目标 App 的响应链实现，这在 macOS 上无法在测试进程内模拟。以下清单确保真实用户体验正确。
>
> **自动化改进**：#70-75 可通过测试音频注入（`VOKEY_TEST_AUDIO` 环境变量）+ AppleScript 读取目标 App 内容实现脚本化验证。识别管道、CGEvent 粘贴、跨进程路由全部真实，仅音频源从麦克风替换为测试文件。#76/#77 已移至 T4 通过 CGEvent 模拟全自动化。#78 可脚本化为 nightly 长运行测试。

#### 验收清单（交付给用户时附带）

```
VoKey MVP 验收清单
==================

前置条件：
□ 在系统设置 > 隐私与安全性 > 辅助功能 中授权 VoKey
□ 在系统设置 > 隐私与安全性 > 麦克风 中授权 VoKey

基本功能：
□ 1. 打开 TextEdit，新建文档
□ 2. 按住 Option+Space，看到录音浮窗出现
□ 3. 说"今天天气真好"
□ 4. 松开 Option+Space，浮窗显示识别中
□ 5. 识别完成，"今天天气真好"自动出现在 TextEdit 中
□ 6. 浮窗短暂显示结果后自动消失
□ 7. 剪贴板内容未被改变（复制一段文字，语音输入后 Cmd+V 粘贴出的是之前复制的内容）

跨 App 验证：
□ 8. 在 Safari 地址栏语音输入 → 文字出现
□ 9. 在 Notes.app 中语音输入 → 文字出现
□ 10. 在 Terminal 中语音输入 → 文字出现

异常情况：
□ 11. 按住后不说话直接松开 → 无文字输出，App 不卡死
□ 12. 连续快速按 3 次 → 每次都正常工作
□ 13. 识别中关闭目标 App → VoKey 不崩溃

稳定性：
□ 14. 语音输入 10 次以上 → 快捷键持续响应（tapDisabledByTimeout 恢复正常）
□ 15. App 运行 30 分钟后 → 快捷键仍然响应
```

| # | 验证点 | 说明 | 自动化 |
|:---:|------|------|:---:|
| 70 | TextEdit 粘贴成功 | Cocoa App | 可脚本化 |
| 71 | 浮窗正确显示/隐藏 | 焦点不被抢走（功能逻辑已被 T4 #61-64 覆盖，此处验证视觉表现） | 🔴 手动 |
| 72 | 剪贴板恢复 | 100ms 时序正确（核心逻辑已被 T1 #22/T4 #56 覆盖） | 可脚本化 |
| 73 | Safari 粘贴成功 | WebKit 进程 | 可脚本化 |
| 74 | Notes 粘贴成功 | 原生 App | 可脚本化 |
| 75 | Terminal 粘贴成功 | 非标准文本输入 | 可脚本化 |
| 78 | 长期运行快捷键不失效 | tapDisabledByTimeout 恢复 | nightly 脚本 |

> **#76（静默松开）和 #77（连续快按）已移至 T4**，通过 CGEvent 模拟全自动化，见 3.4 节。

**T6 小计：7 个验证点。其中 5 个可脚本化（需预留 `VOKEY_TEST_AUDIO` 环境变量），1 个 nightly 自动，1 个纯手动（#71 视觉确认）。**

---

## 四、验证总览

| 层级 | 验证点数 | 自动化程度 | 置信度 |
|:---:|:---:|------|:---:|
| T1 单元测试 | 25 + 2 + 3 = **30** | 全自动 | 高 |
| T2 状态机 & 异常 | 12 + 3 + 1 = **16** | 全自动 | 高 |
| T3 组件接线 | 12 + 1 = **13** | 全自动 | 中高 |
| T4 系统权限 | 15 + 2 = **17** | 半自动（首次授权） | 高 |
| T5 App 冒烟 | 5 + 2 + 1 = **8** | 全自动/半自动（#80 sandbox-exec，#86 核心→T2） | 中 |
| T6 真实验收 | **7** | 可脚本化 5 + nightly 1 + 手动 1 | 最高 |
| **总计** | **91** | | |

**自动化分布：**

| 级别 | 数量 | 占比 | 说明 |
|:---:|:---:|:---:|------|
| 全自动 | **59** | 65% | T1+T2+T3（一条命令） |
| 首次授权后自动 | **17** | 19% | T4（含 #76/#77） |
| 脚本化自动 | **14** | 15% | T5 + T6 可脚本化 + nightly |
| 纯手动 | **1** | 1% | T6 #71 浮窗视觉确认 |

**需求全量追溯覆盖：**

| 需求类别 | 来源 | 总数 | 已覆盖 |
|----------|------|:---:|:---:|
| 功能需求 R1-R9 | 第二节交互流程 | 9 | 9/9 ✅ |
| 技术约束 C1-C8 | 第五节注意事项 | 8 | 6/6 可测项 ✅ (C1/C6 为构建配置) |
| 性能指标 P1-P3 | Phase 5 目标 | 3 | 3/3 ✅ |
| 质量属性 Q1-Q3 | 产品形态隐含 | 3 | 3/3 ✅ |
| **合计** | | **23** | **21/21 可测项** |

**7 维度覆盖：**

| 维度 | 覆盖状态 |
|------|:--------:|
| D1 需求追溯 | ✅ 4 类 23 条需求全量追溯 |
| D2 故障模式 | ✅ 关键故障全覆盖 |
| D3 状态空间 | ✅ 全部状态 + 转换覆盖 |
| D4 数据流 | ✅ 边界条件覆盖 |
| D5 运行环境 | ⏭️ MVP 有意不做（见 1.5） |
| D6 时间维度 | ✅ 启动 + 稳态 + 长运行 |
| D7 安全隐私 | ✅ 离线承诺已验证 |

**演进历程：**
- V1 原方案：38 点，100% 自动（虚假） → 实际仅 18 点有效
- V2 诚实分层：78 点，T1-T6 六层 → 缺自顶向下追溯
- V3 维度完备：86 点，7 维度框架 → 仅追溯了功能需求 R1-R9
- V4 来源完备：90 点 → 4 类需求全量追溯，达到边际收益拐点
- **V4.1 自动化改进：91 点** → 手动点从 11 个降至 1 个（#71 浮窗视觉），自动化率 99%（含脚本化）

---

## 五、关键设计原则（为可测试性服务）

1. **AppState 状态机显式化** — 用 enum 定义状态，转换方法中校验前置状态
2. **HotkeyManager.evaluateEvent() 纯函数** — 事件判断逻辑与 CGEvent tap 解耦
3. **TextOutputService 方法拆分** — save/write/paste/restore 各自独立可测
4. **SpeechRecognizerProtocol 协议** — T2/T3 测试用 mock 注入
5. **AudioRecorderProtocol 协议** — T2/T3 测试用 mock 注入
6. **tapDisabledByTimeout 主动恢复** — HotkeyManager 监听 `.tapDisabledByTimeout` 事件类型，自动 `CGEvent.tapEnable()`
7. **模型路径配置化** — 支持缺失时 `isReady=false` 而非崩溃
8. **PermissionChecker 协议** — 将 `AXIsProcessTrusted` 抽象为可注入协议，T2 测试用 mock（#91）
9. **AudioRecorder 测试音频注入** — 通过 `VOKEY_TEST_AUDIO` 环境变量支持从文件读取音频，用于 T6 脚本化验证

---

## 六、运行策略

```
开发阶段（每次改代码后）：
  → 运行 T1 + T2 + T3（全自动，~2 分钟，59 点）

功能完成后（一次性）：
  → 授权辅助功能 + 麦克风权限
  → 运行 T4（~3 分钟，17 点，含 #76 静默松开 + #77 连续快按）

交付前：
  → 运行 T5 冒烟脚本（含 sandbox-exec 离线验证）
  → 运行 T6 脚本化验证（VOKEY_TEST_AUDIO + AppleScript，6 点）
  → 手动确认 #71 浮窗视觉表现（~1 分钟，唯一手动项）

Nightly（可选）：
  → 运行 long_run_test.sh（#78，30 分钟耐久测试）
```

---

## 七、补充验证点（基于完备性审计新增）

> 以下 8 个测试点来自 1.3 Gap 分析和需求追溯矩阵，填补已识别的缺口。V4 新增 4 个测试点填补技术约束和非功能需求缺口。

#### 填补 D1 需求追溯缺口

| # | 缺口 | 验证点 | 层级 | 说明 |
|:---:|:---:|------|:---:|------|
| 79 | R3 | 音量 level 数据传递到 UI | T3 | AudioRecorder 提供实时音量 level → 回调被调用 → RecordingPanel 收到数据并更新波形。用 mock 验证数据流通路 |
| 80 | R8 | 离线运行验证 | T5 | ~~关闭 Wi-Fi~~ → 使用 `sandbox-exec -p '(version 1)(allow default)(deny network*)'` 进程级网络隔离运行识别测试。比手动断网更严格（精确隔离测试进程），且全自动 |

#### 填补 D2 故障模式缺口

| # | 缺口 | 验证点 | 层级 | 说明 |
|:---:|:---:|------|:---:|------|
| 81 | FM | 极短音频（<0.3s，~4800 样本） | T1 | 识别返回空字符串或极短结果，不崩溃 |
| 82 | FM | 麦克风被占用 | T2 | mock AudioRecorder 返回"设备忙"错误 → 状态回 idle，UI 显示错误提示 |

#### 填补 D3 状态空间缺口

| # | 缺口 | 验证点 | 层级 | 说明 |
|:---:|:---:|------|:---:|------|
| 83 | SS | 模型加载中按快捷键 | T2 | isReady=false 时 onHotkeyDown → 显示"正在准备"提示，不开始录音 |
| 84 | SS | outputting 状态中按快捷键 | T2 | 正在执行粘贴时再按 → 忽略，不重复粘贴 |

#### 填补 D4 数据流缺口

| # | 缺口 | 验证点 | 层级 | 说明 |
|:---:|:---:|------|:---:|------|
| 85 | DF | 识别结果含特殊字符 | T1 | 模拟识别返回"第一行\n第二行"或含 emoji 文字 → 正确写入剪贴板，读回一致 |

#### 填补 D6 时间维度缺口

| # | 缺口 | 验证点 | 层级 | 说明 |
|:---:|:---:|------|:---:|------|
| 86 | TM | 首次启动权限引导 | T5 | 无辅助功能权限时启动 App → 显示权限引导弹窗，不崩溃，不卡死 |

#### 填补技术约束缺口（V4 新增）

| # | 缺口 | 验证点 | 层级 | 说明 |
|:---:|:---:|------|:---:|------|
| 87 | C7 | C 字符串生命周期安全 | T1 | SpeechRecognizer 初始化后，验证模型路径字符串仍可访问（不被提前释放）。方法：init 后延迟 1 秒再调用 recognize，若路径被释放会崩溃或返回乱码 |

#### 填补非功能需求缺口（V4 新增）

| # | 缺口 | 验证点 | 层级 | 说明 |
|:---:|:---:|------|:---:|------|
| 88 | P3 | 内存占用基线 | T1 | 模型加载后测量进程 RSS，断言 <500MB（模型 217MB + 运行时开销） |
| 89 | Q1 | 启动到可用延迟 | T5 | App 启动后测量到 `isReady==true` 的时间，断言 <5s |
| 90 | Q2 | 端到端延迟 | T1 | 从调用 recognize(5秒音频) 开始到返回结果的总时间，断言 <2s |

#### 自动化改进新增（V4.1）

| # | 缺口 | 验证点 | 层级 | 说明 |
|:---:|:---:|------|:---:|------|
| 91 | C5 | 辅助功能权限被拒时行为正确 | T2 | mock `PermissionChecker.isAccessibilityGranted()` 返回 false → 显示引导 UI、不崩溃、不卡死、不开始录音。覆盖 #86 核心逻辑 |

**补充小计：V3 补充 8 个 + V4 补充 4 个 + V4.1 自动化改进 1 个 = 13 个验证点。**
