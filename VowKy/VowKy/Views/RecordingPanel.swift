import SwiftUI
import AppKit
import Combine

// MARK: - RecordingPanel (NSPanel manager)

@MainActor
final class RecordingPanel {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState
    private var toastWorkItem: DispatchWorkItem?
    private var previousState: AppState.State = .idle

    init(appState: AppState) {
        self.appState = appState
        observeState()
    }

    // MARK: - Show / Hide

    func show() {
        if panel == nil {
            createPanel()
        }
        panel?.orderFront(nil)
    }

    func hide() {
        toastWorkItem?.cancel()
        toastWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: - Private

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position: top-center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 130
            let y = screenFrame.maxY - 120
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let hostingView = NSHostingView(
            rootView: RecordingPanelContent()
                .environmentObject(appState)
        )

        // Vibrancy/blur background
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true

        hostingView.frame = visualEffect.bounds
        hostingView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingView)

        panel.contentView = visualEffect
        self.panel = panel
    }

    private func observeState() {
        appState.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                let oldState = self.previousState
                self.previousState = newState

                switch newState {
                case .recording, .recognizing:
                    self.toastWorkItem?.cancel()
                    self.toastWorkItem = nil
                    self.show()

                case .idle:
                    // Coming from recognizing with no new result = recognition failed
                    if oldState == .recognizing {
                        self.showToastThenHide()
                    } else {
                        self.hide()
                    }

                case .loading, .outputting:
                    self.hide()
                }
            }
            .store(in: &cancellables)

        // If lastResult is set, immediately hide (successful recognition)
        appState.$lastResult
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] _ in
                self?.hide()
            }
            .store(in: &cancellables)
    }

    private func showToastThenHide() {
        toastWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        toastWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
}

// MARK: - SwiftUI Content View

struct RecordingPanelContent: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.state {
            case .recording:
                recordingView
            case .recognizing:
                recognizingView
            default:
                toastView
            }
        }
        .frame(width: 260, height: 80)
    }

    private var recordingView: some View {
        HStack(spacing: 12) {
            PulsingMicIcon()
            VStack(alignment: .leading, spacing: 4) {
                Text("正在聆听...")
                    .font(.system(size: 14, weight: .medium))
                AudioLevelBar(level: appState.audioLevel)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 20)
    }

    private var recognizingView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("识别中...")
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 20)
    }

    private var toastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("未识别到语音，请重试")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Pulsing Mic Icon

struct PulsingMicIcon: View {
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 24))
            .foregroundColor(.red)
            .scaleEffect(isPulsing ? 1.15 : 1.0)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Audio Level Bar

struct AudioLevelBar: View {
    let level: Float

    private var normalizedLevel: CGFloat {
        CGFloat(min(max(level, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                Capsule()
                    .fill(Color.green)
                    .frame(width: geometry.size.width * normalizedLevel)
                    .animation(.linear(duration: 0.05), value: normalizedLevel)
            }
        }
    }
}

// MARK: - AppState audio level accessor

extension AppState {
    /// Read audio level from the injected AudioRecorderProtocol.
    var audioLevel: Float { audioRecorder.audioLevel }
}
