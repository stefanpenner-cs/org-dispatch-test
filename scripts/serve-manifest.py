#!/usr/bin/env python3
"""Minimal server for GitHub App manifest flow. Open http://localhost:9876 in your browser."""

import http.server
import json
import sys
import urllib.parse
import urllib.request

ORG = "stefanpenner-cs"
PORT = 9876
APP_COUNTER = [0]
COUNT = int(sys.argv[1]) if len(sys.argv) > 1 else 10

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if "code" in params:
            # GitHub redirected back with a code — exchange it
            code = params["code"][0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()

            try:
                req = urllib.request.Request(
                    f"https://api.github.com/app-manifests/{code}/conversions",
                    method="POST",
                    headers={"Accept": "application/vnd.github+json"},
                )
                with urllib.request.urlopen(req) as resp:
                    creds = json.loads(resp.read())

                app_id = creds["id"]
                slug = creds["slug"]
                pem = creds["pem"]
                num = APP_COUNTER[0]

                import os
                creds_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "credentials")
                os.makedirs(creds_dir, exist_ok=True)

                with open(os.path.join(creds_dir, f"app-{num}.pem"), "w") as f:
                    f.write(pem)
                with open(os.path.join(creds_dir, f"app-{num}.id"), "w") as f:
                    f.write(str(app_id))
                with open(os.path.join(creds_dir, f"app-{num}.json"), "w") as f:
                    json.dump({"id": app_id, "slug": slug, "name": creds.get("name"), "client_id": creds.get("client_id")}, f, indent=2)

                print(f"  App {num} created! ID={app_id} slug={slug}")
                print(f"  Install at: https://github.com/apps/{slug}/installations/new")

                self.wfile.write(f"""<html><body>
<h1>App {num} created: {slug}</h1>
<p>ID: {app_id}</p>
<p><a href="https://github.com/apps/{slug}/installations/new" target="_blank">Click here to install it on {ORG}</a></p>
<p><a href="/">Create next app</a></p>
</body></html>""".encode())

            except Exception as e:
                print(f"  ERROR exchanging code: {e}")
                self.wfile.write(f"<html><body><h1>Error: {e}</h1><a href='/'>Retry</a></body></html>".encode())

        else:
            # Serve the form for the next app
            APP_COUNTER[0] += 1
            num = APP_COUNTER[0]
            app_name = f"dispatch-flood-{num}"

            manifest = {
                "name": app_name,
                "url": f"https://github.com/{ORG}/org-dispatch-test",
                "hook_attributes": {"active": False},
                "redirect_url": f"http://localhost:{PORT}/callback",
                "public": False,
                "default_permissions": {"contents": "write"},
                "default_events": [],
            }

            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            # Use the exact pattern from GitHub docs: set value via JS
            self.wfile.write(f"""<!DOCTYPE html>
<html><body>
<h2>Creating app {num}/{COUNT}: {app_name}</h2>
<form id="f" action="https://github.com/organizations/{ORG}/settings/apps/new" method="post">
  <input type="text" name="manifest" id="manifest"><br><br>
  <input type="submit" value="Create {app_name}" style="font-size: 20px; padding: 10px 20px;">
</form>
<script>
  var m = {json.dumps(manifest)};
  document.getElementById("manifest").value = JSON.stringify(m);
</script>
</body></html>""".encode())

            print(f"Serving form for app {num}: {app_name}")

    def log_message(self, format, *args):
        pass

print(f"Server running at http://localhost:{PORT}")
print(f"Open http://localhost:{PORT} in your browser")
print(f"Creating {COUNT} apps. Press Ctrl-C when done.")
print()

server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
try:
    server.serve_forever()
except KeyboardInterrupt:
    print("\nDone.")
    server.server_close()
