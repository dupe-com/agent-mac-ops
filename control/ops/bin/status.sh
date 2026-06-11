#!/bin/bash
# Health probe for your always-on Mac. Runs ON the remote (shipped over SSH by
# remote-run.sh, which prepends WORK_DIR/TMUX_SESSION). Plain text, one fact per
# line, always exits 0 (report, don't fail). ⚠️ marks unambiguously-bad signals
# only — so a daily digest stays green unless action is genuinely needed.
SESSION="${TMUX_SESSION:-dev}"
WORK_DIR="${WORK_DIR:-~}"; WORK_DIR="${WORK_DIR/#\~/$HOME}"

echo "host: $(hostname -s)   $(date '+%F %T %Z')"
echo "uptime:$(uptime | sed 's/.*up //; s/, [0-9]* user.*//')"
echo "load:  $(uptime | sed -E 's/.*load averages?: //')"

# Disk — the one thing that silently kills an always-on host.
disk=$(df -h / | awk 'NR==2{print $5" used ("$4" free)"}')
pct=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
flag=""; [ "${pct:-0}" -ge 85 ] && flag="  ⚠️ LOW"
echo "disk:  $disk$flag"

# Persistent dev session (informational — you may not always want it up).
tmux has-session -t "$SESSION" 2>/dev/null \
  && echo "tmux:  $SESSION up ($(tmux list-windows -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ') windows)" \
  || echo "tmux:  $SESSION down"

# Repo state, if WORK_DIR is a git checkout (informational).
if [ -d "$WORK_DIR/.git" ]; then
  cd "$WORK_DIR" || exit 0
  echo "repo:  $(git branch --show-current 2>/dev/null) | $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') dirty files"
fi

# Optional: drop an executable ~/.agent-mac-ops/health-hook.sh on the remote for
# project-specific checks (services, queues, GPU temp…). Its output is appended.
hook="$HOME/.agent-mac-ops/health-hook.sh"
[ -x "$hook" ] && { echo "--- health-hook ---"; "$hook"; }

exit 0   # always report, never fail — daily-check.sh treats nonzero as "unreachable"
