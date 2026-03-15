#!/usr/bin/env bash
# Stream Cloud Run + iOS Simulator logs side-by-side in one terminal.
# Usage: ./logs.sh [filter]   (optional grep filter, e.g. "voice\|audio\|log_meal")

FILTER="${1:-}"
PROJECT="rena-490107"
SERVICE="rena-agent"
REGION="us-central1"

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

# ── Cloud Run ──────────────────────────────────────────────────────────────────
cloud_logs() {
  gcloud beta logging tail \
    "resource.type=cloud_run_revision AND resource.labels.service_name=${SERVICE}" \
    --project="${PROJECT}" \
    --format="value(timestamp,textPayload)" \
    2>/dev/null \
  | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ -n "$FILTER" ]] && ! echo "$line" | grep -qiE "$FILTER"; then continue; fi
      echo -e "${CYAN}[SERVER]${RESET} $line"
    done
}

# ── iOS Simulator ──────────────────────────────────────────────────────────────
ios_logs() {
  BOOTED=$(xcrun simctl list devices 2>/dev/null | grep Booted | head -1 | grep -oE '[A-F0-9-]{36}')
  if [[ -z "$BOOTED" ]]; then
    echo -e "${RED}[IOS]${RESET} No booted simulator found."
    return
  fi
  xcrun simctl spawn "$BOOTED" log stream \
    --predicate 'processImagePath CONTAINS "Rena"' \
    --style compact \
    2>/dev/null \
  | while IFS= read -r line; do
      [[ "$line" == Filtering* ]] && continue
      [[ -z "$line" ]] && continue
      if [[ -n "$FILTER" ]] && ! echo "$line" | grep -qiE "$FILTER"; then continue; fi
      # Highlight errors in red
      if echo "$line" | grep -qiE "error|failed|crash"; then
        echo -e "${RED}[IOS]${RESET} $line"
      else
        echo -e "${YELLOW}[IOS]${RESET} $line"
      fi
    done
}

echo "=== Rena logs — Cloud Run (cyan) + iOS simulator (yellow) ==="
[[ -n "$FILTER" ]] && echo "=== Filter: $FILTER ==="
echo "Press Ctrl-C to stop."
echo ""

cloud_logs &
CLOUD_PID=$!

ios_logs &
IOS_PID=$!

trap "kill $CLOUD_PID $IOS_PID 2>/dev/null; exit 0" INT TERM
wait
