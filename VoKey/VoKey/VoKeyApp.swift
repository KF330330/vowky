import SwiftUI

@main
struct VowKyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var appState = AppState(
        speechRecognizer: LocalSpeechRecognizer(),
        audioRecorder: AudioRecorder(),
        permissionChecker: RealPermissionChecker(),
        punctuationService: PunctuationService(),
        backupService: AudioBackupService()
    )

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
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
