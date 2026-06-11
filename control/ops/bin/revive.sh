#!/bin/bash
# Bring the remote's persistent dev session back. Safe/idempotent. Runs ON the
# remote (shipped over SSH by remote-run.sh).
SESSION="${TMUX_SESSION:-dev}"
WORK_DIR="${WORK_DIR:-~}"; WORK_DIR="${WORK_DIR/#\~/$HOME}"

echo "reviving $SESSION tmux session..."
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "  $SESSION already up — leaving it"
else
  tmux new-session -d -s "$SESSION" -c "$WORK_DIR" && echo "  created $SESSION at $WORK_DIR"
fi
