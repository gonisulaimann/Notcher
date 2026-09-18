#!/bin/zsh
# Build Notcher.app. Prefers the Xcode toolchain when present (required
# since the codebase uses SwiftUI macros unavailable under CLT alone);
# falls back to Command Line Tools otherwise.
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "==> Using Xcode toolchain ($DEVELOPER_DIR)"
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building (release)…"
swift build -c release

BIN="$ROOT/.build/release/Notcher"
APP="$ROOT/Notcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Notcher"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Single source of truth: the bundle version ALWAYS comes from the VERSION
# file, so a dev bundle can never report a stale version (observed: repo app
# said 0.1.0 while the DMG said 0.5.0).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(cat "$ROOT/VERSION")" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(cat "$ROOT/VERSION")" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/Notcher.icns" ]]; then
  cp "$ROOT/Resources/Notcher.icns" "$APP/Contents/Resources/Notcher.icns"
fi
/usr/bin/codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> Built: $APP"
