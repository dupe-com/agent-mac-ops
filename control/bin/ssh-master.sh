#!/bin/bash
# Own the shared SSH master to the remote: open it carrying the FORWARD_PORTS -L
# forwards, or — when one is already up — top up whatever forwards it's missing.
#
# Why the top-up exists: `ssh -O check` proves the master socket answers, nothing
# more. A ControlPersist master keeps the -L set it was BORN with for its whole
# life, so the dev-server forwards go missing whenever
#   • the master was opened by something that doesn't know FORWARD_PORTS — a
#     Ghostty split re-making a dead master, box-fwd's own master, a one-off
#     `ssh -L` run by hand; or
#   • FORWARD_PORTS changed and was re-rendered after the master came up.
# Either way `bun dev` runs fine on the remote while http://localhost:3000 hangs on
# the laptop — and every caller that only ran `-O check` reported success.
#
# `-O forward` adds forwards to a LIVE master, so this repairs it in place without
# dropping anyone's attached session.
#
#   ssh-master.sh        ensure master + forwards (quiet; safe to call often)
#   ssh-master.sh -v     ... and report what it opened or added
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
HOST="${REMOTE_HOST:-}"
[ -n "$HOST" ] || { echo "ssh-master: REMOTE_HOST not set — run ./setup.sh" >&2; exit 1; }
CP="$HOME/.ssh/cm-%r@%h:%p"

V=0; [ "${1:-}" = "-v" ] && V=1
say() { [ "$V" = 1 ] && printf '%s\n' "$*"; return 0; }

# Where each forward LANDS on the remote. `localhost` resolves ON THE REMOTE, to its
# own 127.0.0.1 -- which on a shared Mac is the ADMIN's slot-1 loopback, not yours.
# A provisioned teammate who leaves this at the default tunnels into the admin's dev
# servers while their own sit unreachable, and nothing reports it: the forward opens
# fine and something does answer on the other end. Set REMOTE_BIND to your own
# 127.0.0.<index>. Unset keeps single-user setups working exactly as before.
DEST="${REMOTE_BIND:-localhost}"

# Bind every forward on BOTH loopback families: macOS resolves `localhost` to ::1
# first, so a v4-only bind leaves `localhost:3000` hanging while 127.0.0.1:3000 works.
binds() { printf '127.0.0.1:%s:%s:%s\n[::1]:%s:%s:%s\n' "$1" "$DEST" "$1" "$1" "$DEST" "$1"; }

# --- no master yet → open one carrying the full forward set ---
if ! ssh -o ControlPath="$CP" -O check "$HOST" 2>/dev/null; then
  fwds=()
  for p in ${FORWARD_PORTS:-}; do
    while IFS= read -r b; do fwds+=(-L "$b"); done < <(binds "$p")
  done
  if ssh -o ControlMaster=yes -o ControlPath="$CP" -o ControlPersist=4h \
         -fNT ${fwds+"${fwds[@]}"} "$HOST" 2>/dev/null; then
    say "opened master → $HOST (forwards: ${FORWARD_PORTS:-none})"
    exit 0
  fi
  say "couldn't open master → $HOST"
  exit 1
fi

# --- master exists → reconcile its forwards with FORWARD_PORTS ---
# A port already LISTENing here is either forwarded or held by a local process;
# ssh can't rebind it either way, so skip it instead of asking and failing.
bound="$(lsof -nP -iTCP -sTCP:LISTEN -Fn 2>/dev/null | awk '/^n/{print substr($0,2)}' | sort -u)"
added=""
for p in ${FORWARD_PORTS:-}; do
  while IFS= read -r b; do
    lb="${b%%:"$DEST":*}"
    printf '%s\n' "$bound" | grep -Fqx "$lb" && continue
    ssh -o ControlPath="$CP" -O forward -L "$b" "$HOST" 2>/dev/null \
      && added="${added:+$added }$lb"
  done < <(binds "$p")
done

[ -n "$added" ] && say "topped up forwards: $added"
say "master up → $HOST"
exit 0
