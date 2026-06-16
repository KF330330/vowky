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
