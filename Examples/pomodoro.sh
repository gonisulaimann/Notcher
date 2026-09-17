#!/bin/zsh
# pomodoro.sh — 25/5 focus loop on the waterline. Ctrl-C to stop.
# The pill counts down via periodic re-push (TTL 90 s each so a killed loop
# recedes by itself — no orphaned activities, by protocol design).
set -euo pipefail
FOCUS_MIN="${1:-25}"
SRC="pomodoro"
ID="pomo-$$"
loop() {
  local total=$1 label="$2"
  local end=$(( $(date +%s) + total * 60 ))
  while true; do
    local left=$(( end - $(date +%s) ))
    [[ $left -le 0 ]] && break
    local mm=$(( left / 60 )) ss=$(( left % 60 ))
    local done=$(( total * 60 - left )) prog=$(echo "scale=3; $done / ($total * 60)" | bc)
    notcher push "$label" --subtitle "$(printf '%02d:%02d left' $mm $ss)" --progress "$prog" --id "$ID" --ttl 90s --source "$SRC" || true
    sleep 30
  done
}
trap 'notcher clear --id "$ID" 2>/dev/null || true; exit 0' INT TERM
while true; do
  loop "$FOCUS_MIN" "Focus"
  notcher push "Break" --subtitle "5 minutes" --id "$ID" --ttl 6m --source "$SRC" || true
  sleep 300
done
