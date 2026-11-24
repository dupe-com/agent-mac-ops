#!/bin/bash
# claude-sync-node.sh: the per-Mac half of the optional Claude sync (docs/CLAUDE-SYNC.md).
#
# Runs on BOTH Macs, as the user who opted in. control/bin/claude-sync.sh copies it
# to ~/.agent-mac-ops/ on each side and drives it; status.sh on the remote calls
# `status --brief` when it is installed. It is not a template: nothing is rendered.
#
# What it manages, all under ~/.claude-sync (mode 700):
#   st/          Syncthing's config, keys and database for this user only
#   apikey       the API key (0600); run.sh hands it to Syncthing at start
#   gui.sock     Syncthing's API, on a unix socket instead of a TCP port, so other
#                users on a shared Mac cannot reach it and no loopback port is used
#   versions/    deleted or replaced files, kept 30 days (Syncthing "trashcan")
#   conflicts/   conflict copies moved aside by `conflicts --park`
#   backup-*/    copy-on-write snapshots taken by `backup`
#
# Network: global discovery, local discovery, relays and NAT traversal are all off.
# The only way two devices meet is the static address the control script pairs them
# with (the remote's Tailscale name), so transcripts never pass through a third party.
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

BASE="$HOME/.claude-sync"
ST_HOME="$BASE/st"
SOCK="$BASE/gui.sock"
KEYFILE="$BASE/apikey"
LABEL="com.agent-mac-ops.claude-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/agent-mac-ops-claude-sync.log"
PREFIX="claude-"   # every folder this script owns has an ID starting with this

die() { echo "claude-sync: $*" >&2; exit 1; }
expand() { local p="$1"; printf '%s' "${p/#\~/$HOME}"; }

# Folder ID for a path: the two Claude folders get fixed IDs, anything else is named
# after its last path component. Both Macs derive the same ID from the same setting.
folder_id() {
  # shellcheck disable=SC2088  # matching the literal "~/..." spelling from config.env
  case "$1" in
    "~/.claude/projects"|"$HOME/.claude/projects") echo "claude-projects" ;;
    "~/.claude/handoffs"|"$HOME/.claude/handoffs") echo "claude-handoffs" ;;
    *) echo "claude-x-$(basename "$1" | tr -c 'A-Za-z0-9._-\n' '-')" ;;
  esac
}

# The .stignore for each folder. Syncthing uses the first pattern that matches,
# `//` starts a comment, `!` means "do sync this", and (?d) lets Syncthing delete
# the file if it is the only thing blocking a directory delete.
ignores_for() {
  echo "// Managed by agent-mac-ops claude-sync. Reinstalling overwrites this file."
  echo "(?d).DS_Store"
  case "$1" in
    claude-projects)
      cat <<'EOF'
// <project>/memory is a symlink into iCloud Drive (dotfiles link-memory.sh).
// iCloud already shares it; never follow it, replace it or copy it twice.
// No (?d) here on purpose: tested, it lets Syncthing delete a real (not yet linked)
// memory folder with its notes when the project folder goes on the other Mac, and
// keeps no copy. A project folder holding memory therefore stays; status says so.
/*/memory
/*/memory.*
// Sessions started in temporary folders belong to the Mac they ran on.
/-private-*
/-tmp-*
EOF
      ;;
    claude-handoffs)
      cat <<'EOF'
/-private-*
/-tmp-*
// Only the handoff notes themselves. Anything else dropped into a handoff
// folder (work files, scripts, whole git checkouts) stays on its own Mac.
!/*/latest.md
!/*/archive-*.md
!/*/.picked-up
/*/*
EOF
      ;;
    *)
      printf '%s\n' ".git" "node_modules"
      ;;
  esac
}

