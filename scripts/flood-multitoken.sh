#!/usr/bin/env bash
set -euo pipefail

# Multi-token sustained dispatch flood.
# Distributes dispatches across multiple tokens to bypass per-token rate limits.
# Each token gets its own batch stream running in a subshell.
#
# Usage: ./scripts/flood-multitoken.sh [target] [tokens_file]
#   target:      total accepted dispatches to aim for (default: 50500)
#   tokens_file: file with one token per line (default: credentials/tokens.txt)

REPO="stefanpenner-cs/org-dispatch-test"
TARGET="${1:-50500}"
TOKENS_FILE="${2:-credentials/tokens.txt}"
BATCH_SIZE=150
BATCH_DELAY=15
PARALLELISM=30

if [ ! -f "$TOKENS_FILE" ]; then
  echo "Token file not found: ${TOKENS_FILE}"
  echo "Create it with one GitHub PAT per line:"
  echo "  echo 'ghp_xxxx' >> ${TOKENS_FILE}"
  exit 1
fi

# Read tokens into array
mapfile -t TOKENS < <(grep -v '^#' "$TOKENS_FILE" | grep -v '^$')
NUM_TOKENS=${#TOKENS[@]}

if [ "$NUM_TOKENS" -eq 0 ]; then
  echo "No tokens found in ${TOKENS_FILE}"
  exit 1
fi

RUN_ID="multi-$(date +%s)"
RESULTS_DIR="results/${RUN_ID}"
mkdir -p "$RESULTS_DIR"

cat > "${RESULTS_DIR}/meta.txt" <<EOF
start_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
target=${TARGET}
num_tokens=${NUM_TOKENS}
batch_size=${BATCH_SIZE}
batch_delay=${BATCH_DELAY}
parallelism_per_token=${PARALLELISM}
EOF

echo "Multi-token flood targeting ${TARGET} accepted dispatches"
echo "Tokens: ${NUM_TOKENS}, batch_size: ${BATCH_SIZE}, delay: ${BATCH_DELAY}s"
echo "Effective parallelism: ${NUM_TOKENS} tokens x ${PARALLELISM} concurrent = $((NUM_TOKENS * PARALLELISM))"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}/"
echo ""

# Shared counter file for cross-process coordination
COUNTER_FILE="${RESULTS_DIR}/counter"
echo "0" > "$COUNTER_FILE"

