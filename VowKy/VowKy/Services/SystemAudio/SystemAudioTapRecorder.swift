import AVFoundation
import CoreAudio
import Foundation

/// 系统声音路的静音告警通道。故意**不**并进 `AudioRecorderProtocol`:
/// 那是听写与录音共用的协议,加成员会波及所有实现与 mock(听写路径是本次改动的红线)。
/// 本协议不加 @available 门控,好让 VM 与测试 mock 无门控接线。
protocol SystemAudioSilenceReporting: AnyObject {
    /// true = 系统声音路连续 ≥10s 全零;false = 又收到非零样本。只在状态翻转时回调。
    var onSystemAudioSilenceChange: ((Bool) -> Void)? { get set }
}

enum SystemAudioRecorderError: Error, LocalizedError {
    /// 仅当实测确认存在可靠拒权信号时才映射(见 2026-08-25 三态标定:未发现该信号,本 case 当前不触发)。
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case streamEnumerationFailed(OSStatus)
    case converterCreationFailed
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return LL("recording.error.systemAudioPermissionDenied")
        case .tapCreationFailed(let status),
             .aggregateCreationFailed(let status),
             .streamEnumerationFailed(let status),
             .ioProcCreationFailed(let status),
             .deviceStartFailed(let status):
            return LL("recording.error.systemAudioTapFailed", Int(status))
        case .converterCreationFailed:
            return LL("recording.error.systemAudioTapFailed", 0)
        }
    }
}

/// 用 Core Audio Process Tap 采「各进程输出混音」(macOS 14.4+)。
/// 单一职责:只采系统声音,不碰麦克风——混合模式由 `CompositeAudioRecorder` 组合两路。
/// 采到的是数字流,不经过空气,因此绕开会议软件的回声消除(AEC 把对方声音从麦克风信号里减掉,
/// 正是「录会议只录到自己」的根因)。
@available(macOS 14.4, *)
final class SystemAudioTapRecorder: AudioRecorderProtocol, SystemAudioSilenceReporting {

    /// 连续全零到这个样本数(16k 域 = 10s)就报「未检测到系统声音」。
    private static let silenceThresholdSamples = 160_000
    private static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    private let targetSampleRate: Double = 16000

    private let lock = NSLock()
    /// HAL 回调队列:只做 buffer 映射 + 下混 + 重采样。
    private let ioQueue = DispatchQueue(label: "com.vowky.systemaudio.io")
    /// 聚合与对外回调队列(与 AudioRecorder.processingQueue 同语义:FIFO 保序,不占 HAL 线程)。
    private let processingQueue = DispatchQueue(label: "com.vowky.systemaudio.processing")

    private var recordedSamples: [Float] = []
    private var _audioLevel: Float = 0
    private var _isPaused = false

    var onSamplesCaptured: (([Float]) -> Void)?
    var onSystemAudioSilenceChange: ((Bool) -> Void)?

    /// Core Audio 资源:只在 start / stop / deinit(调用方线程)读写,每次 start 全新建、stop 全销毁。
    private var tapID = SystemAudioTapRecorder.unknownObject
    private var aggregateID = SystemAudioTapRecorder.unknownObject
    private var ioProcID: AudioDeviceIOProcID?

    /// 静音检测状态:只在 processingQueue 上读写。
    private var consecutiveSilentSamples = 0
    private var isReportingSilence = false

    /// 畸形周期计数:只在 ioQueue 上读写(IOProc 块串行执行)。
    private var malformedPeriodCount = 0

