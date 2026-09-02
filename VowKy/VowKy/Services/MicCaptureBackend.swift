import AVFoundation
import Foundation

/// 麦克风采集后端抽象：AudioRecorder 只通过它接触系统音频，单测可注入假后端。
///
/// 背景（2026-09-02）：AVAudioEngine 的 `inputNode` 首次绑定存在框架内部锁序反转
/// （UpdateInputNode 持 engine 递归锁后 dispatch_sync 到 engine 私有队列，而私有队列
/// 正在跑 IOBindingChanged 抢同一把锁），会把整个 App 卡死且永不恢复。
/// VowKy 每次录音都新建 engine，把小概率竞态放大成周期性卡死，故麦克风采集彻底改走
/// AVCaptureSession，主进程不再出现任何 AVAudioEngine 调用。
protocol MicCaptureBackend: AnyObject {
    /// 送入 onBuffer 的 buffer 格式；首个 buffer 到达前为 nil。仅用于日志。
    var nativeFormat: AVAudioFormat? { get }
    /// 可能阻塞（只在 AudioRecorder 的控制队列上调用，绝不在主线程）。
    /// onBuffer 在后端自己的串行队列上回调，且**必须**给非交织 Float32 的
    /// AVAudioPCMBuffer（采样率/声道数任意）。
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    /// 同步；返回后不再有 onBuffer 回调。
    func stop()
}