# The same rules, applied to a file list (for the dry run). Reads relative paths
# like ./a/b on stdin, prints the ones the sync would carry.
filter_paths() {
  awk -v id="$1" '
    { p = substr($0, 3); n = split(p, c, "/") }
    c[n] == ".DS_Store" { next }
    p == ".stignore" || c[1] == ".stfolder" || c[1] == ".stversions" || c[n] ~ /^\.syncthing\..*\.tmp$/ { next }
    id == "claude-projects" {
      if (c[1] ~ /^-private-|^-tmp-/) next
      if (n >= 2 && (c[2] == "memory" || c[2] ~ /^memory\./)) next
      print; next
    }
    id == "claude-handoffs" {
      if (c[1] ~ /^-private-|^-tmp-/) next
      if (n == 1) { print; next }
      if (n == 2 && (c[2] == "latest.md" || c[2] ~ /^archive-.*\.md$/ || c[2] == ".picked-up")) print
      next
    }
    { for (i = 1; i <= n; i++) if (c[i] == ".git" || c[i] == "node_modules") next; print }
  '
}

have_st() { command -v syncthing >/dev/null 2>&1; }

api() {   # api METHOD PATH [JSON-BODY]
  local args=(-sS --fail --max-time 20 --unix-socket "$SOCK"
              -H "X-API-Key: $(cat "$KEYFILE" 2>/dev/null)" -X "$1")
  [ $# -ge 3 ] && args+=(-H 'Content-Type: application/json' --data "$3")
  curl "${args[@]}" "http://localhost$2"
}
up() { [ -S "$SOCK" ] && api GET /rest/system/ping >/dev/null 2>&1; }
my_id() { api GET /rest/system/status | jq -r .myID; }

launch_domain() {
  # gui/ needs someone logged in at the screen (true on an always-on Mac after the
  # FileVault unlock); fall back to user/, which loads over SSH alone.
  local d; d="gui/$(id -u)"
  launchctl print "$d" >/dev/null 2>&1 || d="user/$(id -u)"
  echo "$d"
}

cmd_setup() {   # setup <listen-port>
  local port="${1:?usage: setup <listen-port>}"
  have_st || die "syncthing is not installed on $(hostname -s) (brew install syncthing)"
  command -v jq >/dev/null || die "jq is not installed on $(hostname -s) (brew install jq)"
  mkdir -p "$BASE" "$BASE/versions" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  chmod 700 "$BASE"
  if [ ! -s "$KEYFILE" ]; then
    (umask 077; openssl rand -hex 24 > "$KEYFILE")
  fi

  # First run: generate keys and config, then switch every outward-facing feature
  # off in the file BEFORE Syncthing ever starts, so it never announces itself or
  # dials a relay, not even for the few seconds before the API call below.
  if [ ! -f "$ST_HOME/config.xml" ]; then
    syncthing generate --home="$ST_HOME" --no-port-probing >/dev/null \
      || die "syncthing generate failed"
    local cfg="$ST_HOME/config.xml"
    sed -i '' \
      -e "s#<listenAddress>[^<]*</listenAddress>#<listenAddress>tcp://0.0.0.0:${port}</listenAddress>#" \
      -e 's#<globalAnnounceEnabled>true<#<globalAnnounceEnabled>false<#' \
      -e 's#<localAnnounceEnabled>true<#<localAnnounceEnabled>false<#' \
      -e 's#<relaysEnabled>true<#<relaysEnabled>false<#' \
      -e 's#<natEnabled>true<#<natEnabled>false<#' \
      -e 's#<startBrowser>true<#<startBrowser>false<#' \
      -e 's#<crashReportingEnabled>true<#<crashReportingEnabled>false<#' \
      -e 's#<autoUpgradeIntervalH>[0-9]*<#<autoUpgradeIntervalH>0<#' \
      -e 's#<urAccepted>[-0-9]*<#<urAccepted>-1<#' \
      "$cfg"
    local k
    for k in globalAnnounceEnabled localAnnounceEnabled relaysEnabled natEnabled; do
      grep -q "<$k>false</$k>" "$cfg" || { rm -rf "$ST_HOME"; die "could not turn off $k in a fresh config; aborted before first start"; }
    done
    grep -q "<listenAddress>tcp://0.0.0.0:${port}</listenAddress>" "$cfg" \
      || { rm -rf "$ST_HOME"; die "could not set the listen port in a fresh config"; }
  fi

  # The wrapper keeps the API key out of the plist and pins the API to the socket.
  cat > "$BASE/run.sh" <<EOF
#!/bin/bash
export STGUIADDRESS="unix://$SOCK" STGUIAPIKEY="\$(cat "$KEYFILE")" STNOUPGRADE=1
rm -f "$SOCK"
exec "$(command -v syncthing)" serve --home="$ST_HOME" --no-browser --no-restart --log-file="$BASE/syncthing.log" --log-max-old-files=3
EOF
  chmod 700 "$BASE/run.sh"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$BASE/run.sh</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  local d; d=$(launch_domain)
  # bootout returns before the old job is gone, and bootstrapping too early fails
  # with "5: Input/output error". Wait for it to go, then retry a few times.
  launchctl bootout "$d/$LABEL" 2>/dev/null || true
  local _w
  for _w in $(seq 1 40); do launchctl print "$d/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
  launchctl enable "$d/$LABEL" 2>/dev/null || true
  for _w in 1 2 3 4 5; do
    launchctl bootstrap "$d" "$PLIST" 2>/dev/null && break
    [ "$_w" = 5 ] && die "launchctl bootstrap failed ($d)"
    sleep 1
  done

  local _
  for _ in $(seq 1 60); do up && break; sleep 0.5; done
  up || die "Syncthing did not answer on $SOCK within 30s; see $LOG and $BASE/syncthing.log"

  # Same settings again through the API: covers re-runs with a new port.
  api PATCH /rest/config/options "$(jq -cn --arg p "tcp://0.0.0.0:$port" '{
      listenAddresses: [$p], globalAnnounceEnabled: false, localAnnounceEnabled: false,
      relaysEnabled: false, natEnabled: false, startBrowser: false, urAccepted: -1,
      crashReportingEnabled: false, autoUpgradeIntervalH: 0, announceLANAddresses: false }')" >/dev/null \
    || die "could not apply options"
  echo "ready on $(hostname -s) ($d), listening on tcp port $port"
  echo "device-id $(my_id)"
}

