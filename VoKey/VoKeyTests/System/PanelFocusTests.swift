import XCTest
import AppKit
@testable import VowKy

// MARK: - T4: Panel Focus Tests (#61-64)

@MainActor
final class PanelFocusTests: XCTestCase {

    var appState: AppState!
    var recordingPanel: RecordingPanel!

    @MainActor
    override func setUp() {
        super.setUp()
        let mockRecognizer = MockSpeechRecognizer()
        let mockRecorder = MockAudioRecorder()
        let mockPermission = MockPermissionChecker()
        appState = AppState(
            speechRecognizer: mockRecognizer,
            audioRecorder: mockRecorder,
            permissionChecker: mockPermission
        )
        recordingPanel = RecordingPanel(appState: appState)
    }

    @MainActor
    override func tearDown() {
        recordingPanel?.hide()
        recordingPanel = nil
        appState = nil
        super.tearDown()
    }

    // MARK: - #61: Panel 显示不改变 keyWindow

    func test61_panelShow_keyWindowUnchanged() {
        let previousKeyWindow = NSApp.keyWindow

        recordingPanel.show()

        // Panel should not become key window
        let currentKeyWindow = NSApp.keyWindow
        XCTAssertEqual(currentKeyWindow, previousKeyWindow,
                       "Key window should not change when recording panel shows")

        recordingPanel.hide()
    }

    // MARK: - #62: Panel 显示不改变 mainWindow

    func test62_panelShow_mainWindowUnchanged() {
        let previousMainWindow = NSApp.mainWindow

        recordingPanel.show()

        let currentMainWindow = NSApp.mainWindow
        XCTAssertEqual(currentMainWindow, previousMainWindow,
                       "Main window should not change when recording panel shows")

        recordingPanel.hide()
    }

    // MARK: - #63: Panel 为 floating 级别

    func test63_panel_floatingLevel() {
        recordingPanel.show()

        // Find the panel in app windows
        let panel = NSApp.windows.compactMap { $0 as? NSPanel }.first { $0.level == .floating }
        XCTAssertNotNil(panel, "Should have a floating-level panel")

        recordingPanel.hide()
    }

    // MARK: - #64: Panel 为 nonactivatingPanel

    func test64_panel_nonactivatingStyle() {
        recordingPanel.show()

        let panel = NSApp.windows.compactMap { $0 as? NSPanel }.first { $0.level == .floating }
        XCTAssertNotNil(panel, "Should find the floating panel")

        if let panel = panel {
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel),
                          "Panel should have nonactivatingPanel style")
        }

        recordingPanel.hide()
    }
}
