import AppKit
import Sparkle

/// 自定义 Sparkle user driver。
///
/// 继承标准 driver,**只覆盖「发现新版本」这一个窗口**(改成 VowKy 自绘的更新弹窗);
/// 下载 / 解压 / 安装 / 重启 / 错误 / 权限请求等其余全部生命周期 UI 仍走 Sparkle 标准实现
/// (继承自 `SPUStandardUserDriver`),把改动面和风险降到最低。
///
/// Sparkle 通过 `SPUUserDriver` 协议以动态派发调用本实例,因此覆盖 `showUpdateFound(...)` 即可生效。
final class VowKyUpdaterUserDriver: SPUStandardUserDriver {

    /// 由 App 注入:展示自绘「发现新版本」窗口。回调必须在用户选择后调用恰好一次。
    /// 为 nil 时回退到标准 driver 的默认弹窗。
    var presentUpdate: ((SUAppcastItem, @escaping (SPUUserUpdateChoice) -> Void) -> Void)?

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard let presentUpdate else {
            super.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }
        presentUpdate(appcastItem, reply)
    }

    /// 「已是最新版」提示。Sparkle 标准实现用的是 Sparkle 自带按系统语言挑的文案，
    /// 会出现「App 设英文但弹窗中文」的混杂。这里改用 VowKy 自己的本地化文案（跟随 App 内语言）。
    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let alert = NSAlert()
        alert.messageText = LL("update.upToDate.title")
        alert.informativeText = LL("update.upToDate.message", current)
        alert.alertStyle = .informational
        alert.addButton(withTitle: LL("common.ok"))
        alert.runModal()
        acknowledgement()
    }
}
