import AppKit
import SwiftUI
import UniformTypeIdentifiers
// MARK: - State

enum FileTranscriptionJobState: Equatable {
    case queued
    case downloading
    case reading
    case transcribing
    case completed
    case cancelled
    case failed(String)
}

struct FileTranscriptionJob: Identifiable, Equatable {
    /// 本地文件 or 视频链接。
    enum Kind: Equatable { case localFile, remoteURL }

    let id = UUID()
    let url: URL
    var fileName: String
    var fileSize: Int64?
    var state: FileTranscriptionJobState = .queued
    var progress: Double = 0
    var resultText: String = ""
    var currentSegment: Int = 0
    var totalSegments: Int = 0

    /// 实际落盘的 .md 路径；nil 表示尚未写盘（写权限不足 / 转写未完成）
    var markdownURL: URL?

    // MARK: 链接任务专用
    var kind: Kind = .localFile
    /// 原始粘贴的链接（远程任务的去重键）。
    var remoteURLString: String?
    /// 下载完成后的本地媒体文件；nil 表示尚未下载。
    var mediaURL: URL?
    /// 该任务的临时下载目录，用完即删。
    var workDir: URL?
    /// 下载子阶段（准备工具 / 解析 / 下载 / 提取音频），用于显示更准确的状态文案。
    var downloadPhase: DownloadProgress.Phase?
    /// 文字来源：直接拉到平台字幕时记录人工/自动，nil 表示走本地 ASR 转写。
    var transcriptSource: TranscriptSource?

    /// 实际喂给转写管线的本地文件 URL：链接任务用下载产物，本地任务用自身 url。
    var transcriptionInputURL: URL { mediaURL ?? url }

    var isFinished: Bool {
        switch state {
        case .completed, .cancelled, .failed:
            return true
        case .queued, .downloading, .reading, .transcribing:
            return false
        }
    }
}

// MARK: - View Model

@MainActor
final class FileTranscriptionViewModel: ObservableObject {
    /// UserDefaults 里存 cookie 来源（与 SettingsView 共用）。
    static let cookieSourceDefaultsKey = "urlDownload.cookieSource"
    /// UserDefaults 里存字幕优先级（与 SettingsView 共用）。
    static let subtitlePriorityDefaultsKey = "urlDownload.subtitlePriority"

    @Published private(set) var jobs: [FileTranscriptionJob] = []
    @Published private(set) var selectedJobID: UUID?
    @Published private(set) var hasInsertionTarget = false
    @Published private(set) var statusMessage: String?
    /// URL 输入框绑定。
    @Published var urlInputText: String = ""

    private let appState: AppState
    private let fileTranscriptionServiceFactory: () -> FileTranscribing
    private let urlDownloadServiceFactory: () -> URLMediaDownloading
    private let cookieSourceProvider: () -> CookieSource
    private let subtitlePriorityProvider: () -> SubtitlePriority
    private let yieldToVoiceInput: () async -> Void
    private let resultRecorder: (String) -> Void
    /// 带元数据写历史库的闭包。仅生产环境（窗口控制器）注入；测试不注入即为 nil，绝不触碰真实 DB。
    private let metadataRecorder: ((String, TranscriptionMetadata) -> Void)?
    private var transcriptionTask: Task<Void, Never>?
    private var activeTargetJobIDs: Set<UUID>?

