#!/bin/bash
# Install/refresh the iTerm tab-color script on THIS Mac (the one running iTerm).
# Links control/bin/iterm-tab-colors.py into iTerm's AutoLaunch folder, so iTerm
# starts it on every launch, then starts it now. It colors each tab by its
# worktree group (fragblitz-*, DUP-1234-*, ...) and re-colors after every tmux
# reattach. Options live in ~/.config/iterm-tab-colors.json (see the script).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/control/bin/iterm-tab-colors.py"
DEST_DIR="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
DEST="$DEST_DIR/iterm-tab-colors.py"

if [ "$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null)" != "1" ]; then
  echo "Turn on iTerm → Settings → General → Magic → Enable Python API, then re-run." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
ln -sfn "$SRC" "$DEST"
echo "Linked $DEST → $SRC"

# Stop any running copy so a re-install doesn't leave two fighting over colors.
pkill -f "AutoLaunch/iterm-tab-colors.py" 2>/dev/null || true
sleep 1

if osascript -e 'tell application "iTerm2" to launch API script named "iterm-tab-colors.py"' >/dev/null 2>&1; then
  echo "Started. Scripts → Manage → Console shows its log."
else
  echo "Linked, but couldn't start it now — restart iTerm, or Scripts → AutoLaunch → iterm-tab-colors.py."
fi
