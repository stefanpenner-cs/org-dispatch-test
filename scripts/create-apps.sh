#!/usr/bin/env bash
set -euo pipefail

# Creates GitHub Apps via the manifest flow for multi-token dispatch flooding.
# Each app gets independent rate limits.
#
# Usage: ./scripts/create-apps.sh [count]
#   count: number of apps to create (default: 10)
#
# For each app:
#   1. Opens browser to GitHub app creation page
#   2. You click "Create GitHub App"
#   3. GitHub redirects to localhost:9876 with a code
#   4. Script exchanges code for credentials
#   5. Installs app on org
#   6. Saves private key + app ID

ORG="stefanpenner-cs"
REPO="stefanpenner-cs/org-dispatch-test"
COUNT="${1:-10}"
CREDS_DIR="$(cd "$(dirname "$0")/.." && pwd)/credentials"
mkdir -p "$CREDS_DIR"

CALLBACK_PORT=9876

create_one_app() {
  local APP_NUM="$1"
  local APP_NAME="dispatch-flood-${APP_NUM}"

  echo ""
  echo "========================================="
  echo "  Creating app ${APP_NUM}/${COUNT}: ${APP_NAME}"
  echo "========================================="

  # Create the manifest
  local MANIFEST
  MANIFEST=$(jq -n \
    --arg name "$APP_NAME" \
    --arg url "http://localhost:${CALLBACK_PORT}/callback" \
    '{
      name: $name,
      url: "https://github.com/stefanpenner-cs/org-dispatch-test",
      hook_attributes: { active: false },
      redirect_url: $url,
      public: false,
      default_permissions: {
        contents: "write"
      },
      default_events: []
    }')

  # Create a temporary HTML file with the manifest form
  local FORM_FILE
  FORM_FILE=$(mktemp /tmp/gh-app-manifest-XXXXXX.html)
  cat > "$FORM_FILE" <<HTMLEOF
<!DOCTYPE html>
<html>
<body>
<h2>Creating: ${APP_NAME}</h2>
<p>Click the button below to create the app on GitHub.</p>
<form action="https://github.com/organizations/${ORG}/settings/apps/new" method="post">
  <input type="hidden" name="manifest" value='${MANIFEST}'>
  <input type="submit" value="Create ${APP_NAME}" style="font-size: 24px; padding: 20px 40px; cursor: pointer;">
</form>
</body>
</html>
HTMLEOF

  # Start a temporary HTTP server to capture the callback code
  # Using a simple nc-based approach
  local CODE=""

  # Start listener in background
  (
    # Listen for the callback and extract the code
    while true; do
      RESPONSE=$(printf "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h1>App created! You can close this tab.</h1></body></html>" | nc -l "$CALLBACK_PORT" 2>/dev/null)
      if echo "$RESPONSE" | grep -q "code="; then
        echo "$RESPONSE" | grep -oP 'code=\K[^& ]+' > "/tmp/gh-app-code-${APP_NUM}"
        break
      fi
    done
  ) &
  local NC_PID=$!

  # Open the form in the browser
  echo "Opening browser..."
  open "$FORM_FILE"

  echo "Waiting for you to approve the app in the browser..."
  echo "(The browser will redirect to localhost:${CALLBACK_PORT} after approval)"

  # Wait for the code file to appear
  local TIMEOUT=120
  local ELAPSED=0
  while [ ! -f "/tmp/gh-app-code-${APP_NUM}" ] && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
  done

  kill "$NC_PID" 2>/dev/null || true
  rm -f "$FORM_FILE"

  if [ ! -f "/tmp/gh-app-code-${APP_NUM}" ]; then
    echo "ERROR: Timed out waiting for app creation callback"
    return 1
  fi

  CODE=$(cat "/tmp/gh-app-code-${APP_NUM}")
  rm -f "/tmp/gh-app-code-${APP_NUM}"

  echo "Got code: ${CODE:0:8}..."

  # Exchange code for app credentials
  echo "Exchanging code for credentials..."
  local CONVERSION
  CONVERSION=$(curl -s -X POST \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app-manifests/${CODE}/conversions")

  local APP_ID
  APP_ID=$(echo "$CONVERSION" | jq -r '.id')
  local APP_SLUG
  APP_SLUG=$(echo "$CONVERSION" | jq -r '.slug')
  local PEM
  PEM=$(echo "$CONVERSION" | jq -r '.pem')

  if [ "$APP_ID" = "null" ] || [ -z "$APP_ID" ]; then
    echo "ERROR: Failed to exchange code. Response:"
    echo "$CONVERSION" | jq .
    return 1
  fi

  echo "App created! ID: ${APP_ID}, slug: ${APP_SLUG}"

  # Save the private key
  echo "$PEM" > "${CREDS_DIR}/app-${APP_NUM}.pem"
  echo "$APP_ID" > "${CREDS_DIR}/app-${APP_NUM}.id"
  echo "$CONVERSION" | jq '{id, slug, name, client_id}' > "${CREDS_DIR}/app-${APP_NUM}.json"

  echo "Saved: ${CREDS_DIR}/app-${APP_NUM}.pem"
  echo "Saved: ${CREDS_DIR}/app-${APP_NUM}.id"

  # Install the app on the org
  echo "Installing app on ${ORG}..."

  # Generate a JWT for the app
  local JWT
  JWT=$(generate_jwt "$APP_ID" "${CREDS_DIR}/app-${APP_NUM}.pem")

  # Create installation
  local INSTALL_RESULT
  INSTALL_RESULT=$(curl -s -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations" 2>&1 || true)

  # The app needs to be installed via the web UI
  local INSTALL_URL="https://github.com/organizations/${ORG}/settings/installations"
  echo ""
  echo "NOTE: You may need to install the app manually at:"
  echo "  https://github.com/apps/${APP_SLUG}/installations/new"
  echo ""

  echo "App ${APP_NUM} complete!"
}

generate_jwt() {
  local APP_ID="$1"
  local PEM_FILE="$2"

  # Generate JWT using Ruby (available on macOS)
  ruby -e '
    require "openssl"
    require "json"
    require "base64"

    pem = File.read(ARGV[1])
    key = OpenSSL::PKey::RSA.new(pem)

    now = Time.now.to_i
    payload = {
      iat: now - 60,
      exp: now + (10 * 60),
      iss: ARGV[0].to_i
    }

    header = Base64.urlsafe_encode64({"alg" => "RS256", "typ" => "JWT"}.to_json).gsub("=","")
    body = Base64.urlsafe_encode64(payload.to_json).gsub("=","")
    signature = Base64.urlsafe_encode64(key.sign("SHA256", "#{header}.#{body}")).gsub("=","")

    puts "#{header}.#{body}.#{signature}"
  ' "$APP_ID" "$PEM_FILE"
}

export -f generate_jwt

echo "Creating ${COUNT} GitHub Apps for multi-token dispatch flooding"
echo "Credentials will be saved to: ${CREDS_DIR}/"
echo ""
echo "For each app, a browser window will open."
echo "Click 'Create GitHub App', then the script captures the credentials."

for i in $(seq 1 "$COUNT"); do
  create_one_app "$i"
  echo ""
done

echo ""
echo "=== All done! ==="
echo "Apps created: ${COUNT}"
echo "Credentials in: ${CREDS_DIR}/"
echo ""
echo "Next: generate installation tokens with:"
echo "  bash scripts/generate-tokens.sh"
