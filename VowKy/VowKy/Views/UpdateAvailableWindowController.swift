import SwiftUI
import AppKit
import WebKit
import Sparkle

// MARK: - Window Controller

/// VowKy 自绘的更新窗口:「发现新版本」弹窗 + 点「安装更新」后同窗变身的下载/安装进度视图
/// (进度事件由 `VowKyUpdaterUserDriver.progressSink` 送达,Sparkle 原生状态窗被成套接管)。
/// 单例 + NSWindow + NSHostingController,模式与 `WhatsNewWindowController` 一致。
/// `reply` 必须在用户做出选择后恰好调用一次;提示模式红灯关窗 == 「稍后提醒我」(.dismiss);
/// 进度模式红灯关窗 == 下载中取消 / 就绪时延后安装 / 解压安装中仅收起(更新继续)。
@MainActor
final class UpdateAvailableWindowController {
    static let shared = UpdateAvailableWindowController()

    private var window: NSWindow?
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    private var didReply = false
    private var closeObserver: Any?

    // 进度模式状态(progressModel 非 nil == 进度模式)
    private var progressModel: UpdateProgressViewModel?
    private var cancelDownload: (() -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var didReplyReady = false

    func present(
        appcastItem: SUAppcastItem,
        currentVersion: String,
        updater: SPUUpdater,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        self.reply = reply
        self.didReply = false

        UpdateLogger.log("展示「发现新版本」弹窗: 新版本=\(appcastItem.displayVersionString) 当前=\(currentVersion)")

        let icon = Self.appIcon()
        let notesHTML = appcastItem.itemDescription ?? "<p>\(L("update.notesUnavailable"))</p>"

        let view = UpdateAvailableView(
            appIcon: icon,
            newVersion: appcastItem.displayVersionString,
            currentVersion: currentVersion,
            notesHTML: notesHTML,
            autoUpdate: updater.automaticallyDownloadsUpdates,
            onAutoUpdateChange: { updater.automaticallyDownloadsUpdates = $0 },
            onInstall: { [weak self] in self?.beginInstall() },
            onLater: { [weak self] in self?.finish(.dismiss) },
            onSkip: { [weak self] in self?.finish(.skip) }
        )

        let hosting = NSHostingController(rootView: view.environmentObject(LocalizationManager.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = L("window.update.title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 480))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleClose()
        }
        self.window = window
    }

    private func finish(_ choice: SPUUserUpdateChoice) {
        deliver(choice)
        window?.close()
    }

    /// 用户点「安装更新」:回复 Sparkle 后不关窗,同窗变身进度视图(T3:可最小化,不再霸屏)。
    private func beginInstall() {
        deliver(.install)
        switchToProgress()
    }

    private func handleClose() {
        if let model = progressModel {
            // 进度模式红灯关窗:下载中=取消;就绪=延后安装(退出 app 时仍会自动装);
            // 解压/安装中已无可取消,仅收起 UI,更新在后台继续。
            switch model.phase {
            case .downloading: cancelActiveDownload()
            case .ready: deliverReady(.dismiss)
            case .extracting, .installing: break
            }
            progressModel = nil
        } else {
            // 提示模式红灯关窗、未做选择 → 视为「稍后提醒我」
            deliver(.dismiss)
        }
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window = nil
    }

    // MARK: - 进度模式(事件来自 VowKyUpdaterUserDriver.progressSink)

    func handleProgressEvent(_ event: UpdateProgressEvent) {
        switch event {
        case .downloadStarted(let cancel):
            cancelDownload = cancel
            ensureProgressWindow()
            progressModel?.phase = .downloading
        case .downloadExpectedLength(let bytes):
            progressModel?.expectedBytes = bytes
        case .downloadReceived(let bytes):
            progressModel?.receivedBytes += bytes
        case .extractStarted:
            cancelDownload = nil // Sparkle 契约:解压开始后取消块失效
            ensureProgressWindow()
            progressModel?.phase = .extracting
        case .extractProgress(let progress):
            progressModel?.extractProgress = progress
        case .readyToRelaunch(let reply):
            readyReply = reply
            didReplyReady = false
            ensureProgressWindow() // 用户可能中途收起了窗口,就绪需确认时重新展示
            progressModel?.phase = .ready
        case .installing:
            cancelDownload = nil
            progressModel?.phase = .installing
        case .dismiss:
            closeProgress()
        }
    }

    /// 进入/确保进度窗在屏:提示窗还开着就原窗变身;已被关掉就新建一个进度窗。
    private func ensureProgressWindow() {
        if progressModel != nil, window != nil { return }
        switchToProgress()
    }

    private func switchToProgress() {
        let model = progressModel ?? UpdateProgressViewModel()
        progressModel = model

        let view = UpdateProgressView(
            appIcon: Self.appIcon(),
            model: model,
            onCancel: { [weak self] in self?.cancelActiveDownload() },
            onInstallAndRelaunch: { [weak self] in self?.deliverReady(.install) }
        )
        let hosting = NSHostingController(rootView: view.environmentObject(LocalizationManager.shared))

        if let window {
            // 同窗变身:保留位置,只换内容与尺寸
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 460, height: 168))
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = L("window.update.title")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 168))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.handleClose()
            }
            self.window = window
        }
    }

    /// 会话结束(完成/取消/出错):关进度窗;非进度模式(如发现更新前的检查窗清理)则忽略。
    private func closeProgress() {
        guard progressModel != nil else { return }
        progressModel = nil
        cancelDownload = nil
        readyReply = nil
        window?.close()
    }

    private func cancelActiveDownload() {
        guard let cancel = cancelDownload else { return }
        cancelDownload = nil
        UpdateLogger.log("用户取消更新下载")
        cancel() // Sparkle 随后回调 dismissUpdateInstallation → .dismiss 关窗
    }

    private func deliverReady(_ choice: SPUUserUpdateChoice) {
        guard !didReplyReady, let reply = readyReply else { return }
        didReplyReady = true
        UpdateLogger.log("用户在就绪窗选择: \(Self.choiceLabel(choice))")
        reply(choice)
        readyReply = nil
    }

    private static func appIcon() -> NSImage {
        NSImage(named: NSImage.applicationIconName)
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private func deliver(_ choice: SPUUserUpdateChoice) {
        guard !didReply else { return }
        didReply = true
        UpdateLogger.log("用户在更新弹窗选择: \(Self.choiceLabel(choice))")
        AnalyticsService.shared.track("update_prompt_choice", data: [
            "choice": Self.choiceEventValue(choice),
        ])
        reply?(choice)
        reply = nil
    }

    private static func choiceEventValue(_ choice: SPUUserUpdateChoice) -> String {
        switch choice {
        case .install: return "install"
        case .dismiss: return "dismiss"
        case .skip: return "skip"
        @unknown default: return "unknown"
        }
    }

    private static func choiceLabel(_ choice: SPUUserUpdateChoice) -> String {
        switch choice {
        case .install: return "安装更新 (install)"
        case .dismiss: return "稍后提醒 (dismiss)"
        case .skip: return "跳过此版本 (skip)"
        @unknown default: return "未知 (\(choice.rawValue))"
        }
    }
}

