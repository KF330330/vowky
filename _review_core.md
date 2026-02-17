# VoKey 核心层代码审阅报告

> 审阅范围：AppState.swift、VoKeyApp.swift、AppDelegate.swift、Services/Protocols.swift、ContentView.swift
> 审阅日期：2026-02-17

---

## 1. AppState.swift

### 文件职责
应用的核心状态机与业务逻辑协调器，作为唯一事实来源管理语音输入的完整生命周期。

### 已实现功能清单
- 定义五种应用状态枚举：加载中、空闲、录音中、识别中、输出中
- 通过 @Published 发布状态、错误信息、最近一次识别结果、最近三次识别结果列表
- 依赖注入：通过构造函数注入语音识别器、录音器、权限检查器、标点服务（可选）、音频备份服务（可选）
- 延迟初始化三个可选服务：快捷键管理器、文本输出服务、录音面板
- setup() 一次性初始化流程：打开历史数据库、后台加载语音模型和标点模型、绑定备份服务到录音器、创建录音面板和文本输出服务、配置快捷键管理器回调并启动
- 快捷键切换处理（Toggle 模式）：空闲时开始录音，录音中时停止录音并启动识别，加载中提示用户等待，识别中和输出中忽略操作
- 开始录音前检查辅助功能权限，未授权则提示错误
- 录音启动同时启动音频备份
- 停止录音后异步执行语音识别，识别结果为空则直接回到空闲状态并删除备份
- 对识别结果自动追加标点（如标点服务可用）
- 识别成功后：更新最近结果、插入文本到前台应用、完成备份并删除、写入历史记录
- 取消录音功能（Escape 键触发）：停止录音、删除备份、回到空闲状态
- 最近识别结果维护：保持最多 3 条，新结果插入头部，同步写入 HistoryStore
- 崩溃恢复机制：启动时检查是否存在未完成的备份音频，若有则自动恢复识别并输出结果

### 状态机/流程描述
- 启动时进入 loading，模型加载完成后进入 idle
- idle 状态下按快捷键进入 recording
- recording 状态下按快捷键进入 recognizing，按 Escape 回到 idle
- recognizing 完成后自动回到 idle
- loading/recognizing/outputting 状态下忽略快捷键操作
- 流程：idle -> recording -> recognizing -> idle（文本已输出）；recording 可通过 Escape 直接回到 idle

### 关键配置和限制条件
- 标记为 @MainActor，所有状态变更确保在主线程执行
- 模型加载使用 Task.detached(priority: .userInitiated) 在后台执行，避免阻塞主线程
- 采样率硬编码为 16000 Hz
- 最近识别结果上限为 3 条
- 标点服务和备份服务均为可选依赖，缺失时不影响核心流程
- setup() 设计为仅调用一次

### 与其他模块的依赖关系
- 依赖 SpeechRecognizerProtocol（生产实现：LocalSpeechRecognizer）
- 依赖 AudioRecorderProtocol（生产实现：AudioRecorder）
- 依赖 PermissionCheckerProtocol（生产实现：RealPermissionChecker）
- 可选依赖 PunctuationServiceProtocol（生产实现：PunctuationService）
- 可选依赖 AudioBackupProtocol（生产实现：AudioBackupService）
- 依赖 HotkeyManager（直接创建，非协议注入）
- 依赖 TextOutputService（直接创建，非协议注入）
- 依赖 RecordingPanel（直接创建，传入 self）
- 依赖 HistoryStore.shared 单例写入历史记录

---

## 2. VoKeyApp.swift

### 文件职责
SwiftUI 应用入口，负责依赖组装、菜单栏 UI 承载，以及真实权限检查器的实现。

### 已实现功能清单
- 使用 @main 标记为应用入口
- 通过 @NSApplicationDelegateAdaptor 桥接 AppDelegate
- 创建 AppState 并注入所有生产依赖：LocalSpeechRecognizer、AudioRecorder、RealPermissionChecker、PunctuationService、AudioBackupService
- 使用 MenuBarExtra 以 .window 风格创建菜单栏弹窗，内容为 MenuBarView
- 菜单栏图标根据应用状态动态切换：录音中显示实心麦克风图标，其他状态显示空心麦克风图标
- 利用 .task 修饰符在菜单栏标签首次渲染时触发 appState.setup()（仅执行一次，通过检查 hotkeyManager 是否为 nil 守卫）
- 实现 RealPermissionChecker：调用 macOS 原生 AXIsProcessTrusted() 检查辅助功能权限

