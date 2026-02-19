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
                    if appState.hotkeyManager == nil {
                        appState.setup()
                    }
                }
        }
        .menuBarExtraStyle(.window)
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