    var audioLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return _audioLevel
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isPaused
    }

    func pauseRecording() {
        lock.lock()
        _isPaused = true
        _audioLevel = 0
        lock.unlock()
        NSLog("[VowKy][SysAudio] pauseRecording() — dropping samples, tap stays alive")
    }

    func resumeRecording() {
        lock.lock()
        _isPaused = false
        lock.unlock()
        NSLog("[VowKy][SysAudio] resumeRecording()")
    }

    // MARK: - Start

    func startRecording() throws {
        NSLog("[VowKy][SysAudio] startRecording() called")

        // 1. 自身 pid → AudioObjectID(排除自己的输出,避免把 VowKy 自己的声音录进去)。
        //    失败不致命:排除列表传空,tap 会包含本进程输出。
        let excludedProcesses = Self.processObjectID(for: getpid()).map { [$0] } ?? []
        if excludedProcesses.isEmpty {
            NSLog("[VowKy][SysAudio] TranslatePIDToProcessObject failed — tap will include VowKy's own output")
        }

        // 2. mono 全局 tap。muteBehavior 必须 unmuted:开会时用户还要继续听见对方。
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excludedProcesses)
        description.name = "VowKy-SystemAudioTap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        // 3. 创建 tap。
        var tap = Self.unknownObject
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != Self.unknownObject else {
            NSLog("[VowKy][SysAudio] AudioHardwareCreateProcessTap failed: \(Self.fourCC(tapStatus))")
            throw SystemAudioRecorderError.tapCreationFailed(tapStatus)
        }
        NSLog("[VowKy][SysAudio] tap created: id=\(tap) uuid=\(description.uuid.uuidString)")

        // 4. 默认输出设备做聚合设备的主时钟。
        let (outputStatus, outputDevice, outputUID) = Self.defaultOutputDevice()
        guard outputStatus == noErr, let outputUID, !outputUID.isEmpty else {
            NSLog("[VowKy][SysAudio] default output device lookup failed: \(Self.fourCC(outputStatus))")
            Self.destroyTap(tap)
            throw SystemAudioRecorderError.aggregateCreationFailed(outputStatus)
        }
        NSLog("[VowKy][SysAudio] default output device: id=\(outputDevice) uid=\(outputUID)")

        // 5. 私有聚合设备 = 默认输出设备(时钟) + tap。不含任何 mic sub-device。
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VowKy System Audio",
            kAudioAggregateDeviceUIDKey: "com.vowky.systemaudio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: 1]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]
            ],
        ]
        var aggregate = Self.unknownObject
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != Self.unknownObject else {
            NSLog("[VowKy][SysAudio] AudioHardwareCreateAggregateDevice failed: \(Self.fourCC(aggregateStatus))")
            Self.destroyTap(tap)
            throw SystemAudioRecorderError.aggregateCreationFailed(aggregateStatus)
        }
        NSLog("[VowKy][SysAudio] aggregate device created: id=\(aggregate)")

        // 6. 流识别 + 重采样器。
        let plan: StreamPlan
        let converter: AVAudioConverter
        let monoFormat: AVAudioFormat
        let targetFormat: AVAudioFormat
        do {
            plan = try Self.buildStreamPlan(aggregate: aggregate, tap: tap, outputDevice: outputDevice)
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: plan.sampleRate,
                                           channels: 1,
                                           interleaved: false),
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: targetSampleRate,
                                             channels: 1,
                                             interleaved: false),
                  let conv = AVAudioConverter(from: mono, to: target) else {
                throw SystemAudioRecorderError.converterCreationFailed
            }
            monoFormat = mono
            targetFormat = target
            converter = conv
        } catch {
            Self.destroyAggregate(aggregate)
            Self.destroyTap(tap)
            throw error
        }

        // 7. IOProc + 启动。TCC 授权弹窗按 Apple 文档在这一步(首次 AudioDeviceStart)出现。
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.handleInput(inputData,
                              plan: plan,
                              converter: converter,
                              monoFormat: monoFormat,
                              targetFormat: targetFormat)
        }
        guard procStatus == noErr, let procID else {
            NSLog("[VowKy][SysAudio] AudioDeviceCreateIOProcIDWithBlock failed: \(Self.fourCC(procStatus))")
            Self.destroyAggregate(aggregate)
            Self.destroyTap(tap)
            throw SystemAudioRecorderError.ioProcCreationFailed(procStatus)
        }

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            NSLog("[VowKy][SysAudio] AudioDeviceStart failed: \(Self.fourCC(startStatus))")
            AudioDeviceDestroyIOProcID(aggregate, procID)
            Self.destroyAggregate(aggregate)
            Self.destroyTap(tap)
            throw SystemAudioRecorderError.deviceStartFailed(startStatus)
        }

        // 8. 会话状态清零。
        tapID = tap
        aggregateID = aggregate
        ioProcID = procID
        malformedPeriodCount = 0
        processingQueue.sync {
            consecutiveSilentSamples = 0
            isReportingSilence = false
        }
        lock.lock()
        recordedSamples = []
        _audioLevel = 0
        _isPaused = false
        lock.unlock()
        NSLog("[VowKy][SysAudio] capture started (tapRate=\(plan.sampleRate) → 16000 mono)")
    }

    // MARK: - Stop

    func stopRecording() -> [Float] {
        NSLog("[VowKy][SysAudio] stopRecording() called")
        teardown()

        // 排空处理队列:确保已捕获的周期都完成聚合与回调,避免截尾
        processingQueue.sync {}

        lock.lock()
        let samples = recordedSamples
        recordedSamples = []
        _audioLevel = 0
        _isPaused = false
        lock.unlock()

        var maxValue: Float = 0
        var sumValue: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > maxValue { maxValue = magnitude }
            sumValue += magnitude
        }
        let average = samples.isEmpty ? 0 : sumValue / Float(samples.count)
        let duration = Double(samples.count) / targetSampleRate
        NSLog("[VowKy][SysAudio] Returning \(samples.count) samples (duration=\(String(format: "%.1f", duration))s, maxAmp=\(String(format: "%.4f", maxValue)), avgAmp=\(String(format: "%.6f", average)))")
        return samples
    }

    deinit {
        teardown()
    }

    /// 严格逆序销毁,每步失败仅记日志继续;各 ID 判 unknown,可重复调用。
    private func teardown() {
        if aggregateID != Self.unknownObject, let procID = ioProcID {
            let stopStatus = AudioDeviceStop(aggregateID, procID)
            if stopStatus != noErr {
                NSLog("[VowKy][SysAudio] AudioDeviceStop failed: \(Self.fourCC(stopStatus))")
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateID, procID)
            if destroyStatus != noErr {
                NSLog("[VowKy][SysAudio] AudioDeviceDestroyIOProcID failed: \(Self.fourCC(destroyStatus))")
            }
        }
        ioProcID = nil

        if aggregateID != Self.unknownObject {
            Self.destroyAggregate(aggregateID)
            aggregateID = Self.unknownObject
        }
        if tapID != Self.unknownObject {
            Self.destroyTap(tapID)
            tapID = Self.unknownObject
        }
    }

    // MARK: - IOProc

    private func handleInput(
        _ bufferList: UnsafePointer<AudioBufferList>,
        plan: StreamPlan,
        converter: AVAudioConverter,
        monoFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) {
        // 暂停期间在下混/重采样之前直接丢弃,回调近零开销(链路保活)
        if isPaused { return }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard buffers.count == plan.totalBufferCount else {
            logMalformedPeriod("buffer count \(buffers.count) != expected \(plan.totalBufferCount)")
            return
        }

        var monoChunk: [Float]?
        var cursor = 0
        for layout in plan.layouts {
            defer { cursor += layout.bufferCount }
            // 非 tap 输入流(双工耳机/声卡自带的 mic 流等)整流忽略
            guard layout.isTap, monoChunk == nil else { continue }

            if layout.isNonInterleaved {
                var channels: [[Float]] = []
                channels.reserveCapacity(layout.bufferCount)
                for offset in 0..<layout.bufferCount {
                    let buffer = buffers[cursor + offset]
                    guard let samples = Self.floatSamples(of: buffer, bytesPerFrame: layout.bytesPerFrame) else {
                        logMalformedPeriod("stream \(layout.streamID) buffer \(offset) size \(buffer.mDataByteSize) not a multiple of \(layout.bytesPerFrame)")
                        return
                    }
                    channels.append(samples)
                }
                monoChunk = SystemAudioMixer.averageNonInterleaved(channels)
            } else {
                let buffer = buffers[cursor]
                guard Int(buffer.mNumberChannels) == layout.channels,
                      let data = buffer.mData,
                      layout.bytesPerFrame > 0,
                      buffer.mDataByteSize % layout.bytesPerFrame == 0 else {
                    logMalformedPeriod("stream \(layout.streamID) buffer shape ch=\(buffer.mNumberChannels) bytes=\(buffer.mDataByteSize) vs ch=\(layout.channels) bytesPerFrame=\(layout.bytesPerFrame)")
                    return
                }
                let frames = Int(buffer.mDataByteSize / layout.bytesPerFrame)
                monoChunk = SystemAudioMixer.downmixInterleavedToMono(
                    data.assumingMemoryBound(to: Float.self),
                    frames: frames,
                    channels: layout.channels
                )
            }
        }

        guard let mono = monoChunk, !mono.isEmpty else { return }
        guard let samples = resample(mono, converter: converter, monoFormat: monoFormat, targetFormat: targetFormat),
              !samples.isEmpty else { return }

        processingQueue.async { [weak self] in
            guard let self else { return }
            let rms = Self.computeRMS(samples)

            self.lock.lock()
            self.recordedSamples.append(contentsOf: samples)
            self._audioLevel = rms
            self.lock.unlock()

            // 不接 backupService:录音窗口的 WAV 由下游 WAVSampleFileWriter 落盘
            self.onSamplesCaptured?(samples)
            self.updateSilenceState(with: samples)
        }
    }

    private func resample(
        _ mono: [Float],
        converter: AVAudioConverter,
        monoFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) -> [Float]? {
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                                 frameCapacity: AVAudioFrameCount(mono.count)),
              let inputData = inputBuffer.floatChannelData else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                inputData[0].update(from: base, count: mono.count)
            }
        }

        let ratio = targetSampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(max(1, Int(Double(mono.count) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var hasProvided = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvided = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let error {
            NSLog("[VowKy][SysAudio] Converter error: \(error)")
            return nil
        }
        guard let outputData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: outputData[0], count: Int(outputBuffer.frameLength)))
    }

    /// 只在 processingQueue 上调用。
    private func updateSilenceState(with samples: [Float]) {
        if let lastNonZero = samples.lastIndex(where: { $0 != 0 }) {
            consecutiveSilentSamples = samples.count - 1 - lastNonZero
            if isReportingSilence {
                isReportingSilence = false
                NSLog("[VowKy][SysAudio] system audio resumed — clearing silence warning")
                onSystemAudioSilenceChange?(false)
            }
        } else {
            consecutiveSilentSamples += samples.count
            if !isReportingSilence, consecutiveSilentSamples >= Self.silenceThresholdSamples {
                isReportingSilence = true
                NSLog("[VowKy][SysAudio] no system audio for \(Self.silenceThresholdSamples / 16000)s — raising silence warning")
                onSystemAudioSilenceChange?(true)
            }
        }
    }

    /// 只在 ioQueue 上调用(IOProc 块串行执行)。畸形周期可能每个周期都出现,必须限流。
    private func logMalformedPeriod(_ reason: String) {
        malformedPeriodCount += 1
        if malformedPeriodCount == 1 || malformedPeriodCount % 500 == 0 {
            NSLog("[VowKy][SysAudio] dropped malformed period #\(malformedPeriodCount): \(reason)")
        }
    }

    private static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    // MARK: - 流识别

    /// 聚合设备一条输入流的形态。AudioBufferList 按流序排列 buffer:
    /// 交错流 1 流 1 buffer,非交错流 1 流 N buffer(每 buffer 一声道)。
    private struct StreamLayout {
        let streamID: AudioStreamID
        let isTap: Bool
        let channels: Int
        let isNonInterleaved: Bool
        /// 每个 buffer 每帧字节数(非交错时是单声道帧宽)
        let bytesPerFrame: UInt32

        var bufferCount: Int { isNonInterleaved ? channels : 1 }
    }

    private struct StreamPlan {
        let layouts: [StreamLayout]
        /// tap 流的采样率(重采样源)
        let sampleRate: Double

        var totalBufferCount: Int { layouts.reduce(0) { $0 + $1.bufferCount } }
    }

    private static func buildStreamPlan(
        aggregate: AudioObjectID,
        tap: AudioObjectID,
        outputDevice: AudioObjectID
    ) throws -> StreamPlan {
        let (streamsStatus, streams) = inputStreams(of: aggregate)
        guard streamsStatus == noErr, !streams.isEmpty else {
            NSLog("[VowKy][SysAudio] aggregate input streams unavailable: \(fourCC(streamsStatus)) count=\(streams.count)")
            throw SystemAudioRecorderError.streamEnumerationFailed(streamsStatus)
        }

        let (tapFormatStatus, tapFormat) = tapStreamFormat(of: tap)
        NSLog("[VowKy][SysAudio] tap format: \(fourCC(tapFormatStatus)) rate=\(tapFormat.mSampleRate) ch=\(tapFormat.mChannelsPerFrame) flags=\(tapFormat.mFormatFlags)")

        var formats: [AudioStreamBasicDescription] = []
        for stream in streams {
            let owner = objectOwner(of: stream)
            let format = virtualFormat(of: stream)
            formats.append(format)
            NSLog("[VowKy][SysAudio] input stream \(stream): owner=\(owner) rate=\(format.mSampleRate) ch=\(format.mChannelsPerFrame) nonInterleaved=\((format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) bytesPerFrame=\(format.mBytesPerFrame) bits=\(format.mBitsPerChannel) flags=\(format.mFormatFlags)")
        }

        // 计划口径:owner == tapID 的流就是 tap 流。
        // 实测(macOS 26.5)聚合设备所有输入流的 owner 恒为聚合设备本身,拿不到 tap 归属,
        // 故再按聚合构成推导:聚合输入流序 = [子设备(默认输出设备)自带的输入流…, tap 流…],
        // 跳过子设备输入流条数,其余即 tap 流(双工耳机/声卡自带的 mic 流就在这里被整流忽略)。
        var tapIndices = streams.indices.filter { objectOwner(of: streams[$0]) == tap }
        if tapIndices.isEmpty {
            let subDeviceInputCount = inputStreams(of: outputDevice).1.count
            var derived = Array(streams.indices.dropFirst(subDeviceInputCount))
            if tapFormatStatus == noErr {
                derived = derived.filter {
                    formats[$0].mChannelsPerFrame == tapFormat.mChannelsPerFrame
                        && formats[$0].mSampleRate == tapFormat.mSampleRate
                }
            }
            NSLog("[VowKy][SysAudio] no stream owned by tap — derived tap streams by layout: subDeviceInputStreams=\(subDeviceInputCount) tapIndices=\(derived)")
            tapIndices = derived
        }
        guard let tapIndex = tapIndices.first else {
            NSLog("[VowKy][SysAudio] no tap stream found among \(streams.count) input streams")
            throw SystemAudioRecorderError.streamEnumerationFailed(streamsStatus)
        }
        if tapIndices.count > 1 {
            NSLog("[VowKy][SysAudio] \(tapIndices.count) tap streams found — consuming the first (\(streams[tapIndex]))")
        }

        let selectedFormat = formats[tapIndex]
        guard (selectedFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              selectedFormat.mBitsPerChannel == 32,
              selectedFormat.mSampleRate > 0,
              selectedFormat.mChannelsPerFrame > 0,
              selectedFormat.mBytesPerFrame > 0 else {
            NSLog("[VowKy][SysAudio] unsupported tap stream format (expect Float32): flags=\(selectedFormat.mFormatFlags) bits=\(selectedFormat.mBitsPerChannel) bytesPerFrame=\(selectedFormat.mBytesPerFrame)")
            throw SystemAudioRecorderError.converterCreationFailed
        }

        // mBytesPerFrame 对交错流是「整帧字节数」,对非交错流是「单声道帧字节数」——
        // 两种形态下都正好是「该 buffer 的字节数 ÷ 帧数」,故直接沿用。
        let layouts = streams.indices.map { index -> StreamLayout in
            let format = formats[index]
            return StreamLayout(
                streamID: streams[index],
                isTap: index == tapIndex,
                channels: max(Int(format.mChannelsPerFrame), 1),
                isNonInterleaved: (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0,
                bytesPerFrame: format.mBytesPerFrame
            )
        }
        return StreamPlan(layouts: layouts, sampleRate: selectedFormat.mSampleRate)
    }

    // MARK: - Core Audio 取属性

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var propertyAddress = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var objectID = unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                UInt32(MemoryLayout<pid_t>.size),
                pointer,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != unknownObject else { return nil }
        return objectID
    }

    private static func defaultOutputDevice() -> (OSStatus, AudioObjectID, String?) {
        var deviceAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &device
        )
        guard status == noErr, device != unknownObject else { return (status, unknownObject, nil) }

        var uidAddress = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard uidStatus == noErr else { return (uidStatus, device, nil) }
        return (noErr, device, uid as String?)
    }

    private static func inputStreams(of device: AudioObjectID) -> (OSStatus, [AudioStreamID]) {
        guard device != unknownObject else { return (kAudioHardwareBadObjectError, []) }
        var propertyAddress = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(device, &propertyAddress, 0, nil, &size)
        guard sizeStatus == noErr else { return (sizeStatus, []) }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count > 0 else { return (noErr, []) }
        var streams = [AudioStreamID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(device, &propertyAddress, 0, nil, &size, &streams)
        guard status == noErr else { return (status, []) }
        return (noErr, streams)
    }

    private static func objectOwner(of object: AudioObjectID) -> AudioObjectID {
        var propertyAddress = address(kAudioObjectPropertyOwner)
        var owner = unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &owner)
        return status == noErr ? owner : unknownObject
    }

    private static func virtualFormat(of stream: AudioStreamID) -> AudioStreamBasicDescription {
        var propertyAddress = address(kAudioStreamPropertyVirtualFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioObjectGetPropertyData(stream, &propertyAddress, 0, nil, &size, &format)
        return format
    }

    private static func tapStreamFormat(of tap: AudioObjectID) -> (OSStatus, AudioStreamBasicDescription) {
        var propertyAddress = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &propertyAddress, 0, nil, &size, &format)
        return (status, format)
    }

    private static func floatSamples(of buffer: AudioBuffer, bytesPerFrame: UInt32) -> [Float]? {
        guard let data = buffer.mData, bytesPerFrame > 0, buffer.mDataByteSize % bytesPerFrame == 0 else {
            return nil
        }
        let frames = Int(buffer.mDataByteSize / bytesPerFrame)
        guard frames > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames))
    }

    private static func destroyTap(_ tap: AudioObjectID) {
        let status = AudioHardwareDestroyProcessTap(tap)
        if status != noErr {
            NSLog("[VowKy][SysAudio] AudioHardwareDestroyProcessTap failed: \(fourCC(status))")
        }
    }

    private static func destroyAggregate(_ aggregate: AudioObjectID) {
        let status = AudioHardwareDestroyAggregateDevice(aggregate)
        if status != noErr {
            NSLog("[VowKy][SysAudio] AudioHardwareDestroyAggregateDevice failed: \(fourCC(status))")
        }
    }

    /// OSStatus 多是四字符码('nope' 之类),按 ASCII 可读时一并打出来,便于对照 Apple 文档定位。
    private static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let ascii = String(bytes: bytes, encoding: .ascii) {
            return "'\(ascii)'(\(status))"
        }
        return "\(status)"
    }
}
