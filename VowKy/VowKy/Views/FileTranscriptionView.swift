import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Transcription Window Controller

@MainActor
final class FileTranscriptionWindowController {
    static let shared = FileTranscriptionWindowController()

    private var window: NSWindow?
    private var viewModel: FileTranscriptionViewModel?
    /// willClose 观察者 token：窗口关闭时移除，避免每次开→关累积一个僵尸注册
    private var closeObserver: NSObjectProtocol?

    /// 当前活动的 view model（供 Debug E2E 钩子脚本化驱动；正常路径不用）。
    var activeViewModel: FileTranscriptionViewModel? { viewModel }

    func showWindow(appState: AppState) {
        appState.captureCurrentTextInsertionTarget()
        NSApp.setActivationPolicy(.regular)

        if let window = window {
            viewModel?.refreshInsertionTarget()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = FileTranscriptionViewModel(
            appState: appState,
            metadataRecorder: { text, meta in
                HistoryStore.shared.insertWithMetadata(content: text, sourceType: meta.sourceType, metadata: meta)
            }
        )
        let view = FileTranscriptionView(viewModel: viewModel)
            .environmentObject(LocalizationManager.shared)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = L("window.fileTranscription.title")
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

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let token = self.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.closeObserver = nil
                }
                self.viewModel?.cancel()
                self.viewModel = nil
                self.window = nil
                NSApp.setActivationPolicy(.prohibited)
            }
        }

        self.viewModel = viewModel
        self.window = window
    }
}


// MARK: - View

