import AppKit
import Foundation
import XCTest
@testable import VowKy

private struct MockFileTranscriptionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class MockFileTranscribing: FileTranscribing {
    enum Behavior {
        case success(String)
        case failure(String)
        case delayedSuccess(String, UInt64)
    }

    let behavior: Behavior
    private(set) var receivedURLs: [URL] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func transcribe(
        url: URL,
        progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
    ) async throws -> String {
        receivedURLs.append(url)
        await progress(FileTranscriptionProgress(
            phase: .transcribing,
            progress: 0.25,
            currentSegment: 1,
            totalSegments: 1,
            partialText: "partial"
        ))

        switch behavior {
        case .success(let text):
            return text
        case .failure(let message):
            throw MockFileTranscriptionError(message: message)
        case .delayedSuccess(let text, let delay):
            try await Task.sleep(nanoseconds: delay)
            return text
        }
    }
}


/// 链接下载器 mock：绝不联网、绝不 spawn 进程。
/// `hold = true` 时 `download` 发完事件后挂起，测试可用 `emit(_:)` 手动喂进度、断言下载中的中间状态。
private final class MockURLDownloader: URLMediaDownloading, @unchecked Sendable {
    enum Behavior {
        /// 依次发出给定进度事件，最后返回字幕文字。
        case progressThenTranscript([DownloadProgress], String)
        /// 一直挂着直到外部取消（`Task.sleep` 抛 CancellationError）。
        case waitForCancellation
        /// 立即抛「工具准备失败」。
        case failToolSetup(String)
    }

    private let behavior: Behavior
    private let hold: Bool
    private let lock = NSLock()
    private var released = false
    private var progressSink: (@MainActor (DownloadProgress) -> Void)?
    private var calls: [String] = []