cmd_pair() {   # pair <peer-id> <peer-name> <address|dynamic>
  up || die "not running"
  api PUT "/rest/config/devices/$1" "$(jq -cn --arg id "$1" --arg n "$2" --arg a "$3" \
    '{deviceID: $id, name: $n, addresses: [$a], autoAcceptFolders: false, introducer: false}')" >/dev/null \
    || die "could not add device $2"
  echo "paired with $2 ($3)"
}

cmd_folder() {   # folder <path> <peer-id>   (new folders start paused)
  up || die "not running"
  local path; path=$(expand "$1"); local id; id=$(folder_id "$1"); local peer="$2"
  mkdir -p "$path"
  ignores_for "$id" > "$path/.stignore"
  # Syncthing stops a folder whose .stfolder marker disappears. Claude Code's cleanup
  # seems to remove empty folders (there are none in ~/.claude/projects), so give the
  # marker a file to keep it non-empty.
  mkdir -p "$path/.stfolder"
  echo "Syncthing folder marker (agent-mac-ops claude-sync). Deleting it stops the sync." > "$path/.stfolder/README"
  mkdir -p "$BASE/versions/$id"
  local paused=true existing
  existing=$(api GET "/rest/config/folders/$id" 2>/dev/null) && paused=$(jq -r .paused <<<"$existing")
  api PUT "/rest/config/folders/$id" "$(jq -cn --arg id "$id" --arg p "$path" --arg me "$(my_id)" \
      --arg peer "$peer" --arg v "$BASE/versions/$id" --argjson paused "$paused" '{
      id: $id, label: $id, path: $p, type: "sendreceive", paused: $paused,
      devices: [{deviceID: $me}, {deviceID: $peer}],
      fsWatcherEnabled: true, fsWatcherDelayS: 3, rescanIntervalS: 600, maxConflicts: 10,
      versioning: {type: "trashcan", params: {cleanoutDays: "30"}, fsPath: $v, fsType: "basic",
                   cleanupIntervalS: 3600} }')" >/dev/null || die "could not add folder $id"
  echo "folder $id -> $path ($([ "$paused" = true ] && echo paused || echo active))"
}

