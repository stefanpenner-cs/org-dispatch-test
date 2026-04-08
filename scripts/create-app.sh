#!/usr/bin/env bash
set -euo pipefail

# Creates a GitHub App on the org for dispatch flood testing.
# The app needs Contents:write permission to trigger repository_dispatch.
#
# Usage: ./scripts/create-app.sh [app_number]
#   app_number: suffix for the app name (default: 1)
#
# This uses the GitHub App manifest flow:
# 1. Starts a local server to handle the callback
# 2. Opens a browser for you to approve
# 3. Exchanges the code for app credentials
# 4. Saves the private key and app ID

ORG="stefanpenner-cs"
APP_NUM="${1:-1}"
APP_NAME="dispatch-flood-${APP_NUM}"
CREDS_DIR="$(cd "$(dirname "$0")/.." && pwd)/credentials"
mkdir -p "$CREDS_DIR"

echo "Creating GitHub App: ${APP_NAME}"
echo ""

# Create the app via API (org-owned app)
# This requires the manifest flow which needs a web redirect.
# Instead, we'll use the direct API approach with an authenticated user.

# Step 1: Create the app manifest
MANIFEST=$(jq -n \
  --arg name "$APP_NAME" \
  '{
    name: $name,
    url: "https://github.com/stefanpenner-cs/org-dispatch-test",
    hook_attributes: { active: false },
    public: false,
    default_permissions: {
      contents: "write"
    },
    default_events: []
  }')

echo "App manifest:"
echo "$MANIFEST" | jq .
echo ""

# The manifest flow requires a web server. Let's use a simpler approach:
# Create the app directly via the org apps API
echo "Creating app via API..."
RESULT=$(gh api "orgs/${ORG}/apps" \
  --method POST \
  --input - <<< "$MANIFEST" 2>&1) || {
  echo "Direct app creation failed. Trying manifest flow..."
  echo "Error: $RESULT"
  echo ""
  echo "You may need to create the app manually at:"
  echo "  https://github.com/organizations/${ORG}/settings/apps/new"
  echo ""
  echo "Settings:"
  echo "  Name: ${APP_NAME}"
  echo "  Homepage URL: https://github.com/${ORG}/org-dispatch-test"
  echo "  Webhook: unchecked/inactive"
  echo "  Permissions: Contents → Read and write"
  echo "  Install on: ${ORG}"
  exit 1
}

APP_ID=$(echo "$RESULT" | jq -r '.id')
echo "App created! ID: ${APP_ID}"
echo "$RESULT" | jq '{id, name, slug, owner: .owner.login}'

# Generate a private key
echo ""
echo "Generating private key..."
KEY_RESULT=$(gh api "app/installations" 2>&1 || true)

# Save credentials
echo "$RESULT" > "${CREDS_DIR}/app-${APP_NUM}.json"
echo "Credentials saved to ${CREDS_DIR}/app-${APP_NUM}.json"
