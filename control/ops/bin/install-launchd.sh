#!/bin/bash
# Install/refresh the daily health check on THIS control machine (macOS launchd).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/config.env"
HOUR="${CHECK_HOUR:-9}"; MIN="${CHECK_MIN:-0}"
LABEL="com.agent-mac-ops.check"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
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
    <string>$ROOT/control/ops/bin/daily-check.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>$MIN</integer></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/agent-mac-ops-check.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/agent-mac-ops-check.log</string>
</dict>
</plist>
PEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "installed $LABEL — daily at $(printf '%02d:%02d' "$HOUR" "$MIN"); log: ~/Library/Logs/agent-mac-ops-check.log"
