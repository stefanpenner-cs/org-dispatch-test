#!/usr/bin/env bash
set -euo pipefail

PID_FILE="$(cd "$(dirname "$0")" && pwd)/runner.pid"

if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if kill "$PID" 2>/dev/null; then
    echo "Runner stopped (PID: $PID)"
  else
    echo "Runner was not running (stale PID: $PID)"
  fi
  rm -f "$PID_FILE"
else
  echo "No runner PID file found. Runner may not be running."
fi
