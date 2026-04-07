#!/usr/bin/env bash
set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)/_work"

if [ ! -f "$RUNNER_DIR/run.sh" ]; then
  echo "Runner not set up. Run runner/setup.sh first."
  exit 1
fi

cd "$RUNNER_DIR"
./run.sh &
echo $! > "$(dirname "$0")/runner.pid"
echo "Runner started (PID: $(cat "$(dirname "$0")/runner.pid"))"
