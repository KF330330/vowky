import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var statusText = "就绪"
    @State private var resultText = ""
    @State private var isRecording = false

    // sherpa-onnx recognizer
    @State private var recognizer: SherpaOnnxOfflineRecognizer?

    // Audio recording
    @State private var audioEngine: AVAudioEngine?
    @State private var recordedSamples: [Float] = []

    // CGEvent tap for global hotkey
    @State private var eventTapPort: CFMachPort?
    @State private var hotkeyTriggered = false

    var body: some View {
        VStack(spacing: 16) {
            Text("VowKy Spike — 6 集成点验证")
                .font(.title2)
                .bold()

            Divider()

            // S1: 模型加载
            Button("S1: 加载模型") {
                loadModel()
            }

            // S2: WAV 文件识别
            Button("S2: 识别测试音频") {
                recognizeTestWav()
            }

            // S3: 麦克风录音
            Button("S3: 录音 2 秒") {
                recordTwoSeconds()
            }

            // S4: 录音并识别
            Button("S4: 录音并识别") {
                recordAndRecognize()
            }

            // S5: 粘贴到前台应用
            Button("S5: 粘贴到前台应用") {
                pasteToFrontApp()
            }

            // S6: 全局快捷键
            Button("S6: 启动全局快捷键 (Option+Space)") {
                startGlobalHotkey()
            }

            Divider()

            Text("状态: \(statusText)")
                .foregroundColor(.secondary)

            ScrollView {
                Text(resultText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 150)
            .border(Color.gray.opacity(0.3))

            if hotkeyTriggered {
                Text("快捷键触发！")
                    .font(.title)
                    .foregroundColor(.green)
                    .bold()
            }
        }
        .padding(24)
        .frame(width: 500, height: 600)
    }

    // MARK: - S1: 加载模型

    private func loadModel() {
        statusText = "正在加载模型..."

        DispatchQueue.global(qos: .userInitiated).async {
            let modelPath = Bundle.main.path(forResource: "model.int8", ofType: "onnx") ?? ""
            let tokensPath = Bundle.main.path(forResource: "tokens", ofType: "txt") ?? ""

            // 保持字符串存活 — 关键：避免 C 字符串悬空指针
            let modelPathNS = modelPath as NSString
            let tokensPathNS = tokensPath as NSString

            guard !modelPath.isEmpty, !tokensPath.isEmpty else {
                DispatchQueue.main.async {
                    statusText = "模型文件未找到！"
                    resultText = "model path: \(modelPath)\ntokens path: \(tokensPath)"
                }
                return
            }

            let paraformerConfig = sherpaOnnxOfflineParaformerModelConfig(
                model: modelPath
            )

            let modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: tokensPath,
                paraformer: paraformerConfig,
                debug: 1,
                modelType: "paraformer"
            )

            let featConfig = sherpaOnnxFeatureConfig(
                sampleRate: 16000,
                featureDim: 80
            )

            var config = sherpaOnnxOfflineRecognizerConfig(
                featConfig: featConfig,
                modelConfig: modelConfig
            )

            let rec = SherpaOnnxOfflineRecognizer(config: &config)

            // 保持引用
            _ = modelPathNS
            _ = tokensPathNS

            DispatchQueue.main.async {
                self.recognizer = rec
                statusText = "模型加载成功！isReady = true"
                resultText += "✅ S1: 模型加载完成\n"
            }
        }
    }

    // MARK: - S2: 识别测试 WAV

    private func recognizeTestWav() {
        guard let rec = recognizer else {
            statusText = "请先加载模型 (S1)"
            return
        }

        statusText = "正在识别测试音频..."

        DispatchQueue.global(qos: .userInitiated).async {
            guard let wavPath = Bundle.main.path(forResource: "0", ofType: "wav") else {
                DispatchQueue.main.async {
                    statusText = "测试音频文件未找到！"
                }
                return
            }

            let fileURL = URL(fileURLWithPath: wavPath)
            guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
                DispatchQueue.main.async {
                    statusText = "无法读取音频文件"
                }
                return
            }

            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                DispatchQueue.main.async {
                    statusText = "无法创建音频缓冲区"
                }
                return
            }

            try? audioFile.read(into: buffer)

            // 提取 Float32 样本
            guard let channelData = buffer.floatChannelData else {
                DispatchQueue.main.async {
                    statusText = "无法获取音频数据"
                }
                return
            }

            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(buffer.frameLength)
            ))

            let result = rec.decode(samples: samples, sampleRate: Int(format.sampleRate))

            DispatchQueue.main.async {
                let text = result.text
                resultText += "✅ S2: \"\(text)\"\n"
                statusText = "识别完成"
            }
        }
    }

    // MARK: - S3: 麦克风录音 2 秒

    private func recordTwoSeconds() {
        statusText = "录音中 (2秒)..."
        isRecording = true
        recordedSamples = []

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // 目标: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            statusText = "无法创建目标格式"
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            statusText = "无法创建格式转换器 (from: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch)"
            return
        }

        var allSamples: [Float] = []

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // 转换为 16kHz mono
            let ratio = 16000.0 / inputFormat.sampleRate
            let outputFrameCount = UInt32(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let data = outputBuffer.floatChannelData {
                let samples = Array(UnsafeBufferPointer(
                    start: data[0],
                    count: Int(outputBuffer.frameLength)
                ))
                allSamples.append(contentsOf: samples)
            }
        }

        do {
            try engine.start()
        } catch {
            statusText = "录音启动失败: \(error.localizedDescription)"
            return
        }

        self.audioEngine = engine

        // 2 秒后停止
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            engine.stop()
            inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
            self.isRecording = false
            self.recordedSamples = allSamples

            let count = allSamples.count
            statusText = "录音完成"
            resultText += "✅ S3: 样本数=\(count) (期望~32000, 范围28000-36000)\n"
        }
    }

    // MARK: - S4: 录音并识别

    private func recordAndRecognize() {
        guard let rec = recognizer else {
            statusText = "请先加载模型 (S1)"
            return
        }

        statusText = "录音中 (3秒)... 请说话"
        isRecording = true
        recordedSamples = []

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            statusText = "无法创建目标格式"
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            statusText = "无法创建格式转换器"
            return
        }

        var allSamples: [Float] = []

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let ratio = 16000.0 / inputFormat.sampleRate
            let outputFrameCount = UInt32(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let data = outputBuffer.floatChannelData {
                let samples = Array(UnsafeBufferPointer(
                    start: data[0],
                    count: Int(outputBuffer.frameLength)
                ))
                allSamples.append(contentsOf: samples)
            }
        }

        do {
            try engine.start()
        } catch {
            statusText = "录音启动失败: \(error.localizedDescription)"
            return
        }

        self.audioEngine = engine

        // 3 秒后停止并识别
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            engine.stop()
            inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
            self.isRecording = false

            statusText = "识别中..."

            DispatchQueue.global(qos: .userInitiated).async {
                let result = rec.decode(samples: allSamples, sampleRate: 16000)
                DispatchQueue.main.async {
                    let text = result.text
                    resultText += "✅ S4: \"\(text)\" (样本数:\(allSamples.count))\n"
                    statusText = "识别完成"
                }
            }
        }
    }

    // MARK: - S5: 粘贴到前台应用

    private func pasteToFrontApp() {
        let textToPaste = resultText.isEmpty ? "VowKy 测试文本" : String(resultText.suffix(50))

        // 保存当前剪贴板
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        let oldChangeCount = pasteboard.changeCount

        // 写入新文本
        pasteboard.clearContents()
        pasteboard.setString(textToPaste, forType: .string)

        // 验证写入
        let newChangeCount = pasteboard.changeCount
        guard newChangeCount != oldChangeCount else {
            statusText = "剪贴板写入失败"
            return
        }

        statusText = "3秒后粘贴，请切换到 TextEdit..."
        resultText += "📋 S5: 已写入剪贴板，3秒后模拟 Cmd+V...\n"

        // 3 秒延迟，让用户切换到目标 App
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            // 模拟 Cmd+V
            let source = CGEventSource(stateID: .hidSystemState)

            // Key down: V with Cmd
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = V
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            // Key up
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)

            // 恢复剪贴板 (延迟 500ms 确保粘贴完成)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                if let old = oldContents {
                    pasteboard.setString(old, forType: .string)
                }
                statusText = "粘贴完成，剪贴板已恢复"
                resultText += "✅ S5: Cmd+V 已发送，剪贴板已恢复\n"
            }
        }
    }

    // MARK: - S6: 全局快捷键

    private func startGlobalHotkey() {
        // === 详细调试信息 ===
        let trusted = AXIsProcessTrusted()
        let bundlePath = Bundle.main.bundlePath
        let bundleId = Bundle.main.bundleIdentifier ?? "nil"
        let execPath = ProcessInfo.processInfo.arguments.first ?? "unknown"
        let pid = ProcessInfo.processInfo.processIdentifier

        resultText += "=== S6 调试信息 ===\n"
        resultText += "🔍 AXIsProcessTrusted = \(trusted)\n"
        resultText += "📦 bundleId = \(bundleId)\n"
        resultText += "📂 bundlePath = \(bundlePath)\n"
        resultText += "🔧 execPath = \(execPath)\n"
        resultText += "🆔 PID = \(pid)\n"

        // 检查 codesign 信息
        var code: SecStaticCode?
        let bundleURL = Bundle.main.bundleURL as CFURL
        let codeStatus = SecStaticCodeCreateWithPath(bundleURL, [], &code)
        if codeStatus == errSecSuccess, let code = code {
            var info: CFDictionary?
            let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            if infoStatus == errSecSuccess, let info = info as? [String: Any] {
                let teamId = info["teamid"] as? String ?? "nil"
                let signingId = info["identifier"] as? String ?? "nil"
                let flags = info["flags"] as? UInt32 ?? 0
                resultText += "🔏 signingId = \(signingId)\n"
                resultText += "🏢 teamId = \(teamId)\n"
                resultText += "🚩 flags = \(flags)\n"
            } else {
                resultText += "⚠️ SecCodeCopySigningInformation failed: \(infoStatus)\n"
            }
        } else {
            resultText += "⚠️ SecStaticCodeCreateWithPath failed: \(codeStatus)\n"
        }

        // 尝试带弹窗的权限请求
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let trustedWithPrompt = AXIsProcessTrustedWithOptions(opts)
        resultText += "🔍 AXIsProcessTrustedWithOptions(prompt) = \(trustedWithPrompt)\n"

        // 检查 executable 的实际路径（可能与 bundle 不同）
        if let execURL = Bundle.main.executableURL {
            resultText += "🎯 executableURL = \(execURL.path)\n"
        }

        // 检查 app 是否被 translocation（macOS Gatekeeper）
        resultText += "📍 isTranslocated = \(bundlePath.contains("/AppTranslocation/"))\n"
        resultText += "===================\n"

        statusText = trusted ? "AXIsProcessTrusted = true，正在创建 tap..." : "CGEvent tap 创建失败！需要辅助功能权限"

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // 用 userInfo 传递 tap 引用用于 timeout 恢复
        let tapHolder = UnsafeMutablePointer<CFMachPort?>.allocate(capacity: 1)
        tapHolder.initialize(to: nil)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                // tapDisabledByTimeout 自动恢复
                if type == .tapDisabledByTimeout {
                    if let refcon = refcon {
                        let holder = refcon.assumingMemoryBound(to: CFMachPort?.self)
                        if let port = holder.pointee {
                            CGEvent.tapEnable(tap: port, enable: true)
                        }
                    }
                    return Unmanaged.passRetained(event)
                }

                guard type == .keyDown || type == .keyUp else {
                    return Unmanaged.passRetained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                // Option + Space: keyCode 49 (Space), Option flag
                let isSpace = keyCode == 49
                let isOptionOnly = flags.contains(.maskAlternate) &&
                    !flags.contains(.maskCommand) &&
                    !flags.contains(.maskControl) &&
                    !flags.contains(.maskShift)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

                if isSpace && isOptionOnly && !isRepeat {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .hotkeyTriggered,
                            object: type == .keyDown ? "down" : "up"
                        )
                    }
                    return nil
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: tapHolder
        ) else {
            tapHolder.deallocate()
            statusText = "CGEvent tap 创建失败！需要辅助功能权限"
            resultText += "❌ S6: tap 创建失败 — 请在系统设置 > 隐私与安全 > 辅助功能中授权本 App\n"
            return
        }

        tapHolder.pointee = tap
        self.eventTapPort = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // 监听快捷键触发通知
        NotificationCenter.default.addObserver(
            forName: .hotkeyTriggered,
            object: nil,
            queue: .main
        ) { _ in
            self.hotkeyTriggered = true
            self.resultText += "✅ S6: Option+Space 触发！\n"
            self.statusText = "快捷键已触发"

            // 2 秒后重置显示
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.hotkeyTriggered = false
            }
        }

        statusText = "CGEvent tap 已启动，按 Option+Space 测试"
        resultText += "🔑 S6: CGEvent tap 创建成功，等待 Option+Space...\n"
    }
}

extension Notification.Name {
    static let hotkeyTriggered = Notification.Name("hotkeyTriggered")
}
