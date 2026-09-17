#!/bin/zsh
# Build Notcher.app without Xcode (Command Line Tools only).
set -euo pipefail
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
if [[ -f "$ROOT/Resources/Notcher.icns" ]]; then
  cp "$ROOT/Resources/Notcher.icns" "$APP/Contents/Resources/Notcher.icns"
fi
/usr/bin/codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> Built: $APP"
