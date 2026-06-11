#!/bin/bash
# Recent activity on the remote. Runs ON the remote (shipped over SSH by remote-run.sh).
SESSION="${TMUX_SESSION:-dev}"

echo "=== $SESSION session recent output (last 25 lines) ==="
tmux capture-pane -p -t "$SESSION" -S -25 2>/dev/null || echo "(no $SESSION tmux session)"

echo "=== agent-mac-ops daily-check log (last 5) ==="
tail -5 "$HOME/Library/Logs/agent-mac-ops-check.log" 2>/dev/null || echo "(none)"

if [ -n "${EXTRA_LOG:-}" ]; then
  echo "=== $EXTRA_LOG (last 15) ==="
  tail -15 "$EXTRA_LOG" 2>/dev/null || echo "(none)"
fi
