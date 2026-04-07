#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER_DIR="${SCRIPT_DIR}/_work"

if [ ! -f "$RUNNER_DIR/run.sh" ]; then
  echo "Runner not set up. Run runner/setup.sh first."
  exit 1
fi

cd "$RUNNER_DIR"
./run.sh &
echo $! > "${SCRIPT_DIR}/runner.pid"
echo "Runner started (PID: $(cat "${SCRIPT_DIR}/runner.pid"))"
