#!/usr/bin/env python3
"""
Creates GitHub Apps via the manifest flow for multi-token dispatch flooding.
Each app gets independent rate limits (5000 requests/hour).

Usage: python3 scripts/create-apps.py [count]

For each app:
  1. Opens browser to approve the app manifest
  2. Captures the redirect code via a local HTTP server
  3. Exchanges code for credentials (app ID + private key)
  4. Saves credentials to credentials/
"""

import html
import http.server
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser

ORG = "stefanpenner-cs"
REPO = "stefanpenner-cs/org-dispatch-test"
PORT = 9876
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CREDS_DIR = os.path.join(SCRIPT_DIR, "..", "credentials")
os.makedirs(CREDS_DIR, exist_ok=True)


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Serves the manifest form and captures the code from GitHub's redirect."""

    code = None
    manifest_json = None

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if "code" in params:
            # GitHub redirected back with a code
            CallbackHandler.code = params["code"][0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<html><body><h1>App created! You can close this tab.</h1></body></html>")
        elif self.path == "/" or self.path.startswith("/form"):
            # Serve the manifest form — set value via JS (matches GitHub docs pattern)
            # The manifest JSON is injected via a <script> tag to avoid HTML escaping issues
            manifest_for_js = CallbackHandler.manifest_json.replace("\\", "\\\\").replace("`", "\\`").replace("$", "\\$")
            body = f"""<!DOCTYPE html>
<html><body>
<h2>Click the button to create the app on GitHub</h2>
<form id="f" action="https://github.com/organizations/{ORG}/settings/apps/new" method="post">
  <input type="text" name="manifest" id="manifest">
  <input type="submit" value="Create App"
         style="font-size: 24px; padding: 20px 40px; cursor: pointer;">
</form>
<script>
  document.getElementById("manifest").value = `{manifest_for_js}`;
</script>
</body></html>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(body.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress request logging


def exchange_code(code):
    """Exchange the manifest code for app credentials."""
    url = f"https://api.github.com/app-manifests/{code}/conversions"
    req = urllib.request.Request(
        url,
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def create_app(app_num, count):
    app_name = f"dispatch-flood-{app_num}"

    print(f"\n{'=' * 50}")
    print(f"  Creating app {app_num}/{count}: {app_name}")
    print(f"{'=' * 50}")

    manifest = json.dumps({
        "name": app_name,
        "url": f"https://github.com/{REPO}",
        "hook_attributes": {"active": False},
        "redirect_url": f"http://localhost:{PORT}/callback",
        "public": False,
        "default_permissions": {
            "contents": "write",
        },
        "default_events": [],
    })

    # Set manifest on the handler so it can serve the form from localhost
    CallbackHandler.manifest_json = manifest
    CallbackHandler.code = None

    # Start server
    server = http.server.HTTPServer(("127.0.0.1", PORT), CallbackHandler)
    server.timeout = 5

    # Open browser to our local form (served from localhost, not file://)
    print("Opening browser...")
    webbrowser.open(f"http://localhost:{PORT}/form")
    print("Click 'Create App' in the browser, then approve on GitHub...")

    # Serve requests until we get the code back
    deadline = time.time() + 120
    while CallbackHandler.code is None and time.time() < deadline:
        server.handle_request()

    server.server_close()

    if CallbackHandler.code is None:
        print("ERROR: Timed out waiting for app creation callback")
        return None

    code = CallbackHandler.code
    print(f"Got code: {code[:8]}...")

    # Exchange code for credentials
    print("Exchanging code for credentials...")
    creds = exchange_code(code)

    app_id = creds.get("id")
    app_slug = creds.get("slug")
    pem = creds.get("pem")

    if not app_id or not pem:
        print(f"ERROR: Failed to get credentials. Response: {json.dumps(creds, indent=2)}")
        return None

    print(f"App created! ID: {app_id}, slug: {app_slug}")

    # Save credentials
    pem_path = os.path.join(CREDS_DIR, f"app-{app_num}.pem")
    with open(pem_path, "w") as f:
        f.write(pem)

    id_path = os.path.join(CREDS_DIR, f"app-{app_num}.id")
    with open(id_path, "w") as f:
        f.write(str(app_id))

    json_path = os.path.join(CREDS_DIR, f"app-{app_num}.json")
    with open(json_path, "w") as f:
        json.dump({
            "id": app_id,
            "slug": app_slug,
            "name": creds.get("name"),
            "client_id": creds.get("client_id"),
        }, f, indent=2)

    print(f"Saved: {pem_path}")
    print(f"Saved: {id_path}")

    # Show install URL
    print(f"\nInstall the app at:")
    print(f"  https://github.com/apps/{app_slug}/installations/new")

    return {
        "id": app_id,
        "slug": app_slug,
        "pem_path": pem_path,
    }


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 10

    print(f"Creating {count} GitHub Apps for multi-token dispatch flooding")
    print(f"Credentials will be saved to: {CREDS_DIR}/")
    print()
    print("For each app, a browser window will open and auto-submit.")
    print("If it doesn't auto-submit, click the button manually.")

    apps = []
    for i in range(1, count + 1):
        result = create_app(i, count)
        if result:
            apps.append(result)
        else:
            print(f"Failed to create app {i}, continuing...")

    print(f"\n{'=' * 50}")
    print(f"  Created {len(apps)}/{count} apps")
    print(f"{'=' * 50}")
    print()

    if apps:
        print("Next steps:")
        print("  1. Install each app on the org (links shown above)")
        print("  2. Generate installation tokens:")
        print("     python3 scripts/generate-tokens.py")
        print("  3. Run the multi-token flood:")
        print("     bash scripts/flood-multitoken.sh")


if __name__ == "__main__":
    main()
