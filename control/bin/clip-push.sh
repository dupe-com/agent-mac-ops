#!/bin/bash
# Push the control Mac's clipboard IMAGE onto the remote's clipboard, so a tool
# running ON the remote (e.g. Claude Code over SSH) can Ctrl+V it.
#
# Why this is needed: macOS clipboards are per-machine, and a terminal only ever
# forwards clipboard *text* over SSH — never image bytes. So a screenshot you copy
# on your laptop never reaches the remote, and Claude Code (running on the remote)
# pastes from the REMOTE clipboard, which never saw it. This bridges the image:
# extract it locally with pngpaste, ship the PNG over SSH, and set it as the
# remote clipboard's image flavor via AppleScript (pbcopy can't set image types).
#
#   usage: clip-push.sh        # copy a screenshot first (Cmd+Ctrl+Shift+4), then run
#
# Then Ctrl+V it in whatever's running on the remote.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"

command -v pngpaste >/dev/null || {
  echo "clip-push: pngpaste not installed — brew install pngpaste" >&2; exit 1; }

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
if ! pngpaste "$tmpd/clip.png" 2>/dev/null; then
  echo "clip-push: no image on the clipboard — copy a screenshot first (Cmd+Ctrl+Shift+4)" >&2
  exit 1
fi

# Ship the PNG and load it onto the remote clipboard as «class PNGf» (image flavor).
ssh "$REMOTE_HOST" \
  'd=$(mktemp -d); f="$d/clip.png"; cat > "$f"; \
   osascript -e "set the clipboard to (read (POSIX file \"$f\") as «class PNGf»)"; \
   rm -rf "$d"' < "$tmpd/clip.png" \
  && echo "📋 clipboard image → $REMOTE_HOST  (Ctrl+V it there now)"
