#!/usr/bin/env python3
"""Debug version - shows manifest in visible textarea before submission."""

import http.server
import json

ORG = "stefanpenner-cs"
PORT = 9877

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        manifest = {
            "name": "dispatch-flood-test",
            "url": "https://github.com/stefanpenner-cs/org-dispatch-test",
            "hook_attributes": {"active": False},
            "redirect_url": "http://localhost:9877/callback",
            "public": False,
            "default_permissions": {"contents": "write"},
            "default_events": [],
        }
        manifest_str = json.dumps(manifest)

        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        # DO NOT use f-string to avoid any brace issues
        html = '''<!DOCTYPE html>
<html><body>
<h2>Debug: GitHub App Manifest Form</h2>
<form id="f" action="https://github.com/organizations/''' + ORG + '''/settings/apps/new" method="post">
  <label>Manifest JSON (will be submitted):</label><br>
  <textarea name="manifest" id="manifest" rows="10" cols="80"></textarea><br><br>
  <input type="submit" value="Create App" style="font-size: 20px; padding: 10px 20px;"
         onclick="console.log('Submitting:', document.getElementById('manifest').value);">
</form>
<script>
  var manifest = ''' + manifest_str + ''';
  var str = JSON.stringify(manifest);
  document.getElementById("manifest").value = str;
  console.log("Manifest set to:", str);
  document.title = "Manifest length: " + str.length;
</script>
<p>Check: the textarea above should contain valid JSON with a "url" field.</p>
</body></html>'''
        self.wfile.write(html.encode())

    def log_message(self, format, *args):
        pass

print(f"Debug server at http://localhost:{PORT}")
print("Open in your browser, inspect the textarea, then click submit.")
server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
try:
    server.serve_forever()
except KeyboardInterrupt:
    server.server_close()
