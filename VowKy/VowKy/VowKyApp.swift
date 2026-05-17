import SwiftUI
import Sparkle

@main
struct VowKyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    static let automaticUpdateChecksDefaultsKey = "automaticUpdateChecksEnabled"

    private let updateCoordinator = UpdateReminderCoordinator()
    private let updaterController: SPUStandardUpdaterController

    @StateObject private var appState = AppState(
        speechRecognizer: LocalSpeechRecognizer(),
        audioRecorder: AudioRecorder(),
        permissionChecker: RealPermissionChecker(),
        punctuationService: PunctuationService(),
        backupService: AudioBackupService()
    )

    init() {
        let coordinator = updateCoordinator
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: coordinator,
            userDriverDelegate: nil
        )

        // 默认开启自动检查；用户在 Settings 关闭后从 UserDefaults 读取
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.automaticUpdateChecksDefaultsKey) == nil {
            defaults.set(true, forKey: Self.automaticUpdateChecksDefaultsKey)
        }
        let autoEnabled = defaults.bool(forKey: Self.automaticUpdateChecksDefaultsKey)

        updaterController.updater.automaticallyChecksForUpdates = autoEnabled
        updaterController.updater.updateCheckInterval = 86400 // 每天检查一次
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                appState: appState,
                updater: updaterController.updater,
                updateCoordinator: updateCoordinator
            )
        } label: {
            Image(nsImage: Self.butterflyTemplateImage)
                .opacity(menuBarIconActive ? 1.0 : 0.85)
                .task {
                    let needsOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
                    if appState.hotkeyManager == nil {
                        // 新手引导期间跳过热键创建，避免弹出系统辅助功能对话框
                        appState.setup(skipHotkey: needsOnboarding)
                    }
                    if needsOnboarding {
                        checkOnboarding()
                    } else {
                        // 仅在已完成 onboarding 的用户上触发新版功能弹窗，避免新用户被两个窗口同时打扰
                        WhatsNewWindowController.presentIfNeeded()
                    }
                    AnalyticsService.shared.trackInstall()
                    AnalyticsService.shared.trackDAU()
                }
        }
        .menuBarExtraStyle(.window)
    }

    private func checkOnboarding() {
        let hasCompleted = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        guard !hasCompleted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            OnboardingWindowController.shared.showWindow(appState: appState)
        }
    }

    private static let butterflyTemplateImage: NSImage = {
        let img = NSImage(named: "ButterflyTemplate") ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: 22, height: 22)
        return img
    }()

    private var menuBarIconActive: Bool {
        if appState.isRecordingTranscriptionInProgress {
            return true
        }
        switch appState.state {
        case .recording:
            return true
        default:
            return false
        }
    }
}

// MARK: - Real PermissionChecker

struct RealPermissionChecker: PermissionCheckerProtocol {
    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }
}
