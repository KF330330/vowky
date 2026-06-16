import SwiftUI
import AppKit
import WebKit
import Sparkle

// MARK: - Window Controller

/// VowKy 自绘的「发现新版本」弹窗(替换 Sparkle 标准 found-window;下载/安装仍走标准 driver)。
/// 单例 + NSWindow + NSHostingController,模式与 `WhatsNewWindowController` 一致。
/// `reply` 必须在用户做出选择后恰好调用一次;红灯关窗 == 「稍后提醒我」(.dismiss)。
@MainActor
final class UpdateAvailableWindowController {
    static let shared = UpdateAvailableWindowController()

    private var window: NSWindow?
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    private var didReply = false
    private var closeObserver: Any?

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

        let icon = NSImage(named: NSImage.applicationIconName)
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let notesHTML = appcastItem.itemDescription ?? "<p>\(L("update.notesUnavailable"))</p>"

        let view = UpdateAvailableView(
            appIcon: icon,
            newVersion: appcastItem.displayVersionString,
            currentVersion: currentVersion,
            notesHTML: notesHTML,
            autoUpdate: updater.automaticallyDownloadsUpdates,
            onAutoUpdateChange: { updater.automaticallyDownloadsUpdates = $0 },
            onInstall: { [weak self] in self?.finish(.install) },
            onLater: { [weak self] in self?.finish(.dismiss) },
            onSkip: { [weak self] in self?.finish(.skip) }
        )

        let hosting = NSHostingController(rootView: view.environmentObject(LocalizationManager.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = L("window.update.title")
        window.styleMask = [.titled, .closable]
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

    private func handleClose() {
        // 红灯关窗、未做选择 → 视为「稍后提醒我」
        deliver(.dismiss)
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window = nil
    }

    private func deliver(_ choice: SPUUserUpdateChoice) {
        guard !didReply else { return }
        didReply = true
        UpdateLogger.log("用户在更新弹窗选择: \(Self.choiceLabel(choice))")
        reply?(choice)
        reply = nil
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
