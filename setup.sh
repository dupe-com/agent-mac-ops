#!/bin/bash
# agent-mac-ops setup.
#   ./setup.sh          interactive: write config.env, render templates
#   ./setup.sh render   re-render templates from an existing config.env (no prompts)
#   ./setup.sh remote   push dev-session.sh (+ the `open` shim) to the remote
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

# Values spliced into templates by sed: reject what would break the substitution or the
# single-quoted shell strings they land in. Runs before any template is (re)written, so a
# bad value never leaves a half-rendered, truncated shell-snippet.sh behind.
validate() {
  case "${TMUX_RESTORE_PROCESSES-}" in *[\|\&\'\\]*)
    echo "TMUX_RESTORE_PROCESSES can't contain | & ' or \\ — fix config.env" >&2; exit 1 ;; esac
  case "${TMUX_SAVE_INTERVAL:-15}" in ''|*[!0-9]*|0*)   # 0* also catches 08/09 (bash reads them as octal)
    echo "TMUX_SAVE_INTERVAL must be a whole number of minutes ≥ 1, no leading zero — fix config.env" >&2; exit 1 ;; esac
}

render() {
  sed -e "s|@@ALIAS_NAME@@|${ALIAS_NAME}|g" \
      -e "s|@@REMOTE_HOST@@|${REMOTE_HOST}|g" \
      -e "s|@@REMOTE_HOSTNAME@@|${REMOTE_HOSTNAME}|g" \
      -e "s|@@TMUX_SESSION@@|${TMUX_SESSION}|g" \
      -e "s|@@WORK_DIR@@|${WORK_DIR}|g" \
      -e "s|@@ROOT@@|${ROOT}|g" \
      -e "s|@@SSH_FORWARDS@@|${SSH_FORWARDS}|g" \
      -e "s|@@HANDOFF_PORT@@|${HANDOFF_PORT}|g" \
      -e "s|@@HANDOFF_TOKEN@@|${HANDOFF_TOKEN}|g" \
      -e "s|@@GHOSTTY_REMOTE_COLOR@@|${GHOSTTY_REMOTE_COLOR:-}|g" \
      -e "s|@@MOSH_SERVER@@|${MOSH_SERVER:-}|g" \
      -e "s|@@TMUX_SAVE_INTERVAL@@|${TMUX_SAVE_INTERVAL:-15}|g" \
      -e "s|@@TMUX_RESTORE_PROCESSES@@|${TMUX_RESTORE_PROCESSES-\"~claude->claude --continue\"}|g" \
      "$1"
}

# Render every template from the current config (used by both init and render).
render_all() {
  validate
  render "$ROOT/control/shell-snippet.sh.tmpl"     > "$ROOT/control/shell-snippet.sh"
  render "$ROOT/control/bin/ghostty-connect.sh.tmpl" > "$ROOT/control/bin/ghostty-connect.sh"
  render "$ROOT/remote/dev-session.sh.tmpl"        > "$ROOT/remote/dev-session.sh"
  render "$ROOT/remote/open-handoff.sh.tmpl"       > "$ROOT/remote/open-handoff.sh"
  render "$ROOT/remote/code-handoff.sh.tmpl"       > "$ROOT/remote/code-handoff.sh"
  render "$ROOT/remote/tmux-persist.sh.tmpl"       > "$ROOT/remote/tmux-persist.sh"
  chmod +x "$ROOT/control/bin/ghostty-connect.sh" "$ROOT/remote/dev-session.sh" \
           "$ROOT/remote/open-handoff.sh" "$ROOT/remote/code-handoff.sh" \
           "$ROOT/remote/tmux-persist.sh"
}

build_forwards() {
  # The handoff reverse tunnel (-R $HANDOFF_PORT) is NOT carried here anymore — it's
  # owned by the self-healing launchd agent (control/bin/install-handoff-tunnel.sh),
  # so it survives drops/sleep/reboot independently of any shell session and never
  # collides with this master on the remote's :$HANDOFF_PORT bind. The session master
  # carries only the -L dev-server forwards.
  # Bind each forward on BOTH loopback families. A bare `-L $p:...` binds IPv4
  # loopback only, but macOS resolves `localhost` to `::1` first — so the browser
  # hits [::1]:$p, finds nothing listening, and `localhost:$p` hangs while
  # `127.0.0.1:$p` works. Explicit v4 + v6 binds make `localhost` work either way.
  # The forward's DESTINATION resolves on the remote, so `localhost` there means the
  # remote's own 127.0.0.1 -- the admin's slot-1 loopback on a shared Mac. REMOTE_BIND
  # overrides it with your own 127.0.0.<index>; unset keeps single-user setups as-is.
  local f="" p d="${REMOTE_BIND:-localhost}"
  for p in ${FORWARD_PORTS:-}; do f="${f:+$f }-L 127.0.0.1:$p:$d:$p -L [::1]:$p:$d:$p"; done
  SSH_FORWARDS="$f"
}

