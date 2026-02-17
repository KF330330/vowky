# 语音服务代码梳理报告

---

## 1. SpeechRecognizer.swift (LocalSpeechRecognizer)

### 文件职责
离线语音识别服务，将录音采样数据送入 SherpaOnnx Paraformer 模型进行语音转文字。

### 已实现功能清单
- 加载离线 Paraformer 语音识别模型（支持自定义路径或默认从 Bundle.main 加载）
- 接受 Float 采样数组和采样率，异步返回识别文本
- 通过 isReady 属性对外暴露模型是否就绪
- 空采样数组或模型未加载时安全返回 nil

### 技术规格
- 模型类型：Paraformer（modelType: "paraformer"）
- 模型文件：model.int8.onnx（INT8 量化）
- 词表文件：tokens.txt
- 采样率：16000 Hz
- 特征维度：80 维
- 调试模式：关闭（debug: 0）
- 推理方式：离线（Offline）模式，一次性送入全部采样解码

### 回退/容错机制
- 模型路径为空或文件不存在时，loadModel 静默返回，不会触发 fatalError
- 将模型路径字符串保存为实例属性，避免传递给 C API 时出现悬垂指针
- 识别结果为空字符串时返回 nil，上层可据此判断识别失败

### 与其他模块的依赖关系
- 实现 SpeechRecognizerProtocol 协议（定义在 Protocols.swift）
- 依赖 SherpaOnnx 层的 SherpaOnnxOfflineRecognizer 类及相关配置工厂函数
- 被 AppState 在识别阶段调用

---

## 2. AudioRecorder.swift

### 文件职责
使用 AVAudioEngine 捕获麦克风输入，将音频重采样为 16kHz 单声道 Float32 格式并缓存采样数据。

### 已实现功能清单
- 启动录音：创建 AVAudioEngine，安装音频 tap 实时捕获缓冲区
- 停止录音：停止引擎，移除 tap，返回累积的全部采样数据
- 实时音频重采样：通过 AVAudioConverter 将麦克风原始格式转为目标格式
- 实时计算 RMS 音量等级（audioLevel 属性）
- 实时将采样数据追加写入备份服务（内容保护）
- 支持测试模式：通过环境变量 VOKEY_TEST_AUDIO 从指定目录加载 WAV 文件替代麦克风输入

### 技术规格
- 目标采样率：16000 Hz
- 目标格式：PCM Float32，单声道，非交错
- 录音缓冲区大小：4096 帧
- 音量计算：RMS（均方根）算法
- 线程安全：使用 NSLock 保护 recordedSamples 数组

### 回退/容错机制
- 格式创建失败、转换器创建失败、引擎启动失败均抛出具体的 AudioRecorderError 枚举错误
- stopRecording 时若引擎不存在（未启动或已停止）安全返回空数组
- 测试音频目录无 WAV 文件时抛出 testAudioNotFound 错误

### 与其他模块的依赖关系
- 实现 AudioRecorderProtocol 协议
- 持有可选的 AudioBackupProtocol 引用（backupService），录音过程中实时写入备份
- 被 AppState 在录音阶段调用启停

---

## 3. PunctuationService.swift

### 文件职责
加载离线标点预测模型，为语音识别输出的纯文本自动添加标点符号。

### 已实现功能清单
- 加载 CT-Transformer 标点预测模型（支持自定义路径或默认从 Bundle.main 加载）
- 对输入文本添加标点符号，返回加标点后的文本
- 通过 isReady 属性对外暴露模型是否就绪
- 模型未加载时直接返回原文（降级为无标点）

### 技术规格
- 模型类型：CT-Transformer（离线标点模型）
- 模型文件：punct-model.onnx
- 推理方式：离线，同步调用

### 回退/容错机制
- 模型路径为空或文件不存在时打印警告并静默返回，不加载模型
- 创建 wrapper 后检查内部指针是否为 nil，失败则将 wrapper 置空
- 模型未就绪时 addPunctuation 返回原文，不中断流程
- 将模型路径保存为实例属性，避免 C 层悬垂指针

