#!/bin/bash
# Install/refresh the clipboard-image auto-mirror on THIS control Mac (launchd).
# Keeps clip-watch.sh running so screenshots you copy here land on the remote's
# clipboard automatically — no manual `<alias>-clip`. Re-run to apply config changes.
#   uninstall:  launchctl unload ~/Library/LaunchAgents/com.agent-mac-ops.clip-watch.plist
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"
command -v pngpaste >/dev/null || { echo "needs pngpaste — brew install pngpaste" >&2; exit 1; }

LABEL="com.agent-mac-ops.clip-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/agent-mac-ops-clip-watch.log"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

cat > "$PLIST" <<PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT/control/bin/clip-watch.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>CLIP_WATCH_INTERVAL</key><string>${CLIP_WATCH_INTERVAL:-1.5}</string></dict>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PEOF

# Modern launchctl (bootout/enable/bootstrap/kickstart) instead of legacy load/unload,
# which can leave a job loaded-but-never-started after repeated reloads (runs=0). Then
# verify it's actually running rather than blindly reporting success.
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

sleep 0.3
if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running'; then
  echo "installed $LABEL — clipboard images auto-mirror to $REMOTE_HOST; log: $LOG"
else
  echo "installed $LABEL but it is NOT running — check $LOG" >&2
fi
echo "  stop/disable: launchctl bootout $DOMAIN/$LABEL"
