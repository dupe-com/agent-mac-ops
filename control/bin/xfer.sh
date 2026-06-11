#!/bin/bash
# <alias>-push / <alias>-pull — move files between this Mac and the remote without
# typing the host (REMOTE_HOST comes from config.env). Thin rsync wrapper:
# -a archive, -v verbose, -z compress, -P progress + resume partial transfers.
#
#   <alias>-push <path...> [remote-dest]   # 1 path → remote home; else last arg = dest
#   <alias>-pull <remote-path...> [local-dest]   # 1 path → cwd; else last arg = dest
#
# Directory semantics are rsync's: a trailing slash on a source copies its CONTENTS,
# no slash copies the dir itself. Paths pass through exactly as you type them.
#
#   studio-push ~/Downloads/report.json          # → remote ~/report.json
#   studio-push ./dist  ~/deploys/               # → remote ~/deploys/dist/
#   studio-pull ~/Work/app/out.csv               # → ./out.csv
#   studio-pull '~/logs/*.log'  ./logs/          # quote globs so the REMOTE expands them
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"

mode="${1:-}"; shift || true
[ "$mode" = push ] || [ "$mode" = pull ] || { echo "usage: xfer.sh <push|pull> <path...> [dest]" >&2; exit 1; }
[ $# -ge 1 ] || { echo "xfer: need at least one path" >&2; exit 1; }

if [ "$mode" = push ]; then
  if [ $# -ge 2 ]; then dest="${@: -1}"; set -- "${@:1:$(($#-1))}"; else dest=""; fi
  exec rsync -avzP "$@" "$REMOTE_HOST:$dest"
else
  if [ $# -ge 2 ]; then dest="${@: -1}"; set -- "${@:1:$(($#-1))}"; else dest="."; fi
  srcs=(); for s in "$@"; do srcs+=("$REMOTE_HOST:$s"); done
  exec rsync -avzP "${srcs[@]}" "$dest"
fi
