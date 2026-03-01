import Foundation
import CoreGraphics
import AppKit

final class TextOutputService {

    /// Insert text at the current cursor position.
    /// Uses clipboard paste for Electron apps (CGEvent causes duplication in Chromium),
    /// and CGEvent keyboard simulation for native macOS apps.
    func insertText(_ text: String) {
        print("[VowKy][TextOutput] insertText() called with: \(text)")
        if isFrontmostElectron() {
            print("[VowKy][TextOutput] Electron app detected, using clipboard strategy")
            insertViaClipboard(text)
        } else {
            insertViaCGEvent(text)
        }
        print("[VowKy][TextOutput] Text inserted (\(text.utf16.count) chars)")
    }

    // MARK: - Private

    /// Detect if the frontmost app is an Electron app by checking for Electron Framework.
    private func isFrontmostElectron() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleURL = app.bundleURL else { return false }
        let electronFramework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: electronFramework.path)
    }

    /// Insert text via CGEvent keyboard simulation (works best for native macOS apps).
    private func insertViaCGEvent(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        let chunkSize = 20 // CGEvent supports ~20 UTF-16 code units per event

        for start in stride(from: 0, to: utf16.count, by: chunkSize) {
            let end = min(start + chunkSize, utf16.count)
            var chunk = Array(utf16[start..<end])

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    /// Insert text via clipboard paste (Cmd+V). Saves and restores original clipboard content.
    /// Used for Electron/Chromium apps where CGEvent Unicode simulation causes duplication.
    private func insertViaClipboard(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 'v' key
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Restore original clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let saved = saved {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }
}
