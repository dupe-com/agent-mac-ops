#!/usr/bin/env python3
"""agent-mac-ops handoff listener (runs on the CONTROL Mac).

Listens on 127.0.0.1:<port> for requests forwarded from the remote over the reverse
SSH tunnel, and acts on THIS Mac. Two routes, both token-gated (HANDOFF_TOKEN env)
so a stray process on the remote's loopback can't drive your Mac:

  POST/GET /open    url=<http(s)>   → `open <url>` here (browser handoff)
  POST/GET /cursor  path=<abs>      → open your local editor in Remote-SSH mode at
                                      that remote path: `cursor --remote
                                      ssh-remote+$REMOTE_HOST <path>`. This is the
                                      `code .` equivalent for the remote — run
                                      `code-<alias>` in the remote session and your
                                      laptop's Cursor/VS Code opens that folder.

Auto-forward (/open only): when an opened URL carries a localhost callback (e.g. an
OAuth `redirect_uri=http://localhost:PORT/callback`), that PORT is forwarded to the
remote first, so the post-consent redirect to localhost:PORT lands on the remote's
listener instead of dying on your Mac's loopback. This is what makes remote OAuth
logins seamless — no manual `box-fwd`.

  open-listener.py [port]      # port defaults to 17999 or $HANDOFF_PORT
"""
import http.server
import os
import re
import shutil
import subprocess
import sys
import urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("HANDOFF_PORT", "17999"))
TOKEN = os.environ.get("HANDOFF_TOKEN", "")
REMOTE_HOST = os.environ.get("REMOTE_HOST", "")
ALLOWED = ("http://", "https://")

# Repo root from this file: control/bin/open-listener.py → ../../.. = repo root.
_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
_BOX_FWD = os.path.join(_ROOT, "control", "bin", "box-fwd.sh")
_PORT_RE = re.compile(r"localhost:(\d{2,5})\b")

# Editor for the /cursor route. launchd hands us a bare PATH, so resolve a real path
# rather than trusting `cursor` to be on it: $REMOTE_EDITOR (binary name) if set,
# else cursor, then the known app-bundle CLIs, then VS Code's `code`.
def _editor_bin():
    name = os.environ.get("REMOTE_EDITOR", "cursor")
    candidates = [
        shutil.which(name),
        "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        shutil.which("code"),
    ]
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return None


def _autoforward(url):
    """Best-effort: forward any localhost:PORT callback found in the URL to the
    remote, so the OAuth redirect reaches it. Fired async (Popen) so we still
    answer the shim inside its short curl timeout; the forward is up in ~1s,
    well before a human finishes consenting."""
    decoded = urllib.parse.unquote(url)
    for port in dict.fromkeys(_PORT_RE.findall(decoded)):  # de-dupe, keep order
        if port == str(PORT):
            continue  # never the handoff port itself
        try:
            subprocess.Popen([_BOX_FWD, port],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def _params(handler):
    if handler.command == "POST":
        n = int(handler.headers.get("Content-Length", 0))
        raw = handler.rfile.read(n).decode("utf-8", "replace")
    else:
        raw = urllib.parse.urlparse(handler.path).query
    return urllib.parse.parse_qs(raw)


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, code, body):
        self.send_response(code); self.end_headers(); self.wfile.write(body)

    def _handle(self):
        route = urllib.parse.urlparse(self.path).path
        q = _params(self)
        if TOKEN and (q.get("token") or [""])[0] != TOKEN:
            return self._reply(403, b"bad token")
        if route == "/cursor":
            return self._open_cursor((q.get("path") or [""])[0])
        return self._open_url((q.get("url") or [""])[0])

    def _open_url(self, url):
        if not url.startswith(ALLOWED):
            return self._reply(400, b"only http(s)")
        _autoforward(url)
        subprocess.Popen(["open", url])
        self._reply(200, b"ok")

    def _open_cursor(self, path):
        # path is the remote's absolute dir; passed as a list arg (no shell → no
        # injection). It can only ever target the configured REMOTE_HOST.
        if not path.startswith("/"):
            return self._reply(400, b"need an absolute remote path")
        if not REMOTE_HOST:
            return self._reply(500, b"REMOTE_HOST not set in listener env")
        editor = _editor_bin()
        if not editor:
            return self._reply(500, b"no cursor/code binary found on this Mac")
        subprocess.Popen([editor, "--remote", "ssh-remote+" + REMOTE_HOST, path])
        self._reply(200, b"ok")

    do_GET = _handle
    do_POST = _handle

    def log_message(self, *_):  # stay quiet
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