### 与其他模块的依赖关系
- 实现 PunctuationServiceProtocol 协议
- 依赖 SherpaOnnx 层的 SherpaOnnxOfflinePunctuationWrapper 及相关配置工厂函数
- 被 AppState 在识别完成后、文本输出前调用

---

## 4. AudioBackupService.swift

### 文件职责
录音过程中将采样数据实时写入 WAV 备份文件，用于崩溃恢复和内容保护。

### 已实现功能清单
- 启动备份：删除旧备份，创建新 WAV 文件并写入 44 字节标准头
- 追加采样：将 Float32 采样数据以追加方式写入文件尾部
- 完成并删除：更新 WAV 头中的文件大小字段后关闭并删除备份文件
- 恢复采样：从备份 WAV 文件读取全部 PCM 采样数据（跳过 44 字节头）
- 删除备份：关闭文件句柄并移除备份文件
- 通过 hasBackup 属性查询备份文件是否存在

### 技术规格
- 备份格式：标准 WAV 文件（RIFF/WAVE）
- 音频格式标识：3（IEEE Float）
- 采样率：16000 Hz
- 位深度：32 位（Float32）
- 声道数：1（单声道）
- 字节率：64000 字节/秒
- 块对齐：4 字节
- WAV 头大小：44 字节
- 默认备份目录：系统临时目录
- 备份文件名：vokey_recording_backup.wav

### 回退/容错机制
- WAV 头实时更新：在 finalizeAndDelete 时回写 RIFF chunk 大小和 data chunk 大小，保证中途崩溃后文件仍可被大部分播放器识别
- 恢复时验证数据量：文件小于 44 字节（仅有头部）则返回 nil
- 文件删除使用 try? 容错，删除失败不抛异常
- 支持自定义备份目录（构造器参数），便于测试

### 与其他模块的依赖关系
- 实现 AudioBackupProtocol 协议
- 被 AudioRecorder 在录音过程中通过 appendSamples 实时调用
- 被 AppState 在启动时检查是否有待恢复的备份、在录音取消或完成时调用删除

---

## 5. SherpaOnnx.swift

### 文件职责
SherpaOnnx C 语言 API 的 Swift 封装层，提供语音识别、VAD、TTS、标点、说话人分离等全部底层能力的配置构造和资源管理。

### 已实现功能清单

**基础工具**
- toCPointer：将 Swift String 转为 C 层 const char* 指针

**在线（流式）语音识别**
- 配置构造：Transducer、Paraformer、Zipformer2CTC、NemoCTC、ToneCTC 等多种在线模型配置
- 在线模型总配置：支持 tokens、线程数、provider、debug、modelType、建模单元、BPE 词表等参数
- 特征配置：采样率与特征维度
- CTC FST 解码器配置
- 同音替换配置
- 在线识别器配置：支持端点检测（三条规则）、贪心搜索/活跃路径、热词文件与评分、空白惩罚
- SherpaOnnxRecognizer 类：流式识别器，支持 acceptWaveform、decode、getResult、reset（含热词重建流）、inputFinished、isEndpoint
- SherpaOnnxOnlineRecongitionResult 类：封装在线识别结果，包含 text、tokens、timestamps、count

**离线语音识别**
- 配置构造：Transducer、Paraformer、ZipformerCTC、WenetCTC、OmnilingualASR CTC、MedASR CTC、NemoEncDecCTC、Dolphin、Whisper、Canary、FireRedASR、Moonshine、TDNN、SenseVoice、FunASR Nano 等 15+ 种离线模型配置
- 离线模型总配置：覆盖上述全部模型类型
- 语言模型配置：支持外部 LM 模型及 scale 参数
- 离线识别器配置：贪心搜索、活跃路径、热词、规则 FST、空白惩罚、同音替换
- SherpaOnnxOfflineRecognizer 类：离线识别器，接受采样数据一次性解码并返回结果
- SherpaOnnxOfflineRecongitionResult 类：封装离线识别结果，包含 text、timestamps、durations、lang、emotion、event、段级别时间戳与文本

