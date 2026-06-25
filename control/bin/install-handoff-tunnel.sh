#!/bin/bash
# Install/refresh the SELF-HEALING handoff reverse tunnel on THIS control Mac
# (macOS launchd). It runs handoff-tunnel.sh, which re-dials the reverse tunnel
# `-R $HANDOFF_PORT:localhost:$HANDOFF_PORT` to the remote forever, so the remote's
# localhost:$HANDOFF_PORT ALWAYS reaches the open-listener here — no matter how (or
# whether) you connected your session. This is what makes `code-<alias>` and the
# browser handoff keep working after the laptop sleeps, the network blips, or the
# remote reboots: the loop re-dials, which no ControlPersist value can do (a
# dead/slept connection is gone, not persisted).
#
# The reverse tunnel is owned EXCLUSIVELY here; the session master (`_amo_master` in
# shell-snippet.sh) carries only the -L dev-server forwards, so the two never collide
# on the remote's :$HANDOFF_PORT bind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"
HOST="${REMOTE_HOST:?REMOTE_HOST not set — run ./setup.sh}"
PORT="${HANDOFF_PORT:-17999}"
LABEL="com.agent-mac-ops.handoff-tunnel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNNER="$ROOT/control/bin/handoff-tunnel.sh"
LOG="$HOME/Library/Logs/agent-mac-ops-handoff-tunnel.log"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod +x "$RUNNER"

cat > "$PLIST" <<PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$RUNNER</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PEOF

# A pre-existing ControlPersist session master from the old -R-on-the-master design
# may still hold the remote's :$PORT and block this tunnel's bind. Best-effort release
# it; your next `$HOST` reopens the master forwardless-of-:$PORT.
ssh -o ControlPath="$HOME/.ssh/cm-%r@%h:%p" -O exit "$HOST" 2>/dev/null || true

# Modern launchctl (bootout/bootstrap/kickstart). The legacy load/unload pair can
# silently refuse to (re)start a job after repeated reloads; bootstrap + an explicit
# kickstart -k make a refresh deterministic — it's always running when this returns.
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
echo "installed $LABEL — re-dialing reverse tunnel -R $PORT:localhost:$PORT → $HOST"
echo "  log: $LOG"
echo "  stop/disable: launchctl bootout $DOMAIN/$LABEL"