// MARK: - SwiftUI View(对应定稿方案4:真实图标 + 单行标题 + 卡片化说明 + 勾选 + 三按钮)

private struct UpdateAvailableView: View {
    @EnvironmentObject private var loc: LocalizationManager
    let appIcon: NSImage
    let newVersion: String
    let currentVersion: String
    let notesHTML: String
    @State private var autoUpdate: Bool
    let onAutoUpdateChange: (Bool) -> Void
    let onInstall: () -> Void
    let onLater: () -> Void
    let onSkip: () -> Void

    /// VowKy 品牌绿(与 app 图标一致)
    private let brandGreen = Color(red: 0.478, green: 0.780, blue: 0.047)

    init(
        appIcon: NSImage,
        newVersion: String,
        currentVersion: String,
        notesHTML: String,
        autoUpdate: Bool,
        onAutoUpdateChange: @escaping (Bool) -> Void,
        onInstall: @escaping () -> Void,
        onLater: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.appIcon = appIcon
        self.newVersion = newVersion
        self.currentVersion = currentVersion
        self.notesHTML = notesHTML
        _autoUpdate = State(initialValue: autoUpdate)
        self.onAutoUpdateChange = onAutoUpdateChange
        self.onInstall = onInstall
        self.onLater = onLater
        self.onSkip = onSkip
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部:真实图标 + 单行标题 + 当前版本
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.string("update.available.heading", newVersion))
                        .font(.system(size: 18, weight: .bold))
                    Text(loc.string("update.available.currentVersion", currentVersion))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // 说明区(卡片化 HTML 来自 appcast 描述,可滚动)
            NotesWebView(html: notesHTML)
                .frame(height: 214)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 18)

            // 自动更新勾选
            Toggle(loc.string("update.autoDownload"), isOn: $autoUpdate)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .onChange(of: autoUpdate) { onAutoUpdateChange($0) }
                .padding(.horizontal, 22)
                .padding(.top, 14)

            // 底栏按钮
            HStack(spacing: 10) {
                Button(loc.string("update.skipVersion")) { onSkip() }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
                Button(loc.string("update.remindLater")) { onLater() }
                    .controlSize(.large)
                Button(loc.string("update.install")) { onInstall() }
                    .buttonStyle(.borderedProminent)
                    .tint(brandGreen)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .frame(width: 540)
    }
}