### 状态机/流程描述
无独立状态机，UI 状态完全由 AppState 驱动。

### 关键配置和限制条件
- @StateObject 用于 App 结构体中，确保 AppState 实例在应用生命周期内唯一
- MenuBarExtra 使用 .window 风格（弹窗式，非下拉菜单式）
- setup() 调用放在 label 的 .task 中（label 在应用启动时渲染），而非 content 的 .task 中（content 仅在菜单打开时渲染）
- 权限检查器作为值类型（struct）实现

### 与其他模块的依赖关系
- 创建并持有 AppState 实例
- 桥接 AppDelegate 处理应用生命周期事件
- 菜单栏内容委托给 MenuBarView
- 依赖所有核心服务的生产实现类

---

## 3. AppDelegate.swift

### 文件职责
应用启动时执行系统级检查：辅助功能权限引导和快捷键冲突检测。

### 已实现功能清单
- 应用启动完成后自动检查辅助功能权限
- 权限未授予时弹出引导对话框，提供两个选项：「打开系统设置」和「稍后设置」
- 用户选择「打开系统设置」时，通过 AXIsProcessTrustedWithOptions 触发系统权限弹窗
- 检测系统「选择上一个输入法」快捷键是否与 VoKey 的 Option+Space 冲突
- 冲突检测读取 com.apple.symbolichotkeys 中 key "61"（上一个输入法）的配置
- 解析快捷键参数：键码（keyCode=49 为空格）、修饰键（Option=0x80000）
- 仅在纯 Option+Space（不含 Command、Control 修饰键）时判定为冲突
- 冲突时弹出警告对话框，提供「打开键盘设置」和「我知道了」两个选项
- 通过 x-apple.systempreferences URL scheme 直接打开系统键盘快捷键设置页面

### 状态机/流程描述
启动流程（顺序执行）：
1. 检查辅助功能权限 -> 未授权则弹窗引导
2. 检查 Option+Space 快捷键冲突 -> 冲突则弹窗警告

### 关键配置和限制条件
- 所有检查在 applicationDidFinishLaunching 中同步执行
- 快捷键冲突检测依赖系统 UserDefaults 域 com.apple.symbolichotkeys 的数据格式
- 修饰键掩码：Option=0x80000(524288)、Command=0x100000、Control=0x40000
- 仅检测输入法切换快捷键（key "61"），不检测其他可能的系统快捷键冲突

### 与其他模块的依赖关系
- 通过 @NSApplicationDelegateAdaptor 被 VoKeyApp 桥接
- 无对其他应用模块的依赖
- 仅依赖 macOS 系统框架（AppKit、ApplicationServices）

---

## 4. Services/Protocols.swift

### 文件职责
定义所有核心服务的协议接口，作为依赖注入和测试解耦的基础契约。

### 已实现功能清单
- SpeechRecognizerProtocol：定义异步语音识别接口（输入采样数组和采样率，返回可选文本）和就绪状态属性
- AudioRecorderProtocol：定义录音启停接口（启动可抛异常，停止返回采样数组）和实时音频电平属性
- PermissionCheckerProtocol：定义辅助功能权限检查接口
- PunctuationServiceProtocol：定义标点添加接口和就绪状态属性
- AudioBackupProtocol：定义音频备份完整生命周期接口——是否有备份、开始备份、追加采样、完成并删除、恢复采样、删除备份

### 状态机/流程描述
无状态机，纯接口定义。

### 关键配置和限制条件
- 语音识别接口使用 async/await 异步模式
- 录音接口的 startRecording() 声明为可抛异常（throws）
- 音频电平属性为只读
- 所有协议仅包含最小必要接口，无默认实现
- 备份协议区分了"完成并删除"（正常流程）和"仅删除"（取消/异常流程）两种清理路径

