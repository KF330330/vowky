import Foundation

/// 生产实现:spawn `vowky-speechd --diarize <wav>` 一次性子进程做说话人分离。
/// 与常驻听写 helper 是两个进程——分离期间热键听写管道完全不受影响;
/// 模型内存(约 188MB)随进程退出即释放。
final class SubprocessSpeakerDiarizer: SpeakerDiarizing {

    /// PROGRESS/RESULT 停滞超过该时长判 hang(正常节流间隔 0.5s,余量充足)。
    private static let stallTimeout: TimeInterval = 120

    private let helperURL: URL

    init(helperURL: URL? = nil) {
        self.helperURL = helperURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vowky-speechd")
    }

    /// 整体超时:分离实测约为音频时长 5%(RTF≈0.05),0.3 倍即 6 倍余量;含模型冷加载底数。
    static func overallTimeout(audioDuration: TimeInterval) -> TimeInterval {
        min(max(300, audioDuration * 0.3 + 120), 1800)
    }

    func diarize(
        wavURL: URL,
        audioDuration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerSegment] {
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw SpeakerDiarizationError.helperNotFound
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--diarize", wavURL.path]
        process.qualityOfService = .utility
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let state = RunState()
        let timeout = Self.overallTimeout(audioDuration: audioDuration)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SpeakerSegment], Error>) in
                state.continuation = continuation

                // 行读取:readabilityHandler 在系统管线线程回调,不占协作线程池
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        return
                    }
                    state.touch()
                    for line in state.appendAndSplitLines(data) {
                        switch DiarizeSubprocessLine.parse(line) {
                        case .progress(let processed, let total):
                            if total > 0 {
                                onProgress(min(1.0, Double(processed) / Double(total)))
                            }
                        case .result(let dtos):
                            state.storeResult(dtos.map {
                                SpeakerSegment(start: $0.s, end: $0.e, speaker: $0.spk)
                            })
                        case .error(let message):
                            state.storeError(message)
                        case nil:
                            break  // 容忍库残留输出行
                        }
                    }
                }

                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    // 吃掉终止后管道内残留(RESULT 行可能在 terminationHandler 之后才被 readability 消费,
                    // 这里同步读尽保证不丢终态行)
                    let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty {
                        for line in state.appendAndSplitLines(remaining) {
                            switch DiarizeSubprocessLine.parse(line) {
                            case .result(let dtos):
                                state.storeResult(dtos.map {
                                    SpeakerSegment(start: $0.s, end: $0.e, speaker: $0.spk)
                                })
                            case .error(let message):
                                state.storeError(message)
                            default:
                                break
                            }
                        }
                    }
                    state.finish { result, errorMessage, cancelled in
                        if cancelled {
                            return .failure(SpeakerDiarizationError.cancelled)
                        }
                        if let result, proc.terminationStatus == 0 {
                            return .success(result)
                        }
                        return .failure(SpeakerDiarizationError.processFailed(
                            errorMessage ?? "exit \(proc.terminationStatus) without result"))
                    }
                }

                // 看门狗:整体超时 + 输出停滞双重保护
                let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                watchdog.schedule(deadline: .now() + 5, repeating: 5)
                let deadline = Date().addingTimeInterval(timeout)
                watchdog.setEventHandler {
                    let stalled = state.secondsSinceLastActivity() > Self.stallTimeout
                    if Date() > deadline || stalled {
                        state.markTimedOut()
                        process.terminate()
                    }
                }
                state.watchdog = watchdog
                watchdog.resume()

                do {
                    state.touch()
                    try process.run()
                } catch {
                    state.finish { _, _, _ in
                        .failure(SpeakerDiarizationError.processFailed("spawn failed: \(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            state.markCancelled()
            process.terminate()
        }
    }

    /// 跨回调共享状态:锁保护,continuation 恰好 resume 一次。
    private final class RunState: @unchecked Sendable {
        var continuation: CheckedContinuation<[SpeakerSegment], Error>?
        var watchdog: DispatchSourceTimer?

        private let lock = NSLock()
        private var buffer = Data()
        private var result: [SpeakerSegment]?
        private var errorMessage: String?
        private var cancelled = false
        private var timedOut = false
        private var finished = false
        private var lastActivity = Date()

        func touch() {
            lock.lock(); lastActivity = Date(); lock.unlock()
        }

        func secondsSinceLastActivity() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(lastActivity)
        }

        func appendAndSplitLines(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
            var lines: [String] = []
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    lines.append(line)
                }
            }
            return lines
        }

        func storeResult(_ segments: [SpeakerSegment]) {
            lock.lock(); result = segments; lock.unlock()
        }

        func storeError(_ message: String) {
            lock.lock(); errorMessage = message; lock.unlock()
        }

        func markCancelled() {
            lock.lock(); cancelled = true; lock.unlock()
        }

        func markTimedOut() {
            lock.lock(); timedOut = true; lock.unlock()
        }

        /// 终态归一:make 闭包在锁内拿到(result, errorMessage, cancelled)决定成败;只生效一次。
        func finish(_ make: ([SpeakerSegment]?, String?, Bool) -> Result<[SpeakerSegment], Error>) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            watchdog?.cancel()
            watchdog = nil
            let outcome: Result<[SpeakerSegment], Error>
            if timedOut && result == nil {
                outcome = .failure(SpeakerDiarizationError.timedOut)
            } else {
                outcome = make(result, errorMessage, cancelled)
            }
            lock.unlock()
            continuation.resume(with: outcome)
        }
    }
}
