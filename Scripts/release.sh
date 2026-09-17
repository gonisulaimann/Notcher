#!/bin/zsh
# Notcher release pipeline — the ONE reproducible command:
#
#   ./Scripts/release.sh [--version X.Y.Z]
#
# Produces dist/Notcher-<ver>.dmg (+ .sha256) from a cleanroom build:
# universal (arm64+x86_64) release binary, staged .app, ad-hoc signature
# (no Developer ID exists in this environment — see docs/RECORD.md),
# bundle verification, and a DMG with an Applications symlink.
#
# What this does NOT do: notarize, staple, or Developer-ID sign. The DMG is
# suitable for this Mac and for side-loading; Gatekeeper behavior for ad-hoc
# builds is documented in dist/README-install.txt inside the DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VER="${1:-}"
if [[ "$VER" == "--version" ]]; then VER="${2:-}"; fi
if [[ -n "$VER" ]]; then
  # Single source of truth: an explicit version is written back, so the
  # VERSION file can never silently disagree with the last release.
  echo "$VER" > "$ROOT/VERSION"
else
  VER="$(cat VERSION)"
fi

DIST="$ROOT/dist"
STAGE="$(mktemp -d /tmp/notcher-stage.XXXXXX)"
APP="$STAGE/Notcher.app"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Notcher release $VER"
echo "==> Building universal release binary (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

BIN="$ROOT/.build/release/Notcher"
echo "==> Assembling cleanroom .app (outside the repo working copy)…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notcher"
chmod 755 "$APP/Contents/MacOS/Notcher"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/Notcher.icns" ]]; then
  cp "$ROOT/Resources/Notcher.icns" "$APP/Contents/Resources/Notcher.icns"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$APP/Contents/Info.plist"

echo "==> Verifying bundle…"
lipo -info "$APP/Contents/MacOS/Notcher"
test -x "$APP/Contents/MacOS/Notcher"
test -f "$APP/Contents/Resources/Notcher.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"

echo "==> Ad-hoc signing (no Developer ID in this environment)…"
/usr/bin/codesign --force --deep --options runtime --timestamp=none --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
echo "--- spctl assessment (informational; ad-hoc is NOT notarized) ---"
/usr/sbin/spctl -a -vv "$APP" || true

echo "==> Building DMG…"
mkdir -p "$DIST"
DMGROOT="$(mktemp -d /tmp/notcher-dmg.XXXXXX)"
cp -R "$APP" "$DMGROOT/Notcher.app"
ln -s /Applications "$DMGROOT/Applications"
cp "$ROOT/dist-support/README-install.txt" "$DMGROOT/Read Me — Installing Notcher.txt"
DMG="$DIST/Notcher-$VER.dmg"
rm -f "$DMG"
/usr/bin/hdiutil create -volname "Notcher $VER" -srcfolder "$DMGROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMGROOT"

echo "==> Checksumming…"
(cd "$DIST" && /usr/bin/shasum -a 256 "Notcher-$VER.dmg" > "Notcher-$VER.dmg.sha256")

echo "==> Verifying DMG mounts and contains the app…"
MNT="$(/usr/bin/hdiutil attach -nobrowse -readonly "$DMG" | grep Volumes | cut -f3-)"
test -d "$MNT/Notcher.app"
test -L "$MNT/Applications"
/usr/bin/hdiutil detach "$MNT" >/dev/null

echo "==> RELEASE OK: $DMG"
cat "$DIST/Notcher-$VER.dmg.sha256"
