# VoKey 系统服务层代码审阅报告

## 1. HotkeyManager.swift

### 文件职责
全局快捷键监听与事件分发，负责拦截系统级键盘事件并将快捷键动作回调到主线程。

### 已实现功能清单
- 通过 CGEvent Tap 创建系统级全局键盘事件监听
- 监听 keyDown、keyUp、flagsChanged 三类键盘事件
- 快捷键按下时触发 onHotkeyPressed 回调（仅 keyDown 触发，Toggle 模式）
- 快捷键 keyUp 事件被静默吞没，不传递给系统
- 录音过程中按下 Escape 键触发 onCancelPressed 回调
- 通过 shouldInterceptCancel 闭包动态判断是否拦截 Escape 事件
- 事件 Tap 的启动（start）和停止（stop）管理
- 通过 isRunning 属性查询当前监听状态
- 在 deinit 时自动调用 stop 清理资源

### 技术规格
- 事件动作枚举：hotkeyDown / hotkeyUp / cancelRecording / passThrough
- 修饰键模型：支持 Option、Command、Control、Shift 四个修饰键的任意组合
- 纯函数评估器（HotkeyEvaluator）：将事件判定逻辑抽离为无副作用的静态方法，便于单元测试
- Escape 键码：硬编码为 53
- 事件拦截方式：回调返回 nil 来吞没事件，返回 Unmanaged CGEvent 来放行事件
- 回调上下文：通过 UnsafeMutablePointer 包装 HotkeyTapContext 结构体传递上下文

### 容错机制
- 重复调用 start() 时直接返回 true，防止重复创建 Tap
- CGEvent Tap 创建失败时释放已分配的指针内存并返回 false
- tapDisabledByTimeout 事件自动恢复（重新启用 Tap）
- 忽略键盘重复事件（isRepeat），避免连续触发
- stop() 中正确清理 RunLoop Source、禁用 Tap、释放指针内存

### 依赖关系
- 依赖 HotkeyConfig.current 获取当前快捷键配置
- 被 AppState（状态机）持有和调用
- 回调通过闭包注入，与具体业务逻辑解耦

---

## 2. HotkeyConfig.swift

### 文件职责
快捷键配置的数据模型，负责快捷键设置的存储、读取和展示。

### 已实现功能清单
- 定义快捷键配置结构：键码 + 四个修饰键（Option/Command/Control/Shift）
- 从 UserDefaults 读取已保存的快捷键配置
- 将快捷键配置保存到 UserDefaults
- 无已保存配置时返回默认配置
- 生成快捷键的人类可读显示名称（如 ⌥Space）
- 提供完整的 macOS 虚拟键码到可读键名的映射表

### 技术规格
- 默认快捷键：Option + Space（keyCode = 49，needsOption = true，其余 false）
- UserDefaults 键名：hotkey_keyCode / hotkey_option / hotkey_command / hotkey_control / hotkey_shift
- 显示名称格式：修饰键符号按 Control -> Option -> Shift -> Command 顺序排列，后接键名
- 键名映射覆盖范围：字母键 A-Z、数字键 0-9、功能键 F1-F13、方向键、常用特殊键（Tab/Space/Delete/Esc/Return 等）
- 未映射键码：显示为 Key{keyCode} 格式

### 容错机制
- 读取配置时先检查 UserDefaults 中是否存在 keyCodeKey，不存在则返回默认值，避免读取到零值
- keyName 映射未命中时提供 fallback 格式

### 依赖关系
- 被 HotkeyEvaluator 在事件判定时读取（HotkeyConfig.current）
- 被设置界面读取和写入
- 无外部依赖，纯数据模型

---

## 3. TextOutputService.swift

### 文件职责
将识别结果文本通过模拟键盘事件插入到当前光标位置，不依赖剪贴板。

### 已实现功能清单
- 将任意字符串通过 CGEvent 键盘模拟插入到当前活跃应用的光标位置
- 支持完整 Unicode 文本（包括中文、Emoji 等多字节字符）
- 分块发送长文本，每次最多 20 个 UTF-16 编码单元
- 每个分块同时发送 keyDown 和 keyUp 事件以模拟完整按键

### 技术规格
- 事件源：使用 CGEventSource 的 hidSystemState 状态
- 分块大小：20 个 UTF-16 code units（CGEvent 单次支持上限）
- 投递层级：cghidEventTap
- 虚拟键码：统一使用 0（因为实际字符通过 Unicode 字符串设置）
- 编码方式：Swift String 转 UTF-16 数组，再通过 CGEvent keyboardSetUnicodeString 设置

### 容错机制
- CGEvent 创建结果使用可选链调用，创建失败不会崩溃

### 依赖关系
- 需要系统辅助功能权限（Accessibility Permission）才能生效
- 被 AppState 在识别完成后调用
- 无其他模块依赖，完全独立

---

## 4. HistoryStore.swift

### 文件职责
基于 SQLite3 的本地历史记录持久化存储，提供输入历史的增删查统计功能。

### 已实现功能清单
- 打开/创建 SQLite 数据库文件（自动创建目录和表结构）
- 插入历史记录（内容 + 来源类型 + 时间戳）
- 查询全部历史记录（支持分页限制）
- 按关键词模糊搜索历史记录（LIKE 匹配）
- 按 ID 删除单条历史记录
- 清空全部历史记录
- 查询历史记录总数
- 采用单例模式（shared）全局共享实例

### 技术规格
- 数据库路径：~/Library/Application Support/VoKey/history.db
- 表结构：input_history 表，字段为 id（自增主键）、content（文本，非空）、source_type（文本，默认 voice）、created_at（实数，Unix 时间戳）
- 数据模型：HistoryRecord 结构体，遵循 Identifiable 协议，包含 id / content / sourceType / createdAt
- 默认来源类型：voice
- 默认查询上限：500 条
- 排序规则：按 created_at 降序（最新在前）
- 搜索方式：content LIKE 模糊匹配

### 容错机制
- open() 重复调用时通过 guard 检查 db 是否已打开，防止重复打开
- 数据库打开失败时打印日志并提前返回
- 所有数据库操作（insert/fetch/delete/count）在 db 为 nil 时直接返回默认值
- SQL prepare 失败时直接返回，不会崩溃
- 使用 defer 确保 sqlite3_finalize 总是被调用，防止内存泄漏
- 自动创建 Application Support/VoKey 目录

### 依赖关系
- 使用 SQLite3 C API（系统自带，无第三方依赖）
- 被 AppState 在识别完成后调用写入
- 被历史记录界面调用查询和删除
- 无其他模块依赖

---

## 5. APIClient.swift

### 文件职责
为未来的在线 API 集成预留的占位文件。

### 已实现功能清单
- 当前无实际功能实现

### 技术规格
- 仅导入 Foundation 框架
- 注释标注对应 MVP 计划第 6.6 节
- 预留用于在线语音识别服务的集成

### 容错机制
- 不适用（无实现代码）

### 依赖关系
- 不适用（无实现代码）
