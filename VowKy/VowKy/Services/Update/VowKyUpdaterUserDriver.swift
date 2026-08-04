import AppKit
import Sparkle

/// 更新进度事件:由自定义 user driver 发出,注入方(App)决定如何呈现。
/// 与 SPUUserDriver 的下载/解压/安装回调一一对应,载荷只保留 UI 需要的最小信息。
enum UpdateProgressEvent {
    /// 下载开始。`cancel` 在解压开始前随时可调,用于用户取消下载(Sparkle 契约:
    /// `showDownloadDidStartExtractingUpdate` 之后失效)。
    case downloadStarted(cancel: () -> Void)
    /// 服务器告知的总字节数。可能为 0 或不准,UI 需容错;重复回调以最后一次为准。
    case downloadExpectedLength(UInt64)
    /// 新收到一段数据的字节数(由 UI 累加得已下载量)。
    case downloadReceived(UInt64)
    case extractStarted
    /// 解压进度 0.0-1.0。
    case extractProgress(Double)
    /// 更新已就绪,等待用户确认。`reply` 必须恰好调用一次(.install=立即安装并重启,
    /// .dismiss=收起,退出 app 时仍会自动安装)。
    case readyToRelaunch(reply: (SPUUserUpdateChoice) -> Void)
    case installing
    /// 更新会话结束(完成/取消/出错),关闭一切进度 UI。
    case dismiss
}

/// 自定义 Sparkle user driver。
///
/// 覆盖两块 UI,其余(检查中/无更新/错误/权限请求)仍走 Sparkle 标准实现:
/// 1. 「发现新版本」→ `presentUpdate` 闭包(VowKy 自绘更新弹窗);
/// 2. 下载/解压/安装进度 → `progressSink` 事件流(VowKy 自绘进度视图,可最小化)。
///
/// 两个注入点为 nil 时各自回退标准实现。进度接管是成套的:三个会创建 Sparkle
/// 原生状态窗的回调(download initiated / start extracting / ready to install)
/// 必须同进同退,漏掉任何一个都会出现「自绘+原生」双窗口——增删覆盖前先想清楚。
/// 同理,no-update/error 路径**不要**覆盖(历史上覆盖过并回归出双窗口,已撤销)。
///
/// Sparkle 通过 `SPUUserDriver` 协议以动态派发调用本实例(恒主线程)。
final class VowKyUpdaterUserDriver: SPUStandardUserDriver {

    /// 由 App 注入:展示自绘「发现新版本」窗口。回调必须在用户选择后调用恰好一次。
    /// 为 nil 时回退到标准 driver 的默认弹窗。
    var presentUpdate: ((SUAppcastItem, @escaping (SPUUserUpdateChoice) -> Void) -> Void)?

    /// 由 App 注入:接收下载/解压/安装全程进度事件。为 nil 时回退 Sparkle 原生状态窗。
    var progressSink: ((UpdateProgressEvent) -> Void)?

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        UpdateLogger.log("showUpdateFound: \(appcastItem.displayVersionString) (build \(appcastItem.versionString)) — \(presentUpdate != nil ? "展示 VowKy 自绘弹窗" : "回退 Sparkle 标准弹窗")")
        guard let presentUpdate else {
            super.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }
        // 自绘分支跳过了 super,须补上 super 第一件事——关闭「正在检查更新…」窗,
        // 否则该窗一直挂到会话结束(双弹窗)。closeCheckingWindow 是 objc_direct 私有方法
        // 子类不可调;此刻只有检查窗可能在屏,公开的 dismissUpdateInstallation() 与之
        // 净效果等价且幂等(delegate 为 nil,无会话级副作用)。
        super.dismissUpdateInstallation()
        presentUpdate(appcastItem, reply)
    }

    // MARK: - 下载/解压/安装进度(成套接管)

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard let progressSink else { return super.showDownloadInitiated(cancellation: cancellation) }
        UpdateLogger.log("下载开始(自绘进度)")
        progressSink(.downloadStarted(cancel: cancellation))
    }

    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard let progressSink else { return super.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
        progressSink(.downloadExpectedLength(expectedContentLength))
    }

    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard let progressSink else { return super.showDownloadDidReceiveData(ofLength: length) }
        progressSink(.downloadReceived(length))
    }

    override func showDownloadDidStartExtractingUpdate() {
        guard let progressSink else { return super.showDownloadDidStartExtractingUpdate() }
        UpdateLogger.log("下载完成,开始解压(自绘进度)")
        progressSink(.extractStarted)
    }

    override func showExtractionReceivedProgress(_ progress: Double) {
        guard let progressSink else { return super.showExtractionReceivedProgress(progress) }
        progressSink(.extractProgress(progress))
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let progressSink else { return super.showReady(toInstallAndRelaunch: reply) }
        UpdateLogger.log("更新就绪,等待用户确认安装并重启(自绘进度)")
        progressSink(.readyToRelaunch(reply: reply))
    }

    override func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        guard let progressSink else {
            return super.showInstallingUpdate(
                withApplicationTerminated: applicationTerminated,
                retryTerminatingApplication: retryTerminatingApplication
            )
        }
        UpdateLogger.log("正在安装更新(自绘进度, appTerminated=\(applicationTerminated))")
        progressSink(.installing)
    }

    override func dismissUpdateInstallation() {
        // 先关自绘进度 UI,再让 super 清理 Sparkle 侧窗口与回调状态(幂等)。
        progressSink?(.dismiss)
        super.dismissUpdateInstallation()
    }
}
