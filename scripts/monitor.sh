#!/usr/bin/env bash
set -euo pipefail

# Monitor workflow run statuses and API rate limits.
# Usage: ./scripts/monitor.sh [--watch]

REPO="stefanpenner-cs/org-dispatch-test"
WATCH=false
[ "${1:-}" = "--watch" ] && WATCH=true

summarize() {
  echo "=== Workflow Runs Summary ($(date -u +%H:%M:%SZ)) ==="
  echo ""

  for STATUS in queued in_progress completed cancelled failure; do
    COUNT=$(gh api "repos/${REPO}/actions/runs?per_page=1&status=${STATUS}" --jq '.total_count' 2>/dev/null || echo "?")
    printf "%-14s %s\n" "${STATUS}:" "$COUNT"
  done

  echo ""
  echo "--- Recent runs ---"
  gh api "repos/${REPO}/actions/runs?per_page=15" \
    --jq '.workflow_runs[] | [.id, .status, .conclusion // "-", .name, .created_at] | @tsv' 2>/dev/null \
    | column -t -s $'\t' || echo "(none)"

  echo ""
  echo "--- API Rate Limit ---"
  gh api rate_limit --jq '.rate | "remaining: \(.remaining)/\(.limit)  reset: \(.reset | todate)"'
}

if $WATCH; then
  while true; do
    clear
    summarize
    echo ""
    echo "(refreshing every 10s, Ctrl-C to stop)"
    sleep 10
  done
else
  summarize
fi
