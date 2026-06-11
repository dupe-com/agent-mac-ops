#!/bin/bash
# Scheduled health check (control machine): probe the remote, post a digest to a
# webhook if one is configured, always log. Run by launchd (see install-launchd.sh)
# or by hand. Sources config.env from the repo so it works outside an interactive shell.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/config.env"
LOG="$HOME/Library/Logs/agent-mac-ops-check.log"
stamp() { date '+%F %T'; }

report="$("$ROOT/control/ops/bin/remote-run.sh" status.sh 2>&1)"; rc=$?

if [ $rc -ne 0 ] || [ -z "$report" ]; then
  report="❌ could not reach $REMOTE_HOST over SSH (rc=$rc)
$report"
  emoji="🚨"
elif printf '%s' "$report" | grep -q "⚠️"; then
  emoji="⚠️"
else
  emoji="✅"
fi

{ echo "[$(stamp)] check rc=$rc"; echo "$report"; } >> "$LOG"

if [ -n "${NOTIFY_WEBHOOK:-}" ]; then
  text="$emoji *agent-mac-ops* — $REMOTE_HOST — $(stamp)
\`\`\`
$report
\`\`\`"
  payload=$(KEY="${NOTIFY_KEY:-text}" python3 -c 'import json,os,sys; print(json.dumps({os.environ["KEY"]: sys.stdin.read()}))' <<<"$text")
  if curl -sf --max-time 10 -X POST -H 'Content-type: application/json' -d "$payload" "$NOTIFY_WEBHOOK" >/dev/null; then
    echo "[$(stamp)] posted to webhook" >> "$LOG"
  else
    echo "[$(stamp)] WEBHOOK POST FAILED" >> "$LOG"
  fi
else
  echo "[$(stamp)] no NOTIFY_WEBHOOK set — logged only" >> "$LOG"
fi
