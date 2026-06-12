#!/bin/bash
# Auto-mirror this Mac's clipboard IMAGES to the remote's clipboard, so a screenshot
# you copy here (Cmd+Ctrl+Shift+4) is instantly Ctrl+V-able in a tool on the remote
# (Claude Code etc.) with zero manual `<alias>-clip`. Runs on the CONTROL Mac, under
# launchd (install-clip-watch.sh). Images ONLY — text already pastes over the
# terminal, and auto-mirroring text would clobber the remote clipboard constantly.
#
# macOS has no push notification for clipboard changes, so we poll. To stay cheap we
# gate on `clipboard info` (fast — types/sizes, not the data); only when it changes
# AND names an image type do we extract the PNG and ship it. De-duped by md5 so a
# static image clipboard isn't re-pushed. Pushes ride the shared SSH master, so each
# transfer reuses one connection.
set -uo pipefail
# launchd runs with a bare PATH (/usr/bin:/bin:…) that omits Homebrew, so pngpaste/
# mosh/etc. won't resolve. Put Homebrew first — same fix dev-session.sh uses.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"
INTERVAL="${CLIP_WATCH_INTERVAL:-1.5}"

command -v pngpaste >/dev/null || { echo "clip-watch: needs pngpaste (brew install pngpaste)" >&2; exit 1; }

CM=(-o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=10m \
    -o ConnectTimeout=8 -o BatchMode=yes)
tmp="$(mktemp -d)/clip.png"; trap 'rm -rf "$(dirname "$tmp")"' EXIT

push() {  # $1 = png file → remote clipboard (image flavor)
  ssh "${CM[@]}" "$REMOTE_HOST" \
    'd=$(mktemp -d); f="$d/clip.png"; cat > "$f"; \
     osascript -e "set the clipboard to (read (POSIX file \"$f\") as «class PNGf»)"; \
     rm -rf "$d"' < "$1"
}
md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

# Seed from the current clipboard so we DON'T push a stale image at startup —
# only images copied after the watcher starts get mirrored.
last_info="$(osascript -e 'clipboard info' 2>/dev/null || true)"
last_md5=""
if printf '%s' "$last_info" | grep -q 'PNGf\|TIFF' && pngpaste "$tmp" 2>/dev/null; then
  last_md5="$(md5of "$tmp")"
fi

echo "clip-watch: mirroring clipboard images → $REMOTE_HOST every ${INTERVAL}s"
while :; do
  sleep "$INTERVAL"
  info="$(osascript -e 'clipboard info' 2>/dev/null || true)"
  [ "$info" = "$last_info" ] && continue
  last_info="$info"
  case "$info" in
    *PNGf*|*TIFF*)
      pngpaste "$tmp" 2>/dev/null || continue
      md5="$(md5of "$tmp")"
      [ "$md5" = "$last_md5" ] && continue
      if push "$tmp"; then
        last_md5="$md5"
        echo "$(date '+%H:%M:%S') pushed clipboard image → $REMOTE_HOST"
      else
        echo "$(date '+%H:%M:%S') push failed (remote unreachable?) — will retry on next copy" >&2
      fi ;;
  esac
done