struct FileTranscriptionView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @ObservedObject var viewModel: FileTranscriptionViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            header

            if !viewModel.jobs.isEmpty {
                urlInputBar
            }

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
                    TranscriptionTheme.background,
                    TranscriptionTheme.secondaryBackground,
                    TranscriptionTheme.elevatedBackground
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
                .foregroundColor(TranscriptionTheme.accentDark)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TranscriptionTheme.accentBright.opacity(0.35))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(loc.string("file.title"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.textPrimary)
                Text(loc.string("file.subtitle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TranscriptionTheme.textMuted)
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
                        .foregroundColor(TranscriptionTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(TranscriptionTheme.cardBackground.opacity(0.82))
                        .overlay(
                            Capsule()
                                .stroke(TranscriptionTheme.borderLight, lineWidth: 1)
                        )
                )
            }

            if viewModel.canStartTranscription {
                Button {
                    viewModel.startTranscription()
                } label: {
                    Label(loc.string("file.action.transcribeAll"), systemImage: "play.fill")
                }
                .buttonStyle(TranscriptionPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [])
                .help(loc.string("file.help.transcribeAll"))
            }

            Button {
                TranscriptionHistoryWindowController.shared.showWindow(filter: .file)
            } label: {
                Label(loc.string("file.action.history"), systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(TranscriptionSecondaryButtonStyle())
            .help(loc.string("file.action.history"))

            Button {
                viewModel.chooseFile()
            } label: {
                Label(loc.string("file.action.chooseFile"), systemImage: "folder")
            }
            .buttonStyle(TranscriptionSecondaryButtonStyle())
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 42)
    }

    /// 链接输入条：粘贴 YouTube / 哔哩哔哩 / DeepLearning.AI 链接，回车或点「添加链接」入队。
    private var urlInputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(TranscriptionTheme.accentDark)
            TextField(loc.string("file.url.placeholder"), text: $viewModel.urlInputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(TranscriptionTheme.textPrimary)
                .onSubmit { viewModel.appendURLJobs(rawText: viewModel.urlInputText) }
            Button {
                viewModel.appendURLJobs(rawText: viewModel.urlInputText)
            } label: {
                Label(loc.string("file.url.add"), systemImage: "plus")
            }
            .buttonStyle(TranscriptionSecondaryButtonStyle())
            .disabled(viewModel.urlInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(TranscriptionTheme.cardBackground.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(TranscriptionTheme.borderLight, lineWidth: 1)
                )
        )
        .help(loc.string("file.url.help"))
    }

    /// 空状态：左「本地文件」拖拽 / 选择，右「转视频链接」粘贴转写，中间「或」分隔。
    private var dropArea: some View {
        HStack(spacing: 0) {
            fileColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            orDivider
            linkColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 2)
    }

    /// 左栏：本地文件拖拽 + 选择文件。拖拽落点是整个空状态区域（父级 .onDrop），此处仅作视觉落区。
    private var fileColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            emptyPanelHead(
                icon: "doc.text",
                title: loc.string("file.empty.fileTitle"),
                subtitle: loc.string("file.empty.fileSubtitle")
            )

            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(isDropTargeted ? TranscriptionTheme.accentDark : TranscriptionTheme.accentDeep)
                VStack(spacing: 3) {
                    Text(isDropTargeted ? loc.string("file.drop.release") : loc.string("file.empty.dropHere"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(TranscriptionTheme.textSecondary)
                    Text(loc.string("file.empty.formatsShort"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(TranscriptionTheme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(TranscriptionTheme.accentBright.opacity(isDropTargeted ? 0.16 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isDropTargeted ? TranscriptionTheme.accentMain : TranscriptionTheme.border,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .padding(.top, 18)

            Button {
                viewModel.chooseFile()
            } label: {
                Label(loc.string("file.action.chooseFile"), systemImage: "folder")
            }
            .buttonStyle(TranscriptionSecondaryButtonStyle())
            .padding(.top, 16)
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 22, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transcriptionCardStyle()
    }

    /// 右栏：粘贴 YouTube / 哔哩哔哩 / DeepLearning.AI 链接转写。
    private var linkColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            emptyPanelHead(
                icon: "link",
                title: loc.string("file.empty.linkTitle"),
                subtitle: loc.string("file.empty.linkSubtitle")
            )

            HStack(spacing: 8) {
                importChip("YouTube")
                importChip(loc.string("file.platform.bilibili"))
                importChip("DeepLearning.AI")
            }
            .padding(.top, 20)

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.accentDark)
                TextField(loc.string("file.url.placeholder"), text: $viewModel.urlInputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(TranscriptionTheme.textPrimary)
                    .onSubmit { viewModel.addURLsAndStart(rawText: viewModel.urlInputText) }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(TranscriptionTheme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(TranscriptionTheme.accentMain, lineWidth: 1.5)
                    )
            )
            .padding(.top, 16)
            .help(loc.string("file.url.help"))

            Spacer(minLength: 16)

            Button {
                viewModel.addURLsAndStart(rawText: viewModel.urlInputText)
            } label: {
                Label(loc.string("file.url.transcribe"), systemImage: "play.fill")
            }
            .buttonStyle(TranscriptionPrimaryButtonStyle())
            .disabled(viewModel.urlInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 22, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transcriptionCardStyle()
    }

    /// 双栏中间的「或」分隔（竖线 + 圆形徽章）。
    private var orDivider: some View {
        ZStack {
            Rectangle()
                .fill(TranscriptionTheme.border)
                .frame(width: 1)
                .padding(.vertical, 16)
            Text(loc.string("file.empty.or"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(TranscriptionTheme.textMuted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(TranscriptionTheme.cardBackground))
                .overlay(Circle().stroke(TranscriptionTheme.border, lineWidth: 1))
        }
        .frame(width: 46)
    }

    /// 双栏的小标题：图标方块 + 标题 + 副标题。
    private func emptyPanelHead(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(TranscriptionTheme.accentDark)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(TranscriptionTheme.accentBright.opacity(0.30))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(TranscriptionTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func importChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(TranscriptionTheme.accentDarkest)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(TranscriptionTheme.accentBright.opacity(0.28))
            )
    }

    private var queueArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc.string("file.queue.title"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.textPrimary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(loc.string("file.queue.fileCount", viewModel.jobs.count))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(TranscriptionTheme.textSecondary)
                    if let totalFileSizeText = viewModel.totalFileSizeText {
                        Text(totalFileSizeText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(TranscriptionTheme.textMuted)
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
                .foregroundColor(TranscriptionTheme.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(TranscriptionTheme.warning.opacity(0.10))
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
        .transcriptionCardStyle()
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
                        .foregroundColor(TranscriptionTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let fileSizeText = viewModel.fileSizeText(for: job) {
                        Text(fileSizeText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(TranscriptionTheme.textMuted)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 7) {
                    stateChip(for: job)
                    if viewModel.shouldShowProgress(for: job) {
                        ProgressView(value: clampedProgress(job.progress))
                            .progressViewStyle(.linear)
                            .tint(TranscriptionTheme.accentDeep)
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
                .buttonStyle(TranscriptionIconButtonStyle(tint: TranscriptionTheme.accentDeep))
                .help(loc.string("file.help.transcribeThis"))
            }

            Button {
                viewModel.removeJob(job.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(TranscriptionIconButtonStyle(tint: TranscriptionTheme.textMuted))
            .disabled(!viewModel.canRemoveJob(job))
            .help(viewModel.canRemoveJob(job) ? loc.string("file.help.removeFromQueue") : loc.string("file.help.transcribingNow"))
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
                        ? TranscriptionTheme.accentMain.opacity(0.42)
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
                            .foregroundColor(TranscriptionTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 7) {
                            if let fileSizeText = viewModel.fileSizeText(for: selectedJob) {
                                Text(fileSizeText)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(TranscriptionTheme.textMuted)
                            }
                            Text(viewModel.selectedJobStatusText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(TranscriptionTheme.textSecondary)
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
                        .tint(TranscriptionTheme.accentDeep)
                        .frame(height: 6)
                }

                if let errorMessage = viewModel.selectedJobErrorMessage {
                    errorBanner(errorMessage)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.accentDark)

                Text(loc.string("file.result.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.textPrimary)

                Text(resultBadgeText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.accentDarkest)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(TranscriptionTheme.accentBright.opacity(0.30))
                    )

                Spacer()

                if !viewModel.resultText.isEmpty {
                    Text(loc.string("file.result.charCount", viewModel.resultText.count))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TranscriptionTheme.textMuted)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(TranscriptionTheme.secondaryBackground.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(TranscriptionTheme.borderLight, lineWidth: 1)
                    )

                if viewModel.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(emptyResultText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(TranscriptionTheme.textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                }

                TextEditor(text: Binding(
                    get: { viewModel.resultText },
                    set: { viewModel.updateSelectedResultText($0) }
                ))
                .font(.system(size: 14))
                .foregroundColor(TranscriptionTheme.textPrimary)
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
        .transcriptionCardStyle()
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
                    Label(loc.string("file.action.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(TranscriptionSecondaryButtonStyle())
            }
        }
        .foregroundColor(TranscriptionTheme.error)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TranscriptionTheme.error.opacity(0.09))
        )
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if viewModel.isRunning {
                Button {
                    viewModel.cancel()
                } label: {
                    Label(loc.string("file.action.cancel"), systemImage: "xmark")
                }
                .buttonStyle(TranscriptionGhostButtonStyle())
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    viewModel.clear()
                } label: {
                    Label(loc.string("file.action.clear"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(TranscriptionGhostButtonStyle())
                .disabled(viewModel.jobs.isEmpty)
            }

            Spacer()

            Button {
                viewModel.saveResult()
            } label: {
                Label(loc.string("file.action.saveAs"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(TranscriptionSecondaryButtonStyle())
            .disabled(!viewModel.canUseResult)

            Button {
                viewModel.revealMarkdownInFinder()
            } label: {
                Label(loc.string("file.action.revealInFinder"), systemImage: "folder")
            }
            .buttonStyle(TranscriptionSecondaryButtonStyle())
            .disabled(!viewModel.canRevealMarkdownInFinder)
            .help(viewModel.canRevealMarkdownInFinder ? loc.string("file.help.revealMarkdown") : loc.string("file.help.noMarkdownYet"))

        }
        .controlSize(.small)
        .frame(height: 34)
    }

    private var summaryDotColor: Color {
        if viewModel.isRunning { return TranscriptionTheme.accentMain }
        if viewModel.failedCount > 0 { return TranscriptionTheme.error }
        if !viewModel.jobs.isEmpty && viewModel.completedCount == viewModel.jobs.count {
            return TranscriptionTheme.accentDeep
        }
        if !viewModel.jobs.isEmpty && viewModel.cancelledCount == viewModel.jobs.count {
            return TranscriptionTheme.warning
        }
        return TranscriptionTheme.accentDeep
    }

    private var resultBadgeText: String {
        guard let job = viewModel.selectedJob else { return loc.string("file.badge.waitingContent") }
        switch job.state {
        case .completed:
            // 链接任务区分来源：人工字幕 / 自动字幕 / 本地转写。
            if let source = job.transcriptSource {
                switch source {
                case .manualSubtitle: return loc.string("file.badge.fromSubtitle")
                case .autoSubtitle:   return loc.string("file.badge.fromAutoSubtitle")
                }
            }
            if job.kind == .remoteURL {
                return loc.string("file.badge.fromLocalASR")
            }
            return viewModel.canEditSelectedResult ? loc.string("file.badge.editableResult") : loc.string("file.badge.done")
        case .cancelled:
            return viewModel.resultText.isEmpty ? loc.string("file.badge.noResult") : loc.string("file.badge.editableDraft")
        case .downloading:
            return job.downloadPhase == .fetchingSubtitles
                ? loc.string("file.phase.fetchingSubtitle")
                : loc.string("file.badge.downloading")
        case .reading, .transcribing:
            return loc.string("file.badge.livePreview")
        case .failed:
            return viewModel.resultText.isEmpty ? loc.string("file.badge.notGenerated") : loc.string("file.badge.keptDraft")
        case .queued:
            return loc.string("file.badge.waitingContent")
        }
    }

    private var emptyResultText: String {
        guard let job = viewModel.selectedJob else {
            return loc.string("file.empty.selectFile")
        }
        switch job.state {
        case .queued:
            return loc.string("file.empty.queued")
        case .downloading:
            // 按子阶段显示，避免「拉字幕」时误显示「正在下载视频」。
            switch job.downloadPhase {
            case .provisioningTools: return loc.string("file.status.provisioningTools")
            case .resolving:         return loc.string("file.status.resolving")
            case .fetchingSubtitles: return loc.string("file.status.fetchingSubtitles")
            case .extractingAudio:   return loc.string("file.status.extractingAudio")
            case .downloading, .none: return loc.string("file.empty.downloading")
            }
        case .reading:
            return loc.string("file.empty.reading")
        case .transcribing:
            return loc.string("file.empty.transcribing")
        case .completed:
            return loc.string("file.empty.completedNoText")
        case .cancelled:
            return loc.string("file.empty.cancelledNoDraft")
        case .failed:
            return loc.string("file.empty.failed")
        }
    }

    private func iconName(for state: FileTranscriptionJobState) -> String {
        switch state {
        case .queued:
            return "clock"
        case .downloading:
            return "arrow.down.circle"
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
        case .downloading:
            return "arrow.down.circle"
        case .reading, .transcribing:
            return "waveform"
        case .queued:
            return "doc.text"
        }
    }

    private func stateTint(for state: FileTranscriptionJobState) -> Color {
        switch state {
        case .completed:
            return TranscriptionTheme.accentDeep
        case .failed:
            return TranscriptionTheme.error
        case .cancelled:
            return TranscriptionTheme.warning
        case .downloading, .reading, .transcribing:
            return TranscriptionTheme.accentDark
        case .queued:
            return TranscriptionTheme.textMuted
        }
    }

    private func rowBackground(for job: FileTranscriptionJob) -> Color {
        if job.id == viewModel.selectedJobID {
            return TranscriptionTheme.accentBright.opacity(0.22)
        }
        switch job.state {
        case .failed:
            return TranscriptionTheme.error.opacity(0.05)
        case .completed:
            return TranscriptionTheme.accentBright.opacity(0.10)
        default:
            return Color.clear
        }
    }

    private func clampedProgress(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
