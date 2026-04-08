#!/usr/bin/env bash
set -euo pipefail

# Race to 50k using parallel dispatch within each token worker.
# Key insight: ~15 concurrent per token stays under secondary rate limit.

REPO="stefanpenner-cs/org-dispatch-test"
TARGET=50000
BURST=50
CONCURRENCY=15
DELAY=11
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKENS_FILE="${SCRIPT_DIR}/../credentials/tokens.txt"
COUNTER_FILE="/tmp/flood-50k-counter"
START_TIME=$(date +%s)

TOKENS=()
while IFS= read -r t; do
  [ -n "$t" ] && TOKENS+=("$t")
done < "$TOKENS_FILE"
TOKENS+=("$(gh auth token)")
NUM_TOKENS=${#TOKENS[@]}

echo "Using $NUM_TOKENS tokens, target=$TARGET"
echo "Burst=$BURST, concurrency=$CONCURRENCY/token, delay=${DELAY}s"
echo "Start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "0" > "$COUNTER_FILE"

dispatch_one() {
  curl -s -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    -X POST \
    -H "Authorization: Bearer $1" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d '{"event_type":"probe","client_payload":{"probe_id":"f-'"$2"'"}}' \
    "https://api.github.com/repos/${REPO}/dispatches"
}
export -f dispatch_one
export REPO

worker() {
  local TOKEN="$1"
  local WID="$2"
  local ACCEPTED=0
  local REJECTED=0
  local ROUND=0

  while true; do
    TOTAL=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    [ "$TOTAL" -ge "$TARGET" ] && break

    ROUND=$((ROUND + 1))

    # Generate args and run in parallel
    RESULTS=$(seq 1 "$BURST" | xargs -P "$CONCURRENCY" -I{} bash -c 'dispatch_one "'"$TOKEN"'" "'"$WID"'-'"$ROUND"'-{}"' 2>/dev/null)

    BATCH_OK=$(echo "$RESULTS" | grep -c "204" || true)
    BATCH_FAIL=$(echo "$RESULTS" | grep -c "403" || true)
    ACCEPTED=$((ACCEPTED + BATCH_OK))
    REJECTED=$((REJECTED + BATCH_FAIL))

    PREV=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    echo "$((PREV + BATCH_OK))" > "$COUNTER_FILE"

    ELAPSED=$(( $(date +%s) - START_TIME ))
    TOTAL=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    echo "[w$WID] r=$ROUND +$BATCH_OK/-$BATCH_FAIL total≈$TOTAL ${ELAPSED}s"

    # Adaptive delay
    if [ "$BATCH_FAIL" -gt "$((BURST / 2))" ]; then
      sleep $((DELAY * 3))
    elif [ "$BATCH_FAIL" -gt 0 ]; then
      sleep "$DELAY"
    else
      sleep 3
    fi
  done

  echo "[w$WID] DONE accepted=$ACCEPTED rejected=$REJECTED"
}

echo "Starting $NUM_TOKENS workers..."
echo ""

for i in "${!TOKENS[@]}"; do
  worker "${TOKENS[$i]}" "$i" &
  sleep 1
done

while true; do
  sleep 30
  TOTAL=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  ELAPSED=$(( $(date +%s) - START_TIME ))
  RATE=$((TOTAL * 60 / (ELAPSED + 1)))
  REMAIN=$(( (TARGET - TOTAL) * 60 / (RATE + 1) ))
  echo "=== ${ELAPSED}s: ≈$TOTAL dispatched, ≈${RATE}/min, ETA ≈${REMAIN}min ==="
  [ "$TOTAL" -ge "$TARGET" ] && break
done

wait

ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "=== DONE ==="
echo "Duration: ${ELAPSED}s ($((ELAPSED / 60))m $((ELAPSED % 60))s)"
echo "Approximate accepted: $(cat "$COUNTER_FILE")"

CHECK_TOKEN="${TOKENS[0]}"
QUEUED=$(curl -s -H "Authorization: Bearer $CHECK_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/runs?status=queued&per_page=1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count','?'))" 2>/dev/null)
echo "Verified queued runs: $QUEUED"
