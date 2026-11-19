# Contributing to Nyeko

Thanks for wanting to help Nyo! Issues and pull requests are welcome.

## Getting started

- **Mac**: `brew install xcodegen`, then `./scripts/nyeko-install.sh` (or `cd NotchBuddy && xcodegen` and open the
  project). Swift 6, SwiftUI + AppKit, no third-party dependencies.
- **Windows / Linux**: `cd windows && npm install && npm run tauri dev`; tests with `npm test` and `cargo test`.
- **Android**: `cd android && ./gradlew test assembleDebug`.
- **Web app**: plain files in `phone/web/`.

## Ground rules

- Never block Claude Code: if the app doesn't answer, the hook exits at once.
- Secrets live in the Keychain (or the platform's own store), never on disk or in git. No telemetry.
- Nyo is drawn in code from one design (`CoucouKit/NyoPainter.swift`, `windows/src/mochi/nyo.ts`,
  `android/.../nyeko/NyoFace.kt`, `scripts/nyeko-icons.py`): change one, change all.
- Every user-visible string is translated (`scripts/test-localization.py`, `android/scripts/gen-strings.mjs --check`).

By contributing, you agree that your code is released under the MIT License. Nyo, the Nyeko name, icons and sounds stay
Nyeko's own (`LICENSE-ASSETS.md`).
