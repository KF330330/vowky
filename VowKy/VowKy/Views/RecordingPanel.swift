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
            ButterflyIcon()
            VStack(alignment: .leading, spacing: 4) {
                Text("正在聆听...")
                    .font(.system(size: 14, weight: .medium))
                WaveformBars(levelProvider: { appState.audioLevel })
                    .frame(height: 18)
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
//
// 不再用于悬浮窗（已替换为 ButterflyIcon），但 OnboardingView 的"试一试"流程仍引用。
// 保留定义以维持向后兼容。

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

// MARK: - Butterfly Icon

struct ButterflyIcon: View {
    var body: some View {
        Image(nsImage: Self.butterflyImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 28, height: 28)
            .foregroundColor(PanelTheme.accentDeep)
    }

    private static let butterflyImage: NSImage = {
        let img = NSImage(named: "ButterflyLarge") ?? NSImage()
        img.isTemplate = true
        return img
    }()
}

// MARK: - Waveform Bars
//
// 16 条竖向频谱条，按 audioLevel + 各自相位 sin 振荡。
// 没有真 FFT — 视觉上像 EQ，但每条与音频频段无对应关系，等同 HTML 方案 B 的实现。
// baseline 有微弱呼吸，保证没说话时也能看出"在听"。
//
// level 用 () -> Float 闭包传入：AudioRecorder.audioLevel 不是 @Published，
// 父 view body 不会因它变化重新评估。改用闭包，让 TimelineView 每帧 fire 时
// 从 appState 直接拿最新音量，否则 bar 永远停在 view 首次评估那一刻的 RMS 快照。

struct WaveformBars: View {
    let levelProvider: () -> Float

    private static let barCount: Int = 16
    private static let phases: [Double] = (0..<barCount).map { i in
        Double(i) * 0.83 + sin(Double(i) * 1.7)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = levelProvider()
            GeometryReader { geo in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<Self.barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(PanelTheme.barGradient)
                            .frame(
                                width: 4,
                                height: Self.barHeight(
                                    index: i,
                                    time: t,
                                    level: level,
                                    maxHeight: geo.size.height
                                )
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    private static func barHeight(
        index: Int,
        time: TimeInterval,
        level: Float,
        maxHeight: CGFloat
    ) -> CGFloat {
        let n = Double(barCount)
        let mid = (n - 1) / 2.0
        let centerWeight = 1.0 - abs(Double(index) - mid) / mid * 0.55
        let osc = 0.5 + 0.5 * sin(time * 7.5 + phases[index])
        // RMS 是平方均方根，正常说话只在 0.05~0.25 区间，线性传入会让 bar 顶多到 22% 看不清。
        // 用 sqrt 非线性放大 + 1.6x 系数，让说话音量更明显映射到视觉高度。
        let rawLev = Double(min(max(level, 0), 1))
        let lev = min(1.0, sqrt(rawLev) * 1.6)
        let baselineBreath = 0.06 + 0.03 * (0.5 + 0.5 * sin(time * 1.6 + phases[index] * 0.7))
        let dynamic = lev * centerWeight * (0.45 + 0.55 * osc) * 0.88
        let h = min(1.0, baselineBreath + dynamic)
        return maxHeight * CGFloat(h)
    }
}

// MARK: - Panel Theme Tokens
//
// RecordingTheme 定义在 RecordingTranscriptionView.swift 中且为 private，
// 这里只取 RecordingPanel 用到的几个 token，避免改动跨文件可见性。
// 数值同步自 RecordingTheme（accentBright / accentDeep）。

private enum PanelTheme {
    static let accentBright = Color(    // #D4E87C
        red: 0xD4 / 255.0,
        green: 0xE8 / 255.0,
        blue: 0x7C / 255.0
    )
    static let accentMain = Color(      // #B8D458
        red: 0xB8 / 255.0,
        green: 0xD4 / 255.0,
        blue: 0x58 / 255.0
    )
    static let accentDeep = Color(      // #8AAE3A
        red: 0x8A / 255.0,
        green: 0xAE / 255.0,
        blue: 0x3A / 255.0
    )
    static let accentDarkest = Color(   // #4A5A22
        red: 0x4A / 255.0,
        green: 0x5A / 255.0,
        blue: 0x22 / 255.0
    )
    static let barGradient = LinearGradient(
        colors: [accentBright, accentDeep],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - AppState audio level accessor

extension AppState {
    /// Read audio level from the injected AudioRecorderProtocol.
    var audioLevel: Float { audioRecorder.audioLevel }
}
