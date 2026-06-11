import SwiftUI
import AppKit

// MARK: - UserDefaults keys + 字号范围

enum SubtitleDefaults {
    static let enabled  = "subtitle.enabled"
    static let fontSize = "subtitle.fontSize"
    static let originX  = "subtitle.originX"
    static let originY  = "subtitle.originY"

    static let minFont: CGFloat = 16
    static let maxFont: CGFloat = 48
    static let defaultFont: CGFloat = 28
}

// MARK: - 字幕内容数据源（只关心最新一段）

@MainActor
final class SubtitleModel: ObservableObject {
    @Published var original: String = ""
    @Published var translation: ParagraphTranslationState = .pending
    @Published var fontSize: CGFloat

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
    }
}

// MARK: - 浮动字幕窗管理器

/// 管理一个浮在所有窗口（含全屏共享/演示）之上、不抢焦点、可拖动的字幕 NSPanel。
/// 仿 RecordingPanel 模式，但额外解决：盖全屏的 level、DragGesture 拖动、位置/字号持久化。
@MainActor
final class SubtitleOverlayController {
    private var panel: NSPanel?
    let model: SubtitleModel
    private let defaults: UserDefaults
    private var moveObserver: NSObjectProtocol?

    /// 关闭按钮回调：回写 ViewModel 的字幕开关，保持 Toggle 状态一致。
    var requestDisable: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: SubtitleDefaults.fontSize) as? Double
        self.model = SubtitleModel(fontSize: CGFloat(stored ?? Double(SubtitleDefaults.defaultFont)))
    }

    // MARK: Show / Hide

    func show() {
        if panel == nil { createPanel() }
        // nonactivating + 全屏空间：orderFrontRegardless 比 orderFront(nil) 更可靠
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        hide()
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        panel = nil
    }

    // MARK: Content

    func update(paragraph: TranscriptParagraph?) {
        model.original = paragraph?.text ?? ""
        model.translation = paragraph?.translation ?? .pending
        // 只换文字，不动窗口尺寸/位置 → 内容刷新时字幕条纹丝不动，杜绝横跳
    }

    /// 翻译关闭场景：只有原文，无译文段。
    func updateOriginalOnly(_ text: String) {
        model.original = text
        model.translation = .skippedSameLanguage  // 不渲染译文行
    }

    // MARK: Font

    func bumpFont(_ delta: CGFloat) {
        let v = min(SubtitleDefaults.maxFont, max(SubtitleDefaults.minFont, model.fontSize + delta))
        guard v != model.fontSize else { return }
        model.fontSize = v
        defaults.set(Double(v), forKey: SubtitleDefaults.fontSize)
        applyPanelSize()  // 仅字号变化时才调整窗口高度
    }

    // MARK: Private

    private func createPanel() {
        // 用主屏（含原点的内置屏）而非 NSScreen.main：后者会指向已断开的外接屏，
        // 导致字幕跑到不可见区域。
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let width = min(screen.frame.width * 0.65, 900)

        let panel = SubtitlePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false  // 拖动由 SubtitlePanel.mouseDown 的 performDrag 接管
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = SubtitleContentView(
            model: model,
            onFontDelta: { [weak self] d in self?.bumpFont(d) },
            onClose: { [weak self] in self?.requestDisable?() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // 拖动结束后窗口服务器已移好窗，这里只负责把新位置持久化
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let origin = self.panel?.frame.origin else { return }
                self.defaults.set(Double(origin.x), forKey: SubtitleDefaults.originX)
                self.defaults.set(Double(origin.y), forKey: SubtitleDefaults.originY)
            }
        }

        self.panel = panel
        restorePosition(width: width, screen: screen)
        applyPanelSize()
    }

    private func restorePosition(width: CGFloat, screen: NSScreen) {
        if let x = defaults.object(forKey: SubtitleDefaults.originX) as? Double,
           let y = defaults.object(forKey: SubtitleDefaults.originY) as? Double {
            panel?.setFrameOrigin(clampToVisible(NSPoint(x: x, y: y)))
        } else {
            let vf = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.minY + 80))
        }
    }

    /// 记忆位置落在已拔掉的屏 / 拖出可见区时，钳回主屏底部居中。
    private func clampToVisible(_ p: NSPoint) -> NSPoint {
        guard let size = panel?.frame.size else { return p }
        let rect = NSRect(origin: p, size: size)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        if onScreen { return p }
        let vf = (NSScreen.screens.first ?? NSScreen.main!).visibleFrame
        return NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 80)
    }

    /// 固定窗口高度（按字号算，够放 2 行原文 + 2 行译文）。内容刷新**不**调用它，
    /// 只有创建/字号变化时才重算 → 窗口尺寸恒定，从根上消除字幕横跳。
    private func applyPanelSize() {
        guard let panel else { return }
        let f = model.fontSize
        let height = ceil(f * 1.3 * 2 + f * 0.82 * 1.3 * 2 + 6 + 36)
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.minY, width: old.width, height: height), display: true)
        ensureVisible()
    }

    /// 把字幕窗钳进「与它相交面积最大的屏」的可见区；完全不在任何屏上则回主屏底部居中。
    /// 兜底外接屏断开、坐标系偏移、调字号后超出屏幕等情况，杜绝字幕跑到看不见的地方。
    private func ensureVisible() {
        guard let panel else { return }
        let frame = panel.frame
        func area(_ r: NSRect) -> CGFloat { r.isEmpty ? 0 : r.width * r.height }

        let best = NSScreen.screens.max {
            area($0.visibleFrame.intersection(frame)) < area($1.visibleFrame.intersection(frame))
        }
        guard let vf = best?.visibleFrame else { return }

        if area(vf.intersection(frame)) <= 0 {
            let main = (NSScreen.screens.first ?? best!).visibleFrame
            panel.setFrameOrigin(NSPoint(x: main.midX - frame.width / 2, y: main.minY + 80))
            return
        }

        var origin = frame.origin
        origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - frame.width))
        origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - frame.height))
        if origin != frame.origin {
            panel.setFrameOrigin(origin)
        }
    }
}