**语音活动检测（VAD）**
- Silero VAD 模型配置：阈值、最小静音时长、最小语音时长、窗口大小、最大语音时长
- TEN VAD 模型配置
- VAD 总配置
- SherpaOnnxCircularBufferWrapper：环形缓冲区，支持 push、get、pop、size、reset
- SherpaOnnxSpeechSegmentWrapper：语音段封装，包含 start、n、samples
- SherpaOnnxVoiceActivityDetectorWrapper：VAD 检测器，支持 acceptWaveform、isEmpty、isSpeechDetected、pop、clear、front、reset、flush

**离线 TTS（语音合成）**
- 配置构造：VITS、Matcha、Kokoro、Kitten、Zipvoice、Pocket 等 6 种 TTS 模型配置
- TTS 总模型配置与总配置
- SherpaOnnxOfflineTtsWrapper 类：支持普通生成、带回调生成、带进度回调与配置生成
- SherpaOnnxGeneratedAudioWrapper：音频结果封装，支持保存为文件
- SherpaOnnxGenerationConfigSwift / SherpaOnnxGenerationConfigC：TTS 生成配置（静音缩放、速度、说话人 ID、参考音频/文本、步数、extra JSON）
- SherpaOnnxWaveWrapper：WAV 文件读取

**标点恢复**
- 离线标点配置：CT-Transformer 模型
- SherpaOnnxOfflinePunctuationWrapper 类：离线标点添加
- 在线标点配置：CNN-BiLSTM 模型 + BPE 词表
- SherpaOnnxOnlinePunctuationWrapper 类：在线标点添加

**口语语言识别**
- 配置构造：基于 Whisper 的口语语言识别
- SherpaOnnxSpokenLanguageIdentificationWrapper 类：接受采样，返回检测到的语言代码

**关键词检测**
- 配置构造：支持关键词文件、评分、阈值、trailing blanks
- SherpaOnnxKeywordSpotterWrapper 类：支持流式关键词检测

**说话人嵌入与分离**
- 说话人嵌入提取器配置与 Wrapper
- Pyannote 说话人分割模型配置
- 快速聚类配置
- SherpaOnnxOfflineSpeakerDiarizationWrapper 类：离线说话人分离，返回按时间排序的段列表

**语音降噪**
- GTCRN 模型配置
- SherpaOnnxOfflineSpeechDenoiserWrapper 类：离线语音降噪

**版本信息**
- 获取 SherpaOnnx 版本号、Git SHA1、Git 日期

### 技术规格
- 所有 Wrapper 类通过 OpaquePointer 持有 C 层对象，在 deinit 中自动释放
- 默认采样率：16000 Hz（贯穿全部模块）
- 默认特征维度：80
- 默认推理线程数：1
- 默认 provider：cpu
- 字符串传递：统一通过 toCPointer 将 Swift String 转为 C 指针
- 在线识别器 SherpaOnnxRecognizer 内部使用 NSLock 保护 stream 替换操作

### 回退/容错机制
- 多数 Wrapper 的 init 在底层 C 函数返回 nil 时触发 fatalError（设计决策：模型文件必须存在）
- 上层调用方（如 LocalSpeechRecognizer.loadModel）在调用前进行文件存在性检查以规避 fatalError
- deinit 中的 C 资源释放均用 if let 守护，避免对 nil 指针调用销毁函数
- SherpaOnnxCircularBufferWrapper.get 对负 startIndex 或非正 n 返回空数组

### 与其他模块的依赖关系
- 依赖 SherpaOnnx C 库（通过 Bridging Header SherpaOnnx-Bridging-Header.h 引入）
- 被 LocalSpeechRecognizer 直接使用（离线 Paraformer 识别器）
- 被 PunctuationService 直接使用（离线标点 Wrapper）
- 文件本身不依赖项目中的其他 Swift 模块，是纯粹的底层封装层