# Per-token worker function
run_token_worker() {
  local TOKEN_IDX="$1"
  local TOKEN="$2"
  local WORKER_LOG="${RESULTS_DIR}/worker-${TOKEN_IDX}.log"

  local WORKER_OK=0
  local WORKER_FAIL=0
  local WORKER_BATCH=0

  while true; do
    # Check if we've collectively reached the target
    local CURRENT_TOTAL
    CURRENT_TOTAL=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    if [ "$CURRENT_TOTAL" -ge "$TARGET" ]; then
      break
    fi

    WORKER_BATCH=$((WORKER_BATCH + 1))
    local BATCH_OK=0

    # Send a batch using this token
    for i in $(seq 1 "$BATCH_SIZE"); do
      local SEQ="${TOKEN_IDX}-${WORKER_BATCH}-${i}"
      local PROBE_ID="${RUN_ID}-t${SEQ}"

      local HTTP_STATUS
      HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 10 \
        -X POST \
        -H "Authorization: token ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -d "{\"event_type\":\"probe\",\"client_payload\":{\"probe_id\":\"${PROBE_ID}\",\"sleep_seconds\":\"0\"}}" \
        "https://api.github.com/repos/${REPO}/dispatches") || HTTP_STATUS="error"

      local TIMESTAMP
      TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

      if [ "$HTTP_STATUS" = "204" ]; then
        BATCH_OK=$((BATCH_OK + 1))
        echo "${TIMESTAMP} ${PROBE_ID} ok" >> "${RESULTS_DIR}/dispatches.log"
      else
        echo "${TIMESTAMP} ${PROBE_ID} fail:${HTTP_STATUS}" >> "${RESULTS_DIR}/dispatches.log"

        # On 403, stop batch early and back off
        if [ "$HTTP_STATUS" = "403" ]; then
          break
        fi
      fi
    done

    WORKER_OK=$((WORKER_OK + BATCH_OK))
    local BATCH_FAIL=$((BATCH_SIZE - BATCH_OK))
    WORKER_FAIL=$((WORKER_FAIL + BATCH_FAIL))

    # Update shared counter (approximate — no locking, but close enough)
    local PREV
    PREV=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    echo $((PREV + BATCH_OK)) > "$COUNTER_FILE"

    printf "[T%d] batch %d: ok=%d | worker_total=%d\n" \
      "$TOKEN_IDX" "$WORKER_BATCH" "$BATCH_OK" "$WORKER_OK"

    # Back off if high failure rate
    if [ "$BATCH_OK" -lt $((BATCH_SIZE / 2)) ]; then
      sleep $((BATCH_DELAY * 3))
    else
      sleep "$BATCH_DELAY"
    fi

    # Check primary rate limit every 10 batches
    if [ $((WORKER_BATCH % 10)) -eq 0 ]; then
      local REMAINING
      REMAINING=$(curl -s -H "Authorization: token ${TOKEN}" \
        "https://api.github.com/rate_limit" | jq -r '.rate.remaining' 2>/dev/null) || REMAINING=999

      if [ "$REMAINING" -lt 200 ]; then
        local RESET NOW WAIT
        RESET=$(curl -s -H "Authorization: token ${TOKEN}" \
          "https://api.github.com/rate_limit" | jq -r '.rate.reset' 2>/dev/null) || RESET=0
        NOW=$(date +%s)
        WAIT=$((RESET - NOW + 5))
        if [ "$WAIT" -gt 0 ] && [ "$WAIT" -lt 3700 ]; then
          printf "[T%d] primary rate limit low (%d remaining), waiting %ds\n" \
            "$TOKEN_IDX" "$REMAINING" "$WAIT"
          sleep "$WAIT"
        fi
      fi
    fi
  done

  printf "[T%d] DONE: ok=%d fail=%d\n" "$TOKEN_IDX" "$WORKER_OK" "$WORKER_FAIL"
}

# Launch one worker per token in background
PIDS=()
for idx in $(seq 0 $((NUM_TOKENS - 1))); do
  run_token_worker "$idx" "${TOKENS[$idx]}" &
  PIDS+=($!)
  # Stagger start slightly to avoid all tokens hitting secondary limit at once
  sleep 2
done

echo "Launched ${NUM_TOKENS} workers: PIDs ${PIDS[*]}"
echo "Waiting for target..."
echo ""

# Monitor progress
while true; do
  sleep 30
  CURRENT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  TOTAL_LOG=$(wc -l < "${RESULTS_DIR}/dispatches.log" 2>/dev/null | tr -d ' ' || echo 0)
  OK_LOG=$(grep -c ' ok$' "${RESULTS_DIR}/dispatches.log" 2>/dev/null || echo 0)
  FAIL_LOG=$((TOTAL_LOG - OK_LOG))

  printf "PROGRESS: accepted=%d/%d  failed=%d  (%.1f%%)\n" \
    "$OK_LOG" "$TARGET" "$FAIL_LOG" \
    "$(awk "BEGIN {printf \"%.1f\", (${OK_LOG}/${TARGET})*100}")"

  # Check if all workers are done
  ALL_DONE=true
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      ALL_DONE=false
      break
    fi
  done

  if $ALL_DONE; then
    break
  fi
done

# Wait for all workers
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

echo "end_time=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >> "${RESULTS_DIR}/meta.txt"

FINAL_OK=$(grep -c ' ok$' "${RESULTS_DIR}/dispatches.log" 2>/dev/null || echo 0)
FINAL_FAIL=$(grep -c ' fail:' "${RESULTS_DIR}/dispatches.log" 2>/dev/null || echo 0)

echo ""
echo "=== Final Summary ==="
echo "Tokens used:    ${NUM_TOKENS}"
echo "Total accepted: ${FINAL_OK}"
echo "Total rejected: ${FINAL_FAIL}"
echo "Log: ${RESULTS_DIR}/dispatches.log"
echo ""
echo "Run reconcile to check for silent drops:"
echo "  bash scripts/reconcile.sh ${RESULTS_DIR}"
