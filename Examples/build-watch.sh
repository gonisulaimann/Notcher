#!/bin/zsh
# build-watch.sh — wrap any command; the notch shows it while it runs.
# Usage: ./build-watch.sh "Building API" -- make -j8
# Needs: notcher CLI installed (./Scripts/install-cli.sh) + one-time consent.
set -euo pipefail
if [[ $# -lt 3 ]]; then
  echo "usage: build-watch.sh \"Title\" -- <command...>" >&2
  exit 2
fi
TITLE="$1"; shift
if [[ "${1:-}" != "--" ]]; then
  echo "usage: build-watch.sh \"Title\" -- <command...>" >&2
  exit 2
fi
shift
ID="build-$$"
notcher push "$TITLE" --subtitle "running…" --id "$ID" --ttl 10m --source "build-watch" || true
# set -e is off around the wrapped command so failures reach the pill below.
set +e
"$@"
STATUS=$?
set -e
if [[ $STATUS -eq 0 ]]; then
  notcher push "$TITLE" --subtitle "done ✓" --progress 1 --id "$ID" --ttl 20s --source "build-watch" || true
else
  notcher push "$TITLE" --subtitle "failed (exit $STATUS)" --id "$ID" --ttl 2m --source "build-watch" || true
fi
sleep 1
notcher clear --id "$ID" || true
exit $STATUS
