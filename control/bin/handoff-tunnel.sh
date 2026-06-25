#!/bin/bash
# Re-dialing keeper for the handoff REVERSE TUNNEL. Run under launchd by
# install-handoff-tunnel.sh; not meant to be run by hand. Holds
# `-R $HANDOFF_PORT:localhost:$HANDOFF_PORT` open to the remote so the remote's
# localhost:$HANDOFF_PORT ALWAYS reaches the open-listener on this Mac — which is what
# keeps `code-<alias>` and the browser handoff working no matter how (or whether) you
# connected your session.
#
# Why a loop instead of leaning on launchd KeepAlive alone: a foreground ssh exits on
# every network drop, laptop sleep/wake, or remote reboot. launchd KeepAlive *can*
# respawn it, but its throttle/respawn timing is fiddly (an externally-killed job can
# sit dead for far longer than ThrottleInterval). This `while` loop re-dials ~5s after
# ANY exit, deterministically — the classic autossh pattern. launchd then only has to
# keep THIS loop alive, which it does reliably.
#
# Owns the reverse tunnel EXCLUSIVELY: the session master (`_amo_master` in
# shell-snippet.sh) carries only the -L dev-server forwards, so the two never collide
# on the remote's :$HANDOFF_PORT bind. Dedicated connection (ControlMaster=no,
# ControlPath=none) so it never touches the shared session master or box-fwd.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"
PORT="${HANDOFF_PORT:-17999}"
HOST="${REMOTE_HOST:?REMOTE_HOST not set — run ./setup.sh}"

while :; do
  # BatchMode      never block on a prompt (would wedge the agent forever)
  # ExitOnForward  if :$PORT can't bind (a stale forward still held remote-side), exit
  #                fast and let the loop retry rather than sit up with a dead tunnel
  # ServerAlive*   notice a silently-dead link in ~60s → exit → re-dial
  # ConnectTimeout fail fast when the remote is unreachable (e.g. foreign network)
  ssh -NT \
    -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none \
    -R "${PORT}:localhost:${PORT}" "$HOST" || true
  sleep 5
done