// MARK: - WKWebView 包装(透明背景,HTML 卡片自带底色;暗色由 HTML 的 prefers-color-scheme 适配)

private struct NotesWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        // 透明背景:让 HTML 的纸张底色透出(等宽文档风)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// 加载完成后强制滚到顶部 —— 否则 WebView 会把焦点落到说明末尾的链接而自动滚到底。
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.scrollTo(0,0)", completionHandler: nil)
        }
    }
}

// MARK: - 进度模式(下载/解压/安装/就绪)

@MainActor
final class UpdateProgressViewModel: ObservableObject {
    enum Phase {
        case downloading
        case extracting
        case installing
        case ready
    }

    @Published var phase: Phase = .downloading
    @Published var receivedBytes: UInt64 = 0
    /// 服务器告知的总字节数,可能为 0(未知)或不准 —— 进度值须钳制。
    @Published var expectedBytes: UInt64 = 0
    @Published var extractProgress: Double = 0
}

private struct UpdateProgressView: View {
    @EnvironmentObject private var loc: LocalizationManager
    let appIcon: NSImage
    @ObservedObject var model: UpdateProgressViewModel
    let onCancel: () -> Void
    let onInstallAndRelaunch: () -> Void

    /// VowKy 品牌绿(与 app 图标一致)
    private let brandGreen = Color(red: 0.478, green: 0.780, blue: 0.047)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleText)
                        .font(.system(size: 15, weight: .semibold))
                    Text(detailText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            progressBar
                .padding(.horizontal, 20)
                .padding(.top, 12)

            HStack(spacing: 10) {
                if model.phase == .downloading {
                    Text(loc.string("update.progress.minimizeHint"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                switch model.phase {
                case .downloading:
                    Button(loc.string("update.progress.cancel")) { onCancel() }
                        .controlSize(.large)
                case .ready:
                    Button(loc.string("update.progress.installAndRelaunch")) { onInstallAndRelaunch() }
                        .buttonStyle(.borderedProminent)
                        .tint(brandGreen)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                case .extracting, .installing:
                    EmptyView()
                }
            }
            .frame(height: 32)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(width: 460)
    }

    @ViewBuilder
    private var progressBar: some View {
        switch model.phase {
        case .downloading:
            if model.expectedBytes > 0 {
                ProgressView(value: downloadFraction)
            } else {
                ProgressView() // 总长未知 → 不确定进度条
                    .progressViewStyle(.linear)
            }
        case .extracting:
            ProgressView(value: min(max(model.extractProgress, 0), 1))
        case .installing:
            ProgressView()
                .progressViewStyle(.linear)
        case .ready:
            ProgressView(value: 1)
        }
    }

    private var downloadFraction: Double {
        guard model.expectedBytes > 0 else { return 0 }
        return min(Double(model.receivedBytes) / Double(model.expectedBytes), 1)
    }

    private var titleText: String {
        switch model.phase {
        case .downloading: return loc.string("update.progress.downloading")
        case .extracting: return loc.string("update.progress.extracting")
        case .installing: return loc.string("update.progress.installing")
        case .ready: return loc.string("update.progress.ready")
        }
    }

    private var detailText: String {
        switch model.phase {
        case .downloading:
            let received = Self.formatBytes(model.receivedBytes)
            if model.expectedBytes > 0 {
                let total = Self.formatBytes(max(model.expectedBytes, model.receivedBytes))
                return loc.string("update.progress.downloadedOfTotal", received, total)
            }
            return loc.string("update.progress.downloaded", received)
        case .extracting, .installing:
            return loc.string("update.progress.minimizeHint")
        case .ready:
            return loc.string("update.progress.readyHint")
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
