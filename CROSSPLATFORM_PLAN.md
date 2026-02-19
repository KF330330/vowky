# VowKy 跨平台迁移方案：Rust + Tauri（macOS + Windows）

## Context

VowKy 当前是一款纯 macOS 菜单栏语音输入工具（Swift + SwiftUI + AppKit），深度绑定 macOS API（CGEvent、AVAudioEngine、NSPanel、MenuBarExtra 等）。用户决定采用 **Rust + Tauri** 技术路线重构为跨平台版本，同时支持 macOS 和 Windows，**Windows 版功能对齐后再上线**。

核心目标：将 12 项已实现功能全部迁移到 Tauri，保持相同的用户体验，同时获得跨平台能力。

---

## 一、技术选型

| 层 | 技术 | 理由 |
|----|------|------|
| 后端 | **Rust** | 性能最优，内存安全，sherpa-onnx C FFI 原生支持 |
| 框架 | **Tauri v2** | 体积小（~40MB），原生系统托盘/快捷键插件，双平台支持 |
| 前端 | **Svelte + Vite + Tailwind** | 无运行时开销，编译为原生 DOM，适合轻量桌面 UI |
| 语音识别 | **sherpa-onnx C API → Rust FFI** | 已有 macOS/Windows 预编译库，C API 跨平台 |
| 音频录制 | **cpal + rubato** | cpal 统一 CoreAudio/WASAPI，rubato 做 16kHz 重采样 |
| 键盘模拟 | macOS: **core-graphics** CGEvent / Windows: **enigo** SendInput | 各平台最可靠方案 |
| 数据库 | **rusqlite** | SQLite 跨平台，表结构与 Swift 版兼容 |
| 全局快捷键 | **tauri-plugin-global-shortcut** | Tauri 官方插件，双平台统一 API |
| 系统托盘 | **Tauri 内置 tray** | 官方支持，菜单自定义 |
| 开机自启 | **tauri-plugin-autostart** | 官方插件 |

---

## 二、项目结构

```
vowky-tauri/
├── src-tauri/                        # Rust 后端
│   ├── Cargo.toml
│   ├── build.rs                      # sherpa-onnx 链接配置（cfg target_os 切换）
│   ├── tauri.conf.json               # 窗口/插件/权限配置
│   ├── resources/models/             # model.int8.onnx + tokens.txt + punct-model.onnx
│   ├── libs/
│   │   ├── macos/                    # libsherpa-onnx.a + libonnxruntime.a
│   │   └── windows/                  # sherpa-onnx.lib + onnxruntime.lib
│   └── src/
│       ├── main.rs                   # Tauri 入口，插件注册
│       ├── commands.rs               # #[tauri::command] 前后端桥接（唯一通信层）
│       ├── state.rs                  # AppState 5 状态机（RwLock 替代 @MainActor）
│       ├── error.rs                  # 统一错误类型
│       ├── engine/                   # 纯 Rust 核心引擎（不依赖 Tauri）
│       │   ├── recognizer.rs         # sherpa-onnx 离线识别封装
│       │   ├── punctuation.rs        # CT-Transformer 标点恢复
│       │   ├── audio_backup.rs       # WAV 实时备份与崩溃恢复
│       │   └── history.rs            # SQLite CRUD（rusqlite）
│       ├── platform/                 # 跨平台适配层（trait + cfg）
│       │   ├── mod.rs                # trait 定义 + 工厂函数
│       │   ├── macos/                # CoreAudio + CGEvent + AXIsProcessTrusted
│       │   └── windows/              # WASAPI + SendInput + 无需权限检查
│       └── sherpa_ffi/               # sherpa-onnx C API Rust 绑定
│           ├── bindings.rs           # extern "C" 声明（手写，精确对齐 c-api.h）
│           └── safe_wrapper.rs       # 安全 Rust 封装（CString 生命周期管理）
│
├── src/                              # Svelte 前端
│   ├── App.svelte
│   ├── lib/
│   │   ├── stores/                   # appState.ts / history.ts / settings.ts
│   │   └── api/commands.ts           # Tauri invoke 类型化封装
│   └── components/
│       ├── RecordingPanel.svelte     # 录音浮窗 260x80（毛玻璃 + 脉冲动画）
│       ├── TrayMenu.svelte           # 托盘弹窗菜单
│       ├── HistoryWindow.svelte      # 识别历史（搜索/删除/清空）
│       └── SettingsWindow.svelte     # 设置（快捷键/权限/自启动）
└── package.json
```

