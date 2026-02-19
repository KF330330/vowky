# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Generate Xcode project (must run after changing project.yml)
xcodegen generate

# Build
xcodebuild -project VowKy.xcodeproj -scheme VowKy -configuration Debug build

# Run all tests (99 tests)
xcodebuild test -project VowKy.xcodeproj -scheme VowKy -configuration Debug

# Run a single test class
xcodebuild test -project VowKy.xcodeproj -scheme VowKy -only-testing:VowKyTests/AppStateTests

# Run a single test method
xcodebuild test -project VowKy.xcodeproj -scheme VowKy -only-testing:VowKyTests/AppStateTests/test26_initialState_isIdle

# Launch built app
open ~/Library/Developer/Xcode/DerivedData/VowKy-*/Build/Products/Debug/VowKy.app
```

Always run `xcodegen generate` before building if `project.yml` was modified.

## What This App Does

VowKy is a macOS menu bar app for global voice input. User presses Option+Space (configurable), speaks, presses again to stop — recognized text is inserted at the cursor position in any app via CGEvent keyboard simulation (no clipboard).

## Architecture

**State machine** (`AppState.swift`, `@MainActor`): Single source of truth.
```
idle → recording → recognizing → idle (text inserted)
         ↓ (Escape)
        idle (cancelled, backup deleted)
```

**Protocol-based DI**: All services conform to protocols in `Services/Protocols.swift`. Production types are injected in `VowKyApp.swift`; tests use mocks from `VowKyTests/Mocks/TestMocks.swift`.

**Key services**:
- `AudioRecorder` — AVAudioEngine, 16kHz mono Float32 samples
- `LocalSpeechRecognizer` — Sherpa-ONNX Paraformer model (offline)
- `PunctuationService` — Sherpa-ONNX CT-Transformer model
- `HotkeyManager` — CGEvent tap for global hotkey; `HotkeyEvaluator` is a pure function for testability
- `TextOutputService` — `CGEventKeyboardSetUnicodeString` for text insertion
- `AudioBackupService` — WAV file backup during recording for crash recovery
- `HistoryStore` — SQLite3 C API, stores all recognition results in `~/Library/Application Support/VowKy/history.db`

**UI**: SwiftUI `MenuBarExtra(.window)` style. `SettingsWindowController` and `HistoryWindowController` use singleton + NSWindow + NSHostingController pattern.

## Critical Gotchas

- **Info.plist must have CFBundleIdentifier**: Without it, `Bundle.main.bundleIdentifier` returns nil and macOS TCC never grants accessibility permissions (`AXIsProcessTrusted()` always false).
- **SherpaOnnx fatalError**: `SherpaOnnxOfflineRecognizer(config:)` calls `fatalError` if model files don't exist. Always check `FileManager.default.fileExists(atPath:)` before creating recognizer.
- **@StateObject in SwiftUI App struct**: Never capture `self` (the App struct) in closures — it copies the struct, creating a second instance with a different `@StateObject`. Use `.task {}` on views instead.
- **MenuBarExtra label vs content**: `.task {}` on the label Image runs at app launch; `.task {}` on content only runs when the menu is opened.
- **HotkeyConfig UserDefaults**: Hotkey settings stored in UserDefaults. If hotkey stops working, check `defaults read com.vowky.app` for corrupted values.

## Test Organization

Tests are in `VowKyTests/` organized by layer:
- `Unit/` — Individual service tests (recognizer, audio, backup, punctuation, hotkey logic)
- `StateMachine/` — AppState transition tests
- `HotkeyLogic/` — Pure HotkeyEvaluator tests
- `System/` — CGEvent tap, simulation, audio capture (may require accessibility permissions)
- `Integration/` — Full pipeline, callback chain, thread safety

Mocks: `VowKyTests/Mocks/TestMocks.swift` has `MockSpeechRecognizer`, `MockAudioRecorder`, `MockPermissionChecker`, `MockPunctuationService`, `MockAudioBackupService`.

## Project Configuration

- **Build tool**: XcodeGen (`project.yml`)
- **Bundle ID**: `com.vowky.app`
- **Deployment target**: macOS 13.0
- **Signing**: Apple Development, Team REDACTED_TEAM_ID
- **Native libs**: `Libraries/sherpa-onnx.xcframework` + `Libraries/libonnxruntime.a` (linked via `-lonnxruntime -lc++`)
- **Bridging header**: `VowKy/SherpaOnnx/SherpaOnnx-Bridging-Header.h`
- **LSUIElement**: true (menu bar only, no Dock icon)