    init(
        appState: AppState,
        fileTranscriptionServiceFactory: (() -> FileTranscribing)? = nil,
        urlDownloadServiceFactory: (() -> URLMediaDownloading)? = nil,
        cookieSourceProvider: (() -> CookieSource)? = nil,
        subtitlePriorityProvider: (() -> SubtitlePriority)? = nil,
        yieldToVoiceInput: (() async -> Void)? = nil,
        resultRecorder: ((String) -> Void)? = nil,
        metadataRecorder: ((String, TranscriptionMetadata) -> Void)? = nil
    ) {
        self.appState = appState
        self.fileTranscriptionServiceFactory = fileTranscriptionServiceFactory ?? {
            appState.makeFileTranscriptionService()
        }
        self.urlDownloadServiceFactory = urlDownloadServiceFactory ?? {
            appState.makeURLDownloadService()
        }
        self.cookieSourceProvider = cookieSourceProvider ?? {
            let raw = UserDefaults.standard.string(forKey: FileTranscriptionViewModel.cookieSourceDefaultsKey) ?? "none"
            return CookieSource.fromRawValue(raw)
        }
        self.subtitlePriorityProvider = subtitlePriorityProvider ?? {
            let raw = UserDefaults.standard.string(forKey: FileTranscriptionViewModel.subtitlePriorityDefaultsKey) ?? "all"
            return SubtitlePriority.fromRawValue(raw)
        }
        self.yieldToVoiceInput = yieldToVoiceInput ?? { [weak appState] in
            await appState?.waitWhileVoiceInputActive()
        }
        self.resultRecorder = resultRecorder ?? { text in
            // 只更新菜单栏最近结果；历史库由 metadataRecorder 带元数据写入，避免重复插入。
            appState.recordRecognitionResult(text: text, sourceType: "file", persistToHistory: false)
        }
        self.metadataRecorder = metadataRecorder
        refreshInsertionTarget()
    }

    /// 为文件/链接转录结果构造历史元数据（标题=文件名/视频标题，路径=落盘的 .md）。
    private static func makeFileMetadata(title: String, markdownURL: URL?) -> TranscriptionMetadata {
        TranscriptionMetadata(
            id: UUID(),
            title: title,
            summary: "",
            audioPath: nil,
            markdownPath: markdownURL?.path ?? "",
            generatedAt: Date(),
            durationSeconds: nil,
            provider: "local",
            sourceType: "file",
            aiEnhancementSucceeded: false,
            warnings: []
        )
    }

    var isRunning: Bool {
        transcriptionTask != nil
    }

    var selectedJob: FileTranscriptionJob? {
        guard let selectedJobID else { return jobs.first }
        return jobs.first { $0.id == selectedJobID } ?? jobs.first
    }

    var fileName: String {
        selectedJob?.fileName ?? ""
    }

    var resultText: String {
        selectedJob?.resultText ?? ""
    }

    var progress: Double {
        guard !jobs.isEmpty else { return 0 }
        let total = jobs.reduce(0) { $0 + min(1, max(0, $1.progress)) }
        return total / Double(jobs.count)
    }