cmd="${1:-init}"
case "$cmd" in
  init)
    if [ -f "$ROOT/config.env" ]; then . "$ROOT/config.env"; else . "$ROOT/config.env.example"; fi
    ask() { local p="$1" d="$2" v; read -r -p "$p [$d]: " v; printf '%s' "${v:-$d}"; }

    echo "agent-mac-ops setup — answers land in config.env (gitignored)."
    echo
    REMOTE_HOST="$(ask 'SSH host/alias for your always-on Mac' "$REMOTE_HOST")"
    REMOTE_HOSTNAME="$(ask 'Remote short hostname (hostname -s on the remote)' "$REMOTE_HOSTNAME")"
    WORK_DIR="$(ask 'Dev session dir on remote (~ = home, or absolute)' "$WORK_DIR")"
    TMUX_SESSION="$(ask 'tmux session name' "$TMUX_SESSION")"
    ALIAS_NAME="$(ask 'local shell command to connect' "$ALIAS_NAME")"
    PROFILE_NAME="$(ask 'iTerm2 profile name (see SETUP.md)' "$PROFILE_NAME")"
    GHOSTTY_REMOTE_COLOR="$(ask 'Ghostty remote background tint, hex (blank = no tint)' "${GHOSTTY_REMOTE_COLOR:-#2a1f3d}")"
    FORWARD_PORTS="$(ask 'ports to auto-forward on connect (space-sep, blank = none)' "${FORWARD_PORTS:-}")"
    REMOTE_BIND="$(ask 'forward destination on the remote (your 127.0.0.<index> on a shared Mac; localhost = admin)' "${REMOTE_BIND:-localhost}")"
    HANDOFF_ENABLED="$(ask 'open remote auth URLs on this Mac? (true/false)' "${HANDOFF_ENABLED:-true}")"
    HANDOFF_PORT="$(ask 'handoff listener port (MUST be unique per user on a shared remote: 18000 + your index)' "${HANDOFF_PORT:-17999}")"
    NOTIFY_WEBHOOK="$(ask 'notify webhook URL (blank = log-only)' "${NOTIFY_WEBHOOK:-}")"
    NOTIFY_KEY="$(ask 'webhook json key (slack/mattermost=text, discord=content)' "${NOTIFY_KEY:-text}")"
    EXTRA_LOG="$(ask 'extra remote log to surface in logs.sh (blank = none)' "${EXTRA_LOG:-}")"

    # Generate a stable handoff token once; keep it across re-runs.
    HANDOFF_TOKEN="${HANDOFF_TOKEN:-}"
    [ -z "$HANDOFF_TOKEN" ] && HANDOFF_TOKEN="$(uuidgen 2>/dev/null || date +%s%N)"

    TMUX_RESTORE_PROCESSES="${TMUX_RESTORE_PROCESSES-\"~claude->claude --continue\"}"
    build_forwards

    cat > "$ROOT/config.env" <<EOF
# agent-mac-ops config — generated by setup.sh. Gitignored. Edit + re-run ./setup.sh.
REMOTE_HOST="$REMOTE_HOST"
REMOTE_HOSTNAME="$REMOTE_HOSTNAME"
WORK_DIR="$WORK_DIR"
TMUX_SESSION="$TMUX_SESSION"
ALIAS_NAME="$ALIAS_NAME"
PROFILE_NAME="$PROFILE_NAME"
GHOSTTY_REMOTE_COLOR="$GHOSTTY_REMOTE_COLOR"
MOSH_SERVER="${MOSH_SERVER:-}"
TMUX_PERSIST="${TMUX_PERSIST:-true}"
TMUX_SAVE_INTERVAL="${TMUX_SAVE_INTERVAL:-15}"
TMUX_RESTORE_PROCESSES='$TMUX_RESTORE_PROCESSES'
FORWARD_PORTS="$FORWARD_PORTS"
REMOTE_BIND="${REMOTE_BIND:-localhost}"
HANDOFF_ENABLED="$HANDOFF_ENABLED"
HANDOFF_PORT="$HANDOFF_PORT"
HANDOFF_TOKEN="$HANDOFF_TOKEN"
NOTIFY_WEBHOOK="$NOTIFY_WEBHOOK"
NOTIFY_KEY="$NOTIFY_KEY"
EXTRA_LOG="$EXTRA_LOG"
CHECK_HOUR="${CHECK_HOUR:-9}"
CHECK_MIN="${CHECK_MIN:-0}"
EOF

    render_all

    echo
    echo "✅ wrote config.env + rendered shell-snippet.sh, ghostty-connect.sh, dev-session.sh, open-handoff.sh"
    echo
    echo "next:"
    echo "  1) add to ~/.zshrc, BEFORE your iTerm shell-integration line:"
    echo "       source \"$ROOT/control/shell-snippet.sh\""
    echo "  2) push to the remote:                   ./setup.sh remote"
    echo "  3) iTerm2 GUI steps in SETUP.md          (profile + Automatic Profile Switching)"
    echo "     Ghostty users: no GUI steps — '$ALIAS_NAME' just works (see SETUP.md §4b)."
    [ "${HANDOFF_ENABLED}" = "true" ] && {
    echo "  4) browser/editor handoff listener:      control/bin/install-open-listener.sh"
    echo "     + self-healing reverse tunnel:        control/bin/install-handoff-tunnel.sh"
    }
    echo "  5) optional daily digest:                control/ops/bin/install-launchd.sh"
    echo "  6) point your agent at control/ops/ and say:  \"check on $REMOTE_HOST\""
    ;;

  render)
    [ -f "$ROOT/config.env" ] || { echo "no config.env — run ./setup.sh first" >&2; exit 1; }
    . "$ROOT/config.env"
    build_forwards
    render_all
    echo "✅ re-rendered shell-snippet.sh, ghostty-connect.sh, dev-session.sh, open-handoff.sh, tmux-persist.sh from config.env"
    ;;

  remote)
    [ -f "$ROOT/config.env" ] || { echo "run ./setup.sh first" >&2; exit 1; }
    . "$ROOT/config.env"
    build_forwards   # render_all (after mosh discovery) needs SSH_FORWARDS
    [ -f "$ROOT/remote/dev-session.sh" ] || { echo "missing remote/dev-session.sh — run ./setup.sh" >&2; exit 1; }
    echo "pushing to $REMOTE_HOST ..."
    scp "$ROOT/remote/dev-session.sh" "$REMOTE_HOST:~/dev-session.sh"
    ssh "$REMOTE_HOST" 'chmod +x ~/dev-session.sh; command -v tmux >/dev/null || echo "⚠️  tmux not on remote — install it: brew install tmux"'

    # Install Ghostty's terminfo on the remote so TERM=xterm-ghostty resolves there.
    # Without it, native Ghostty sessions send an unknown TERM and keystrokes come
    # back garbled/doubled. Ghostty ships its terminfo INSIDE the app bundle, not the
    # system db — so look there too. dev-session.sh also falls back to xterm-256color,
    # so this is fidelity, not a hard requirement (best-effort, safe under set -e).
    GTI=""
    if ! infocmp -x xterm-ghostty >/dev/null 2>&1; then
      for d in /Applications/Ghostty.app "$HOME/Applications/Ghostty.app"; do
        if TERMINFO="$d/Contents/Resources/terminfo" infocmp -x xterm-ghostty >/dev/null 2>&1; then
          GTI="$d/Contents/Resources/terminfo"; break
        fi
      done
      HAVE_GTI=$([ -n "$GTI" ] && echo 1 || echo "")
    else
      HAVE_GTI=1
    fi
    if [ -n "${HAVE_GTI:-}" ]; then
      if { [ -n "$GTI" ] && env TERMINFO="$GTI" infocmp -x xterm-ghostty || infocmp -x xterm-ghostty; } 2>/dev/null \
           | ssh "$REMOTE_HOST" 'tic -x - >/dev/null 2>&1'; then
        echo "✅ installed xterm-ghostty terminfo on $REMOTE_HOST"
      else
        echo "⚠️  couldn't install xterm-ghostty terminfo (sessions fall back to xterm-256color — fine)"
      fi
    else
      echo "ℹ️  no local xterm-ghostty terminfo found — Ghostty sessions use xterm-256color (fine)"
    fi
    # mosh: power the `*-mosh` command (predictive-echo typing for laggy links).
    # Ensure mosh-server exists on the remote and record its absolute path — macOS
    # Homebrew installs it outside ssh's non-interactive PATH, so the launcher pins
    # it via --server. Best-effort; the *-mosh command is optional.
    MS="$(ssh "$REMOTE_HOST" 'command -v mosh-server 2>/dev/null' || true)"
    if [ -z "$MS" ]; then
      echo "ℹ️  installing mosh on $REMOTE_HOST (for the '$ALIAS_NAME-mosh' command)…"
      ssh "$REMOTE_HOST" 'command -v brew >/dev/null && brew install mosh >/dev/null 2>&1 || true'
      MS="$(ssh "$REMOTE_HOST" 'command -v mosh-server 2>/dev/null' || true)"
    fi
    if [ -n "$MS" ]; then
      if grep -q '^MOSH_SERVER=' "$ROOT/config.env"; then
        sed -i '' "s|^MOSH_SERVER=.*|MOSH_SERVER=\"$MS\"|" "$ROOT/config.env"
      else
        echo "MOSH_SERVER=\"$MS\"" >> "$ROOT/config.env"
      fi
      MOSH_SERVER="$MS"; render_all
      echo "✅ mosh-server at $MS — '$ALIAS_NAME-mosh' ready (snippet re-rendered)"
    else
      echo "⚠️  no mosh-server on $REMOTE_HOST — '$ALIAS_NAME-mosh' will try the default PATH (may fail; brew install mosh on the remote)"
    fi

    # tmux persistence: saved windows come back after a reboot / power loss. Clones
    # tmux-resurrect (pinned) into the remote's ~/.agent-mac-ops and pushes the helper
    # that dev-session.sh + revive.sh use to create the session. Opt out: TMUX_PERSIST=false
    # (also removes a previously pushed helper, so sessions go back to plain tmux).
    if [ "${TMUX_PERSIST:-true}" = "true" ]; then
      if ssh "$REMOTE_HOST" 'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; set -e
          d=~/.agent-mac-ops/tmux-resurrect; ref=cff343cf9e81983d3da0c8562b01616f12e8d548  # master 2023-03
          [ -d "$d/.git" ] || git clone -q https://github.com/tmux-plugins/tmux-resurrect "$d"
          git -C "$d" cat-file -e "$ref^{commit}" 2>/dev/null || git -C "$d" fetch -q --depth 1 origin "$ref"
          git -C "$d" -c advice.detachedHead=false checkout -q "$ref"'; then
        scp -q "$ROOT/remote/tmux-persist.sh" "$REMOTE_HOST:~/.agent-mac-ops/tmux-persist.sh"
        ssh "$REMOTE_HOST" 'chmod +x ~/.agent-mac-ops/tmux-persist.sh'
        echo "✅ tmux persistence on — windows saved every ${TMUX_SAVE_INTERVAL:-15} min, restored on the first connect after a reboot"
      else
        echo "⚠️  couldn't install tmux-resurrect on $REMOTE_HOST — sessions won't survive a reboot (git missing?)"
      fi
    else
      ssh "$REMOTE_HOST" 'rm -f ~/.agent-mac-ops/tmux-persist.sh'
      echo "ℹ️  tmux persistence off (TMUX_PERSIST=false) — an already-running save loop stops when the remote's tmux server next restarts"
    fi

    if [ "${HANDOFF_ENABLED:-true}" = "true" ] && [ -f "$ROOT/remote/open-handoff.sh" ]; then
      ssh "$REMOTE_HOST" 'mkdir -p ~/bin'
      scp "$ROOT/remote/open-handoff.sh" "$REMOTE_HOST:~/bin/open"
      scp "$ROOT/remote/code-handoff.sh" "$REMOTE_HOST:~/bin/code-$ALIAS_NAME"
      ssh "$REMOTE_HOST" "chmod +x ~/bin/open ~/bin/code-$ALIAS_NAME"
      echo "✅ pushed dev-session.sh + ~/bin/open + ~/bin/code-$ALIAS_NAME (handoff shims)"
    else
      echo "✅ pushed dev-session.sh (handoff disabled — no shim)"
    fi
    echo
    echo "one-time remote prep (needs admin on the remote):"
    echo "  • System Settings → General → Sharing → Remote Login = ON"
    echo "  • keep it awake:  sudo pmset -a sleep 0    (laptop, also: sudo pmset -a disablesleep 1)"
    echo "  • power back on after an outage:  sudo pmset -a autorestart 1"
    echo "    (with FileVault on it still waits at the unlock screen until someone types the password)"
    ;;

  *) echo "usage: ./setup.sh [init|render|remote]" >&2; exit 1 ;;
esac
