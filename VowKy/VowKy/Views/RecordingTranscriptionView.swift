import AppKit
import Combine
import SwiftUI

// MARK: - Recording Transcription Window Controller

@MainActor
final class RecordingTranscriptionWindowController {
    static let shared = RecordingTranscriptionWindowController()

    private var window: NSWindow?
    private var viewModel: RecordingTranscriptionViewModel?
    /// willClose 观察者 token：窗口关闭时移除，避免每次开→关累积一个僵尸注册
    private var closeObserver: NSObjectProtocol?

    /// 供 AppDelegate.applicationShouldTerminate 检查/驱动当前的录音流程。
    var activeViewModel: RecordingTranscriptionViewModel? { viewModel }

    func showWindow(appState: AppState) {
        NSApp.setActivationPolicy(.regular)

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            viewModel?.start()
            return
        }

        let viewModel = RecordingTranscriptionViewModel(
            appState: appState,
            metadataRecorder: { text, meta in
                HistoryStore.shared.insertWithMetadata(content: text, sourceType: meta.sourceType, metadata: meta)
            }
        )
        let view = RecordingTranscriptionView(viewModel: viewModel)
            .environmentObject(LocalizationManager.shared)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = L("window.recording.title")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 520))
        window.minSize = NSSize(width: 540, height: 420)
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
                // 退出流程中由 AppDelegate 驱动 stop()，这里不能 cancel 否则会删除正在保存的文件
                if self.viewModel?.isFinalizingForQuit != true {
                    self.viewModel?.cancel()
                }
                self.viewModel = nil
                self.window = nil
                NSApp.setActivationPolicy(.prohibited)
            }
        }

        self.viewModel = viewModel
        self.window = window
        viewModel.start()
    }
}

// MARK: - View

