#!/usr/bin/env bash
set -euo pipefail

# Flood via push events to bypass API secondary rate limit.
# Creates N branches and pushes them all at once.
# Each branch push generates a webhook → workflow run.
#
# Usage: ./scripts/flood-push.sh [count]
#   count: number of branches to create and push (default: 600)

COUNT="${1:-600}"
RUN_ID="push-$(date +%s)"
PREFIX="flood/${RUN_ID}"

echo "Creating ${COUNT} branches with prefix ${PREFIX}/..."

# Get current HEAD
HEAD=$(git rev-parse HEAD)

# Create all branches locally (fast — no disk I/O, just ref updates)
for i in $(seq 1 "$COUNT"); do
  git branch "${PREFIX}/${i}" "$HEAD" 2>/dev/null
done
echo "Created ${COUNT} local branches."

# Push all at once
echo "Pushing all branches (this triggers webhooks)..."
START_TIME=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

git push origin "refs/heads/${PREFIX}/*:refs/heads/${PREFIX}/*" 2>&1

END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

echo ""
echo "Push completed."
echo "Start: ${START_TIME}"
echo "End:   ${END_TIME}"
echo ""
echo "Branches pushed: ${COUNT}"
echo "Monitor with: bash scripts/monitor.sh"
echo ""
echo "Cleanup later with:"
echo "  git push origin --delete \$(git branch -r | grep '${PREFIX}' | sed 's|origin/||')"
echo "  git branch -D \$(git branch | grep '${PREFIX}')"
