#!/usr/bin/env bash
set -euo pipefail

# Bulk cancel queued runs. Each token loops on page 1 since pagination shifts.
REPO="stefanpenner-cs/org-dispatch-test"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKENS_FILE="${SCRIPT_DIR}/../credentials/tokens.txt"

TOKENS=()
TOKENS+=("$(gh auth token)")
while IFS= read -r t; do
  [ -n "$t" ] && TOKENS+=("$t")
done < "$TOKENS_FILE"

NUM_TOKENS=${#TOKENS[@]}
echo "Using $NUM_TOKENS tokens"

cancel_worker() {
  local TOKEN="$1"
  local WORKER_ID="$2"
  local CANCELLED=0

  while true; do
    # Always page 1 — as runs cancel, new ones fill in
    RESPONSE=$(curl -s -w '\n%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${REPO}/actions/runs?status=queued&per_page=100")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "429" ]; then
      echo "[worker-$WORKER_ID] Rate limited ($HTTP_CODE). Sleeping 60s..."
      sleep 60
      continue
    fi

    IDS=$(echo "$BODY" | python3 -c "import sys,json; [print(r['id']) for r in json.load(sys.stdin).get('workflow_runs',[])]" 2>/dev/null)
    COUNT=$(echo "$IDS" | grep -c '[0-9]' || true)

    if [ "$COUNT" -eq 0 ]; then
      echo "[worker-$WORKER_ID] Done. Cancelled $CANCELLED total."
      break
    fi

    # Fire all cancels concurrently
    echo "$IDS" | xargs -P 100 -I{} curl -s -o /dev/null \
      -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${REPO}/actions/runs/{}/cancel"

    CANCELLED=$((CANCELLED + COUNT))
    if (( CANCELLED % 500 == 0 )) || (( CANCELLED < 200 )); then
      echo "[worker-$WORKER_ID] cancelled=$CANCELLED"
    fi
  done
}

echo "Starting $NUM_TOKENS cancel workers..."

for i in "${!TOKENS[@]}"; do
  cancel_worker "${TOKENS[$i]}" "$i" &
done

wait

echo ""
echo "All workers done."
REMAINING=$(curl -s \
  -H "Authorization: Bearer ${TOKENS[1]}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/runs?status=queued" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count',0))")
echo "Remaining queued: $REMAINING"
