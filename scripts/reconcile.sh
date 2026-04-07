#!/usr/bin/env bash
set -euo pipefail

# Reconcile dispatched probes against actual workflow runs.
# Finds "silent drops" — dispatches the API accepted but never became runs.
# Usage: ./scripts/reconcile.sh <results_dir>

REPO="stefanpenner-cs/org-dispatch-test"
RESULTS_DIR="${1:?Usage: reconcile.sh <results_dir>}"

if [ ! -f "${RESULTS_DIR}/dispatches.log" ]; then
  echo "No dispatches.log found in ${RESULTS_DIR}"
  exit 1
fi

# Count dispatches by status
SENT_OK=$(grep -c ' ok$' "${RESULTS_DIR}/dispatches.log" || true)
SENT_FAIL=$(grep -c ' fail:' "${RESULTS_DIR}/dispatches.log" || true)
SENT_TOTAL=$(wc -l < "${RESULTS_DIR}/dispatches.log" | tr -d ' ')

echo "=== Dispatch Reconciliation ==="
echo "Results dir: ${RESULTS_DIR}"
echo ""
echo "--- Dispatches sent ---"
echo "Total:    ${SENT_TOTAL}"
echo "Accepted: ${SENT_OK} (HTTP 204)"
echo "Rejected: ${SENT_FAIL}"

# Show failure breakdown if any
if [ "$SENT_FAIL" -gt 0 ]; then
  echo ""
  echo "--- Failure breakdown ---"
  grep ' fail:' "${RESULTS_DIR}/dispatches.log" | sed 's/.* fail://' | sort | uniq -c | sort -rn
fi

echo ""
echo "--- Workflow runs on GitHub ---"

# Count runs by status
for STATUS in queued in_progress completed cancelled failure; do
  COUNT=$(gh api "repos/${REPO}/actions/runs?per_page=1&status=${STATUS}" --jq '.total_count' 2>/dev/null || echo "?")
  printf "%-14s %s\n" "${STATUS}:" "$COUNT"
done

TOTAL_RUNS=$(gh api "repos/${REPO}/actions/runs?per_page=1" --jq '.total_count' 2>/dev/null || echo "?")

echo ""
echo "--- Summary ---"
echo "Dispatches accepted (204): ${SENT_OK}"
echo "Workflow runs created:     ${TOTAL_RUNS}"

if [ "$TOTAL_RUNS" != "?" ] && [ "$SENT_OK" -gt 0 ]; then
  DIFF=$((SENT_OK - TOTAL_RUNS))
  if [ "$DIFF" -gt 0 ]; then
    echo "SILENT DROPS:              ${DIFF} (API accepted but no run created)"
  elif [ "$DIFF" -lt 0 ]; then
    echo "EXTRA RUNS:                $((-DIFF)) (more runs than dispatches — pre-existing?)"
  else
    echo "MATCH:                     All accepted dispatches became runs"
  fi
fi
