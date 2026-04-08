#!/usr/bin/env bash
set -euo pipefail

# Flood matrix dispatches and monitor queued run/job counts.
# Usage: ./scripts/matrix-flood.sh [count] [batch_size]
#   count: total dispatches to send (default: 250)
#   batch_size: dispatches per burst (default: 10)

REPO="stefanpenner-cs/dispatch-matrix-test"
COUNT="${1:-250}"
BATCH="${2:-10}"
JOBS_PER_RUN=256

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKENS_FILE="${SCRIPT_DIR}/../credentials/tokens.txt"

# Load tokens (app tokens only — PAT may be rate limited)
TOKENS=()
while IFS= read -r t; do
  [ -n "$t" ] && TOKENS+=("$t")
done < "$TOKENS_FILE"
NUM_TOKENS=${#TOKENS[@]}

echo "Flooding $COUNT dispatches in batches of $BATCH"
echo "Each dispatch creates 1 run with $JOBS_PER_RUN jobs"
echo "Using $NUM_TOKENS tokens"
echo ""

SENT=0
ACCEPTED=0
REJECTED=0
TOKEN_IDX=0

while [ "$SENT" -lt "$COUNT" ]; do
  # Send a batch
  BATCH_ACCEPTED=0
  BATCH_REJECTED=0

  for i in $(seq 1 "$BATCH"); do
    [ "$SENT" -ge "$COUNT" ] && break

    TOKEN="${TOKENS[$((TOKEN_IDX % NUM_TOKENS))]}"
    TOKEN_IDX=$((TOKEN_IDX + 1))

    STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "{\"event_type\":\"matrix-probe\",\"client_payload\":{\"batch\":$((SENT / BATCH)),\"index\":$i}}" \
      "https://api.github.com/repos/${REPO}/dispatches")

    SENT=$((SENT + 1))

    if [ "$STATUS" = "204" ]; then
      BATCH_ACCEPTED=$((BATCH_ACCEPTED + 1))
      ACCEPTED=$((ACCEPTED + 1))
    else
      BATCH_REJECTED=$((BATCH_REJECTED + 1))
      REJECTED=$((REJECTED + 1))
      if [ "$STATUS" = "403" ]; then
        echo "  [rate limited at dispatch $SENT, sleeping 15s]"
        sleep 15
      fi
    fi
  done

  # Check queued count (use a different token to avoid wasting rate limit)
  CHECK_TOKEN="${TOKENS[$(( (TOKEN_IDX + 5) % NUM_TOKENS ))]}"
  QUEUED_RUNS=$(curl -s \
    -H "Authorization: Bearer ${CHECK_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/runs?status=queued&per_page=1" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count','?'))" 2>/dev/null)

  IMPLIED_JOBS=$((QUEUED_RUNS * JOBS_PER_RUN))

  echo "sent=$SENT accepted=$ACCEPTED rejected=$REJECTED | queued_runs=$QUEUED_RUNS implied_jobs=$IMPLIED_JOBS"

  # If we see silent drops (accepted but queued didn't increase), flag it
  if [ "$QUEUED_RUNS" != "?" ] && [ "$ACCEPTED" -gt "$QUEUED_RUNS" ]; then
    DROPS=$((ACCEPTED - QUEUED_RUNS))
    echo "*** SILENT DROPS DETECTED: $DROPS dispatches accepted but not queued ***"
    echo "*** Queue limit likely hit at $QUEUED_RUNS runs ($IMPLIED_JOBS jobs) ***"
  fi

  sleep 2
done

echo ""
echo "=== FINAL ==="
echo "Sent: $SENT"
echo "Accepted (204): $ACCEPTED"
echo "Rejected: $REJECTED"
echo "Queued runs: $QUEUED_RUNS"
echo "Implied jobs: $IMPLIED_JOBS"
