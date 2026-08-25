import Foundation

/// 系统声音链路的纯样本运算(无 CoreAudio 依赖,可单测)。
enum SystemAudioMixer {

    /// 交错多声道 → mono(求平均)。channels == 1 时直拷。
    static func downmixInterleavedToMono(_ data: UnsafePointer<Float>, frames: Int, channels: Int) -> [Float] {
        guard frames > 0, channels > 0 else { return [] }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data, count: frames))
        }
        var mono = [Float](repeating: 0, count: frames)
        let invChannels = 1.0 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * channels
            for channel in 0..<channels {
                sum += data[base + channel]
            }
            mono[frame] = sum * invChannels
        }
        return mono
    }

    /// 非交错多 buffer(每 buffer 一声道)逐样本求平均成 mono。长度不齐时取各声道 min,宁缺勿越界。
    static func averageNonInterleaved(_ channels: [[Float]]) -> [Float] {
        guard let shortest = channels.map(\.count).min(), shortest > 0 else { return [] }
        if channels.count == 1 {
            return Array(channels[0][0..<shortest])
        }
        var mono = [Float](repeating: 0, count: shortest)
        let invChannels = 1.0 / Float(channels.count)
        for channel in channels {
            for i in 0..<shortest {
                mono[i] += channel[i]
            }
        }
        for i in 0..<shortest {
            mono[i] *= invChannels
        }
        return mono
    }

    /// 逐样本求和 + 硬钳制 [-1, 1]。语音场景不做 AGC(增益漂移比偶发削波更伤识别)。
    static func mixAndClamp(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> [Float] {
        let count = min(a.count, b.count)
        guard count > 0 else { return [] }
        var mixed = [Float](repeating: 0, count: count)
        let aBase = a.startIndex
        let bBase = b.startIndex
        for i in 0..<count {
            let sum = a[aBase + i] + b[bBase + i]
            mixed[i] = sum > 1 ? 1 : (sum < -1 ? -1 : sum)
        }
        return mixed
    }
}

/// 多流 16k 域 FIFO 对齐混音:push 后 drain 出 min(各流长度) 的混音段,余量留存等下一批。
/// 两路时钟不同(麦克风走输入设备时钟,tap 走输出设备时钟),靠 min 对齐吸收漂移;
/// 典型漂移 <100ppm(10 分钟 <60ms),远小于 maxDepth 容限。
///
/// 线程约定:本类**不加锁**,所有 push/drain 必须序列化在同一条队列上
/// (CompositeAudioRecorder 把两路回调都投到自己的 processingQueue 上再调用)。
final class StreamFIFOMixer {

    private var fifos: [[Float]]
    private let maxDepth: Int

    init(streamCount: Int, maxDepth: Int = 32_000) {
        self.fifos = Array(repeating: [], count: max(streamCount, 1))
        self.maxDepth = maxDepth
    }

    func push(streamIndex: Int, samples: [Float]) {
        guard fifos.indices.contains(streamIndex), !samples.isEmpty else { return }
        fifos[streamIndex].append(contentsOf: samples)
    }

    /// 正常情况按各流共同长度出段;某条流停摆(为空或严重滞后)导致另一条堆积超过 maxDepth 时,
    /// 缺失部分按静音补齐直接放行,避免一路失效把整条录音拖停。
    func drainMixed() -> [Float] {
        let depths = fifos.map(\.count)
        guard let common = depths.min(), let deepest = depths.max() else { return [] }
        let count = deepest > maxDepth ? deepest : common
        return take(count)
    }

    /// stop 时清尾:剩余样本全部混出,短的流按静音补齐。
    func flushRemainder() -> [Float] {
        take(fifos.map(\.count).max() ?? 0)
    }

    private func take(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var mixed = [Float](repeating: 0, count: count)
        for index in fifos.indices {
            let available = min(count, fifos[index].count)
            guard available > 0 else { continue }
            let chunk = fifos[index][0..<available]
            let head = SystemAudioMixer.mixAndClamp(mixed[0..<available], chunk)
            mixed.replaceSubrange(0..<available, with: head)
            fifos[index].removeFirst(available)
        }
        return mixed
    }
}
