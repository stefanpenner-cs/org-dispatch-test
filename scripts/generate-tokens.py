#!/usr/bin/env python3
"""
Generates installation tokens for all GitHub Apps in credentials/.
Tokens are valid for 1 hour and have independent rate limits.

Usage: python3 scripts/generate-tokens.py

Outputs tokens to credentials/tokens.txt (one per line).
"""

import glob
import json
import jwt  # PyJWT
import os
import sys
import time
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CREDS_DIR = os.path.join(SCRIPT_DIR, "..", "credentials")
TOKENS_FILE = os.path.join(CREDS_DIR, "tokens.txt")
ORG = "stefanpenner-cs"


def generate_jwt_token(app_id, pem_path):
    """Generate a JWT for the GitHub App."""
    with open(pem_path, "r") as f:
        private_key = f.read()

    now = int(time.time())
    payload = {
        "iat": now - 60,
        "exp": now + (10 * 60),
        "iss": int(app_id),
    }

    return jwt.encode(payload, private_key, algorithm="RS256")


def get_installation_id(jwt_token):
    """Get the installation ID for the app on the org."""
    url = "https://api.github.com/app/installations"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {jwt_token}",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        installations = json.loads(resp.read())

    for inst in installations:
        if inst.get("account", {}).get("login") == ORG:
            return inst["id"]

    return None


def create_installation_token(jwt_token, installation_id):
    """Create an installation access token."""
    url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
    req = urllib.request.Request(
        url,
        method="POST",
        headers={
            "Authorization": f"Bearer {jwt_token}",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    return data["token"], data["expires_at"]


def main():
    # Find all app credentials
    id_files = sorted(glob.glob(os.path.join(CREDS_DIR, "app-*.id")))

    if not id_files:
        print(f"No app credentials found in {CREDS_DIR}/")
        print("Run: python3 scripts/create-apps.py")
        sys.exit(1)

    print(f"Found {len(id_files)} apps")
    print()

    tokens = []
    for id_file in id_files:
        app_num = os.path.basename(id_file).replace("app-", "").replace(".id", "")
        pem_file = os.path.join(CREDS_DIR, f"app-{app_num}.pem")

        if not os.path.exists(pem_file):
            print(f"  app-{app_num}: SKIP (no .pem file)")
            continue

        with open(id_file) as f:
            app_id = f.read().strip()

        try:
            jwt_token = generate_jwt_token(app_id, pem_file)
            installation_id = get_installation_id(jwt_token)

            if not installation_id:
                print(f"  app-{app_num} (ID {app_id}): NOT INSTALLED on {ORG}")
                print(f"    Install at: https://github.com/apps/dispatch-flood-{app_num}/installations/new")
                continue

            token, expires = create_installation_token(jwt_token, installation_id)
            tokens.append(token)
            print(f"  app-{app_num} (ID {app_id}): OK (expires {expires})")

        except Exception as e:
            print(f"  app-{app_num} (ID {app_id}): ERROR - {e}")

    if tokens:
        with open(TOKENS_FILE, "w") as f:
            for t in tokens:
                f.write(t + "\n")
        print(f"\nWrote {len(tokens)} tokens to {TOKENS_FILE}")
        print(f"Tokens expire in ~1 hour. Re-run this script to refresh.")
        print(f"\nRun the flood:")
        print(f"  bash scripts/flood-multitoken.sh 50500 {TOKENS_FILE}")
    else:
        print("\nNo tokens generated. Make sure apps are installed on the org.")


if __name__ == "__main__":
    main()
