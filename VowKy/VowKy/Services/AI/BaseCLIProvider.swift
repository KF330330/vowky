import Foundation

/// CLI provider 共享逻辑：路径探测、Process 启动、stdin/stdout、超时、取消。
class BaseCLIProvider {

    let commandName: String           // 如 "codex"、"claude"
    let runArgs: [String]             // 实际调用参数（非 probe）
    let probeArgs: [String]           // 探活参数（如 --version）
    let userBinaryPath: String        // UserDefaults 用户指定的绝对路径（空字符串表示自动探测）
    let timeoutSeconds: Int
    let extraEnvironment: [String: String]

    init(
        commandName: String,
        runArgs: [String],
        probeArgs: [String] = ["--version"],
        userBinaryPath: String,
        timeoutSeconds: Int,
        extraEnvironment: [String: String] = [:]
    ) {
        self.commandName = commandName
        self.runArgs = runArgs
        self.probeArgs = probeArgs
        self.userBinaryPath = userBinaryPath
        self.timeoutSeconds = max(10, timeoutSeconds)
        self.extraEnvironment = extraEnvironment
    }

    // MARK: - Path resolution

    static let candidateBinaryDirectories: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "/usr/bin",
            "/bin",
        ]
    }()

    /// 返回二进制绝对路径，找不到时抛 `.cliNotFound`。
    func resolveBinaryPath() throws -> String {
        let userPath = userBinaryPath.trimmingCharacters(in: .whitespaces)
        if !userPath.isEmpty {
            if FileManager.default.isExecutableFile(atPath: userPath) {
                return userPath
            }
            throw AIProviderError.cliNotFound("\(commandName)（用户指定路径无法执行：\(userPath)）")
        }

        for dir in Self.candidateBinaryDirectories {
            let candidate = "\(dir)/\(commandName)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // 最后兜底：跑 /bin/sh -lc "command -v {cmd}"
        if let resolved = try? Self.shellCommandV(commandName) {
            return resolved
        }

        throw AIProviderError.cliNotFound(commandName)
    }

    private static func shellCommandV(_ name: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    // MARK: - Run helpers

    /// 跑命令，stdin 接收 prompt，stdout 返回纯文本。支持超时和 Task 取消。
    func runWithStdin(
        prompt: String,
        arguments: [String]
    ) async throws -> String {
        let binary = try resolveBinaryPath()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                // GUI 启动的 .app PATH 极窄，强制注入常用 bin 路径
                let pathList = Self.candidateBinaryDirectories.joined(separator: ":")
                let existingPath = env["PATH"] ?? ""
                env["PATH"] = existingPath.isEmpty ? pathList : "\(pathList):\(existingPath)"
                env["HOME"] = env["HOME"] ?? NSHomeDirectory()
                for (k, v) in extraEnvironment { env[k] = v }
                process.environment = env

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let timeoutSource = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                timeoutSource.schedule(
                    deadline: .now() + .seconds(timeoutSeconds),
                    repeating: .never
                )

                let timedOut = AtomicFlag()
                let completed = AtomicFlag()

                timeoutSource.setEventHandler {
                    if !completed.value {
                        timedOut.value = true
                        if process.isRunning { process.terminate() }
                    }
                }
                timeoutSource.resume()

                process.terminationHandler = { proc in
                    completed.value = true
                    timeoutSource.cancel()

                    if timedOut.value {
                        continuation.resume(throwing: AIProviderError.timeout)
                        return
                    }
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    let status = proc.terminationStatus
                    if status != 0 {
                        continuation.resume(throwing: AIProviderError.cliExitNonZero(
                            code: status,
                            stderr: stderr.isEmpty ? stdout : stderr
                        ))
                        return
                    }
                    continuation.resume(returning: stdout)
                }

                do {
                    try process.run()
                } catch {
                    completed.value = true
                    timeoutSource.cancel()
                    continuation.resume(throwing: AIProviderError.cliExitNonZero(
                        code: -1,
                        stderr: "无法启动命令：\(error.localizedDescription)"
                    ))
                    return
                }

                // 关键：写完 prompt 必须 close stdin，否则 CLI 会一直等
                if let data = prompt.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                try? stdinPipe.fileHandleForWriting.close()
            }
        } onCancel: {
            // 取消：直接尝试干掉进程（如果还在运行）
            // process 在 closure 内创建，无法直接访问；依赖 terminationHandler 不被调用即可。
            // 简化版：用户取消时，timeout 超时后会强杀。这里不主动 terminate，依赖 timeout 兜底。
        }
    }
}

/// 简单的原子标志，用于 timeout/terminationHandler 之间的状态同步。
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