    var canUseResult: Bool {
        !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    var canEditSelectedResult: Bool {
        guard let selectedJob,
              !isRunning else {
            return false
        }

        switch selectedJob.state {
        case .completed, .cancelled:
            return true
        case .queued, .downloading, .reading, .transcribing, .failed:
            return false
        }
    }

    var canSaveAllResults: Bool {
        !isRunning && jobs.contains { !$0.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var canStartTranscription: Bool {
        !isRunning && jobs.contains { isStartable($0.state) }
    }

    var completedCount: Int {
        jobs.filter { $0.state == .completed }.count
    }

    var failedCount: Int {
        jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
    }

    var cancelledCount: Int {
        jobs.filter { $0.state == .cancelled }.count
    }

    var startableCount: Int {
        jobs.filter { isStartable($0.state) }.count
    }

    var totalFileSizeText: String? {
        let totalSize = jobs.compactMap(\.fileSize).reduce(Int64(0), +)
        guard totalSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var queueSummaryText: String {
        guard !jobs.isEmpty else { return L("file.summary.chooseOrDrop") }
        if isRunning {
            return L("file.summary.completedOfTotal", completedCount, jobs.count)
        }
        if failedCount > 0 {
            return L("file.summary.completedFailed", completedCount, failedCount)
        }
        if completedCount == jobs.count {
            return L("file.summary.allCompleted")
        }
        if jobs.allSatisfy({ $0.state == .cancelled }) {
            return L("file.summary.cancelledCanRestart")
        }
        return L("file.summary.pendingCount", startableCount)
    }

    var selectedJobStatusText: String {
        selectedJob.map(jobStatusText) ?? L("file.selectFile")
    }

    var selectedJobErrorMessage: String? {
        guard let selectedJob,
              case .failed(let message) = selectedJob.state else {
            return nil
        }
        return message
    }

    var canRetrySelectedJob: Bool {
        guard !isRunning,
              let selectedJob,
              case .failed = selectedJob.state else {
            return false
        }
        return true
    }

    func queueRowStatusText(for job: FileTranscriptionJob) -> String {
        switch job.state {
        case .queued:
            return L("file.row.waiting")
        case .downloading:
            // 真正下载阶段显示百分比；拉字幕子阶段显示「获取字幕」；其余子阶段显示短词。
            if job.downloadPhase == .downloading, job.progress > 0 {
                return "\(Int(clampedProgress(job.progress) * 100))%"
            }
            if job.downloadPhase == .fetchingSubtitles {
                return L("file.phase.fetchingSubtitle")
            }
            return L("file.row.downloading")
        case .reading, .transcribing:
            return "\(Int(clampedProgress(job.progress) * 100))%"
        case .completed:
            return L("file.row.completed")
        case .cancelled:
            return L("file.row.cancelled")
        case .failed:
            return L("file.row.failed")
        }
    }

    func shouldShowProgress(for job: FileTranscriptionJob) -> Bool {
        switch job.state {
        case .downloading, .reading, .transcribing:
            return true
        case .queued, .completed, .cancelled, .failed:
            return false
        }
    }

    func canRemoveJob(_ job: FileTranscriptionJob) -> Bool {
        switch job.state {
        case .downloading, .reading, .transcribing:
            return false
        case .queued, .completed, .cancelled, .failed:
            return true
        }
    }

    func fileSizeText(for job: FileTranscriptionJob) -> String? {
        guard let fileSize = job.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    func canStartJob(_ job: FileTranscriptionJob) -> Bool {
        !isRunning && isStartable(job.state)
    }

    func updateSelectedResultText(_ text: String) {
        guard canEditSelectedResult,
              let selectedJobID = selectedJob?.id else {
            return
        }
        updateJob(id: selectedJobID) { job in
            job.resultText = text
        }
    }

    func retrySelectedJob() {
        guard canRetrySelectedJob,
              let selectedJobID = selectedJob?.id else {
            return
        }
        updateJob(id: selectedJobID) { job in
            job.state = .queued
            job.progress = 0
            job.currentSegment = 0
            job.totalSegments = 0
            job.mediaURL = nil          // 链接任务重试需重新下载
            job.downloadPhase = nil
        }
        startTranscription(id: selectedJobID)
    }

    var hasStatusMessage: Bool {
        statusMessage != nil
    }

    var queueHeaderStatusText: String {
        if let statusMessage {
            return statusMessage
        }
        if isRunning {
            return L("file.header.transcribingCanAdd")
        }
        if canStartTranscription {
            if jobs.contains(where: { $0.state == .cancelled })
                && !jobs.contains(where: { $0.state == .queued }) {
                return L("file.header.cancelledCanRestart")
            }
            return L("file.header.readyToTranscribe")
        }
        return statusText
    }

    var statusText: String {
        guard !jobs.isEmpty else { return L("file.status.chooseOrDropMedia") }

        if isRunning {
            let finishedCount = jobs.filter(\.isFinished).count
            if let selectedJob {
                return "\(jobStatusText(selectedJob)) · \(finishedCount) / \(jobs.count)"
            }
            return L("file.status.transcribingProgress", finishedCount, jobs.count)
        }

        let failedCount = jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
        let completedCount = jobs.filter { $0.state == .completed }.count
        if failedCount > 0 {
            return L("file.status.completedFailedCount", completedCount, failedCount)
        }
        if completedCount == jobs.count {
            return L("file.status.allCompleted")
        }
        if jobs.allSatisfy({ $0.state == .cancelled }) {
            return L("file.status.cancelled")
        }
        return selectedJob.map(jobStatusText) ?? L("file.header.readyToTranscribe")
    }

    func refreshInsertionTarget() {
        hasInsertionTarget = appState.hasTextInsertionTarget
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = L("file.picker.chooseMedia")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.allowsOtherFileTypes = false

        guard panel.runModal() == .OK else { return }
        appendJobs(urls: panel.urls)
    }

    func appendJobs(urls: [URL]) {
        var seen = Set(jobs.map { normalizedFileKey($0.url) })
        let uniqueURLs = urls.reduce(into: [URL]()) { result, url in
            guard seen.insert(normalizedFileKey(url)).inserted else { return }
            result.append(url)
        }
        guard !uniqueURLs.isEmpty else { return }

        statusMessage = nil
        let newJobs = uniqueURLs.map {
            FileTranscriptionJob(
                url: $0,
                fileName: $0.lastPathComponent,
                fileSize: fileSize(for: $0)
            )
        }
        let shouldSelectFirstNewJob = !isRunning || selectedJobID == nil || jobs.isEmpty
        jobs.append(contentsOf: newJobs)
        if shouldSelectFirstNewJob {
            selectedJobID = newJobs.first?.id
        }
    }

    /// 从一段文本抽取 http(s) 链接，建为「链接转写」任务（支持多条、去重、非法提示）。
    func appendURLJobs(rawText: String) {
        let candidates = Self.extractURLs(from: rawText)
        guard !candidates.isEmpty else {
            if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = L("file.url.invalid")
            }
            return
        }
        var seen = Set(jobs.compactMap { $0.remoteURLString })
        let fresh = candidates.filter { seen.insert($0).inserted }
        urlInputText = ""
        guard !fresh.isEmpty else { return }

        statusMessage = nil
        let newJobs = fresh.map { urlString -> FileTranscriptionJob in
            var job = FileTranscriptionJob(
                url: URL(string: urlString) ?? URL(fileURLWithPath: "/"),
                fileName: Self.displayName(forURLString: urlString),
                fileSize: nil
            )
            job.kind = .remoteURL
            job.remoteURLString = urlString
            return job
        }
        let shouldSelectFirstNewJob = !isRunning || selectedJobID == nil || jobs.isEmpty
        jobs.append(contentsOf: newJobs)
        if shouldSelectFirstNewJob {
            selectedJobID = newJobs.first?.id
        }
    }

    /// 空状态「转录」按钮：抽取链接入队，并立即开始转写（无有效链接则只提示、不启动）。
    func addURLsAndStart(rawText: String) {
        let before = jobs.count
        appendURLJobs(rawText: rawText)
        guard jobs.count > before else { return }
        startTranscription()
    }

    /// 解析空白/换行分隔的多条 http(s) 链接。
    static func extractURLs(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'")) }
            .filter { ($0.hasPrefix("http://") || $0.hasPrefix("https://")) && URL(string: $0) != nil }
    }

    static func displayName(forURLString urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    func startTranscription() {
        startTranscription(targetJobIDs: nil)
    }

    func startTranscription(id: UUID) {
        startTranscription(targetJobIDs: [id])
    }

    private func startTranscription(targetJobIDs: Set<UUID>?) {
        guard !isRunning,
              jobs.contains(where: { shouldStartJob($0, targetJobIDs: targetJobIDs) }) else {
            return
        }

        if let reason = appState.beginFileTranscription() {
            statusMessage = reason
            return
        }
        statusMessage = nil
        activeTargetJobIDs = targetJobIDs

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                appState.endFileTranscription()
                transcriptionTask = nil
                activeTargetJobIDs = nil
                refreshInsertionTarget()
            }

            while let index = jobs.firstIndex(where: { shouldStartJob($0, targetJobIDs: targetJobIDs) }) {
                guard !Task.isCancelled else {
                    markUnfinishedJobsCancelled(targetJobIDs: targetJobIDs)
                    return
                }

                let jobID = jobs[index].id
                let job = jobs[index]
                selectedJobID = jobID

                // 链接任务：先把视频下成本地 .m4a，再走与本地文件完全相同的转写路径。
                if job.kind == .remoteURL, job.mediaURL == nil {
                    await yieldToVoiceInput()   // 礼让实时语音输入后再开始重活
                    guard !Task.isCancelled else {
                        markUnfinishedJobsCancelled(targetJobIDs: targetJobIDs)
                        return
                    }
                    let workDir = Self.makeWorkDir()
                    updateJob(id: jobID) { item in
                        item.state = .downloading
                        item.downloadPhase = .provisioningTools
                        item.progress = 0
                        item.resultText = ""
                        item.currentSegment = 0
                        item.totalSegments = 0
                        item.workDir = workDir
                    }
                    let downloader = urlDownloadServiceFactory()
                    do {
                        let result = try await downloader.download(
                            urlString: job.remoteURLString ?? "",
                            into: workDir,
                            cookies: cookieSourceProvider(),
                            subtitlePriority: subtitlePriorityProvider()
                        ) { [weak self] update in
                            self?.applyDownload(update, to: jobID)
                        }
                        guard !Task.isCancelled else {
                            updateJob(id: jobID) { $0.state = .cancelled }
                            cleanupWorkDir(for: jobID)
                            markUnfinishedJobsCancelled(targetJobIDs: targetJobIDs)
                            return
                        }
                        switch result {
                        case .media(let media):
                            updateJob(id: jobID) { item in
                                item.mediaURL = media.mediaURL
                                item.fileName = Self.sanitizedFileNameStatic(media.rawTitle)
                                item.downloadPhase = nil
                            }
                            // 落到下面与本地文件相同的 reading/transcribing 路径。
                        case .transcript(let text, let source, let title):
                            // 直接拿到平台字幕：跳过下载媒体 + ASR，直接出文字并落盘。
                            let displayTitle = Self.sanitizedFileNameStatic(title)
                            updateJob(id: jobID) { item in
                                item.fileName = displayTitle
                                item.resultText = text
                                item.transcriptSource = source
                                item.downloadPhase = nil
                                item.progress = 1
                                item.state = .completed
                            }
                            resultRecorder(text)
                            let mdURL = Self.resolveMarkdownOutputURL(forRemoteTitle: displayTitle)
                            do {
                                try text.write(to: mdURL, atomically: true, encoding: .utf8)
                                updateJob(id: jobID) { $0.markdownURL = mdURL }
                            } catch {
                                print("[VowKy][FileTranscription] 字幕落盘失败: \(error.localizedDescription)")
                            }
                            metadataRecorder?(text, Self.makeFileMetadata(title: displayTitle, markdownURL: mdURL))
                            cleanupWorkDir(for: jobID)
                            continue   // 跳过 reading/transcribing
                        }
                    } catch is CancellationError {
                        updateJob(id: jobID) { $0.state = .cancelled }
                        cleanupWorkDir(for: jobID)
                        markUnfinishedJobsCancelled(targetJobIDs: targetJobIDs)
                        return
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        updateJob(id: jobID) { $0.state = .failed(message) }
                        cleanupWorkDir(for: jobID)
                        continue
                    }
                }

                // 取最新快照（链接任务此时已带 mediaURL），决定喂给转写管线的本地 URL 与 .md 命名方式。
                let isRemote = job.kind == .remoteURL
                let inputURL = jobs.first(where: { $0.id == jobID })?.transcriptionInputURL ?? job.url

                updateJob(id: jobID) { item in
                    item.state = .reading
                    item.progress = 0
                    item.resultText = ""
                    item.currentSegment = 0
                    item.totalSegments = 0
                }

                let service = fileTranscriptionServiceFactory()
                do {
                    let finalText = try await service.transcribe(url: inputURL) { [weak self] update in
                        self?.apply(progressUpdate: update, to: jobID)
                    }
                    guard !Task.isCancelled else {
                        cleanupWorkDir(for: jobID)
                        markUnfinishedJobsCancelled(targetJobIDs: targetJobIDs)
                        return
                    }
                    updateJob(id: jobID) { job in
                        job.resultText = finalText
                        job.progress = 1
                        job.state = .completed
                    }
                    resultRecorder(finalText)

                    // 转写一完成就自动落盘 raw text .md（与录音流程一致）。
                    // 链接任务的「源」是即将删除的临时文件，必须落到固定的 Recordings 目录、用视频标题命名。
                    let mdURL: URL = isRemote
                        ? Self.resolveMarkdownOutputURL(forRemoteTitle: jobs.first(where: { $0.id == jobID })?.fileName ?? L("file.defaultName"))
                        : Self.resolveMarkdownOutputURL(for: inputURL)
                    do {
                        try finalText.write(to: mdURL, atomically: true, encoding: .utf8)
                        updateJob(id: jobID) { $0.markdownURL = mdURL }
                    } catch {
                        print("[VowKy][FileTranscription] 自动落盘失败: \(error.localizedDescription)")
                    }
                    let fileTitle = jobs.first(where: { $0.id == jobID })?.fileName ?? mdURL.deletingPathExtension().lastPathComponent
                    metadataRecorder?(finalText, Self.makeFileMetadata(title: fileTitle, markdownURL: mdURL))
                    cleanupWorkDir(for: jobID)   // 转写完即删临时媒体
                } catch is CancellationError {
                    cleanupWorkDir(for: jobID)
                    updateJob(id: jobID) { job in
                        job.state = .cancelled
                    }
                    markUnfinishedJobsCancelled(targetJobIDs: targetJobIDs)
                    return
                } catch {
                    cleanupWorkDir(for: jobID)
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    updateJob(id: jobID) { job in
                        job.state = .failed(message)
                    }
                }
            }
        }
    }

    func selectJob(_ id: UUID) {
        selectedJobID = id
        refreshInsertionTarget()
    }

    func removeJob(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              canRemoveJob(jobs[index]) else {
            return
        }

        if let workDir = jobs[index].workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
        let removedSelectedJob = selectedJobID == id
        jobs.remove(at: index)
        if jobs.isEmpty {
            selectedJobID = nil
            statusMessage = nil
        } else if removedSelectedJob || selectedJobID == nil {
            selectedJobID = jobs[min(index, jobs.count - 1)].id
        }
        refreshInsertionTarget()
    }

    func cancel() {
        guard isRunning else { return }
        transcriptionTask?.cancel()
        markUnfinishedJobsCancelled(targetJobIDs: activeTargetJobIDs)
        sweepAllWorkDirs()   // 兜底清掉链接任务的临时下载目录（窗口关闭/取消时 weak self 可能来不及清）
    }

    func clear() {
        guard !isRunning else { return }
        sweepAllWorkDirs()
        jobs = []
        selectedJobID = nil
        statusMessage = nil
        refreshInsertionTarget()
    }

    /// 删除所有任务残留的临时下载目录。
    private func sweepAllWorkDirs() {
        for index in jobs.indices {
            if let workDir = jobs[index].workDir {
                try? FileManager.default.removeItem(at: workDir)
                jobs[index].workDir = nil
            }
        }
    }

    func copyResult() {
        guard canUseResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        AnalyticsService.shared.trackHistoryCopy()
    }

    func saveResult() {
        guard canUseResult, let selectedJob else { return }

        let panel = NSSavePanel()
        panel.title = L("file.action.saveAs")
        // 允许 .md 和 .txt（用户可在 SavePanel 自由编辑扩展名）
        panel.allowedContentTypes = [.plainText, .data]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = defaultSaveName(for: selectedJob)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = resultText
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            updateJob(id: selectedJob.id) { job in
                job.state = .failed(L("file.error.saveFailed", error.localizedDescription))
            }
        }
    }

    func saveAllResults() {
        guard canSaveAllResults else { return }

        let panel = NSOpenPanel()
        panel.title = L("file.picker.chooseFolder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        var usedNames: Set<String> = []
        for job in jobs where !job.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (content, ext) = (job.resultText, "txt")
            let fileURL = uniqueOutputFileURL(
                in: folderURL,
                baseName: (job.fileName as NSString).deletingPathExtension,
                ext: ext,
                usedNames: &usedNames
            )
            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                updateJob(id: job.id) { item in
                    item.state = .failed(L("file.error.saveFailed", error.localizedDescription))
                }
            }
        }
    }

    /// 在 Finder 中显示当前选中 job 自动落盘的 .md 文件。
    func revealMarkdownInFinder() {
        guard let url = selectedJob?.markdownURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var canRevealMarkdownInFinder: Bool {
        selectedJob?.markdownURL != nil
    }

    func insertResult() {
        guard canUseResult, hasInsertionTarget else { return }
        guard appState.activateTextInsertionTarget() else {
            hasInsertionTarget = false
            return
        }

        let text = resultText
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [appState] in
            (appState.textOutputService ?? TextOutputService()).insertText(text)
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls = Array<URL?>(repeating: nil, count: fileProviders.count)

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else {
                    url = item as? URL
                }

                lock.lock()
                urls[index] = url
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.appendJobs(urls: urls.compactMap { $0 })
        }

        return true
    }

    private func applyDownload(_ update: DownloadProgress, to jobID: UUID) {
        updateJob(id: jobID) { job in
            job.state = .downloading
            job.downloadPhase = update.phase
            if update.fractionCompleted >= 0 {
                job.progress = min(1, max(0, update.fractionCompleted))
            }
        }
    }

    /// 为链接任务建唯一临时下载目录（NSTemporaryDirectory 下，OS 会自动回收，适合大且短命的媒体）。
    private static func makeWorkDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VowKy-URLDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 删除某任务的临时下载目录并清空其媒体引用（转写完/失败/取消都调用）。
    private func cleanupWorkDir(for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if let workDir = jobs[index].workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
        jobs[index].workDir = nil
        jobs[index].mediaURL = nil
        jobs[index].downloadPhase = nil
    }

    private func apply(progressUpdate: FileTranscriptionProgress, to jobID: UUID) {
        updateJob(id: jobID) { job in
            job.progress = min(1, max(0, progressUpdate.progress))
            job.currentSegment = progressUpdate.currentSegment
            job.totalSegments = progressUpdate.totalSegments
            job.resultText = progressUpdate.partialText

            switch progressUpdate.phase {
            case .reading:
                job.state = .reading
            case .transcribing:
                job.state = .transcribing
            case .finishing:
                job.state = .completed
            }
        }
    }

    private func updateJob(id: UUID, mutate: (inout FileTranscriptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    private func normalizedFileKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func markUnfinishedJobsCancelled(targetJobIDs: Set<UUID>?) {
        for index in jobs.indices
            where !jobs[index].isFinished && shouldIncludeJob(jobs[index], targetJobIDs: targetJobIDs) {
            jobs[index].state = .cancelled
        }
    }

    private func shouldStartJob(_ job: FileTranscriptionJob, targetJobIDs: Set<UUID>?) -> Bool {
        shouldIncludeJob(job, targetJobIDs: targetJobIDs) && isStartable(job.state)
    }

    private func shouldIncludeJob(_ job: FileTranscriptionJob, targetJobIDs: Set<UUID>?) -> Bool {
        guard let targetJobIDs else { return true }
        return targetJobIDs.contains(job.id)
    }

    private func isStartable(_ state: FileTranscriptionJobState) -> Bool {
        switch state {
        case .queued, .cancelled:
            return true
        case .downloading, .reading, .transcribing, .completed, .failed:
            return false
        }
    }

    private func jobStatusText(_ job: FileTranscriptionJob) -> String {
        switch job.state {
        case .queued:
            return L("file.row.waiting")
        case .downloading:
            switch job.downloadPhase {
            case .provisioningTools: return L("file.status.provisioningTools")
            case .resolving:         return L("file.status.resolving")
            case .fetchingSubtitles: return L("file.status.fetchingSubtitles")
            case .extractingAudio:   return L("file.status.extractingAudio")
            case .downloading, .none: return L("file.status.downloading")
            }
        case .reading:
            return L("file.status.readingAudio")
        case .transcribing:
            guard job.totalSegments > 0 else { return L("file.status.transcribing") }
            return L("file.status.transcribingSegment", job.currentSegment, job.totalSegments)
        case .completed:
            return L("file.status.transcribeCompleted")
        case .cancelled:
            return job.resultText.isEmpty ? L("file.status.cancelled") : L("file.status.cancelledKeptResult")
        case .failed(let message):
            return message
        }
    }

    private func defaultSaveName(for job: FileTranscriptionJob) -> String {
        let baseName = (job.fileName as NSString).deletingPathExtension
        let base = baseName.isEmpty ? L("file.defaultName") : baseName
        return "\(base).txt"
    }

    private func uniqueOutputFileURL(
        in folderURL: URL,
        baseName: String,
        ext: String,
        usedNames: inout Set<String>
    ) -> URL {
        let cleanBaseName = sanitizedFileName(baseName.isEmpty ? L("file.defaultName") : baseName)
        var candidate = "\(cleanBaseName).\(ext)"
        var suffix = 2
        while usedNames.contains(candidate)
            || FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(candidate).path) {
            candidate = "\(cleanBaseName)-\(suffix).\(ext)"
            suffix += 1
        }
        usedNames.insert(candidate)
        return folderURL.appendingPathComponent(candidate)
    }

    private func sanitizedFileName(_ name: String) -> String {
        Self.sanitizedFileNameStatic(name)
    }

    private static func sanitizedFileNameStatic(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let parts = name.components(separatedBy: invalid)
        let cleaned = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? L("file.defaultName") : cleaned
    }

    /// 为给定音频 URL 选一个可写的 .md 落盘位置：优先音频同目录；
    /// 同目录不可写时回退到 `~/Documents/VowKy Recordings/`。同名时加 `-2` / `-3` 后缀。
    static func resolveMarkdownOutputURL(for audioURL: URL) -> URL {
        let baseName = (audioURL.lastPathComponent as NSString).deletingPathExtension
        let safeBase = sanitizedFileNameStatic(baseName)

        let audioDir = audioURL.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: audioDir.path) {
            return pickNonExisting(dir: audioDir, base: safeBase)
        }

        let fallback = RecordingTranscriptionOutputStore.defaultOutputDirectory()
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return pickNonExisting(dir: fallback, base: safeBase)
    }

    /// 链接任务的 .md 落盘：固定存到 `~/Documents/VowKy Recordings/`，用视频标题命名（临时媒体目录会被删，不能落那）。
    static func resolveMarkdownOutputURL(forRemoteTitle title: String) -> URL {
        let safeBase = sanitizedFileNameStatic(title)
        let dir = RecordingTranscriptionOutputStore.defaultOutputDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return pickNonExisting(dir: dir, base: safeBase)
    }

    private static func pickNonExisting(dir: URL, base: String) -> URL {
        var url = dir.appendingPathComponent("\(base).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(suffix).md")
            suffix += 1
        }
        return url
    }

    private func clampedProgress(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func fileSize(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return nil
        }
        return Int64(fileSize)
    }

    private static var allowedContentTypes: [UTType] {
        let explicitTypes = [
            "wav", "mp3", "m4a", "aac", "aiff", "aif", "flac",
            "mp4", "mov", "m4v"
        ].compactMap { UTType(filenameExtension: $0) }
        return [.audio, .movie] + explicitTypes
    }
}
