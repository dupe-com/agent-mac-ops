#!/bin/bash
# Ad-hoc SSH port forwarding to the remote, without reconnecting your session.
# Self-contained: keeps its own short-lived master connection, so it works whether
# or not you've configured ControlMaster in ~/.ssh/config.
#
#   box-fwd 3000 8080         forward localhost:3000 & :8080 ⇄ remote (your Mac → remote)
#   box-fwd cancel 3000       stop forwarding port 3000
#   box-fwd oauth '<url>'     parse the localhost callback port out of an OAuth URL,
#                             forward it, then open the URL in your Mac's browser
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
HOST="${REMOTE_HOST:?REMOTE_HOST not set — run ./setup.sh or export it}"

CM=(-o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=10m)
master() { ssh "${CM[@]}" -O check "$HOST" 2>/dev/null || ssh "${CM[@]}" -fN "$HOST"; }
fwd()    { master; ssh "${CM[@]}" -O forward -L "$1:localhost:$1" "$HOST" && echo "→ localhost:$1 ⇄ $HOST:$1"; }
cancel() { ssh "${CM[@]}" -O cancel  -L "$1:localhost:$1" "$HOST" 2>/dev/null && echo "✕ stopped $1" || echo "(not forwarding $1)"; }

action="${1:-}"
case "$action" in
  "" ) echo "usage: box-fwd <port...> | box-fwd cancel <port...> | box-fwd oauth <url>" >&2; exit 1 ;;
  cancel) shift; for p in "$@"; do cancel "$p"; done ;;
  oauth)
    url="${2:?usage: box-fwd oauth <url>}"
    # callback port appears as localhost:PORT or url-encoded localhost%3APORT
    port=$(printf '%s' "$url" | grep -oiE 'localhost(%3a|:)[0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -n "$port" ]; then fwd "$port"; else echo "no localhost callback port found in URL — forwarding nothing" >&2; fi
    open "$url" ;;
  *) for p in "$@"; do
       case "$p" in (*[!0-9]*) echo "not a port: $p" >&2; exit 1;; esac
       fwd "$p"
     done ;;
esac
