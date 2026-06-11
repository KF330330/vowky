import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Transcription Window Controller

@MainActor
final class FileTranscriptionWindowController {
    static let shared = FileTranscriptionWindowController()

    private var window: NSWindow?
    private var viewModel: FileTranscriptionViewModel?

    func showWindow(appState: AppState) {
        appState.captureCurrentTextInsertionTarget()
        NSApp.setActivationPolicy(.regular)

        if let window = window {
            viewModel?.refreshInsertionTarget()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = FileTranscriptionViewModel(appState: appState)
        let view = FileTranscriptionView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "VowKy 文件转录"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 900, height: 660))
        window.minSize = NSSize(width: 760, height: 520)
        window.backgroundColor = NSColor(
            red: 247.0 / 255.0,
            green: 250.0 / 255.0,
            blue: 240.0 / 255.0,
            alpha: 1
        )
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.cancel()
                self?.viewModel = nil
                self?.window = nil
                NSApp.setActivationPolicy(.prohibited)
            }
        }

        self.viewModel = viewModel
        self.window = window
    }
}

// MARK: - State

enum FileTranscriptionJobState: Equatable {
    case queued
    case reading
    case transcribing
    case completed
    case cancelled
    case failed(String)
}

struct FileTranscriptionJob: Identifiable, Equatable {
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

    var isFinished: Bool {
        switch state {
        case .completed, .cancelled, .failed:
            return true
        case .queued, .reading, .transcribing:
            return false
        }
    }
}

// MARK: - View Model

@MainActor
final class FileTranscriptionViewModel: ObservableObject {
    @Published private(set) var jobs: [FileTranscriptionJob] = []
    @Published private(set) var selectedJobID: UUID?
    @Published private(set) var hasInsertionTarget = false
    @Published private(set) var statusMessage: String?

    private let appState: AppState
    private let fileTranscriptionServiceFactory: () -> FileTranscribing
    private let resultRecorder: (String) -> Void
    private var transcriptionTask: Task<Void, Never>?
    private var activeTargetJobIDs: Set<UUID>?

    init(
        appState: AppState,
        fileTranscriptionServiceFactory: (() -> FileTranscribing)? = nil,
        resultRecorder: ((String) -> Void)? = nil
    ) {
        self.appState = appState
        self.fileTranscriptionServiceFactory = fileTranscriptionServiceFactory ?? {
            appState.makeFileTranscriptionService()
        }
        self.resultRecorder = resultRecorder ?? { text in
            appState.recordRecognitionResult(text: text, sourceType: "file")
        }
        refreshInsertionTarget()
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
        case .queued, .reading, .transcribing, .failed:
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
        guard !jobs.isEmpty else { return "选择或拖入文件" }
        if isRunning {
            return "\(completedCount) / \(jobs.count) 完成"
        }
        if failedCount > 0 {
            return "\(completedCount) 完成 · \(failedCount) 失败"
        }
        if completedCount == jobs.count {
            return "全部完成"
        }
        if jobs.allSatisfy({ $0.state == .cancelled }) {
            return "已取消 · 可重新开始"
        }
        return "\(startableCount) 个待转录"
    }