    init(_ behavior: Behavior, hold: Bool = false) {
        self.behavior = behavior
        self.hold = hold
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    var receivedURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func release() {
        lock.lock(); released = true; lock.unlock()
    }

    private var isReleased: Bool {
        lock.lock(); defer { lock.unlock() }
        return released
    }

    /// 在 `hold` 挂起期间手动喂一条进度事件（同步执行，返回后即可断言）。
    @MainActor
    func emit(_ update: DownloadProgress) {
        lock.lock()
        let sink = progressSink
        lock.unlock()
        sink?(update)
    }

    private func recordCall(_ urlString: String, _ progress: @escaping @MainActor (DownloadProgress) -> Void) {
        lock.lock()
        calls.append(urlString)
        progressSink = progress
        lock.unlock()
    }

    func download(
        urlString: String,
        into workDir: URL,
        cookies: CookieSource,
        subtitlePriority: SubtitlePriority,
        progress: @escaping @MainActor (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        // 加锁写状态放在同步方法里：async 函数里直接 NSLock.lock() 会触发
        // 「unavailable from asynchronous contexts」告警。
        recordCall(urlString, progress)

        switch behavior {
        case .progressThenTranscript(let events, let text):
            for event in events {
                await progress(event)
            }
            while hold, !isReleased {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return .transcript(text: text, source: .manualSubtitle(language: "en"), title: "mock")
        case .waitForCancellation:
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        case .failToolSetup(let reason):
            throw URLDownloadError.toolSetupFailed(reason)
        }
    }
}

@MainActor
final class FileTranscriptionViewModelTests: XCTestCase {
    private var appState: AppState!

    override func setUp() {
        super.setUp()
        appState = AppState(
            speechRecognizer: MockSpeechRecognizer(),
            audioRecorder: MockAudioRecorder(),
            permissionChecker: MockPermissionChecker()
        )
    }

    override func tearDown() {
        appState = nil
        super.tearDown()
    }

    func testFastSingleStreamServiceCompletesJobCleanly() async throws {
        // SpeechAnalyzer 式引擎:单流快速完成(reading→transcribing→finishing 一口气),VM 状态机不被打乱
        final class FastSingleStreamService: FileTranscribing {
            func transcribe(
                url: URL,
                progress: @escaping @MainActor (FileTranscriptionProgress) -> Void
            ) async throws -> String {
                await progress(FileTranscriptionProgress(
                    phase: .reading, progress: 0, currentSegment: 0, totalSegments: 0, partialText: ""))
                await progress(FileTranscriptionProgress(
                    phase: .transcribing, progress: 0.5, currentSegment: 1, totalSegments: 2, partialText: "前半"))
                await progress(FileTranscriptionProgress(
                    phase: .finishing, progress: 1, currentSegment: 2, totalSegments: 2, partialText: "前半后半"))
                return "前半后半"
            }
        }

        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { FastSingleStreamService() }
        )
        viewModel.appendJobs(urls: [URL(fileURLWithPath: "/tmp/fast.mp4")])
        viewModel.startTranscription()
        try await waitUntil("fast job completes") {
            viewModel.jobs.first?.state == .completed
        }

        XCTAssertEqual(viewModel.jobs.count, 1)
        XCTAssertEqual(viewModel.jobs[0].state, .completed)
        XCTAssertEqual(viewModel.jobs[0].resultText, "前半后半")
        XCTAssertEqual(viewModel.jobs[0].progress, 1)
    }

    func testBatchTranscribesInOrderAndContinuesAfterFailure() async throws {
        let services = [
            MockFileTranscribing(.success("第一个结果")),
            MockFileTranscribing(.failure("第二个失败")),
            MockFileTranscribing(.success("第三个结果"))
        ]
        var serviceIndex = 0
        var recordedResults: [String] = []

        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: {
                defer { serviceIndex += 1 }
                return services[serviceIndex]
            },
            resultRecorder: { recordedResults.append($0) }
        )

        let urls = [
            URL(fileURLWithPath: "/tmp/one.mp4"),
            URL(fileURLWithPath: "/tmp/two.m4a"),
            URL(fileURLWithPath: "/tmp/three.mp3")
        ]
        viewModel.appendJobs(urls: urls)

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertTrue(viewModel.canStartTranscription)
        XCTAssertTrue(services.allSatisfy { $0.receivedURLs.isEmpty })

        viewModel.startTranscription()

        try await waitUntil("batch completes") {
            !viewModel.isRunning
        }

        XCTAssertEqual(services.map { $0.receivedURLs.first?.lastPathComponent }, ["one.mp4", "two.m4a", "three.mp3"])
        XCTAssertEqual(viewModel.jobs.map(\.fileName), ["one.mp4", "two.m4a", "three.mp3"])
        XCTAssertEqual(viewModel.jobs[0].state, .completed)
        XCTAssertEqual(viewModel.jobs[0].resultText, "第一个结果")
        XCTAssertEqual(viewModel.jobs[2].state, .completed)
        XCTAssertEqual(viewModel.jobs[2].resultText, "第三个结果")
        if case .failed(let message) = viewModel.jobs[1].state {
            XCTAssertEqual(message, "第二个失败")
        } else {
            XCTFail("Expected second job to fail")
        }
        XCTAssertEqual(recordedResults, ["第一个结果", "第三个结果"])
        XCTAssertFalse(appState.isFileTranscriptionInProgress)
    }

    func testCancelStopsCurrentJobAndSkipsQueuedJobsWithoutRecordingHistory() async throws {
        let services = [
            MockFileTranscribing(.delayedSuccess("不应写入", 1_000_000_000)),
            MockFileTranscribing(.success("不应开始"))
        ]
        var serviceIndex = 0
        var recordedResults: [String] = []

        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: {
                defer { serviceIndex += 1 }
                return services[serviceIndex]
            },
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.appendJobs(urls: [
            URL(fileURLWithPath: "/tmp/current.mp4"),
            URL(fileURLWithPath: "/tmp/queued.mp4")
        ])
        viewModel.startTranscription()

        try await waitUntil("first job starts") {
            if case .transcribing = viewModel.jobs.first?.state {
                return true
            }
            return false
        }

        viewModel.cancel()

        try await waitUntil("cancel completes") {
            !viewModel.isRunning
        }

        XCTAssertEqual(services[0].receivedURLs.first?.lastPathComponent, "current.mp4")
        XCTAssertTrue(services[1].receivedURLs.isEmpty)
        XCTAssertEqual(viewModel.jobs.map(\.state), [.cancelled, .cancelled])
        XCTAssertTrue(viewModel.canStartTranscription)
        XCTAssertEqual(viewModel.queueHeaderStatusText, L("file.header.cancelledCanRestart"))
        XCTAssertEqual(recordedResults, [])
        XCTAssertFalse(appState.isFileTranscriptionInProgress)
    }

    func testCancelledJobsCanBeStartedAgain() async throws {
        let services = [
            MockFileTranscribing(.delayedSuccess("不应写入", 1_000_000_000)),
            MockFileTranscribing(.success("当前重跑结果")),
            MockFileTranscribing(.success("排队重跑结果"))
        ]
        var serviceIndex = 0
        var recordedResults: [String] = []

        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: {
                defer { serviceIndex += 1 }
                return services[serviceIndex]
            },
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.appendJobs(urls: [
            URL(fileURLWithPath: "/tmp/current.mp4"),
            URL(fileURLWithPath: "/tmp/queued.mp4")
        ])
        viewModel.startTranscription()

        try await waitUntil("first job starts") {
            if case .transcribing = viewModel.jobs.first?.state {
                return true
            }
            return false
        }

        viewModel.cancel()

        try await waitUntil("cancel completes") {
            !viewModel.isRunning
        }

        XCTAssertEqual(viewModel.jobs.map(\.state), [.cancelled, .cancelled])
        XCTAssertTrue(viewModel.canStartTranscription)

        viewModel.startTranscription()

        try await waitUntil("restart completes") {
            !viewModel.isRunning
        }

        XCTAssertEqual(
            services.map { $0.receivedURLs.first?.lastPathComponent },
            ["current.mp4", "current.mp4", "queued.mp4"]
        )
        XCTAssertEqual(viewModel.jobs.map(\.state), [.completed, .completed])
        XCTAssertEqual(recordedResults, ["当前重跑结果", "排队重跑结果"])
    }

    func testStartSingleJobOnlyTranscribesThatJob() async throws {
        let service = MockFileTranscribing(.success("第二个结果"))
        var recordedResults: [String] = []
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { service },
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.appendJobs(urls: [
            URL(fileURLWithPath: "/tmp/one.mp4"),
            URL(fileURLWithPath: "/tmp/two.mp4")
        ])

        let secondJobID = viewModel.jobs[1].id
        XCTAssertTrue(viewModel.canStartJob(viewModel.jobs[0]))
        XCTAssertTrue(viewModel.canStartJob(viewModel.jobs[1]))

        viewModel.startTranscription(id: secondJobID)

        try await waitUntil("single job completes") {
            !viewModel.isRunning
        }

        XCTAssertEqual(service.receivedURLs.map(\.lastPathComponent), ["two.mp4"])
        XCTAssertEqual(viewModel.jobs[0].state, .queued)
        XCTAssertEqual(viewModel.jobs[1].state, .completed)
        XCTAssertEqual(viewModel.jobs[1].resultText, "第二个结果")
        XCTAssertEqual(recordedResults, ["第二个结果"])
        XCTAssertTrue(viewModel.canStartTranscription)
    }

    func testCancelSingleJobLeavesOtherQueuedJobsReady() async throws {
        let service = MockFileTranscribing(.delayedSuccess("不应写入", 1_000_000_000))
        var recordedResults: [String] = []
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { service },
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.appendJobs(urls: [
            URL(fileURLWithPath: "/tmp/one.mp4"),
            URL(fileURLWithPath: "/tmp/two.mp4")
        ])

        viewModel.startTranscription(id: viewModel.jobs[0].id)

        try await waitUntil("single job starts") {
            if case .transcribing = viewModel.jobs.first?.state {
                return true
            }
            return false
        }

        viewModel.cancel()

        try await waitUntil("single cancel completes") {
            !viewModel.isRunning
        }

        XCTAssertEqual(service.receivedURLs.map(\.lastPathComponent), ["one.mp4"])
        XCTAssertEqual(viewModel.jobs.map(\.state), [.cancelled, .queued])
        XCTAssertEqual(recordedResults, [])
        XCTAssertTrue(viewModel.canStartTranscription)
    }

    func testAppendJobsDoesNotStartAutomaticallyAndDeduplicatesURLs() {
        let service = MockFileTranscribing(.success("结果"))
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { service },
            resultRecorder: { _ in }
        )

        let url = URL(fileURLWithPath: "/tmp/same.mp4")
        viewModel.appendJobs(urls: [url, url])

        XCTAssertEqual(viewModel.jobs.map(\.fileName), ["same.mp4"])
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertTrue(viewModel.canStartTranscription)
        XCTAssertTrue(service.receivedURLs.isEmpty)
        XCTAssertEqual(viewModel.queueRowStatusText(for: viewModel.jobs[0]), L("file.row.waiting"))
        XCTAssertFalse(viewModel.shouldShowProgress(for: viewModel.jobs[0]))
    }