**关键边界**：
- `commands.rs` 是前后端唯一桥梁
- `engine/` 纯 Rust，可独立测试，不依赖 Tauri
- `platform/` 通过 trait 抽象，`cfg(target_os)` 条件编译切换实现

---

## 三、跨平台适配层设计

三个需要平台适配的 trait：

| trait | macOS 实现 | Windows 实现 |
|-------|-----------|-------------|
| `AudioCapture` | cpal (CoreAudio) + rubato 重采样 | cpal (WASAPI) + rubato 重采样 |
| `TextOutput` | core-graphics CGEvent + UTF-16 分块（20 单元） | enigo SendInput |
| `PermissionChecker` | FFI 调用 AXIsProcessTrusted() | 直接返回 true（无需特殊权限） |

工厂函数通过 `cfg(target_os)` 返回对应平台实现，上层代码完全平台无关。

**Windows 特殊适配**：
- 默认快捷键改为 **Ctrl+Shift+Space**（Alt+Space 是 Windows 系统快捷键）
- 录音浮窗毛玻璃用 Mica/Acrylic（window-vibrancy crate）
- 系统托盘位于任务栏右下角（Tauri 自动适配）
- 开机自启用注册表（tauri-plugin-autostart 自动处理）

---

## 四、开发里程碑（共 10 周）

### M0：项目初始化（第 1 周）
- 创建 Tauri v2 + Svelte 脚手架
- 下载 sherpa-onnx macOS/Windows 预编译库，build.rs 链接验证
- CI 配置（GitHub Actions：macOS + Windows 双平台构建）
- **验证**：`cargo tauri dev` 启动空白窗口，双平台 `cargo build` 通过

### M1：核心引擎移植（第 2-3 周）
- sherpa_ffi/ C API 绑定（离线识别 + 标点恢复）
- engine/ 全部模块：recognizer、punctuation、history、audio_backup
- 单元测试覆盖
- **验证**：对测试 WAV 输出正确识别结果，SQLite/WAV 格式与 Swift 版兼容

### M2：macOS 平台适配（第 4-5 周）
- platform/macos/ 全部实现（audio_capture、text_output、permission）
- state.rs 状态机 + commands.rs 全部命令
- **验证**：通过 Tauri command 完成 录音→识别→文字插入 TextEdit 全流程

### M3：macOS UI 完成（第 6-7 周）
- 全部 Svelte 组件：RecordingPanel、TrayMenu、HistoryWindow、SettingsWindow
- 全局快捷键 + Escape 取消 + 快捷键自定义 + 冲突检测
- 开机自启 + 权限引导
- **验证**：功能 100% 对齐 Swift 原版 12 项功能

### M4：Windows 平台适配（第 8-9 周）
- platform/windows/ 全部实现
- Windows 安装包（.msi + NSIS）
- UI 适配（托盘位置、浮窗位置、Acrylic 效果）
- **验证**：Windows 上完整流程可用，安装/卸载正常

### M5：质量保证 + 发布（第 10 周）
- 双平台端到端测试
- 错误处理完善 + 日志系统（tracing crate）
- macOS .dmg + Windows .msi 签名
- **验证**：无 crash，启动 < 3s，安装包 < 100MB

---

## 五、5 人团队分工

