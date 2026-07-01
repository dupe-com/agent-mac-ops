#!/bin/bash
# Install/refresh the browser-handoff listener on THIS control Mac (macOS launchd).
# Keeps open-listener.py running on 127.0.0.1:$HANDOFF_PORT so URLs forwarded from
# the remote always have somewhere to land.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"
PORT="${HANDOFF_PORT:-17999}"
TOKEN="${HANDOFF_TOKEN:-}"
LABEL="com.agent-mac-ops.open-listener"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PY="$(command -v python3 || echo /usr/bin/python3)"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

cat > "$PLIST" <<PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$ROOT/control/bin/open-listener.py</string>
    <string>$PORT</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HANDOFF_TOKEN</key><string>$TOKEN</string>
    <key>REMOTE_HOST</key><string>${REMOTE_HOST:-}</string>
    <key>REMOTE_EDITOR</key><string>${REMOTE_EDITOR:-cursor}</string>
  </dict>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/agent-mac-ops-open-listener.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/agent-mac-ops-open-listener.log</string>
</dict>
</plist>
PEOF

# Modern bootstrap instead of legacy load/unload: bootout clears any stale
# registration, enable clears a disabled override, bootstrap loads + RunAtLoad starts
# it, kickstart is belt-and-suspenders. Legacy `launchctl load` could leave the job
# loaded-but-never-started (runs=0) after repeated load/unload churn.
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

sleep 0.3
if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running'; then
  echo "installed $LABEL — running on 127.0.0.1:$PORT; log: ~/Library/Logs/agent-mac-ops-open-listener.log"
else
  echo "installed $LABEL but it is NOT running — check ~/Library/Logs/agent-mac-ops-open-listener.log" >&2
fi
