#!/usr/bin/env bash
set -euo pipefail

# Parallel dispatch flood using xargs -P.
# Usage: ./scripts/flood-parallel.sh [count] [parallelism] [event_type] [sleep_seconds]
#   count:         number of dispatches to send (default: 500)
#   parallelism:   concurrent dispatch processes (default: 50)
#   event_type:    repository_dispatch event type (default: probe)
#   sleep_seconds: payload sleep for each job (default: 0)

REPO="stefanpenner-cs/org-dispatch-test"
COUNT="${1:-500}"
PARALLELISM="${2:-50}"
EVENT_TYPE="${3:-probe}"
SLEEP_SECS="${4:-0}"

RUN_ID="pflood-$(date +%s)"
RESULTS_DIR="results/${RUN_ID}"
mkdir -p "$RESULTS_DIR"

# Cache the auth token so each subprocess doesn't call gh auth token
GH_TOKEN=$(gh auth token)

cat > "${RESULTS_DIR}/meta.txt" <<EOF
start_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
count=${COUNT}
parallelism=${PARALLELISM}
event_type=${EVENT_TYPE}
sleep_seconds=${SLEEP_SECS}
EOF

echo "Parallel flood: ${COUNT} dispatches, parallelism=${PARALLELISM}, event_type=${EVENT_TYPE}"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}/"

export REPO GH_TOKEN EVENT_TYPE SLEEP_SECS RESULTS_DIR RUN_ID

dispatch_one() {
  local SEQ="$1"
  local PROBE_ID="${RUN_ID}-${SEQ}"
  local TIMESTAMP
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

  local BODY
  BODY=$(jq -n \
    --arg et "$EVENT_TYPE" \
    --arg pid "$PROBE_ID" \
    --arg ss "$SLEEP_SECS" \
    '{event_type: $et, client_payload: {probe_id: $pid, sleep_seconds: $ss}}')

  local HTTP_STATUS
  HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$BODY" \
    "https://api.github.com/repos/${REPO}/dispatches") || HTTP_STATUS="error"

  local STATUS
  if [ "$HTTP_STATUS" = "204" ]; then
    STATUS="ok"
  else
    STATUS="fail:${HTTP_STATUS}"
  fi

  echo "${TIMESTAMP} ${PROBE_ID} ${STATUS}" >> "${RESULTS_DIR}/dispatches.log"
}
export -f dispatch_one

seq 1 "$COUNT" | xargs -P "$PARALLELISM" -I{} bash -c 'dispatch_one "$@"' _ {}

echo "end_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >> "${RESULTS_DIR}/meta.txt"

# Summary
TOTAL=$(wc -l < "${RESULTS_DIR}/dispatches.log" | tr -d ' ')
OK=$(grep -c ' ok$' "${RESULTS_DIR}/dispatches.log" || true)
FAIL=$((TOTAL - OK))

echo ""
echo "Done: ${OK} ok, ${FAIL} failed out of ${TOTAL}"
echo "Log: ${RESULTS_DIR}/dispatches.log"
