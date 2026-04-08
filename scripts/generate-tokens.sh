#!/usr/bin/env bash
set -euo pipefail

# Generates installation tokens for all GitHub Apps in credentials/.
# Tokens are valid for 1 hour and have independent rate limits.
#
# Usage: ./scripts/generate-tokens.sh
# Output: credentials/tokens.txt (one token per line)

ORG="stefanpenner-cs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDS_DIR="${SCRIPT_DIR}/../credentials"
TOKENS_FILE="${CREDS_DIR}/tokens.txt"

generate_jwt() {
  local APP_ID="$1"
  local PEM_FILE="$2"

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

    header = Base64.urlsafe_encode64({"alg" => "RS256", "typ" => "JWT"}.to_json).delete("=")
    body = Base64.urlsafe_encode64(payload.to_json).delete("=")
    signature = Base64.urlsafe_encode64(key.sign("SHA256", "#{header}.#{body}")).delete("=")

    puts "#{header}.#{body}.#{signature}"
  ' "$APP_ID" "$PEM_FILE"
}

get_installation_id() {
  local JWT="$1"
  curl -s \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations" | \
    jq -r ".[] | select(.account.login == \"${ORG}\") | .id"
}

create_installation_token() {
  local JWT="$1"
  local INSTALL_ID="$2"
  curl -s -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" | \
    jq -r '.token'
}

# Find all app credentials
ID_FILES=$(find "$CREDS_DIR" -name 'app-*.id' 2>/dev/null | sort)

if [ -z "$ID_FILES" ]; then
  echo "No app credentials found in ${CREDS_DIR}/"
  echo "Run: python3 scripts/create-apps.py"
  exit 1
fi

COUNT=$(echo "$ID_FILES" | wc -l | tr -d ' ')
echo "Found ${COUNT} apps"
echo ""

> "$TOKENS_FILE"
TOKEN_COUNT=0

for ID_FILE in $ID_FILES; do
  APP_NUM=$(basename "$ID_FILE" | sed 's/app-//;s/.id//')
  PEM_FILE="${CREDS_DIR}/app-${APP_NUM}.pem"

  if [ ! -f "$PEM_FILE" ]; then
    echo "  app-${APP_NUM}: SKIP (no .pem file)"
    continue
  fi

  APP_ID=$(cat "$ID_FILE")

  JWT=$(generate_jwt "$APP_ID" "$PEM_FILE")
  INSTALL_ID=$(get_installation_id "$JWT")

  if [ -z "$INSTALL_ID" ] || [ "$INSTALL_ID" = "null" ]; then
    echo "  app-${APP_NUM} (ID ${APP_ID}): NOT INSTALLED on ${ORG}"
    JSON_FILE="${CREDS_DIR}/app-${APP_NUM}.json"
    if [ -f "$JSON_FILE" ]; then
      SLUG=$(jq -r '.slug' "$JSON_FILE")
      echo "    Install at: https://github.com/apps/${SLUG}/installations/new"
    fi
    continue
  fi

  TOKEN=$(create_installation_token "$JWT" "$INSTALL_ID")

  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "  app-${APP_NUM} (ID ${APP_ID}): ERROR generating token"
    continue
  fi

  echo "$TOKEN" >> "$TOKENS_FILE"
  TOKEN_COUNT=$((TOKEN_COUNT + 1))
  echo "  app-${APP_NUM} (ID ${APP_ID}): OK"
done

echo ""
echo "Generated ${TOKEN_COUNT} tokens -> ${TOKENS_FILE}"
echo "Tokens expire in ~1 hour. Re-run to refresh."
echo ""

if [ "$TOKEN_COUNT" -gt 0 ]; then
  echo "Run the flood:"
  echo "  bash scripts/flood-multitoken.sh 50500 ${TOKENS_FILE}"
fi