our_folders() { api GET /rest/config/folders | jq -r --arg p "$PREFIX" '.[] | select(.id|startswith($p)) | "\(.id)\t\(.path)\t\(.paused)"'; }

peers_paused() {   # peers_paused true|false: pause or resume every paired device
  up || die "not running"
  local me d; me=$(my_id)
  for d in $(api GET /rest/config/devices | jq -r --arg me "$me" '.[] | select(.deviceID != $me) | .deviceID'); do
    api PATCH "/rest/config/devices/$d" "{\"paused\": $1}" >/dev/null || die "could not change device $d"
  done
  echo "other Mac $([ "$1" = true ] && echo paused || echo resumed) on $(hostname -s)"
}

# scan-check <path> <expected-files>: wait for the folder's first scan, then compare
# what Syncthing will share with what `manifest` (the dry run) counted. A mismatch
# means the .stignore rules and the dry run disagree, which must stop the first sync.
cmd_scan_check() {
  up || die "not running"
  local id; id=$(folder_id "$1"); local want="$2" st state _
  for _ in $(seq 1 360); do
    st=$(api GET "/rest/db/status?folder=$id") && state=$(jq -r .state <<<"$st")
    [ "$state" = idle ] && break
    sleep 5
  done
  [ "$state" = idle ] || { echo "MISMATCH $id: still '$state' after 30 minutes"; return 1; }
  local files links tol
  files=$(jq -r .localFiles <<<"$st"); links=$(jq -r .localSymlinks <<<"$st")
  tol=$(( want / 100 )); [ "$tol" -lt 5 ] && tol=5
  if [ "$links" -gt 0 ]; then echo "MISMATCH $id: Syncthing sees $links symlinks (expected 0; memory links must be ignored)"; return 1; fi
  if [ $(( files - want )) -gt "$tol" ] || [ $(( want - files )) -gt "$tol" ]; then
    echo "MISMATCH $id on $(hostname -s): Syncthing will share $files files, the dry run counted $want"; return 1
  fi
  echo "ok $id on $(hostname -s): $files files (dry run: $want), 0 symlinks"
}

set_paused() {
  up || die "not running"
  local id
  for id in $(our_folders | cut -f1); do
    api PATCH "/rest/config/folders/$id" "{\"paused\": $1}" >/dev/null || die "could not change $id"
    echo "$id $([ "$1" = true ] && echo paused || echo resumed)"
  done
}

conflict_files() {   # prints <folder-id>\t<absolute path> for each conflict copy
  local id path _p
  while IFS=$'\t' read -r id path _p; do
    [ -d "$path" ] || continue
    find "$path" -name '*.sync-conflict-*' -not -path "*/.stversions/*" 2>/dev/null | sed "s#^#$id	#"
  done < <(our_folders)
}

cmd_conflicts() {   # conflicts [--park]
  up || die "not running"
  local list; list=$(conflict_files)
  if [ -z "$list" ]; then echo "no conflict copies on $(hostname -s)"; return 0; fi
  echo "conflict copies on $(hostname -s):"
  echo "$list" | cut -f2 | sed 's#^#  #'
  [ "${1:-}" = "--park" ] || { echo "(re-run with --park to move them to $BASE/conflicts/)"; return 0; }
  local id f root rel
  while IFS=$'\t' read -r id f; do
    root=$(our_folders | awk -F'\t' -v i="$id" '$1==i{print $2}')
    rel="${f#"$root"/}"
    mkdir -p "$BASE/conflicts/$id/$(dirname -- "$rel")"
    mv "$f" "$BASE/conflicts/$id/$rel" && echo "parked $rel"
  done <<<"$list"
}

ago() { # seconds -> "5m", "3h", "2d"
  local s=$1
  if [ "$s" -lt 120 ]; then echo "${s}s"; elif [ "$s" -lt 7200 ]; then echo "$((s/60))m"
  elif [ "$s" -lt 172800 ]; then echo "$((s/3600))h"; else echo "$((s/86400))d"; fi
}