struct RecordingTranscriptionView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @ObservedObject var viewModel: RecordingTranscriptionViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                header
                recordingCard
                transcriptCard
                footer
            }
            .padding(12)
            .frame(minWidth: 540, minHeight: 420)
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

            if viewModel.isFinalizingForQuit {
                finalizingForQuitOverlay
            }
        }
        .background(translationHost)
    }

    /// Apple 翻译引擎的 session 宿主（不可见）。LLM 引擎或翻译关闭时为空。
    @ViewBuilder
    private var translationHost: some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *),
           viewModel.translationConfig.enabled,
           viewModel.translationConfig.engine == .apple,
           let provider = viewModel.translationProvider as? AppleTranslationProvider,
           let coordinator = viewModel.translationCoordinator {
            AppleTranslationHostView(
                provider: provider,
                coordinator: coordinator,
                target: viewModel.translationConfig.target
            )
        }
        #endif
    }

    private var translationControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.translationConfig.enabled },
                set: { viewModel.setTranslationEnabled($0) }
            )) {
                Text(loc.string("recording.translation.toggle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TranscriptionTheme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()

            if viewModel.translationConfig.enabled {
                Menu {
                    ForEach(TranslationTarget.presets, id: \.target) { preset in
                        Button {
                            viewModel.setTranslationTarget(preset.target)
                        } label: {
                            if preset.target == viewModel.translationConfig.target {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10, weight: .semibold))
                        Text(viewModel.translationConfig.target.displayName)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(TranscriptionTheme.accentDark)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Toggle(isOn: Binding(
                get: { viewModel.subtitleEnabled },
                set: { viewModel.setSubtitleEnabled($0) }
            )) {
                Text(loc.string("recording.subtitle.toggle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TranscriptionTheme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            .help(loc.string("recording.subtitle.help"))
        }
    }

    private var finalizingForQuitOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(loc.string("recording.quitOverlay.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(loc.string("recording.quitOverlay.subtitle"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.55))
            )
        }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(TranscriptionTheme.accentDark)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TranscriptionTheme.accentBright.opacity(0.35))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(loc.string("recording.header.title"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.textPrimary)
                Text(loc.string("recording.header.subtitle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TranscriptionTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                TranscriptionHistoryWindowController.shared.showWindow(filter: .recording)
            } label: {
                Label(loc.string("recording.action.history"), systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(TranscriptionGhostButtonStyle())
            .help(loc.string("recording.action.history"))

            statusPill
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 42)
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(statusDotColor.opacity(isLiveState ? 0.28 : 0), lineWidth: isLiveState ? 5 : 0)
                )
            Text(statusBadgeText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(TranscriptionTheme.textSecondary)
                .lineLimit(1)
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

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                RecordingPulseIcon(
                    state: viewModel.state,
                    level: viewModel.audioLevel,
                    reduceMotion: reduceMotion
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(cardTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(TranscriptionTheme.textPrimary)
                        .lineLimit(1)

                    Text(headerSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(TranscriptionTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(headerDurationText)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundColor(TranscriptionTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(durationCaption)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(TranscriptionTheme.textMuted)
                }
            }

            RecordingWaveformView(
                bands: viewModel.waveformBands,
                isActive: viewModel.state == .recording,
                isProcessing: viewModel.state == .loadingModel || viewModel.state == .finishing
            )
            .frame(height: 36)

            if viewModel.state == .finishing {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = viewModel.finalizationFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(TranscriptionTheme.accentDeep)
                            .frame(height: 8)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(TranscriptionTheme.accentDeep)
                            .frame(height: 8)
                    }
                    Text(loc.string("recording.finishing.hint"))
                        .font(.system(size: 11))
                        .foregroundColor(TranscriptionTheme.textMuted)
                        .lineLimit(2)
                }
            } else if viewModel.state == .loadingModel {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(TranscriptionTheme.accentDeep)
                    .frame(height: 4)
            }
        }
        .padding(14)
        .frame(minHeight: 104)
        .transcriptionCardStyle()
    }

    private var headerSubtitle: String {
        if viewModel.state == .finishing {
            let segment = viewModel.finalizationSegmentText ?? loc.string("recording.segment.preparing")
            if let eta = viewModel.finalizationETAText {
                return loc.string("recording.headerSubtitle.segmentETA", segment, eta)
            }
            return segment
        }
        return viewModel.statusText
    }

    private var headerDurationText: String {
        viewModel.state == .finishing ? viewModel.finalizationDurationText : viewModel.durationText
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: transcriptIconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.accentDark)

                Text(loc.string("recording.transcript.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.textPrimary)

                Text(transcriptBadgeText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.accentDarkest)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(TranscriptionTheme.accentBright.opacity(0.32))
                    )

                if viewModel.state == .loadingModel || viewModel.state == .finishing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TranscriptionTheme.accentDeep)
                }

                Spacer()

                translationControls

                if !viewModel.transcriptText.isEmpty {
                    Text(loc.string("recording.transcript.charCount", viewModel.transcriptText.count))
                        .font(.system(size: 11))
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

                if let coordinator = viewModel.translationCoordinator, viewModel.bilingualViewActive {
                    BilingualTranscriptView(
                        coordinator: coordinator,
                        emptyText: emptyTranscriptText
                    )
                } else {
                    if viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(emptyTranscriptText)
                            .font(.system(size: 14))
                            .foregroundColor(TranscriptionTheme.textMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                    }

                    TextEditor(text: Binding(
                        get: { viewModel.transcriptText },
                        set: { _ in }
                    ))
                    .font(.system(size: 14))
                    .foregroundColor(TranscriptionTheme.textPrimary)
                    .lineSpacing(4)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
            .frame(minHeight: 128, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(TranscriptionTheme.accentDark)
                Text(outputPathText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TranscriptionTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .frame(height: 18)
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .transcriptionCardStyle()
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if viewModel.canCancel {
                Button {
                    viewModel.cancel()
                } label: {
                    Label(loc.string("recording.button.cancel"), systemImage: "xmark")
                }
                .buttonStyle(TranscriptionGhostButtonStyle())
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    viewModel.start()
                } label: {
                    Label(loc.string("recording.button.reRecord"), systemImage: "record.circle")
                }
                .buttonStyle(TranscriptionPrimaryButtonStyle())
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.return, modifiers: [])
            }

            if viewModel.canStop {
                Button {
                    viewModel.stop()
                } label: {
                    Label(loc.string("recording.button.finish"), systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(TranscriptionPrimaryButtonStyle())
            }

            Spacer()

            Button {
                viewModel.copyResult()
            } label: {
                Label(loc.string("recording.button.copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(TranscriptionSecondaryButtonStyle())
            .disabled(!viewModel.canCopyResult)

            Button {
                viewModel.openOutputFolder()
            } label: {
                Label(loc.string("recording.button.openFolder"), systemImage: "folder")
            }
            .buttonStyle(TranscriptionSecondaryButtonStyle())
            .disabled(!viewModel.canOpenOutputFolder)
        }
        .controlSize(.small)
        .frame(height: 34)
    }

    private var isLiveState: Bool {
        viewModel.state == .recording || viewModel.state == .loadingModel || viewModel.state == .finishing
    }

    private var statusBadgeText: String {
        switch viewModel.state {
        case .idle:
            return loc.string("recording.badge.ready")
        case .loadingModel:
            return loc.string("recording.badge.loading")
        case .recording:
            return loc.string("recording.badge.live")
        case .finishing:
            return loc.string("recording.badge.finalizing")
        case .completed:
            return loc.string("recording.badge.saved")
        case .cancelled:
            return loc.string("recording.badge.cancelled")
        case .failed:
            return loc.string("recording.badge.failed")
        }
    }

    private var cardTitle: String {
        switch viewModel.state {
        case .idle:
            return loc.string("recording.cardTitle.idle")
        case .loadingModel:
            return loc.string("recording.cardTitle.loadingModel")
        case .recording:
            return loc.string("recording.cardTitle.recording")
        case .finishing:
            return loc.string("recording.cardTitle.finishing")
        case .completed:
            return loc.string("recording.cardTitle.completed")
        case .cancelled:
            return loc.string("recording.cardTitle.cancelled")
        case .failed:
            return loc.string("recording.cardTitle.failed")
        }
    }

    private var durationCaption: String {
        switch viewModel.state {
        case .completed:
            return loc.string("recording.durationCaption.total")
        case .finishing:
            return loc.string("recording.durationCaption.processing")
        default:
            return loc.string("recording.durationCaption.current")
        }
    }

    private var transcriptBadgeText: String {
        switch viewModel.state {
        case .completed:
            return loc.string("recording.transcriptBadge.completed")
        case .finishing:
            return loc.string("recording.transcriptBadge.finishing")
        case .recording:
            return loc.string("recording.transcriptBadge.recording")
        case .failed:
            return loc.string("recording.transcriptBadge.failed")
        default:
            return loc.string("recording.transcriptBadge.waiting")
        }
    }

    private var transcriptIconName: String {
        switch viewModel.state {
        case .completed:
            return "checkmark.seal.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return "text.quote"
        }
    }

    private var emptyTranscriptText: String {
        switch viewModel.state {
        case .loadingModel:
            return loc.string("recording.empty.loadingModel")
        case .recording:
            return loc.string("recording.empty.recording")
        case .finishing:
            return loc.string("recording.empty.finishing")
        case .completed:
            return loc.string("recording.empty.completed")
        case .failed:
            return viewModel.recoveredAudioURL == nil
                ? loc.string("recording.empty.failedNoAudio")
                : loc.string("recording.empty.failedWithAudio")
        case .cancelled:
            return loc.string("recording.empty.cancelled")
        case .idle:
            return loc.string("recording.empty.idle")
        }
    }

    private var outputPathText: String {
        if let output = viewModel.output {
            return output.textURL.deletingLastPathComponent().path
        }
        if let recovered = viewModel.recoveredAudioURL {
            return recovered.deletingLastPathComponent().path
        }
        return loc.string("recording.outputPath.default")
    }

    private var statusDotColor: Color {
        switch viewModel.state {
        case .idle, .completed:
            return TranscriptionTheme.accentDeep
        case .loadingModel, .finishing:
            return TranscriptionTheme.accentMain
        case .recording:
            return TranscriptionTheme.recordingRed
        case .cancelled:
            return TranscriptionTheme.warning
        case .failed:
            return TranscriptionTheme.recordingRed
        }
    }
}

