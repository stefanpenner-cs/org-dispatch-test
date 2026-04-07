#!/usr/bin/env bash
set -euo pipefail

# Sustained dispatch flood for reaching 50k queued runs.
# Paces itself to stay under both secondary (~180/burst) and primary (5000/hr) rate limits.
#
# Usage: ./scripts/flood-sustained.sh [target] [batch_size] [batch_delay]
#   target:      total queued runs to aim for (default: 50500)
#   batch_size:  dispatches per batch (default: 150, stay under ~180 secondary limit)
#   batch_delay: seconds between batches (default: 12)

REPO="stefanpenner-cs/org-dispatch-test"
TARGET="${1:-50500}"
BATCH_SIZE="${2:-150}"
BATCH_DELAY="${3:-12}"

RUN_ID="sustained-$(date +%s)"
RESULTS_DIR="results/${RUN_ID}"
mkdir -p "$RESULTS_DIR"

GH_TOKEN=$(gh auth token)

cat > "${RESULTS_DIR}/meta.txt" <<EOF
start_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
target=${TARGET}
batch_size=${BATCH_SIZE}
batch_delay=${BATCH_DELAY}
EOF

echo "Sustained flood targeting ${TARGET} queued runs"
echo "Batch size: ${BATCH_SIZE}, delay: ${BATCH_DELAY}s between batches"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}/"
echo ""

TOTAL_SENT=0
TOTAL_OK=0
TOTAL_FAIL=0
BATCH_NUM=0
CONSECUTIVE_FAILURES=0

dispatch_batch() {
  local BATCH_OK=0
  local BATCH_FAIL=0

  for i in $(seq 1 "$BATCH_SIZE"); do
    local SEQ=$((TOTAL_SENT + i))
    local PROBE_ID="${RUN_ID}-${SEQ}"

    local HTTP_STATUS
    HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -d "{\"event_type\":\"probe\",\"client_payload\":{\"probe_id\":\"${PROBE_ID}\",\"sleep_seconds\":\"0\"}}" \
      "https://api.github.com/repos/${REPO}/dispatches") || HTTP_STATUS="error"

    local TIMESTAMP
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

    if [ "$HTTP_STATUS" = "204" ]; then
      BATCH_OK=$((BATCH_OK + 1))
      echo "${TIMESTAMP} ${PROBE_ID} ok" >> "${RESULTS_DIR}/dispatches.log"
    else
      BATCH_FAIL=$((BATCH_FAIL + 1))
      echo "${TIMESTAMP} ${PROBE_ID} fail:${HTTP_STATUS}" >> "${RESULTS_DIR}/dispatches.log"

      # If we get a 403, stop this batch early — we've hit the secondary limit
      if [ "$HTTP_STATUS" = "403" ]; then
        TOTAL_SENT=$((TOTAL_SENT + i))
        TOTAL_OK=$((TOTAL_OK + BATCH_OK))
        TOTAL_FAIL=$((TOTAL_FAIL + BATCH_FAIL))
        return 1
      fi
    fi
  done

  TOTAL_SENT=$((TOTAL_SENT + BATCH_SIZE))
  TOTAL_OK=$((TOTAL_OK + BATCH_OK))
  TOTAL_FAIL=$((TOTAL_FAIL + BATCH_FAIL))
  return 0
}

check_rate_limit() {
  local REMAINING
  REMAINING=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/rate_limit" | jq -r '.rate.remaining') || REMAINING=0

  if [ "$REMAINING" -lt 200 ]; then
    local RESET
    RESET=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
      "https://api.github.com/rate_limit" | jq -r '.rate.reset')
    local NOW
    NOW=$(date +%s)
    local WAIT=$((RESET - NOW + 5))
    if [ "$WAIT" -gt 0 ]; then
      echo "  ⏸  Primary rate limit low (${REMAINING} remaining). Waiting ${WAIT}s for reset..."
      sleep "$WAIT"
    fi
  fi
}

check_queued_count() {
  curl -s -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/runs?per_page=1&status=queued" | jq -r '.total_count' 2>/dev/null || echo "?"
}

while true; do
  BATCH_NUM=$((BATCH_NUM + 1))

  # Check primary rate limit every 10 batches
  if [ $((BATCH_NUM % 10)) -eq 0 ]; then
    check_rate_limit
  fi

  # Check queued count every 25 batches
  if [ $((BATCH_NUM % 25)) -eq 0 ]; then
    QUEUED=$(check_queued_count)
    echo "  📊 Queued runs on GitHub: ${QUEUED}"

    if [ "$QUEUED" != "?" ] && [ "$QUEUED" -ge "$TARGET" ]; then
      echo ""
      echo "🎯 Target reached! ${QUEUED} queued runs >= ${TARGET} target"
      break
    fi
  fi

  # Send batch
  if dispatch_batch; then
    CONSECUTIVE_FAILURES=0
    printf "  batch %d: sent=%d ok=%d fail=%d | total_ok=%d total_fail=%d\n" \
      "$BATCH_NUM" "$BATCH_SIZE" "$((TOTAL_OK - ${PREV_OK:-0}))" "$((TOTAL_FAIL - ${PREV_FAIL:-0}))" "$TOTAL_OK" "$TOTAL_FAIL"
  else
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    printf "  batch %d: HIT SECONDARY LIMIT | total_ok=%d total_fail=%d (consecutive: %d)\n" \
      "$BATCH_NUM" "$TOTAL_OK" "$TOTAL_FAIL" "$CONSECUTIVE_FAILURES"

    # Back off: longer wait after hitting the limit
    local BACKOFF=$((BATCH_DELAY * 2))
    if [ "$CONSECUTIVE_FAILURES" -ge 3 ]; then
      BACKOFF=60
    fi
    echo "  backing off ${BACKOFF}s..."
    sleep "$BACKOFF"
    continue
  fi

  PREV_OK=$TOTAL_OK
  PREV_FAIL=$TOTAL_FAIL

  sleep "$BATCH_DELAY"
done

echo "end_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >> "${RESULTS_DIR}/meta.txt"
echo "total_sent=${TOTAL_SENT}" >> "${RESULTS_DIR}/meta.txt"
echo "total_ok=${TOTAL_OK}" >> "${RESULTS_DIR}/meta.txt"
echo "total_fail=${TOTAL_FAIL}" >> "${RESULTS_DIR}/meta.txt"

echo ""
echo "=== Final Summary ==="
echo "Batches:        ${BATCH_NUM}"
echo "Total sent:     ${TOTAL_SENT}"
echo "Total accepted: ${TOTAL_OK}"
echo "Total rejected: ${TOTAL_FAIL}"
echo "Queued on GH:   $(check_queued_count)"
echo "Log: ${RESULTS_DIR}/dispatches.log"
