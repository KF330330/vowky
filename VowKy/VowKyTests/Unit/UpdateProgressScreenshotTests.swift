import XCTest
import AppKit
@testable import VowKy

/// 更新进度视图截图钩子:驱动假进度事件,把四个阶段(下载/解压/安装/就绪)的窗口内容
/// 渲染成 PNG,供改 UI 后人工目检。默认跳过;设置环境变量后启用:
///   xcodebuild test ... -only-testing:VowKyTests/UpdateProgressScreenshotTests \
///     TEST_RUNNER_VOWKY_SCREENSHOT_DIR=/path/to/output
@MainActor
final class UpdateProgressScreenshotTests: XCTestCase {

    func testCaptureProgressPhases() throws {
        guard let dir = ProcessInfo.processInfo.environment["VOWKY_SCREENSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("未设置 VOWKY_SCREENSHOT_DIR,跳过截图(仅供 UI 目检使用)")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let controller = UpdateAvailableWindowController.shared

        controller.handleProgressEvent(.downloadStarted(cancel: {}))
        controller.handleProgressEvent(.downloadExpectedLength(239_287_632))
        controller.handleProgressEvent(.downloadReceived(83_442_100))
        try capture(named: "progress_1_downloading", in: dir)

        controller.handleProgressEvent(.extractStarted)
        controller.handleProgressEvent(.extractProgress(0.62))
        try capture(named: "progress_2_extracting", in: dir)

        controller.handleProgressEvent(.readyToRelaunch(reply: { _ in }))
        try capture(named: "progress_3_ready", in: dir)

        controller.handleProgressEvent(.installing(retryTerminate: nil))
        try capture(named: "progress_4_installing", in: dir)

        controller.handleProgressEvent(.dismiss)
    }

    private func capture(named name: String, in dir: String) throws {
        // 给 SwiftUI 一个 runloop 周期完成布局/渲染
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let window = try XCTUnwrap(
            NSApp.windows.first { $0.isVisible && $0.title == L("window.update.title") },
            "找不到更新窗口"
        )
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