| 角色 | 职责 | 负责模块 |
|------|------|----------|
| **P1 Tech Lead** | 架构决策、代码评审、集成协调 | state.rs、commands.rs、main.rs、build.rs、CI |
| **P2 Rust 核心** | 引擎层实现、FFI 绑定 | engine/*、sherpa_ffi/* |
| **P3 平台适配** | 跨平台 trait 实现、原生 API | platform/macos/*、platform/windows/* |
| **P4 前端开发** | Svelte UI、Tauri 窗口管理、CSS 动画 | src/ 前端全部 |
| **P5 QA/DevOps** | 测试、CI/CD、安装包、兼容性 | 测试文件、CI 配置、installer |

### 各阶段分配

| 阶段 | P1 | P2 | P3 | P4 | P5 |
|------|----|----|----|----|-----|
| M0 | 脚手架+配置 | sherpa-onnx 链接验证 | cpal 可行性验证 | Svelte 初始化 | CI 配置 |
| M1 | 状态机+评审 | FFI 绑定+识别器+标点 | 备份+历史（协助P2） | UI 组件骨架（mock数据） | 引擎单元测试 |
| M2 | commands.rs+集成 | 性能优化 | macOS 全部适配 | 对接后端真实数据 | 集成测试 |
| M3 | 快捷键+冲突检测 | 模型加载优化 | 开机自启+权限引导 | 全部窗口UI | macOS 端到端测试 |
| M4 | Windows 集成协调 | Windows sherpa-onnx | Windows 全部适配 | Windows UI 适配 | Windows 安装包+测试 |
| M5 | 最终评审+发布 | 内存泄漏排查 | 边缘场景处理 | UI 微调 | 签名+公证+发布 |

---

## 六、风险与缓解

| 风险 | 严重性 | 缓解措施 |
|------|--------|----------|
| sherpa-onnx C 结构体字段与 Rust #[repr(C)] 不匹配 → segfault | 高 | M1 用 offsetof() 逐字段验证偏移量 |
| cpal 重采样精度影响识别率 | 中 | 同段录音对比 Swift 版和 Rust 版识别结果 |
| CGEvent 键盘模拟在 Rust core-graphics crate 中缺少 setUnicodeString | 中 | 先验证 API；降级方案用 objc2 FFI 直接调用 |
| Tauri 浮窗抢焦点（不支持 NSPanel nonactivating） | 中 | 自定义插件通过 objc2 转为 NSPanel；或设为不可交互 |
| Windows sherpa-onnx 静态库 MSVC 版本不兼容 | 中 | M0 即验证 Windows 链接；降级用动态链接 .dll |
| Alt+Space 是 Windows 系统快捷键 | 低 | Windows 默认改为 Ctrl+Shift+Space |
| 安装包含模型过大（~200MB） | 低 | ZSTD 压缩模型；或首次启动下载 |

---

## 七、验证方式

1. **引擎层**：Rust 单元测试（cargo test），对比 Swift 版识别结果
2. **平台适配**：独立测试二进制验证 CGEvent/SendInput/cpal
3. **UI**：`cargo tauri dev` 手动验证所有交互流程
4. **端到端**：在 TextEdit (macOS) / Notepad (Windows) 中完成 快捷键→录音→识别→文字插入 全流程
5. **回归**：与 Swift 原版逐功能对比，12 项功能全部 pass

---

## 八、关键参考文件

| 文件 | 用途 |
|------|------|
| `VowKy/VowKy/AppState.swift` | 状态机逻辑，迁移到 state.rs |
| `VowKy/VowKy/Services/Protocols.swift` | 5 个协议 → 5 个 Rust trait |
| `VowKy/VowKy/SherpaOnnx/SherpaOnnx.swift` | 1892 行 FFI 封装，Rust 绑定字段顺序参考 |
| `VowKy/VowKy/Services/TextOutputService.swift` | CGEvent UTF-16 分块逻辑，Rust 版精确复刻 |
| `VowKy/VowKy/Services/AudioBackupService.swift` | WAV 格式处理，Rust 版直接翻译 |
| `Libraries/sherpa-onnx.xcframework/.../c-api.h` | C API 头文件，Rust #[repr(C)] 字段顺序权威来源 |
| `PRD_VowKy_V1.1.md` | 12 项已实现功能清单，验收标准 |
