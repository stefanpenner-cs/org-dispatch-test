#!/usr/bin/env bash
set -euo pipefail

# Sustained dispatch flood for reaching 50k queued runs.
# Sends batches in parallel (like flood-parallel.sh) with pacing between batches
# to stay under both secondary (~180/burst) and primary (5000/hr) rate limits.
#
# Usage: ./scripts/flood-sustained.sh [target] [batch_size] [batch_delay]
#   target:      total accepted dispatches to aim for (default: 50500)
#   batch_size:  dispatches per batch (default: 150, stay under ~180 secondary limit)
#   batch_delay: seconds between batches (default: 15)

REPO="stefanpenner-cs/org-dispatch-test"
TARGET="${1:-50500}"
BATCH_SIZE="${2:-150}"
BATCH_DELAY="${3:-15}"
PARALLELISM=50

RUN_ID="sustained-$(date +%s)"
RESULTS_DIR="results/${RUN_ID}"
mkdir -p "$RESULTS_DIR"

GH_TOKEN=$(gh auth token)
export GH_TOKEN REPO RESULTS_DIR RUN_ID

cat > "${RESULTS_DIR}/meta.txt" <<EOF
start_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
target=${TARGET}
batch_size=${BATCH_SIZE}
batch_delay=${BATCH_DELAY}
parallelism=${PARALLELISM}
EOF

echo "Sustained flood targeting ${TARGET} accepted dispatches"
echo "Batch size: ${BATCH_SIZE}, parallelism: ${PARALLELISM}, delay: ${BATCH_DELAY}s between batches"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}/"
echo ""

# Single dispatch function, called by xargs
dispatch_one() {
  local PROBE_ID="$1"
  local TIMESTAMP
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

  local HTTP_STATUS
  HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"event_type\":\"probe\",\"client_payload\":{\"probe_id\":\"${PROBE_ID}\",\"sleep_seconds\":\"0\"}}" \
    "https://api.github.com/repos/${REPO}/dispatches") || HTTP_STATUS="error"

  if [ "$HTTP_STATUS" = "204" ]; then
    echo "${TIMESTAMP} ${PROBE_ID} ok" >> "${RESULTS_DIR}/dispatches.log"
  else
    echo "${TIMESTAMP} ${PROBE_ID} fail:${HTTP_STATUS}" >> "${RESULTS_DIR}/dispatches.log"
  fi
}
export -f dispatch_one

check_rate_limit() {
  local REMAINING
  REMAINING=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/rate_limit" | jq -r '.rate.remaining') || REMAINING=0
  echo "$REMAINING"
}

check_queued_count() {
  curl -s -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/runs?per_page=1&status=queued" | jq -r '.total_count' 2>/dev/null || echo "?"
}

TOTAL_OK=0
TOTAL_FAIL=0
BATCH_NUM=0
BATCH_START_SEQ=1

while [ "$TOTAL_OK" -lt "$TARGET" ]; do
  BATCH_NUM=$((BATCH_NUM + 1))

  # Check primary rate limit every 10 batches
  if [ $((BATCH_NUM % 10)) -eq 0 ]; then
    REMAINING=$(check_rate_limit)
    if [ "$REMAINING" -lt 200 ]; then
      RESET=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
        "https://api.github.com/rate_limit" | jq -r '.rate.reset')
      NOW=$(date +%s)
      WAIT=$((RESET - NOW + 5))
      if [ "$WAIT" -gt 0 ]; then
        echo "  PRIMARY RATE LIMIT LOW (${REMAINING} remaining). Waiting ${WAIT}s..."
        sleep "$WAIT"
      fi
    fi
  fi

  # Send batch in parallel
  BATCH_END_SEQ=$((BATCH_START_SEQ + BATCH_SIZE - 1))
  seq "$BATCH_START_SEQ" "$BATCH_END_SEQ" | xargs -P "$PARALLELISM" -I{} bash -c 'dispatch_one "'"${RUN_ID}"'-{}"'
  BATCH_START_SEQ=$((BATCH_END_SEQ + 1))

  # Count results from this batch
  BATCH_OK=$(tail -"$BATCH_SIZE" "${RESULTS_DIR}/dispatches.log" 2>/dev/null | grep -c ' ok$' || true)
  BATCH_FAIL=$((BATCH_SIZE - BATCH_OK))
  TOTAL_OK=$((TOTAL_OK + BATCH_OK))
  TOTAL_FAIL=$((TOTAL_FAIL + BATCH_FAIL))

  # Check queued count every 25 batches
  QUEUED_MSG=""
  if [ $((BATCH_NUM % 25)) -eq 0 ]; then
    QUEUED=$(check_queued_count)
    QUEUED_MSG=" | queued_on_gh=${QUEUED}"
  fi

  printf "  batch %d: ok=%d fail=%d | total_ok=%d total_fail=%d%s\n" \
    "$BATCH_NUM" "$BATCH_OK" "$BATCH_FAIL" "$TOTAL_OK" "$TOTAL_FAIL" "$QUEUED_MSG"

  # If we got many failures, back off longer
  if [ "$BATCH_OK" -lt $((BATCH_SIZE / 2)) ]; then
    BACKOFF=$((BATCH_DELAY * 3))
    echo "  high failure rate (${BATCH_FAIL}/${BATCH_SIZE}), backing off ${BACKOFF}s..."
    sleep "$BACKOFF"
  else
    sleep "$BATCH_DELAY"
  fi
done

echo "end_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >> "${RESULTS_DIR}/meta.txt"
echo "total_ok=${TOTAL_OK}" >> "${RESULTS_DIR}/meta.txt"
echo "total_fail=${TOTAL_FAIL}" >> "${RESULTS_DIR}/meta.txt"
echo "batches=${BATCH_NUM}" >> "${RESULTS_DIR}/meta.txt"

FINAL_QUEUED=$(check_queued_count)

echo ""
echo "=== Final Summary ==="
echo "Batches:        ${BATCH_NUM}"
echo "Total accepted: ${TOTAL_OK}"
echo "Total rejected: ${TOTAL_FAIL}"
echo "Queued on GH:   ${FINAL_QUEUED}"
echo "Log: ${RESULTS_DIR}/dispatches.log"
