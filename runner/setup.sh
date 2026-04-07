#!/usr/bin/env bash
set -euo pipefail

# Downloads and configures an org-level self-hosted runner for stefanpenner-cs.
# Prerequisites: gh CLI authenticated with admin access to the org.

ORG="stefanpenner-cs"
RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)/_work"

mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# Get a runner registration token via the API
TOKEN=$(gh api "orgs/${ORG}/actions/runners/registration-token" --method POST --jq '.token')

# Download runner if not already present
if [ ! -f ./config.sh ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    arm64) RUNNER_ARCH="osx-arm64" ;;
    x86_64) RUNNER_ARCH="osx-x64" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
  esac

  # Fetch latest runner version
  RUNNER_VERSION=$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | sed 's/^v//')
  RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

  echo "Downloading runner ${RUNNER_VERSION} for ${RUNNER_ARCH}..."
  curl -o actions-runner.tar.gz -L "$RUNNER_URL"
  tar xzf actions-runner.tar.gz
  rm actions-runner.tar.gz
fi

# Configure (--replace in case re-running)
./config.sh \
  --url "https://github.com/${ORG}" \
  --token "$TOKEN" \
  --name "dispatch-probe-runner" \
  --labels "self-hosted" \
  --work "_work" \
  --replace \
  --unattended

echo ""
echo "Runner configured. Control it with:"
echo "  Start:  runner/start.sh"
echo "  Stop:   runner/stop.sh"
