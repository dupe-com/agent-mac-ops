#!/bin/bash
# Interactive port manager for THIS Mac. Lists every TCP port something is
# LISTENing on, shows who owns it, and lets you kill the holder — handy for
# clearing a stale dev server or an orphaned SSH tunnel before `bun dev`.
#
#   ports              fzf picker of all listening ports (Tab = multi-select,
#                      Enter = kill the selected processes, Esc = cancel)
#   ports 3000         target one port directly: show its holder, offer to kill
#   ports 3000 8080    target several ports at once
#
# Kill is a graceful SIGTERM; if the process is still listening ~1.5s later you're
# offered an escalation to SIGKILL. Root-owned holders print a sudo hint.
#
# Self-contained: no config, no remote — purely local lsof + kill.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --- collect listening TCP sockets → "PORT<tab>PID<tab>USER<tab>COMMAND", deduped ---
# -FpcLn = field output: p(pid) c(command) L(login) n(host:port). Robust against
# spaces/odd chars that trip column-position parsing of plain `lsof`.
collect() {
  lsof -nP -iTCP -sTCP:LISTEN -FpcLn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2); next }
    /^c/ { cmd = substr($0, 2); next }
    /^L/ { usr = substr($0, 2); next }
    /^n/ {
      name = substr($0, 2)
      port = name; sub(/.*:/, "", port)        # after the last colon
      if (port !~ /^[0-9]+$/) next
      key = port SUBSEP pid
      if (seen[key]++) next
      printf "%s\t%s\t%s\t%s\n", port, pid, usr, cmd
    }
  ' | sort -t$'\t' -k1,1n -k2,2n
}

# --- pretty one-line-per-row, columns the picker shows (PORT PID USER COMMAND) ---
rows() {
  collect | awk -F'\t' '{ printf "%-6s  %-8s  %-10s  %s\n", $1, $2, $3, $4 }'
}

# --- preview pane: full detail for one PID (invoked by fzf) ---
preview() {
  local pid="$1"
  [ -z "$pid" ] && { echo "(no selection)"; return; }
  if ! ps -p "$pid" >/dev/null 2>&1; then echo "PID $pid is gone."; return; fi
  echo "PID $pid"
  ps -p "$pid" -o user=,%cpu=,%mem=,etime=,lstart= 2>/dev/null \
    | awk '{ printf "  user=%s  cpu=%s%%  mem=%s%%  uptime=%s\n  started=%s %s %s %s %s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9 }'
  echo
  echo "command:"
  ps -p "$pid" -o command= 2>/dev/null | fold -s -w 76 | sed 's/^/  /'
  echo
  echo "listening on:"
  lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" -Fn 2>/dev/null \
    | awk '/^n/ { print "  " substr($0,2) }' | sort -u
}

# --- kill a set of PIDs: confirm, SIGTERM, then optional SIGKILL escalation ---
kill_pids() {
  local pids=("$@")
  [ ${#pids[@]} -eq 0 ] && { echo "Nothing selected."; return; }

  echo "About to terminate:"
  local p
  for p in "${pids[@]}"; do
    ps -p "$p" >/dev/null 2>&1 || continue
    printf "  PID %-8s %s\n" "$p" "$(ps -p "$p" -o command= 2>/dev/null | cut -c1-70)"
  done
  printf "Kill these? [y/N] "
  local ans; read -r ans
  case "$ans" in [yY]*) ;; *) echo "Aborted."; return ;; esac

  local survivors=()
  for p in "${pids[@]}"; do
    ps -p "$p" >/dev/null 2>&1 || continue
    if kill -TERM "$p" 2>/dev/null; then
      echo "→ SIGTERM $p"
    else
      echo "✕ couldn't signal $p — try: sudo kill $p" >&2
    fi
  done

  sleep 1.5
  for p in "${pids[@]}"; do
    ps -p "$p" >/dev/null 2>&1 && survivors+=("$p")
  done

  if [ ${#survivors[@]} -gt 0 ]; then
    echo "Still alive: ${survivors[*]}"
    printf "Force kill (SIGKILL)? [y/N] "
    read -r ans
    case "$ans" in
      [yY]*)
        for p in "${survivors[@]}"; do
          kill -9 "$p" 2>/dev/null && echo "→ SIGKILL $p" || echo "✕ SIGKILL $p failed — try: sudo kill -9 $p" >&2
        done ;;
      *) echo "Left running." ;;
    esac
  else
    echo "✓ all cleared."
  fi
}

case "${1:-}" in
  # internal: fzf preview callback
  __preview) shift; preview "${1:-}"; exit 0 ;;
esac

# --- direct mode: `ports 3000 [8080 ...]` ---
if [ $# -gt 0 ]; then
  for a in "$@"; do
    case "$a" in (*[!0-9]*) echo "not a port: $a" >&2; exit 1 ;; esac
  done
  pids=()
  while IFS= read -r p; do [ -n "$p" ] && pids+=("$p"); done < <(
    collect | awk -F'\t' -v want=" $* " '{ if (index(want, " " $1 " ")) print $2 }' | sort -un)
  if [ ${#pids[@]} -eq 0 ]; then
    echo "Nothing is listening on: $*"
    exit 0
  fi
  echo "Listeners on $*:"
  collect | awk -F'\t' -v want=" $* " '
    index(want, " " $1 " ") { printf "  %-6s  PID %-8s  %s\n", $1, $2, $4 }'
  echo
  kill_pids "${pids[@]}"
  exit 0
fi

# --- interactive mode ---
data="$(rows)"
if [ -z "$data" ]; then
  echo "No TCP ports are currently being listened on. 🎉"
  exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf not found — install it (brew install fzf) for the picker."
  echo "Listening ports:"
  echo "PORT    PID       USER        COMMAND"
  echo "$data"
  echo
  echo "Kill with: ports <port>"
  exit 0
fi

selected="$(printf '%s\n' "$data" | fzf \
  --multi \
  --reverse \
  --border=rounded \
  --border-label=' ports — open TCP listeners ' \
  --header=$'TAB: multi-select   ENTER: kill   ESC: cancel\nPORT    PID       USER        COMMAND' \
  --preview="$SELF __preview {2}" \
  --preview-window='down,45%,wrap,border-top' \
  --prompt='kill > ' || true)"

[ -z "$selected" ] && { echo "Cancelled."; exit 0; }

pids=()
while IFS= read -r p; do [ -n "$p" ] && pids+=("$p"); done < <(
  printf '%s\n' "$selected" | awk '{print $2}' | sort -un)
kill_pids "${pids[@]}"
