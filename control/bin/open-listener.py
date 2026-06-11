#!/usr/bin/env python3
"""agent-mac-ops browser-handoff listener (runs on the CONTROL Mac).

Listens on 127.0.0.1:<port> for URLs forwarded from the remote's `open` shim over
the reverse SSH tunnel, and opens each on THIS Mac. Only http(s) URLs are honored,
and a shared token (HANDOFF_TOKEN env) is required, so a stray process on the
remote's loopback can't make your Mac open arbitrary pages.

  open-listener.py [port]      # port defaults to 17999 or $HANDOFF_PORT
"""
import http.server
import os
import subprocess
import sys
import urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("HANDOFF_PORT", "17999"))
TOKEN = os.environ.get("HANDOFF_TOKEN", "")
ALLOWED = ("http://", "https://")


def _params(handler):
    if handler.command == "POST":
        n = int(handler.headers.get("Content-Length", 0))
        raw = handler.rfile.read(n).decode("utf-8", "replace")
    else:
        raw = urllib.parse.urlparse(handler.path).query
    return urllib.parse.parse_qs(raw)


class Handler(http.server.BaseHTTPRequestHandler):
    def _handle(self):
        q = _params(self)
        token = (q.get("token") or [""])[0]
        url = (q.get("url") or [""])[0]
        if TOKEN and token != TOKEN:
            self.send_response(403); self.end_headers(); self.wfile.write(b"bad token"); return
        if not url.startswith(ALLOWED):
            self.send_response(400); self.end_headers(); self.wfile.write(b"only http(s)"); return
        subprocess.Popen(["open", url])
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

    do_GET = _handle
    do_POST = _handle

    def log_message(self, *_):  # stay quiet
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
