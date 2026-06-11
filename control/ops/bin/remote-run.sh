#!/bin/bash
# Ship a health script to the remote over SSH, prefixed with config so the remote
# scripts know WORK_DIR / TMUX_SESSION / EXTRA_LOG without anything being installed
# on the remote. The remote stays stateless except for ~/dev-session.sh.
#
#   usage: bin/remote-run.sh <status.sh|logs.sh|revive.sh|stop-dev.sh>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/config.env"

script="${1:?usage: remote-run.sh <status.sh|logs.sh|revive.sh|stop-dev.sh>}"
src="$ROOT/control/ops/bin/$script"
[ -f "$src" ] || { echo "no such script: $script" >&2; exit 1; }

{
  printf 'export WORK_DIR=%q TMUX_SESSION=%q EXTRA_LOG=%q\n' \
    "${WORK_DIR:-~}" "${TMUX_SESSION:-dev}" "${EXTRA_LOG:-}"
  cat "$src"
} | ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" 'bash -s'
