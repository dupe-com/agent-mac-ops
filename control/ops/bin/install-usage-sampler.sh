#!/bin/bash
# Install/refresh the 5-minute usage sampler ON the remote (a LaunchAgent for the
# SSH user). Copies usage-sample.sh to ~/.agent-mac-ops/ there and loads it.
# Output: ~/Library/Logs/agent-mac-ops-usage.csv on the remote (read it with usage-report.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/config.env"
LABEL="com.agent-mac-ops.usage"
INTERVAL="${USAGE_INTERVAL:-300}"

ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes "$REMOTE_HOST" \
  "mkdir -p ~/.agent-mac-ops ~/Library/LaunchAgents ~/Library/Logs && cat > ~/.agent-mac-ops/usage-sample.sh && chmod +x ~/.agent-mac-ops/usage-sample.sh" \
  < "$ROOT/control/ops/bin/usage-sample.sh"

ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes "$REMOTE_HOST" "bash -s" <<REOF
set -e
PLIST="\$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "\$PLIST" <<PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>\$HOME/.agent-mac-ops/usage-sample.sh</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>\$HOME/Library/Logs/agent-mac-ops-usage.err</string>
</dict>
</plist>
PEOF
launchctl bootout gui/\$(id -u)/$LABEL 2>/dev/null || true
launchctl bootstrap gui/\$(id -u) "\$PLIST"
echo "installed $LABEL on \$(hostname -s) — every ${INTERVAL}s; csv: ~/Library/Logs/agent-mac-ops-usage.csv"
REOF
