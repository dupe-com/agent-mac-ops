#!/bin/bash
# Optional two-way sync of Claude session files between THIS Mac and the remote.
# Off by default and per user: nothing runs until you `install`, and nothing syncs
# until you `start`. Full guide: docs/CLAUDE-SYNC.md.
#
#   claude-sync.sh plan              read-only: sizes, and what the first merge would do
#   claude-sync.sh backup            copy-on-write snapshot of every synced folder, both Macs
#   claude-sync.sh install [--yes]   install Syncthing (asks first), pair, add folders PAUSED
#   claude-sync.sh start   [--yes]   un-pause: the first real sync (needs a backup from today)
#   claude-sync.sh pause             stop syncing, keep everything installed
#   claude-sync.sh status            both sides: connection, how far behind, conflict copies
#   claude-sync.sh conflicts [--park]  list conflict copies; --park moves them aside
#   claude-sync.sh uninstall         stop and remove the services; keeps all files
#
# Settings (config.env): CLAUDE_SYNC_FOLDERS, CLAUDE_SYNC_PORT. See config.env.example.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1

FOLDERS="${CLAUDE_SYNC_FOLDERS:-~/.claude/projects ~/.claude/handoffs}"
PORT="${CLAUDE_SYNC_PORT:-22000}"
NODE_SRC="$ROOT/remote/claude-sync-node.sh"
NODE="$HOME/.agent-mac-ops/claude-sync-node.sh"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes "$REMOTE_HOST")
YES=0; for a in "$@"; do [ "$a" = "--yes" ] && YES=1; done