cmd_status() {   # status [--brief]   (always exits 0)
  local brief=0; [ "${1:-}" = "--brief" ] && brief=1
  if [ ! -f "$PLIST" ]; then
    [ $brief = 1 ] || echo "claude-sync is not installed for $(whoami) on $(hostname -s)"
    return 0
  fi
  if ! up; then
    echo "sync:  ⚠️ claude-sync is installed but not running (log: $LOG)"
    return 0
  fi
  local cfg conns stats now
  cfg=$(api GET /rest/config) || { echo "sync:  ⚠️ claude-sync API not answering"; return 0; }
  local me; me=$(my_id)
  conns=$(api GET /rest/system/connections)
  stats=$(api GET /rest/stats/device)
  now=$(date +%s)

  local peer_line="" peer_id peer_name connected last last_s
  while IFS=$'\t' read -r peer_id peer_name; do
    connected=$(jq -r --arg d "$peer_id" '.connections[$d].connected // false' <<<"$conns")
    if [ "$connected" = true ]; then
      peer_line="${peer_line}${peer_name} connected; "
    else
      last=$(jq -r --arg d "$peer_id" '.[$d].lastSeen // ""' <<<"$stats" \
        | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
      last_s=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$last" +%s 2>/dev/null || echo 0)
      if [ "$last_s" -gt 86400 ]; then
        peer_line="${peer_line}${peer_name} offline (last seen $(ago $((now - last_s))) ago); "
      else
        peer_line="${peer_line}${peer_name} never connected; "
      fi
    fi
  done < <(jq -r --arg me "$me" '.devices[] | select(.deviceID != $me) | "\(.deviceID)\t\(.name)"' <<<"$cfg")

  local problems="" summary="" id path paused st state need errs comp peer_need total=0 behind=0 waiting=0 npaused=0
  while IFS=$'\t' read -r id path paused; do
    total=$((total+1))
    if [ "$paused" = true ]; then npaused=$((npaused+1)); continue; fi
    st=$(api GET "/rest/db/status?folder=$id") || continue
    state=$(jq -r .state <<<"$st"); need=$(jq -r '.needFiles + .needDeletes' <<<"$st")
    [ "$state" = error ] && problems="${problems}sync:  ⚠️ folder $id: $(jq -r .error <<<"$st")
"
    # A folder deleted on the other Mac but still holding an ignored item (a memory
    # folder or link) is kept on purpose: report it plainly, warn on anything else.
    local fe kept
    fe=$(api GET "/rest/folder/errors?folder=$id&perpage=1000" 2>/dev/null || echo '{}')
    kept=$(jq '[.errors[]? | select(.error | test("contains ignored files"))] | length' <<<"$fe")
    errs=$(jq '[.errors[]? | select(.error | test("contains ignored files") | not)] | length' <<<"$fe")
    [ "${errs:-0}" -gt 0 ] && problems="${problems}sync:  ⚠️ folder $id: $errs files failed to sync (api /rest/folder/errors?folder=$id)
"
    [ "${kept:-0}" -gt 0 ] && problems="${problems}sync:  $kept folders in $id were deleted on the other Mac but kept here (they hold memory)
"
    behind=$((behind + need))
    while IFS=$'\t' read -r peer_id peer_name; do
      comp=$(api GET "/rest/db/completion?folder=$id&device=$peer_id") || continue
      peer_need=$(jq -r '.needItems + .needDeletes' <<<"$comp")
      waiting=$((waiting + peer_need))
    done < <(jq -r --arg me "$me" '.devices[] | select(.deviceID != $me) | "\(.deviceID)\t\(.name)"' <<<"$cfg")
    [ $brief = 1 ] || summary="${summary}  $id  ($path): $state, $need to fetch here, $peer_need waiting for the other Mac
"
  done < <(our_folders)

  local conflicts; conflicts=$(conflict_files | wc -l | tr -d ' ')
  [ "$conflicts" -gt 0 ] && problems="${problems}sync:  ⚠️ $conflicts conflict copies (same file changed on both Macs; a .jsonl one shows up as an extra session). List or park them: control/bin/claude-sync.sh conflicts
"
  local headline
  if [ "$npaused" = "$total" ]; then headline="all $total folders paused (first sync not started yet)"
  elif [ "$behind" = 0 ] && [ "$waiting" = 0 ]; then headline="$total folders in sync"
  else headline="$behind files to fetch here, $waiting waiting for the other Mac"; fi
  echo "sync:  claude-sync up; ${peer_line}${headline}"
  [ -n "$problems" ] && printf '%s' "$problems"
  [ $brief = 1 ] || { [ -n "$summary" ] && printf '%s' "$summary"; [ "$conflicts" -gt 0 ] && conflict_files | cut -f2 | sed 's#^#  conflict: #'; }
  return 0
}

cmd_manifest() {   # manifest <path>: "relpath<TAB>size<TAB>mtime" for files the sync would carry
  local path; path=$(expand "$1"); local id; id=$(folder_id "$1")
  [ -d "$path" ] || return 0
  ( cd "$path" && find . -type f -print | filter_paths "$id" | sort \
      | tr '\n' '\0' | xargs -0 stat -f '%N	%z	%m' 2>/dev/null )
}

cmd_hash() {   # hash <path>: reads relpaths on stdin, prints "relpath<TAB>sha"
  local path; path=$(expand "$1")
  cd "$path" || return 0
  while IFS= read -r f; do printf '%s\t%s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done
}

cmd_backup() {   # backup <stamp> <path>...: copy-on-write snapshot (APFS clones take ~no space)
  local stamp="$1"; shift
  local dest="$BASE/backup-$stamp" p src name n_src n_dst l_src l_dst
  mkdir -p "$dest"; chmod 700 "$BASE"
  for p in "$@"; do
    src=$(expand "$p"); [ -d "$src" ] || continue
    name=$(folder_id "$p")
    [ -e "$dest/$name" ] && die "$dest/$name already exists"
    cp -Rc "$src" "$dest/$name" || die "copy of $src failed"
    n_src=$(find "$src" -type f | wc -l | tr -d ' '); n_dst=$(find "$dest/$name" -type f | wc -l | tr -d ' ')
    l_src=$(find "$src" -type l | wc -l | tr -d ' '); l_dst=$(find "$dest/$name" -type l | wc -l | tr -d ' ')
    [ "$n_src" = "$n_dst" ] && [ "$l_src" = "$l_dst" ] \
      || die "backup of $src does not match: files $n_src vs $n_dst, symlinks $l_src vs $l_dst"
    echo "backed up $src -> $dest/$name ($n_dst files, $l_dst symlinks kept as symlinks)"
  done
}

cmd_uninstall() {
  local d; d=$(launch_domain)
  launchctl bootout "$d/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "stopped and removed the claude-sync service on $(hostname -s)."
  echo "kept: $BASE (config, keys, versions, backups) and all synced files."
  echo "to remove completely: rm -rf $BASE, and delete .stignore/.stfolder from each synced folder."
}

case "${1:-}" in
  setup)     shift; cmd_setup "$@" ;;
  pair)      shift; cmd_pair "$@" ;;
  folder)    shift; cmd_folder "$@" ;;
  pause)     set_paused true ;;
  resume)    set_paused false ;;
  status)    shift; cmd_status "$@" ;;
  conflicts) shift; cmd_conflicts "$@" ;;
  manifest)  shift; cmd_manifest "$@" ;;
  hash)      shift; cmd_hash "$@" ;;
  backup)    shift; cmd_backup "$@" ;;
  id)        up || die "not running"; my_id ;;
  folder-id) shift; folder_id "$1" ;;
  peers-paused) shift; peers_paused "$1" ;;
  scan-check) shift; cmd_scan_check "$@" ;;
  installed) have_st && echo yes || echo no ;;
  uninstall) cmd_uninstall ;;
  *) echo "usage: $0 setup|pair|folder|pause|resume|status|conflicts|manifest|hash|backup|id|installed|uninstall" >&2; exit 2 ;;
esac
