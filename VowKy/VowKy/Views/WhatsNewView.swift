import SwiftUI
import AppKit

// MARK: - What's New Window Controller

/// 升级后首次启动展示当前版本的「新版功能」窗口；菜单也可随时打开。
@MainActor
final class WhatsNewWindowController {
    static let shared = WhatsNewWindowController()

    /// 上次用户看到过的 build 号（CFBundleVersion）；首次安装时为 nil。
    static let lastSeenBuildKey = "whatsNew_lastSeenBuild"

    /// What's New 启动判定结果。
    enum LaunchDecision: Equatable {
        case skip              // 同一 build，已看过，什么也不做
        case markSeenOnly      // 首次安装，写入 build 但不弹
        case showWindow        // 升级后首次启动，弹一次
    }

    private var window: NSWindow?
    private var markBuildSeenOnClose = false
    private var closeObserver: Any?

    /// 启动时调用：升级后首次启动才弹窗。
    static func presentIfNeeded(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        let currentBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        let lastSeen = defaults.string(forKey: lastSeenBuildKey)

        switch decision(lastSeenBuild: lastSeen, currentBuild: currentBuild) {
        case .skip:
            return
        case .markSeenOnly:
            defaults.set(currentBuild, forKey: lastSeenBuildKey)
        case .showWindow:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    WhatsNewWindowController.shared.showWindow(markBuildSeenOnClose: true, bundle: bundle, defaults: defaults)
                }
            }
        }
    }

    /// 纯函数：决定本次启动该不该弹 What's New。
    nonisolated static func decision(lastSeenBuild: String?, currentBuild: String) -> LaunchDecision {
        if currentBuild.isEmpty { return .skip }
        guard let lastSeenBuild else { return .markSeenOnly }
        return lastSeenBuild == currentBuild ? .skip : .showWindow
    }

    /// 弹出 What's New 窗口。`markBuildSeenOnClose` 控制关闭时是否记录"已看过当前 build"。
    /// 从菜单触发时传 false，否则用户手动看一次反而会导致下次升级提示丢失。
    func showWindow(
        markBuildSeenOnClose: Bool = false,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
        let notes = ReleaseNotesLoader.load(forVersion: shortVersion, bundle: bundle)

        self.markBuildSeenOnClose = markBuildSeenOnClose

        let view = WhatsNewView(version: shortVersion, notes: notes) { [weak self] in
            self?.closeWindow(bundle: bundle, defaults: defaults)
        }
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "VowKy 新版功能"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 420))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowClosed(bundle: bundle, defaults: defaults)
        }

        self.window = window
    }

    func closeWindow(bundle: Bundle, defaults: UserDefaults) {
        window?.close()
    }

    private func handleWindowClosed(bundle: Bundle, defaults: UserDefaults) {
        if markBuildSeenOnClose {
            let currentBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
            if !currentBuild.isEmpty {
                defaults.set(currentBuild, forKey: Self.lastSeenBuildKey)
            }
        }
        markBuildSeenOnClose = false

        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window = nil
    }
}

// MARK: - Release Notes Loader

enum ReleaseNotesLoader {
    static let fallbackText = "本次更新尚无详细说明。\n\n请访问 https://github.com/KF330330/vowky/releases 查看完整发布说明。"

    /// 从 bundle 的 `ReleaseNotes/<version>.md` 读取版本说明；缺失或为空时返回 fallback。
    /// XcodeGen 把 `VowKy/Resources/` 加进 resources 时，目录结构可能被 group/folder reference
    /// 两种方式处理，所以这里先按子目录找一次，找不到再按平铺名查一次。
    static func load(forVersion version: String, bundle: Bundle = .main) -> String {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空 version 时 bundle.url(forResource:"") 会意外匹配第一个 .md 文件，需要先短路掉
        guard !trimmedVersion.isEmpty else { return fallbackText }

        let resolvedURL = bundle.url(forResource: trimmedVersion, withExtension: "md", subdirectory: "ReleaseNotes")
            ?? bundle.url(forResource: trimmedVersion, withExtension: "md")
        guard let url = resolvedURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return fallbackText
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackText : trimmed
    }
}

// MARK: - Markdown Rendering
// 简单的块级 markdown 解析：足够覆盖 release notes 用到的 # / ## / ### / - / 段落 / 空行；
// 内联格式（**bold** / *italic* / [link] / `code`）由 SwiftUI 自带的 AttributedString(markdown:) 处理。
enum MarkdownBlock: Equatable {
    case h1(String)
    case h2(String)
    case h3(String)
    case bullet(String)
    case paragraph(String)
    case spacer
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blocks.append(.spacer)
            } else if line.hasPrefix("### ") {
                blocks.append(.h3(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                blocks.append(.h2(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                blocks.append(.h1(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }

    /// SwiftUI Text 渲染 inline markdown（**bold** / *italic* / [link](url) / `code`）。
    static func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }
}

// MARK: - What's New View

struct WhatsNewView: View {
    let version: String
    let notes: String
    let onClose: () -> Void

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(notes) }

    // 取系统已注册的 app icon（NSImage.applicationIconName 拿到当前 app 的 AppIcon）。
    // 失败回退到 SF 符号，保证至少不空白。
    private var appIcon: NSImage {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            return icon
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            // === Hero：居中 logo + 标题 + 版本号 ===
            VStack(spacing: 8) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.black.opacity(0.10), radius: 6, y: 3)
                Text("VowKy 已更新")
                    .font(.system(size: 19, weight: .bold))
                    .kerning(-0.3)
                Text("版本 \(version)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.bottom, 14)

            Divider().opacity(0.6)

            // === 内容：滚动区，markdown 渲染 ===
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .textSelection(.enabled)
            }

            Divider().opacity(0.6)

            // === 底栏：右下 [好的] ===
            HStack {
                Spacer()
                Button("好的") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .h1(let s):
            Text(s)
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 6)
                .padding(.bottom, 2)
        case .h2(let s):
            Text(s)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 6)
                .padding(.bottom, 2)
        case .h3(let s):
            Text(s)
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 4)
        case .bullet(let s):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                MarkdownParser.inlineText(s)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let s):
            MarkdownParser.inlineText(s)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .spacer:
            Color.clear.frame(height: 4)
        }
    }
}
