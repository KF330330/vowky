# Path Audit: VoKey in File/Directory Names

> Generated: 2026-02-19
> Scope: `/Users/rl/Nutstore_Files/my_nutstore/520-program/vowky`
> Search patterns: VoKey, vokey, VOKEY, Vokey (all case variants)

## Summary

| Type | Count |
|------|-------|
| Directories | 4 |
| Files | 3 |
| **Total** | **7** |

Only `VoKey` (exact casing) was found. No matches for `vokey`, `VOKEY`, `Vokey` or other variants.

---

## Directories (4)

| # | Path (relative to project root) | Notes |
|---|--------------------------------|-------|
| D1 | `VoKey/` | Top-level Xcode project wrapper directory |
| D2 | `VoKey/VoKey/` | Main app source directory (inside Xcode project) |
| D3 | `VoKey/VoKey.xcodeproj/` | Xcode project bundle |
| D4 | `VoKey/VoKeyTests/` | Test target directory |

## Files (3)

| # | Path (relative to project root) | Notes |
|---|--------------------------------|-------|
| F1 | `PRD_VoKey_V1.0.md` | Product requirements doc v1.0 |
| F2 | `PRD_VoKey_V1.1.md` | Product requirements doc v1.1 |
| F3 | `VoKey/VoKey/VoKeyApp.swift` | SwiftUI App entry point file |

---

## Xcode Project Internal Files

The `.xcodeproj` bundle itself is named `VoKey.xcodeproj` (D3). Its internal contents do **not** have "VoKey" in their own filenames:

- `VoKey/VoKey.xcodeproj/project.pbxproj` -- standard name, no VoKey
- `VoKey/VoKey.xcodeproj/project.xcworkspace/contents.xcworkspacedata` -- standard name
- `VoKey/VoKey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/` -- standard
- `VoKey/VoKey.xcodeproj/xcshareddata/` -- standard

No `.xcscheme` files with "VoKey" in filename were found (schemes may be auto-generated or not yet committed).

---

## Rename Impact Notes

- **D1-D4**: Renaming directories will break all import paths, Xcode project references, and the `project.pbxproj` internal references. Must be coordinated with content-level rename.
- **D3** (`VoKey.xcodeproj`): Renaming the `.xcodeproj` bundle requires updating `project.yml` (XcodeGen config) and any CI/script references.
- **F3** (`VoKeyApp.swift`): Contains the `@main` struct. Renaming the file requires updating `project.pbxproj` file references.
- **F1, F2**: Documentation files, safe to rename independently.
