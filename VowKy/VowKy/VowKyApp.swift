import SwiftUI
import Sparkle

@main
struct VowKyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let updaterController: SPUStandardUpdaterController

    @StateObject private var appState = AppState(
        speechRecognizer: LocalSpeechRecognizer(),
        audioRecorder: AudioRecorder(),
        permissionChecker: RealPermissionChecker(),
        punctuationService: PunctuationService(),
        backupService: AudioBackupService()
    )

    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, updater: updaterController.updater)
        } label: {
            Image(systemName: menuBarIconName)
                .task {
                    let needsOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
                    if appState.hotkeyManager == nil {
                        // 新手引导期间跳过热键创建，避免弹出系统辅助功能对话框
                        appState.setup(skipHotkey: needsOnboarding)
                    }
                    if needsOnboarding {
                        checkOnboarding()
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

    private var menuBarIconName: String {
        switch appState.state {
        case .recording:
            return "mic.fill"
        default:
            return "mic"
        }
    }
}

// MARK: - Real PermissionChecker

struct RealPermissionChecker: PermissionCheckerProtocol {
    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }
}
