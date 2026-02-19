import Foundation
import CoreGraphics

final class TextOutputService {

    /// Insert text at the current cursor position via CGEvent keyboard simulation.
    /// Does NOT touch the clipboard.
    func insertText(_ text: String) {
        print("[VowKy][TextOutput] insertText() called with: \(text)")
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
        print("[VowKy][TextOutput] Text inserted (\(utf16.count) chars)")
    }
}
