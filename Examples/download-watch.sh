#!/bin/zsh
# download-watch.sh — curl with a live notch meter.
# Usage: ./download-watch.sh <url> <output>
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: download-watch.sh <url> <output>" >&2; exit 2; }
URL="$1"; OUT="$2"
ID="dl-$$"
SRC="download-watch"
notcher push "Downloading" --subtitle "$(basename "$OUT")" --progress 0 --id "$ID" --ttl 30m --source "$SRC" || true
# Poll the growing file; curl writes it in place.
curl -sL -o "$OUT" "$URL" &
CURLPID=$!
while kill -0 $CURLPID 2>/dev/null; do
  SIZE=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
  # Progress needs a total; without Content-Length we pulse by size known.
  notcher push "Downloading" --subtitle "$(basename "$OUT") · $((SIZE/1024)) KB" --id "$ID" --ttl 60s --source "$SRC" || true
  sleep 2
done
STATUS=0
wait $CURLPID || STATUS=$?
notcher push "Download" --subtitle "$(basename "$OUT") · done" --progress 1 --id "$ID" --ttl 20s --source "$SRC" || true
sleep 1
notcher clear --id "$ID" || true
exit $STATUS