    func testAppendJobsRecordsFileSize() throws {
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { MockFileTranscribing(.success("结果")) },
            resultRecorder: { _ in }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try Data(repeating: 1, count: 1_536).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.appendJobs(urls: [url])

        let job = try XCTUnwrap(viewModel.jobs.first)
        XCTAssertEqual(job.fileSize, Int64(1_536))
        XCTAssertFalse((viewModel.fileSizeText(for: job) ?? "").isEmpty)
    }

    func testRemoveJobDeletesQueuedItemAndUpdatesSelection() {
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { MockFileTranscribing(.success("结果")) },
            resultRecorder: { _ in }
        )
        viewModel.appendJobs(urls: [
            URL(fileURLWithPath: "/tmp/one.mp4"),
            URL(fileURLWithPath: "/tmp/two.mp4"),
            URL(fileURLWithPath: "/tmp/three.mp4")
        ])

        let secondJobID = viewModel.jobs[1].id
        viewModel.selectJob(secondJobID)
        viewModel.removeJob(secondJobID)

        XCTAssertEqual(viewModel.jobs.map(\.fileName), ["one.mp4", "three.mp4"])
        XCTAssertEqual(viewModel.selectedJob?.fileName, "three.mp4")

        viewModel.removeJob(viewModel.jobs[0].id)
        XCTAssertEqual(viewModel.jobs.map(\.fileName), ["three.mp4"])
        XCTAssertEqual(viewModel.selectedJob?.fileName, "three.mp4")

