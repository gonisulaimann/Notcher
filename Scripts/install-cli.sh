#!/bin/zsh
# Installs the `notcher` CLI (IslandKit command line) outside the app bundle.
# The app itself needs no CLI; this is a convenience for scripts.
#   ./Scripts/install-cli.sh [--prefix /usr/local]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="/usr/local"
if [[ "${1:-}" == "--prefix" && -n "${2:-}" ]]; then PREFIX="$2"; fi
cd "$ROOT"
swift build -c release --product notcher-cli
BIN="$ROOT/.build/release/notcher-cli"
if [[ ! -x "$PREFIX/bin" ]]; then
  echo "creating $PREFIX/bin (may ask for sudo)"
  sudo mkdir -p "$PREFIX/bin"
fi
if [[ -w "$PREFIX/bin" ]]; then
  cp "$BIN" "$PREFIX/bin/notcher"
else
  echo "installing to $PREFIX/bin (may ask for sudo)"
  sudo cp "$BIN" "$PREFIX/bin/notcher"
fi
echo "installed $(which notcher 2>/dev/null || echo "$PREFIX/bin/notcher")"
notcher 2>&1 | head -n 2 || true
