#!/usr/bin/env bash
set -euo pipefail

# Serial dispatch flood.
# Usage: ./scripts/flood.sh [count] [event_type] [rate_per_sec] [sleep_seconds]
#   count:         number of dispatches to send (default: 10)
#   event_type:    repository_dispatch event type (default: probe)
#   rate_per_sec:  dispatches per second, 0 = unlimited (default: 0)
#   sleep_seconds: payload sleep for each job (default: 0)

REPO="stefanpenner-cs/org-dispatch-test"
COUNT="${1:-10}"
EVENT_TYPE="${2:-probe}"
RATE="${3:-0}"
SLEEP_SECS="${4:-0}"

RUN_ID="flood-$(date +%s)"
RESULTS_DIR="results/${RUN_ID}"
mkdir -p "$RESULTS_DIR"

echo "Flood: ${COUNT} dispatches, event_type=${EVENT_TYPE}, rate=${RATE}/s, job_sleep=${SLEEP_SECS}s"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}/"

cat > "${RESULTS_DIR}/meta.txt" <<EOF
start_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
count=${COUNT}
event_type=${EVENT_TYPE}
rate=${RATE}
sleep_seconds=${SLEEP_SECS}
EOF

DELAY=0
if [ "$RATE" -gt 0 ] 2>/dev/null; then
  DELAY=$(awk "BEGIN {printf \"%.4f\", 1.0 / ${RATE}}")
fi

SUCCESS=0
FAIL=0

for i in $(seq 1 "$COUNT"); do
  PROBE_ID="${RUN_ID}-${i}"
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

  BODY=$(jq -n \
    --arg et "$EVENT_TYPE" \
    --arg pid "$PROBE_ID" \
    --arg ss "$SLEEP_SECS" \
    '{event_type: $et, client_payload: {probe_id: $pid, sleep_seconds: $ss}}')

  HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Authorization: token $(gh auth token)" \
    -H "Accept: application/vnd.github+json" \
    -d "$BODY" \
    "https://api.github.com/repos/${REPO}/dispatches") || HTTP_STATUS="error"

  if [ "$HTTP_STATUS" = "204" ]; then
    STATUS="ok"
    SUCCESS=$((SUCCESS + 1))
  else
    STATUS="fail:${HTTP_STATUS}"
    FAIL=$((FAIL + 1))
  fi

  echo "${TIMESTAMP} ${PROBE_ID} ${STATUS}" >> "${RESULTS_DIR}/dispatches.log"

  # Progress every 50
  if [ $((i % 50)) -eq 0 ]; then
    echo "  sent ${i}/${COUNT} (ok=${SUCCESS} fail=${FAIL})"
  fi

  # Rate limiting
  if [ "$DELAY" != "0" ]; then
    sleep "$DELAY"
  fi
done

echo "end_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >> "${RESULTS_DIR}/meta.txt"
echo ""
echo "Done: ${SUCCESS} ok, ${FAIL} failed out of ${COUNT}"
echo "Log: ${RESULTS_DIR}/dispatches.log"