    var selectedJobStatusText: String {
        selectedJob.map(jobStatusText) ?? "请选择文件"
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
            return "等待开始"
        case .reading, .transcribing:
            return "\(Int(clampedProgress(job.progress) * 100))%"
        case .completed:
            return "完成"
        case .cancelled:
            return "已取消"
        case .failed:
            return "失败"
        }
    }

    func shouldShowProgress(for job: FileTranscriptionJob) -> Bool {
        switch job.state {
        case .reading, .transcribing:
            return true
        case .queued, .completed, .cancelled, .failed:
            return false
        }
    }

    func canRemoveJob(_ job: FileTranscriptionJob) -> Bool {
        switch job.state {
        case .reading, .transcribing:
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
            return "转录中，可继续添加文件"
        }
        if canStartTranscription {
            if jobs.contains(where: { $0.state == .cancelled })
                && !jobs.contains(where: { $0.state == .queued }) {
                return "已取消，可重新开始"
            }
            return "准备转录"
        }
        return statusText
    }

    var statusText: String {
        guard !jobs.isEmpty else { return "选择或拖入音频/视频文件" }

        if isRunning {
            let finishedCount = jobs.filter(\.isFinished).count
            if let selectedJob {
                return "\(jobStatusText(selectedJob)) · \(finishedCount) / \(jobs.count)"
            }
            return "正在转录 · \(finishedCount) / \(jobs.count)"
        }

        let failedCount = jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
        let completedCount = jobs.filter { $0.state == .completed }.count
        if failedCount > 0 {
            return "\(completedCount) 个完成，\(failedCount) 个失败"
        }
        if completedCount == jobs.count {
            return "全部转录完成"
        }
        if jobs.allSatisfy({ $0.state == .cancelled }) {
            return "已取消"
        }
        return selectedJob.map(jobStatusText) ?? "准备转录"
    }

    func refreshInsertionTarget() {
        hasInsertionTarget = appState.hasTextInsertionTarget
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "选择要转录的音频或视频"
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
                let jobURL = jobs[index].url
                selectedJobID = jobID
                updateJob(id: jobID) { job in
                    job.state = .reading
                    job.progress = 0
                    job.resultText = ""
                    job.currentSegment = 0
                    job.totalSegments = 0
                }

                let service = fileTranscriptionServiceFactory()
                do {
                    let finalText = try await service.transcribe(url: jobURL) { [weak self] update in
                        self?.apply(progressUpdate: update, to: jobID)
                    }
                    guard !Task.isCancelled else {
                        markUnfinishedJobsCancelled(targetJobIDs: targetJobIDs)
                        return
                    }
                    updateJob(id: jobID) { job in
                        job.resultText = finalText
                        job.progress = 1
                        job.state = .completed
                    }
                    resultRecorder(finalText)

                    // 转写一完成就自动落盘 raw text .md（与录音流程一致）
                    let mdURL = Self.resolveMarkdownOutputURL(for: jobURL)
                    do {
                        try finalText.write(to: mdURL, atomically: true, encoding: .utf8)
                        updateJob(id: jobID) { $0.markdownURL = mdURL }
                    } catch {
                        print("[VowKy][FileTranscription] 自动落盘失败: \(error.localizedDescription)")
                    }
                } catch is CancellationError {
                    updateJob(id: jobID) { job in
                        job.state = .cancelled
                    }
                    markUnfinishedJobsCancelled(targetJobIDs: targetJobIDs)
                    return
                } catch {
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
    }

    func clear() {
        guard !isRunning else { return }
        jobs = []
        selectedJobID = nil
        statusMessage = nil
        refreshInsertionTarget()
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
        panel.title = "另存为"
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
                job.state = .failed("保存失败：\(error.localizedDescription)")
            }
        }
    }

    func saveAllResults() {
        guard canSaveAllResults else { return }

        let panel = NSOpenPanel()
        panel.title = "选择保存转录文本的文件夹"
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
                    item.state = .failed("保存失败：\(error.localizedDescription)")
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
        case .reading, .transcribing, .completed, .failed:
            return false
        }
    }

    private func jobStatusText(_ job: FileTranscriptionJob) -> String {
        switch job.state {
        case .queued:
            return "等待开始"
        case .reading:
            return "正在读取音轨..."
        case .transcribing:
            guard job.totalSegments > 0 else { return "正在转录..." }
            return "正在转录第 \(job.currentSegment) / \(job.totalSegments) 段"
        case .completed:
            return "转录完成"
        case .cancelled:
            return job.resultText.isEmpty ? "已取消" : "已取消，已保留当前结果"
        case .failed(let message):
            return message
        }
    }

    private func defaultSaveName(for job: FileTranscriptionJob) -> String {
        let baseName = (job.fileName as NSString).deletingPathExtension
        let base = baseName.isEmpty ? "VowKy转录" : baseName
        return "\(base).txt"
    }

    private func uniqueOutputFileURL(
        in folderURL: URL,
        baseName: String,
        ext: String,
        usedNames: inout Set<String>
    ) -> URL {
        let cleanBaseName = sanitizedFileName(baseName.isEmpty ? "VowKy转录" : baseName)
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
        return cleaned.isEmpty ? "VowKy转录" : cleaned
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

// MARK: - View

struct FileTranscriptionView: View {
    @ObservedObject var viewModel: FileTranscriptionViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            header

            Group {
                if viewModel.jobs.isEmpty {
                    dropArea
                } else {
                    HStack(spacing: 12) {
                        queueArea
                            .frame(minWidth: 300, idealWidth: 330, maxWidth: 360)
                        resultArea
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(
                of: [UTType.fileURL.identifier],
                isTargeted: $isDropTargeted,
                perform: viewModel.handleDrop(providers:)
            )

            footer
        }
        .padding(12)
        .frame(minWidth: 760, minHeight: 520)
        .background(
            LinearGradient(
                colors: [
                    FileTranscriptionTheme.background,
                    FileTranscriptionTheme.secondaryBackground,
                    FileTranscriptionTheme.elevatedBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            viewModel.refreshInsertionTarget()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(FileTranscriptionTheme.accentDark)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(FileTranscriptionTheme.accentBright.opacity(0.35))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("文件转录")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(FileTranscriptionTheme.textPrimary)
                Text("批量音视频，本地离线处理")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FileTranscriptionTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            if !viewModel.jobs.isEmpty {
                HStack(spacing: 7) {
                    Circle()
                        .fill(summaryDotColor)
                        .frame(width: 7, height: 7)
                    Text(viewModel.queueSummaryText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(FileTranscriptionTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(FileTranscriptionTheme.cardBackground.opacity(0.82))
                        .overlay(
                            Capsule()
                                .stroke(FileTranscriptionTheme.borderLight, lineWidth: 1)
                        )
                )
            }

            if viewModel.canStartTranscription {
                Button {
                    viewModel.startTranscription()
                } label: {
                    Label("全部转录", systemImage: "play.fill")
                }
                .buttonStyle(FilePrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [])
                .help("转录队列中所有等待开始或已取消的文件")
            }

            Button {
                viewModel.chooseFile()
            } label: {
                Label("选择文件", systemImage: "folder")
            }
            .buttonStyle(FileSecondaryButtonStyle())
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 42)
    }

    private var dropArea: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(isDropTargeted ? FileTranscriptionTheme.accentDark : FileTranscriptionTheme.accentDeep)
                .frame(width: 76, height: 76)
                .background(
                    Circle()
                        .fill(FileTranscriptionTheme.accentBright.opacity(isDropTargeted ? 0.48 : 0.32))
                )

            VStack(spacing: 6) {
                Text(isDropTargeted ? "松开后加入队列" : "拖入音频或视频文件")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(FileTranscriptionTheme.textPrimary)
                Text("支持批量选择 MP3、M4A、MP4、MOV、WAV、FLAC 等格式，全程本地处理。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FileTranscriptionTheme.textMuted)
                    .multilineTextAlignment(.center)
            }

            Button {
                viewModel.chooseFile()
            } label: {
                Label("选择文件", systemImage: "folder")
            }
            .buttonStyle(FilePrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FileTranscriptionTheme.cardBackground.opacity(0.96))
                .shadow(color: FileTranscriptionTheme.shadow, radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isDropTargeted ? FileTranscriptionTheme.accentMain : FileTranscriptionTheme.borderLight,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: isDropTargeted ? [6, 4] : [])
                )
        )
    }

    private func importChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(FileTranscriptionTheme.accentDarkest)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(FileTranscriptionTheme.accentBright.opacity(0.28))
            )
    }

    private var queueArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("队列")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FileTranscriptionTheme.textPrimary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(viewModel.jobs.count) 个文件")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(FileTranscriptionTheme.textSecondary)
                    if let totalFileSizeText = viewModel.totalFileSizeText {
                        Text(totalFileSizeText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(FileTranscriptionTheme.textMuted)
                    }
                }
            }

            if viewModel.hasStatusMessage, let statusMessage = viewModel.statusMessage {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                }
                .foregroundColor(FileTranscriptionTheme.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(FileTranscriptionTheme.warning.opacity(0.10))
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.jobs) { job in
                        queueRow(job)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .fileTranscriptionCardStyle()
    }

    private func queueRow(_ job: FileTranscriptionJob) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: iconName(for: job.state))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(stateTint(for: job.state))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(job.fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(FileTranscriptionTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let fileSizeText = viewModel.fileSizeText(for: job) {
                        Text(fileSizeText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(FileTranscriptionTheme.textMuted)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 7) {
                    stateChip(for: job)
                    if viewModel.shouldShowProgress(for: job) {
                        ProgressView(value: clampedProgress(job.progress))
                            .progressViewStyle(.linear)
                            .tint(FileTranscriptionTheme.accentDeep)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.canStartJob(job) {
                Button {
                    viewModel.startTranscription(id: job.id)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(FileIconButtonStyle(tint: FileTranscriptionTheme.accentDeep))
                .help("只转录这个文件")
            }

            Button {
                viewModel.removeJob(job.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(FileIconButtonStyle(tint: FileTranscriptionTheme.textMuted))
            .disabled(!viewModel.canRemoveJob(job))
            .help(viewModel.canRemoveJob(job) ? "从队列移除" : "当前文件转录中")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(rowBackground(for: job))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    job.id == viewModel.selectedJobID
                        ? FileTranscriptionTheme.accentMain.opacity(0.42)
                        : Color.clear,
                    lineWidth: 1
                )
        )
        .onTapGesture {
            viewModel.selectJob(job.id)
        }
    }

    private func stateChip(for job: FileTranscriptionJob) -> some View {
        Text(viewModel.queueRowStatusText(for: job))
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(stateTint(for: job.state))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(stateTint(for: job.state).opacity(0.12))
            )
    }

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedJob = viewModel.selectedJob {
                HStack(alignment: .top, spacing: 12) {
                    detailIcon(for: selectedJob.state)
                        .frame(width: 42, height: 42)
                        .background(
                            Circle()
                                .fill(stateTint(for: selectedJob.state).opacity(0.13))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedJob.fileName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(FileTranscriptionTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 7) {
                            if let fileSizeText = viewModel.fileSizeText(for: selectedJob) {
                                Text(fileSizeText)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(FileTranscriptionTheme.textMuted)
                            }
                            Text(viewModel.selectedJobStatusText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(FileTranscriptionTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer()
                    stateChip(for: selectedJob)
                }

                if viewModel.shouldShowProgress(for: selectedJob) {
                    ProgressView(value: clampedProgress(selectedJob.progress))
                        .progressViewStyle(.linear)
                        .tint(FileTranscriptionTheme.accentDeep)
                        .frame(height: 6)
                }

                if let errorMessage = viewModel.selectedJobErrorMessage {
                    errorBanner(errorMessage)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FileTranscriptionTheme.accentDark)

                Text("转录结果")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FileTranscriptionTheme.textPrimary)

                Text(resultBadgeText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(FileTranscriptionTheme.accentDarkest)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(FileTranscriptionTheme.accentBright.opacity(0.30))
                    )

                Spacer()

                if !viewModel.resultText.isEmpty {
                    Text("\(viewModel.resultText.count) 字")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(FileTranscriptionTheme.textMuted)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(FileTranscriptionTheme.secondaryBackground.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(FileTranscriptionTheme.borderLight, lineWidth: 1)
                    )

                if viewModel.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(emptyResultText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(FileTranscriptionTheme.textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                }

                TextEditor(text: Binding(
                    get: { viewModel.resultText },
                    set: { viewModel.updateSelectedResultText($0) }
                ))
                .font(.system(size: 14))
                .foregroundColor(FileTranscriptionTheme.textPrimary)
                .lineSpacing(4)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .allowsHitTesting(viewModel.canEditSelectedResult)
            }
            .frame(minHeight: 230, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .fileTranscriptionCardStyle()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.canRetrySelectedJob {
                Button {
                    viewModel.retrySelectedJob()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(FileSecondaryButtonStyle())
            }
        }
        .foregroundColor(FileTranscriptionTheme.error)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(FileTranscriptionTheme.error.opacity(0.09))
        )
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if viewModel.isRunning {
                Button {
                    viewModel.cancel()
                } label: {
                    Label("取消", systemImage: "xmark")
                }
                .buttonStyle(FileGhostButtonStyle())
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    viewModel.clear()
                } label: {
                    Label("清空", systemImage: "arrow.clockwise")
                }
                .buttonStyle(FileGhostButtonStyle())
                .disabled(viewModel.jobs.isEmpty)
            }

            Spacer()

            Button {
                viewModel.saveResult()
            } label: {
                Label("另存为", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(FileSecondaryButtonStyle())
            .disabled(!viewModel.canUseResult)

            Button {
                viewModel.revealMarkdownInFinder()
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            .buttonStyle(FileSecondaryButtonStyle())
            .disabled(!viewModel.canRevealMarkdownInFinder)
            .help(viewModel.canRevealMarkdownInFinder ? "打开自动落盘的 .md 文件位置" : "尚未生成 .md 文件")

        }
        .controlSize(.small)
        .frame(height: 34)
    }

    private var summaryDotColor: Color {
        if viewModel.isRunning { return FileTranscriptionTheme.accentMain }
        if viewModel.failedCount > 0 { return FileTranscriptionTheme.error }
        if !viewModel.jobs.isEmpty && viewModel.completedCount == viewModel.jobs.count {
            return FileTranscriptionTheme.accentDeep
        }
        if !viewModel.jobs.isEmpty && viewModel.cancelledCount == viewModel.jobs.count {
            return FileTranscriptionTheme.warning
        }
        return FileTranscriptionTheme.accentDeep
    }

    private var resultBadgeText: String {
        guard let job = viewModel.selectedJob else { return "等待内容" }
        switch job.state {
        case .completed:
            return viewModel.canEditSelectedResult ? "可编辑结果" : "已完成"
        case .cancelled:
            return viewModel.resultText.isEmpty ? "无结果" : "可编辑草稿"
        case .reading, .transcribing:
            return "实时预览"
        case .failed:
            return viewModel.resultText.isEmpty ? "未生成" : "保留草稿"
        case .queued:
            return "等待内容"
        }
    }

    private var emptyResultText: String {
        guard let job = viewModel.selectedJob else {
            return "选择一个文件后会显示转录结果。"
        }
        switch job.state {
        case .queued:
            return "点击“全部转录”处理所有等待文件，或点击左侧行内播放按钮只转录这个文件。"
        case .reading:
            return "正在读取音轨，识别结果会稍后出现。"
        case .transcribing:
            return "正在转录，识别到的内容会实时显示在这里。"
        case .completed:
            return "该文件没有生成文本。"
        case .cancelled:
            return "转录已取消，当前没有可用草稿。"
        case .failed:
            return "没有生成可用文本。可以修复文件或重试。"
        }
    }

    private func iconName(for state: FileTranscriptionJobState) -> String {
        switch state {
        case .queued:
            return "clock"
        case .reading:
            return "waveform"
        case .transcribing:
            return "text.bubble"
        case .completed:
            return "checkmark.circle.fill"
        case .cancelled:
            return "minus.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder
    private func detailIcon(for state: FileTranscriptionJobState) -> some View {
        switch state {
        case .reading, .transcribing:
            Image(nsImage: Self.butterflyLargeImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundColor(stateTint(for: state))
        default:
            Image(systemName: detailIconName(for: state))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(stateTint(for: state))
        }
    }

    private static let butterflyLargeImage: NSImage = {
        let img = NSImage(named: "ButterflyLarge") ?? NSImage()
        img.isTemplate = true
        return img
    }()

    private func detailIconName(for state: FileTranscriptionJobState) -> String {
        switch state {
        case .completed:
            return "checkmark.seal.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "minus.circle"
        case .reading, .transcribing:
            return "waveform"
        case .queued:
            return "doc.text"
        }
    }

    private func stateTint(for state: FileTranscriptionJobState) -> Color {
        switch state {
        case .completed:
            return FileTranscriptionTheme.accentDeep
        case .failed:
            return FileTranscriptionTheme.error
        case .cancelled:
            return FileTranscriptionTheme.warning
        case .reading, .transcribing:
            return FileTranscriptionTheme.accentDark
        case .queued:
            return FileTranscriptionTheme.textMuted
        }
    }

    private func rowBackground(for job: FileTranscriptionJob) -> Color {
        if job.id == viewModel.selectedJobID {
            return FileTranscriptionTheme.accentBright.opacity(0.22)
        }
        switch job.state {
        case .failed:
            return FileTranscriptionTheme.error.opacity(0.05)
        case .completed:
            return FileTranscriptionTheme.accentBright.opacity(0.10)
        default:
            return Color.clear
        }
    }

    private func clampedProgress(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

// MARK: - File Transcription Visual Components

private struct FilePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FileTranscriptionTheme.accentDarkest)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [FileTranscriptionTheme.accentBright, FileTranscriptionTheme.accentMain]
                                : [FileTranscriptionTheme.borderLight, FileTranscriptionTheme.border],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(
                        color: isEnabled ? FileTranscriptionTheme.accentMain.opacity(configuration.isPressed ? 0.10 : 0.24) : .clear,
                        radius: configuration.isPressed ? 3 : 8,
                        x: 0,
                        y: configuration.isPressed ? 1 : 3
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct FileSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FileTranscriptionTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(FileTranscriptionTheme.cardBackground.opacity(isEnabled ? 0.92 : 0.54))
                    .overlay(
                        Capsule()
                            .stroke(FileTranscriptionTheme.border, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.52)
    }
}

private struct FileGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FileTranscriptionTheme.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? FileTranscriptionTheme.borderLight.opacity(0.6) : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct FileIconButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(tint)
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(FileTranscriptionTheme.cardBackground.opacity(isEnabled ? 0.86 : 0.32))
                    .overlay(
                        Circle()
                            .stroke(FileTranscriptionTheme.border.opacity(0.82), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.40)
    }
}

private struct FileTranscriptionCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(FileTranscriptionTheme.cardBackground.opacity(0.96))
                    .shadow(color: FileTranscriptionTheme.shadow, radius: 18, x: 0, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(FileTranscriptionTheme.borderLight, lineWidth: 1)
            )
    }
}

private extension View {
    func fileTranscriptionCardStyle() -> some View {
        modifier(FileTranscriptionCardModifier())
    }
}

private enum FileTranscriptionTheme {
    static let background = color(0xF7FAF0)
    static let secondaryBackground = color(0xF0F5E4)
    static let cardBackground = color(0xFFFFFF)
    static let elevatedBackground = color(0xE8EED8)
    static let textPrimary = color(0x1A2210)
    static let textSecondary = color(0x4E5C3A)
    static let textMuted = color(0x8A9872)
    static let accentBright = color(0xD4E87C)
    static let accentMain = color(0xB8D458)
    static let accentDeep = color(0x8AAE3A)
    static let accentDark = color(0x5A6B2A)
    static let accentDarkest = color(0x4A5A22)
    static let border = color(0xDCE6C8)
    static let borderLight = color(0xE8EED8)
    static let error = color(0xD8544C)
    static let warning = color(0xC88A2A)
    static let shadow = color(0x4A5A22, opacity: 0.10)

    private static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