// MARK: - 字幕专用 Panel（AppKit 原生拖动）

/// 空白处按下即交给窗口服务器的原生拖动会话（performDrag）。位移基于全局鼠标位置，
/// 参照系不随窗口移动——不会出现 SwiftUI DragGesture 移窗时的自我强化反馈循环
/// （即字幕窗自己不停往下滑的 bug）。按钮等控件自行消费点击，不会触发拖动。
private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        performDrag(with: event)
    }
}

// MARK: - 字幕内容视图

struct SubtitleContentView: View {
    @ObservedObject var model: SubtitleModel
    let onFontDelta: (CGFloat) -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var translationText: String? {
        if case .translated(let t) = model.translation { return t }
        return nil
    }

    private var showTranslationRow: Bool {
        switch model.translation {
        case .skippedSameLanguage, .failed: return false
        case .pending, .translated: return true
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 背景圆角条填满整个固定窗口
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.7))

            // 文字垂直居中在固定窗口里；内容变化只换字、窗口不动
            VStack(alignment: .center, spacing: 6) {
                Text(model.original.isEmpty ? " " : model.original)
                    .font(.system(size: model.fontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.center)

                if showTranslationRow {
                    Text(translationText ?? " ")
                        .font(.system(size: model.fontSize * 0.82, weight: .regular))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .multilineTextAlignment(.center)
                        .opacity(translationText == nil ? 0 : 1)  // pending 占位不闪
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hovering {
                HStack(spacing: 6) {
                    iconButton("textformat.size.smaller") { onFontDelta(-2) }
                    iconButton("textformat.size.larger") { onFontDelta(2) }
                    iconButton("xmark") { onClose() }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}