### 与其他模块的依赖关系
- 被 AppState 通过构造函数注入引用
- 生产实现分布在各 Services 子目录中
- 测试 Mock 实现在 VoKeyTests/Mocks/TestMocks.swift 中

---

## 5. ContentView.swift

### 文件职责
早期技术验证视图（Spike），用于逐步验证六个核心集成点，非正式产品 UI。

### 已实现功能清单
- S1 模型加载：后台加载 Sherpa-ONNX Paraformer 模型（model.int8.onnx）和 tokens 文件，通过 NSString 保持 C 字符串引用存活避免悬空指针
- S2 WAV 文件识别：从 Bundle 读取测试音频文件（0.wav），通过 AVAudioFile 解析为 Float32 采样数组，调用识别器解码
- S3 麦克风录音：使用 AVAudioEngine 录音 2 秒，通过 AVAudioConverter 从系统原始格式转换为 16kHz 单声道 Float32，验证采样数量（期望约 32000）
- S4 录音并识别：录音 3 秒后自动停止，在后台线程执行识别并显示结果
- S5 粘贴到前台应用：将文本写入剪贴板，3 秒延迟后通过 CGEvent 模拟 Cmd+V 粘贴，粘贴完成 500ms 后恢复原剪贴板内容
- S6 全局快捷键：创建 CGEvent tap 监听 Option+Space，包含详细调试信息输出（AXIsProcessTrusted 状态、Bundle 信息、代码签名信息、Gatekeeper translocation 检测），支持 tap 超时自动恢复
- 全局快捷键使用 NotificationCenter 从回调线程安全传递到主线程
- 过滤键盘重复事件（autorepeat），仅响应纯 Option+Space（不含 Command/Control/Shift）

### 状态机/流程描述
无正式状态机。通过 @State 变量 isRecording 和 statusText 跟踪简单的操作状态。各验证步骤相互独立，可按任意顺序执行（S2/S4 依赖 S1 先加载模型）。

### 关键配置和限制条件
- 这是一个 Spike 验证视图，不参与正式产品流程
- 录音时长硬编码（S3: 2秒，S4: 3秒）
- S5 使用剪贴板中转方案（非最终产品的 CGEvent 直接输入方案）
- S6 中 kAXTrustedCheckOptionPrompt.takeRetainedValue() 每次调用会转移所有权，多次调用可能有内存问题
- CGEvent tap 回调中使用 Unmanaged.passRetained 可能存在内存泄漏（每次事件都增加引用计数）
- 窗口固定尺寸 500x600
- 模型配置硬编码：采样率 16000，特征维度 80，模型类型 "paraformer"

### 与其他模块的依赖关系
- 直接依赖 Sherpa-ONNX C/Swift 桥接接口（SherpaOnnxOfflineRecognizer 等）
- 依赖 AVFoundation 框架进行音频录制和格式转换
- 依赖 ApplicationServices 框架进行 CGEvent 操作
- 依赖 Security 框架进行代码签名信息查询
- 使用自定义 NotificationCenter 通知名 .hotkeyTriggered
- 不依赖 AppState 或任何协议抽象，属于独立验证代码

---

## 模块间依赖关系总览

```
VoKeyApp (入口)
  |-- AppDelegate (启动检查)
  |-- AppState (核心状态机)
  |     |-- SpeechRecognizerProtocol -> LocalSpeechRecognizer
  |     |-- AudioRecorderProtocol -> AudioRecorder
  |     |-- PermissionCheckerProtocol -> RealPermissionChecker (定义在 VoKeyApp.swift)
  |     |-- PunctuationServiceProtocol -> PunctuationService
  |     |-- AudioBackupProtocol -> AudioBackupService
  |     |-- HotkeyManager (直接创建)
  |     |-- TextOutputService (直接创建)
  |     |-- RecordingPanel (直接创建)
  |     +-- HistoryStore.shared (单例)
  +-- MenuBarView (菜单栏 UI)

ContentView (Spike 验证，独立于正式架构)
```
