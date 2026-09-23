#!/bin/bash
# Bring the remote's persistent dev session back. Safe/idempotent. Runs ON the
# remote (shipped over SSH by remote-run.sh).
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH   # shipped as non-login `bash -s`: Homebrew tmux isn't on PATH otherwise
SESSION="${TMUX_SESSION:-dev}"
WORK_DIR="${WORK_DIR:-~}"; WORK_DIR="${WORK_DIR/#\~/$HOME}"

echo "reviving $SESSION tmux session..."
PERSIST="$HOME/.agent-mac-ops/tmux-persist.sh"
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "  $SESSION already up — leaving it"
elif [ -x "$PERSIST" ]; then
  "$PERSIST" ensure "$SESSION" "$WORK_DIR" && echo "  created $SESSION at $WORK_DIR (restored last saved windows if any)"
else
  tmux new-session -d -s "$SESSION" -c "$WORK_DIR" && echo "  created $SESSION at $WORK_DIR"
fi