die() { echo "claude-sync: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
lnode() { bash "$NODE" "$@"; }
rnode() { "${SSH[@]}" "bash ~/.agent-mac-ops/claude-sync-node.sh $(printf '%q ' "$@")"; }
confirm() {
  [ $YES = 1 ] && return 0
  local r; read -r -p "$1 [y/N] " r </dev/tty; [ "$r" = y ] || [ "$r" = Y ]
}

# Copy the per-Mac script to ~/.agent-mac-ops/ on both sides (the remote copy is
# also what status.sh calls).
push_node() {
  mkdir -p "$HOME/.agent-mac-ops" && install -m 755 "$NODE_SRC" "$NODE" || die "could not copy node script locally"
  "${SSH[@]}" "mkdir -p ~/.agent-mac-ops && cat > ~/.agent-mac-ops/claude-sync-node.sh && chmod 755 ~/.agent-mac-ops/claude-sync-node.sh" \
    < "$NODE_SRC" || die "could not copy node script to $REMOTE_HOST"
}

remote_dns() { ssh -G "$REMOTE_HOST" 2>/dev/null | awk '/^hostname /{print $2; exit}'; }
human() { awk -v b="$1" 'BEGIN{ split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5){b/=1024;i++}; printf (i==1?"%d %s":"%.1f %s"), b, u[i] }'; }

cmd_plan() {
  push_node
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  local out="$HOME/.claude-sync/plan-$stamp"; mkdir -p "$out"; chmod 700 "$HOME/.claude-sync"
  local f id L R tot_in_local=0 tot_in_remote=0
  for f in $FOLDERS; do
    id=$(lnode folder-id "$f")
    say "$f  ($id)"
    L="$out/$id.local.tsv"; R="$out/$id.remote.tsv"
    lnode manifest "$f" > "$L"
    rnode manifest "$f" > "$R" || die "remote manifest failed for $f"
    # only-here / only-there / on both but different
    # FILENAME, not NR==FNR: the latter breaks when the first file is empty.
    awk -F'\t' 'FILENAME==ARGV[1]{r[$1]=$2"\t"$3; next} !($1 in r){print > "/dev/stderr"; next} r[$1]!=$2"\t"$3{print $1}' \
      "$R" "$L" > "$out/$id.differ.txt" 2> "$out/$id.only-local.tsv"
    awk -F'\t' 'FILENAME==ARGV[1]{l[$1]=1; next} !($1 in l)' "$L" "$R" > "$out/$id.only-remote.tsv"
    local nL nR oL oR bL bR nD same=0 diff=0
    nL=$(wc -l < "$L" | tr -d ' '); nR=$(wc -l < "$R" | tr -d ' ')
    oL=$(wc -l < "$out/$id.only-local.tsv" | tr -d ' '); oR=$(wc -l < "$out/$id.only-remote.tsv" | tr -d ' ')
    bL=$(awk -F'\t' '{s+=$2} END{print s+0}' "$out/$id.only-local.tsv")
    bR=$(awk -F'\t' '{s+=$2} END{print s+0}' "$out/$id.only-remote.tsv")
    nD=$(wc -l < "$out/$id.differ.txt" | tr -d ' ')
    if [ "$nD" -gt 0 ]; then
      # Same path, different size or time: compare content. Same content merges
      # quietly; different content becomes a conflict copy on the first sync.
      lnode hash "$f" < "$out/$id.differ.txt" | sort > "$out/$id.hash.local"
      "${SSH[@]}" "bash ~/.agent-mac-ops/claude-sync-node.sh hash $(printf '%q' "$f")" < "$out/$id.differ.txt" | sort > "$out/$id.hash.remote"
      join -t $'\t' "$out/$id.hash.local" "$out/$id.hash.remote" | awk -F'\t' '$2!=$3{print $1}' > "$out/$id.conflicts.txt"
      diff=$(wc -l < "$out/$id.conflicts.txt" | tr -d ' '); same=$((nD - diff))
    fi
    tot_in_local=$((tot_in_local + bR)); tot_in_remote=$((tot_in_remote + bL))
    echo "files carried: here $nL, $REMOTE_HOST $nR"
    echo "only here:     $oL files, $(human "$bL") (will be copied to $REMOTE_HOST)"
    echo "only there:    $oR files, $(human "$bR") (will be copied here)"
    echo "on both, same path but different size/time: $nD ($same identical content, $diff really different)"
    if [ "${diff:-0}" -gt 0 ]; then
      echo "  these $diff will produce conflict copies on the first sync (list: $out/$id.conflicts.txt):"
      head -5 "$out/$id.conflicts.txt" | sed 's#^#    #'
    fi
  done
  say "disk"
  echo "here:        $(df -h "$HOME" | awk 'NR==2{print $4" free ("$5" used)"}'), will receive $(human $tot_in_local)"
  echo "$REMOTE_HOST: $("${SSH[@]}" 'df -h ~' | awk 'NR==2{print $4" free ("$5" used)"}'), will receive $(human $tot_in_remote)"
  echo; echo "nothing was changed. full lists: $out"
}

cmd_backup() {
  push_node
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  say "backup on this Mac"; lnode backup "$stamp" $FOLDERS || die "local backup failed"
  say "backup on $REMOTE_HOST"; rnode backup "$stamp" $FOLDERS || die "remote backup failed"
  echo; echo "snapshots: ~/.claude-sync/backup-$stamp on both Macs (APFS clones: they use almost no extra disk until files change)"
}

cmd_install() {
  push_node
  local here there
  here=$(lnode installed); there=$(rnode installed) || die "cannot reach $REMOTE_HOST"
  if [ "$here" != yes ]; then confirm "Install Syncthing on this Mac with Homebrew?" || die "cancelled"; brew install syncthing || die "brew install failed"; fi
  if [ "$there" != yes ]; then
    confirm "Install Syncthing on $REMOTE_HOST with Homebrew?" || die "cancelled"
    "${SSH[@]}" 'HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew install syncthing' || die "remote brew install failed"
  fi
  say "starting the service on this Mac"
  local lout rout lid rid dns
  lout=$(lnode setup "$PORT") || die "local setup failed"; echo "$lout"
  say "starting the service on $REMOTE_HOST"
  rout=$(rnode setup "$PORT") || die "remote setup failed"; echo "$rout"
  lid=$(awk '/^device-id /{print $2}' <<<"$lout"); rid=$(awk '/^device-id /{print $2}' <<<"$rout")
  [ -n "$lid" ] && [ -n "$rid" ] || die "could not read device IDs"
  dns=$(remote_dns); [ -n "$dns" ] || die "could not resolve the HostName of $REMOTE_HOST from ssh config"
  say "pairing (static address only; discovery and relays are off)"
  lnode pair "$rid" "$REMOTE_HOST" "tcp://$dns:$PORT" || die "pair failed"
  # The laptop normally dials the remote. Giving the remote the laptop's Tailscale
  # name as well lets it dial back after the laptop wakes.
  local ts lts laddr=dynamic
  ts=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
  lts=$("$ts" status --self --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
  [ -n "$lts" ] && laddr="tcp://$lts:$PORT"
  rnode pair "$lid" "$(scutil --get LocalHostName 2>/dev/null || hostname -s)" "$laddr" || die "remote pair failed"
  say "folders (new ones start paused)"
  local f
  for f in $FOLDERS; do lnode folder "$f" "$rid" || die "folder $f failed"; rnode folder "$f" "$lid" || die "remote folder $f failed"; done
  echo; echo "installed. Folders that were already syncing keep syncing. New ones stay paused until: claude-sync.sh plan, backup, start."
}

cmd_start() {
  local today; today=$(date +%Y%m%d)
  ls -d "$HOME/.claude-sync/backup-$today"* >/dev/null 2>&1 || die "no backup from today on this Mac. Run: claude-sync.sh backup"
  "${SSH[@]}" "ls -d ~/.claude-sync/backup-$today*" >/dev/null 2>&1 || die "no backup from today on $REMOTE_HOST. Run: claude-sync.sh backup"
  confirm "Start syncing (the first run merges both sides; nothing is deleted, differing files become conflict copies)?" || die "cancelled"

  # Safety gate. Keep the Macs from talking, let each one scan with the real
  # .stignore rules, and compare with the dry run's count before any file moves.
  say "scanning with the Macs kept apart"
  lnode peers-paused true && rnode peers-paused true || die "could not pause the peers"
  lnode resume && rnode resume || die "could not resume folders"
  local f want ok=1
  for f in $FOLDERS; do
    want=$(lnode manifest "$f" | wc -l | tr -d ' '); lnode scan-check "$f" "$want" || ok=0
    want=$(rnode manifest "$f" | wc -l | tr -d ' '); rnode scan-check "$f" "$want" || ok=0
  done
  if [ $ok != 1 ]; then
    lnode pause; rnode pause
    die "the ignore rules do not match the dry run; folders paused again and nothing was synced"
  fi
  say "counts match; letting the Macs talk"
  lnode peers-paused false && rnode peers-paused false
}

cmd_status() {
  say "this Mac ($(hostname -s))"; lnode status
  say "$REMOTE_HOST"; rnode status 2>/dev/null || echo "unreachable"
}

case "${1:-}" in
  plan)      cmd_plan ;;
  backup)    cmd_backup ;;
  install)   cmd_install ;;
  start)     cmd_start ;;
  pause)     lnode pause; rnode pause ;;
  status)    cmd_status ;;
  conflicts) shift; say "this Mac"; lnode conflicts "$@"; say "$REMOTE_HOST"; rnode conflicts "$@" ;;
  uninstall) lnode uninstall; rnode uninstall ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