/// 基于 AVCaptureSession + AVCaptureAudioDataOutput 的真实麦克风后端。
final class MicCaptureSession: NSObject, MicCaptureBackend, AVCaptureAudioDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    /// AVF 要求 sample buffer delegate 队列必须串行，且不能是主队列。
    private let captureQueue = DispatchQueue(label: "com.vowky.audio.capture")
    private let lock = NSLock()

    /// lock 保护（captureQueue 写，控制队列/主线程读）
    private var _nativeFormat: AVAudioFormat?
    /// start 里赋值（startRunning 之前）、stop 里 captureQueue.sync 置 nil
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    // 下面几个只在 captureQueue 上访问
    private var lastASBD: AudioStreamBasicDescription?
    private var sourceFormat: AVAudioFormat?
    private var floatFormat: AVAudioFormat?
    /// 源已是 Float32 非交织时为 nil（免一次拷贝）
    private var floatConverter: AVAudioConverter?
    private var didLogFormatFailure = false

    private var runtimeErrorObserver: NSObjectProtocol?

    var nativeFormat: AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        return _nativeFormat
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AudioRecorderError.noInputDevice
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioRecorderError.captureStartFailed(error)
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AudioRecorderError.captureStartFailed(nil)
        }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioRecorderError.captureStartFailed(nil)
        }
        session.addOutput(output)
        session.commitConfiguration()

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { note in
            let desc = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "?"
            CrashLogger.log("[Audio] AVCaptureSession runtime error: \(desc)")
        }

        // 必须在 startRunning 之前挂上，否则首个 sample buffer 会被丢弃
        self.onBuffer = onBuffer

        session.startRunning()
        guard session.isRunning else {
            throw AudioRecorderError.captureStartFailed(nil)
        }
        CrashLogger.log("[Audio] AVCaptureSession running, device=\(device.localizedName)")
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }
        // stopRunning 返回后不再有新回调；排空队列并断开引用
        captureQueue.sync { self.onBuffer = nil }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            logFormatFailureOnce("missing stream basic description")
            return
        }
        let asbd = asbdPtr.pointee
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }

        if lastASBD == nil || !MicCaptureSession.isSameFormat(lastASBD!, asbd) {
            let layout = MicCaptureSession.channelLayout(from: formatDescription, channels: asbd.mChannelsPerFrame)
            guard let src = MicCaptureSession.makeFormat(from: asbdPtr, layout: layout) else {
                logFormatFailureOnce("cannot build source AVAudioFormat for rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame)")
                return
            }
            sourceFormat = src
            if src.commonFormat == .pcmFormatFloat32 && !src.isInterleaved {
                // 已经是下游要的格式，直接透传，省一次拷贝
                floatFormat = nil
                floatConverter = nil
            } else {
                guard let flt = MicCaptureSession.makeFloatFormat(like: asbd, layout: layout ?? src.channelLayout) else {
                    logFormatFailureOnce("cannot build float AVAudioFormat for rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame)")
                    return
                }
                guard let conv = AVAudioConverter(from: src, to: flt) else {
                    logFormatFailureOnce("cannot build float converter for rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame)")
                    return
                }
                floatFormat = flt
                floatConverter = conv
            }
            lastASBD = asbd
            lock.lock(); _nativeFormat = floatFormat ?? src; lock.unlock()
            CrashLogger.log("[Audio] Input: rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=0x\(String(asbd.mFormatFlags, radix: 16))")
        }

        guard let sourceFormat,
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return }
        // frameLength 必须在拷贝前设好，否则 ABL 的 mDataByteSize 为 0，拷贝失败
        srcBuffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: srcBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            logFormatFailureOnce("CMSampleBufferCopyPCMDataIntoAudioBufferList failed: \(status)")
            return
        }

        guard let converter = floatConverter, let floatFormat else {
            onBuffer?(srcBuffer)
            return
        }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: frames) else { return }
        do {
            try converter.convert(to: outBuffer, from: srcBuffer)
            onBuffer?(outBuffer)
        } catch {
            logFormatFailureOnce("float conversion failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// 取 sample buffer 的声道布局。AVAudioFormat 对「声道数 ≠ 1/2」的 ASBD 必须带布局才能构造
    /// （实测本机 MacBook Pro 内置三麦阵列，AVCaptureSession 报 3 声道，裸 ASBD 构造直接返回 nil）。
    private static func channelLayout(from formatDescription: CMAudioFormatDescription,
                                      channels: UInt32) -> AVAudioChannelLayout? {
        var size = 0
        if let aclPtr = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &size), size > 0 {
            return AVAudioChannelLayout(layout: aclPtr)
        }
        // 设备没给布局时按「离散顺序」兜底，只为让 AVAudioFormat 能建起来；
        // 下游 processBuffer 本来就是按声道求平均做 downmix，不依赖具体布局语义。
        return AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
    }

    private static func makeFormat(from asbdPtr: UnsafePointer<AudioStreamBasicDescription>,
                                   layout: AVAudioChannelLayout?) -> AVAudioFormat? {
        if let format = AVAudioFormat(streamDescription: asbdPtr) {
            return format
        }
        guard let layout else { return nil }
        return AVAudioFormat(streamDescription: asbdPtr, channelLayout: layout)
    }

    /// 构造「同采样率、同声道数、Float32 非交织」的目标格式。
    ///
    /// 先走 commonFormat 便捷构造；它在非标准声道数上会返回 nil
    /// （实测本机内置麦克风 AVCaptureSession 报 3 声道，commonFormat 直接失败），
    /// 此时回落到显式 ASBD + 源格式的声道布局。
    private static func makeFloatFormat(like asbd: AudioStreamBasicDescription,
                                        layout: AVAudioChannelLayout?) -> AVAudioFormat? {
        if let standard = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame,
            interleaved: false
        ) {
            return standard
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: asbd.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: asbd.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        if let layout {
            return AVAudioFormat(streamDescription: &description, channelLayout: layout)
        }
        return AVAudioFormat(streamDescription: &description)
    }

    private static func isSameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mFormatFlags == b.mFormatFlags
            && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mFormatID == b.mFormatID
    }

    /// 实时回调里失败只记一次日志，避免刷爆日志文件
    private func logFormatFailureOnce(_ reason: String) {
        guard !didLogFormatFailure else { return }
        didLogFormatFailure = true
        CrashLogger.log("[Audio] capture buffer dropped: \(reason)")
    }
}

#if DEBUG
/// 环境变量 VOWKY_DEBUG_WEDGE=start|stop：模拟框架级卡死，供看门狗端到端验证。
final class DebugHangingMicBackend: MicCaptureBackend {
    private let inner: MicCaptureSession
    private let phase: String

    init(wrapping inner: MicCaptureSession, hangOn phase: String) {
        self.inner = inner
        self.phase = phase
    }

    var nativeFormat: AVAudioFormat? { inner.nativeFormat }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if phase == "start" {
            CrashLogger.log("[Audio] DEBUG wedge: start() hanging forever")
            DispatchSemaphore(value: 0).wait()
        }
        try inner.start(onBuffer: onBuffer)
    }

    func stop() {
        if phase == "stop" {
            CrashLogger.log("[Audio] DEBUG wedge: stop() hanging forever")
            DispatchSemaphore(value: 0).wait()
        }
        inner.stop()
    }
}
#endif
