#!/bin/bash
# Stop the remote dev stack cleanly WITHOUT killing the tmux session or closing
# your terminal window. Sends SIGTERM to the `bun scripts/dev.ts` multiplexer so
# its own shutdown reaps every child (api/web/worker/wrangler/workerd/inngest/
# studio/…) and the pane simply drops back to a shell. Runs ON the remote (shipped
# over SSH by remote-run.sh). Falls back to a targeted sweep for orphaned services.
#
# Why not just send `q`? `q` reaches dev.ts the same way, but driving it via the
# keyboard from a -CC session can take the iTerm window down with it. Signalling
# the process is window-safe.
#
# Assumes ONE dev stack on the box (single-user dev machine). The targeted sweep
# at the end would also catch a second worktree's `next dev`/`workerd` — fine here,
# but worth knowing if you ever run two stacks at once.
set -uo pipefail

SESSION="${TMUX_SESSION:-dev}"
PATTERNS=("next dev" "wrangler dev" "workerd" "inngest-cli" "sanity dev")

reaped=0
pids="$(pgrep -f 'scripts/dev\.ts' || true)"
if [ -n "$pids" ]; then
  echo "stopping bun dev (scripts/dev.ts): $(echo "$pids" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  # dev.ts SIGTERMs its children, waits ~3s, SIGKILLs survivors, then exits.
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 1
    pgrep -f 'scripts/dev\.ts' >/dev/null 2>&1 || { reaped=1; break; }
  done
  if [ "$reaped" = 1 ]; then
    echo "  ✅ dev.ts exited cleanly"
  else
    echo "  ⚠️ dev.ts still up after 8s — force-killing"
    pkill -KILL -f 'scripts/dev\.ts' 2>/dev/null || true
  fi
else
  echo "no bun dev (scripts/dev.ts) running"
fi

# Sweep any service that escaped dev.ts's own reap (e.g. a workerd reparented to
# init after an abrupt earlier exit). A no-op after a clean shutdown.
strays=""
for pat in "${PATTERNS[@]}"; do
  pgrep -f "$pat" >/dev/null 2>&1 && strays="$strays $pat"
done
if [ -n "$strays" ]; then
  echo "sweeping orphaned services:$strays"
  for pat in "${PATTERNS[@]}"; do pkill -TERM -f "$pat" 2>/dev/null || true; done
  sleep 2
  for pat in "${PATTERNS[@]}"; do pkill -KILL -f "$pat" 2>/dev/null || true; done
fi

# Report what (if anything) still holds the common dev ports.
held="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E ':(3000|3001|8484|8787|8791|8288|3333)\b' || true)"
if [ -n "$held" ]; then
  echo "⚠️ ports still bound:"; echo "$held"
else
  echo "dev ports released"
fi

echo "done — tmux session '$SESSION' left intact; reconnect with your alias."