        viewModel.removeJob(viewModel.jobs[0].id)
        XCTAssertTrue(viewModel.jobs.isEmpty)
        XCTAssertNil(viewModel.selectedJobID)
    }

    func testCanAppendQueuedFileWhileTranscriptionIsRunning() async throws {
        let services = [
            MockFileTranscribing(.delayedSuccess("第一个结果", 80_000_000)),
            MockFileTranscribing(.success("追加结果"))
        ]
        var serviceIndex = 0
        var recordedResults: [String] = []

        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: {
                defer { serviceIndex += 1 }
                return services[serviceIndex]
            },
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.appendJobs(urls: [URL(fileURLWithPath: "/tmp/current.mp4")])
        viewModel.startTranscription()

        try await waitUntil("first job starts") {
            if case .transcribing = viewModel.jobs.first?.state {
                return true
            }
            return false
        }

        viewModel.appendJobs(urls: [URL(fileURLWithPath: "/tmp/appended.mp4")])

        XCTAssertEqual(viewModel.jobs.map(\.fileName), ["current.mp4", "appended.mp4"])
        XCTAssertEqual(viewModel.jobs[1].state, .queued)
        XCTAssertEqual(viewModel.queueRowStatusText(for: viewModel.jobs[1]), L("file.row.waiting"))
        XCTAssertFalse(viewModel.shouldShowProgress(for: viewModel.jobs[1]))
        XCTAssertEqual(viewModel.selectedJob?.fileName, "current.mp4")

        try await waitUntil("appended job completes") {
            !viewModel.isRunning
        }

        XCTAssertEqual(services.map { $0.receivedURLs.first?.lastPathComponent }, ["current.mp4", "appended.mp4"])
        XCTAssertEqual(viewModel.jobs.map(\.state), [.completed, .completed])
        XCTAssertEqual(recordedResults, ["第一个结果", "追加结果"])
    }

    func testSingleFailureWithoutTextMarksJobFailed() async throws {
        let service = MockFileTranscribing(.failure("真实失败"))
        var recordedResults: [String] = []
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { service },
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.appendJobs(urls: [URL(fileURLWithPath: "/tmp/failure.mp4")])
        viewModel.startTranscription()

        try await waitUntil("failure completes") {
            !viewModel.isRunning
        }

        if case .failed(let message) = viewModel.jobs.first?.state {
            XCTAssertEqual(message, "真实失败")
        } else {
            XCTFail("Expected failed job")
        }
        XCTAssertEqual(recordedResults, [])
    }

    func testQueueRowDisplayStateAvoidsQueuedZeroPercent() {
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { MockFileTranscribing(.success("结果")) },
            resultRecorder: { _ in }
        )

        let url = URL(fileURLWithPath: "/tmp/sample.mp4")
        let queued = FileTranscriptionJob(url: url, fileName: "sample.mp4", state: .queued, progress: 0)
        let reading = FileTranscriptionJob(url: url, fileName: "sample.mp4", state: .reading, progress: 0.25)
        let transcribing = FileTranscriptionJob(url: url, fileName: "sample.mp4", state: .transcribing, progress: 0.52)
        let completed = FileTranscriptionJob(url: url, fileName: "sample.mp4", state: .completed, progress: 1)
        let failed = FileTranscriptionJob(url: url, fileName: "sample.mp4", state: .failed("尾段失败"), progress: 0.96)
        let cancelled = FileTranscriptionJob(url: url, fileName: "sample.mp4", state: .cancelled, progress: 0.4)

        XCTAssertEqual(viewModel.queueRowStatusText(for: queued), L("file.row.waiting"))
        XCTAssertFalse(viewModel.shouldShowProgress(for: queued))
        XCTAssertEqual(viewModel.queueRowStatusText(for: reading), "25%")
        XCTAssertTrue(viewModel.shouldShowProgress(for: reading))
        XCTAssertEqual(viewModel.queueRowStatusText(for: transcribing), "52%")
        XCTAssertTrue(viewModel.shouldShowProgress(for: transcribing))
        XCTAssertEqual(viewModel.queueRowStatusText(for: completed), L("file.row.completed"))
        XCTAssertFalse(viewModel.shouldShowProgress(for: completed))
        XCTAssertEqual(viewModel.queueRowStatusText(for: failed), L("file.row.failed"))
        XCTAssertFalse(viewModel.shouldShowProgress(for: failed))
        XCTAssertEqual(viewModel.queueRowStatusText(for: cancelled), L("file.row.cancelled"))
        XCTAssertFalse(viewModel.shouldShowProgress(for: cancelled))
    }

    func testEditingCompletedResultUpdatesWindowActionsWithoutChangingRecordedHistory() async throws {
        let service = MockFileTranscribing(.success("原始结果"))
        var recordedResults: [String] = []
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { service },
            resultRecorder: { recordedResults.append($0) }
        )

        viewModel.appendJobs(urls: [URL(fileURLWithPath: "/tmp/editable.mp4")])
        XCTAssertFalse(viewModel.canEditSelectedResult)
        viewModel.updateSelectedResultText("不应写入")
        XCTAssertEqual(viewModel.resultText, "")

        viewModel.startTranscription()

        try await waitUntil("editable job completes") {
            !viewModel.isRunning
        }

        XCTAssertEqual(viewModel.jobs.first?.state, .completed)
        XCTAssertEqual(viewModel.resultText, "原始结果")
        XCTAssertTrue(viewModel.canEditSelectedResult)

        viewModel.updateSelectedResultText("编辑后的结果")

        XCTAssertEqual(viewModel.resultText, "编辑后的结果")
        XCTAssertEqual(viewModel.jobs.first?.resultText, "编辑后的结果")
        XCTAssertEqual(recordedResults, ["原始结果"])

        NSPasteboard.general.clearContents()
        viewModel.copyResult()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "编辑后的结果")
    }

    func testTranscribingResultIsReadOnlyButCancelledDraftCanBeEdited() async throws {
        let service = MockFileTranscribing(.delayedSuccess("最终结果", 1_000_000_000))
        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { service },
            resultRecorder: { _ in }
        )

        viewModel.appendJobs(urls: [URL(fileURLWithPath: "/tmp/cancel-draft.mp4")])
        viewModel.startTranscription()

        try await waitUntil("job starts with partial text") {
            viewModel.resultText == "partial"
        }

        XCTAssertFalse(viewModel.canEditSelectedResult)
        viewModel.updateSelectedResultText("转录中不应编辑")
        XCTAssertEqual(viewModel.resultText, "partial")

        viewModel.cancel()

        try await waitUntil("cancel leaves draft") {
            !viewModel.isRunning
        }

        XCTAssertEqual(viewModel.jobs.first?.state, .cancelled)
        XCTAssertEqual(viewModel.resultText, "partial")
        XCTAssertTrue(viewModel.canEditSelectedResult)

        viewModel.updateSelectedResultText("取消后的草稿编辑")
        XCTAssertEqual(viewModel.resultText, "取消后的草稿编辑")
    }

    // MARK: - 链接任务：准备下载工具的进度 / 文案 / 取消 / 拒收

    private func makeURLViewModel(_ mock: MockURLDownloader) -> FileTranscriptionViewModel {
        FileTranscriptionViewModel(
            appState: appState,
            fileTranscriptionServiceFactory: { MockFileTranscribing(.success("x")) },
            urlDownloadServiceFactory: { mock },
            cookieSourceProvider: { .none },
            subtitlePriorityProvider: { .all },
            yieldToVoiceInput: {},
            resultRecorder: { _ in }
        )
    }

    private func toolEvent(_ toolProgress: ToolProvisionProgress) -> DownloadProgress {
        DownloadProgress(
            phase: .provisioningTools,
            fractionCompleted: toolProgress.phase == .ready ? -1 : toolProgress.fractionCompleted,
            toolName: toolProgress.tool.isEmpty ? nil : toolProgress.tool,
            toolProgress: toolProgress
        )
    }

    func test_provisioningProgress_updatesJobFields() async throws {
        let mock = MockURLDownloader(.progressThenTranscript([], "字幕文字"), hold: true)
        let viewModel = makeURLViewModel(mock)
        viewModel.appendURLJobs(rawText: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        viewModel.startTranscription()
        try await waitUntil("downloader called") { mock.callCount == 1 }

        // 第 1 个工具下载到一半：整体进度 = (1-1 + 0.5) / 2 = 0.25
        mock.emit(toolEvent(ToolProvisionProgress(
            phase: .downloading, tool: "yt-dlp", fractionCompleted: 0.5,
            bytesReceived: 18 * 1024 * 1024, totalBytes: 36 * 1024 * 1024,
            bytesPerSecond: 2 * 1024 * 1024, toolIndex: 1, toolCount: 2
        )))

        let job = try XCTUnwrap(viewModel.jobs.first)
        XCTAssertEqual(job.progress, 0.25, accuracy: 0.001)
        let statusText = viewModel.jobStatusText(job)
        XCTAssertTrue(statusText.contains("yt-dlp"), "状态文案应含工具名: \(statusText)")
        XCTAssertTrue(statusText.contains("1/2"), "状态文案应含序号: \(statusText)")
        let rowText = viewModel.queueRowStatusText(for: job)
        XCTAssertTrue(rowText.hasPrefix(L("file.phase.provisioningTools")), "队列行文案: \(rowText)")
        XCTAssertTrue(rowText.contains("25%"), "队列行应含百分比: \(rowText)")

        // 第 2 个工具刚开始：整体进度 = (2-1 + 0) / 2 = 0.5
        mock.emit(toolEvent(ToolProvisionProgress(
            phase: .downloading, tool: "ffmpeg", fractionCompleted: 0,
            bytesReceived: 0, totalBytes: 63 * 1024 * 1024,
            bytesPerSecond: 1024 * 1024, toolIndex: 2, toolCount: 2
        )))
        XCTAssertEqual(try XCTUnwrap(viewModel.jobs.first).progress, 0.5, accuracy: 0.001)

        mock.release()
        try await waitUntil("job completes") { !viewModel.isRunning }
    }

    func test_refreshChecking_showsRefreshText() async throws {
        let mock = MockURLDownloader(.progressThenTranscript([], "字幕文字"), hold: true)
        let viewModel = makeURLViewModel(mock)
        viewModel.appendURLJobs(rawText: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        viewModel.startTranscription()
        try await waitUntil("downloader called") { mock.callCount == 1 }

        mock.emit(toolEvent(ToolProvisionProgress(
            phase: .checking, tool: "", fractionCompleted: -1, isRefresh: true
        )))

        let job = try XCTUnwrap(viewModel.jobs.first)
        XCTAssertEqual(viewModel.jobStatusText(job), L("file.status.refreshingTools"))

        mock.release()
        try await waitUntil("job completes") { !viewModel.isRunning }
    }

    func test_readyThenSubtitlePhase_progressResets() async throws {
        let mock = MockURLDownloader(.progressThenTranscript([], "字幕文字"), hold: true)
        let viewModel = makeURLViewModel(mock)
        viewModel.appendURLJobs(rawText: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        viewModel.startTranscription()
        try await waitUntil("downloader called") { mock.callCount == 1 }

        // `.ready` 不再带 fraction 1（旧行为会把进度条打满，后续阶段又不刷新 → 「下载中但已满格」）。
        mock.emit(toolEvent(ToolProvisionProgress(
            phase: .ready, tool: "", fractionCompleted: -1, toolCount: 2
        )))
        XCTAssertEqual(try XCTUnwrap(viewModel.jobs.first).progress, 0, accuracy: 0.001)

        mock.emit(DownloadProgress(phase: .fetchingSubtitles, fractionCompleted: -1))
        XCTAssertEqual(try XCTUnwrap(viewModel.jobs.first).progress, 0, accuracy: 0.001)

        mock.emit(DownloadProgress(phase: .downloading, fractionCompleted: 0.4))
        XCTAssertEqual(try XCTUnwrap(viewModel.jobs.first).progress, 0.4, accuracy: 0.001)

        // 回归「进度条满」本体：工具阶段涨到 1 后切阶段必须归零。
        mock.emit(toolEvent(ToolProvisionProgress(
            phase: .downloading, tool: "ffmpeg", fractionCompleted: 1,
            bytesReceived: 63 * 1024 * 1024, totalBytes: 63 * 1024 * 1024,
            bytesPerSecond: -1, toolIndex: 1, toolCount: 1
        )))
        XCTAssertEqual(try XCTUnwrap(viewModel.jobs.first).progress, 1, accuracy: 0.001)
        // 收尾的 .ready 与前一条同属 .provisioningTools，外层阶段没变 → 必须由 .ready 自己清零。
        mock.emit(toolEvent(ToolProvisionProgress(
            phase: .ready, tool: "", fractionCompleted: -1, toolCount: 1
        )))
        XCTAssertEqual(try XCTUnwrap(viewModel.jobs.first).progress, 0, accuracy: 0.001)
        mock.emit(DownloadProgress(phase: .fetchingSubtitles, fractionCompleted: -1))
        XCTAssertEqual(try XCTUnwrap(viewModel.jobs.first).progress, 0, accuracy: 0.001)

        mock.release()
        try await waitUntil("job completes") { !viewModel.isRunning }
    }

    func test_cancelDuringProvisioning_marksCancelledNotFailed() async throws {
        let mock = MockURLDownloader(.waitForCancellation)
        let viewModel = makeURLViewModel(mock)
        viewModel.appendURLJobs(rawText: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        viewModel.startTranscription()
        try await waitUntil("downloader called") { mock.callCount == 1 }

        viewModel.cancel()
        try await waitUntil("cancel completes") { !viewModel.isRunning }

        XCTAssertEqual(viewModel.jobs.first?.state, .cancelled)
    }

    func test_toolSetupFailure_marksFailedWithLogHint() async throws {
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VowKyToolsLogTest-\(UUID().uuidString).log")
        ToolLogger.overrideLogURL = logURL
        defer { ToolLogger.overrideLogURL = nil }

        let mock = MockURLDownloader(.failToolSetup("下载 yt-dlp 失败：x"))
        let viewModel = makeURLViewModel(mock)
        viewModel.appendURLJobs(rawText: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        viewModel.startTranscription()
        try await waitUntil("failure settles") { !viewModel.isRunning }

        guard case .failed(let message) = try XCTUnwrap(viewModel.jobs.first).state else {
            return XCTFail("应为失败态: \(String(describing: viewModel.jobs.first?.state))")
        }
        XCTAssertTrue(message.contains("下载 yt-dlp 失败：x"), "应保留原始原因: \(message)")
        XCTAssertTrue(message.contains(ToolLogger.logFilePath), "应带日志路径: \(message)")
    }

    func test_appendURLJobs_playlistMarkedFailed() async throws {
        let mock = MockURLDownloader(.progressThenTranscript([], "字幕文字"))
        let viewModel = makeURLViewModel(mock)
        viewModel.appendURLJobs(rawText: "https://www.youtube.com/@x/videos https://youtu.be/abc")

        XCTAssertEqual(viewModel.jobs.count, 2)
        XCTAssertEqual(viewModel.jobs[0].state, .failed(L("file.url.error.playlist")))
        XCTAssertEqual(viewModel.jobs[1].state, .queued)

        viewModel.startTranscription()
        try await waitUntil("second job completes") { !viewModel.isRunning }

        XCTAssertEqual(mock.callCount, 1, "只应下载被放行的那一条")
        XCTAssertEqual(mock.receivedURLs, ["https://youtu.be/abc"])
    }

    func test_provisioningStatusText_pureFunction() {
        XCTAssertEqual(
            FileTranscriptionViewModel.provisioningStatusText(nil),
            L("file.status.provisioningTools")
        )

        let withTotal = FileTranscriptionViewModel.provisioningStatusText(ToolProvisionProgress(
            phase: .downloading, tool: "yt-dlp", fractionCompleted: 0.5,
            bytesReceived: 18 * 1024 * 1024, totalBytes: 36 * 1024 * 1024,
            bytesPerSecond: 2 * 1024 * 1024, toolIndex: 1, toolCount: 2
        ))
        XCTAssertTrue(withTotal.contains(" / "), "已知总量应显示「已下载 / 总量」: \(withTotal)")

        let unknownTotal = FileTranscriptionViewModel.provisioningStatusText(ToolProvisionProgress(
            phase: .downloading, tool: "yt-dlp", fractionCompleted: -1,
            bytesReceived: 18 * 1024 * 1024, totalBytes: -1,
            bytesPerSecond: 2 * 1024 * 1024, toolIndex: 1, toolCount: 2
        ))
        XCTAssertFalse(unknownTotal.contains(" / "), "总量未知不应显示分母: \(unknownTotal)")

        let unknownSpeed = FileTranscriptionViewModel.provisioningStatusText(ToolProvisionProgress(
            phase: .downloading, tool: "yt-dlp", fractionCompleted: -1,
            bytesReceived: 18 * 1024 * 1024, totalBytes: -1,
            bytesPerSecond: -1, toolIndex: 1, toolCount: 2
        ))
        XCTAssertFalse(unknownSpeed.contains("/秒"), "速度未知不应显示速率: \(unknownSpeed)")
        XCTAssertFalse(unknownSpeed.contains("/s"), "速度未知不应显示速率: \(unknownSpeed)")
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
