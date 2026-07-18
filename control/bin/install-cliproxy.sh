#!/bin/bash
# install-cliproxy.sh — optional: run other models (GPT, Gemini, Kimi, …) inside
# Claude Code via CLIProxyAPI (https://github.com/router-for-me/CLIProxyAPI).
#
# CLIProxyAPI wraps CLI-tool OAuth sessions (ChatGPT/Codex, Gemini, Kimi, xAI …)
# and re-exposes them as an Anthropic-compatible endpoint on localhost:8317, so
# `claude` can point at it with ANTHROPIC_BASE_URL and run e.g. gpt-5.6-sol.
#
#   ./install-cliproxy.sh              install + configure + verify (idempotent)
#   ./install-cliproxy.sh --login codex    (re)run a provider OAuth login
#   ./install-cliproxy.sh --install-alias  append the xclaude alias to ~/.zshrc.local
#                                          (sourcing control/shell-snippet.sh already
#                                           defines xclaude once this installer has run)
#   ./install-cliproxy.sh status       show service, auth files, and model list
#
# Everything is local-only: the proxy binds localhost, the API key is generated
# per-machine and stored at ~/.cli-proxy-api/.local-api-key (chmod 600).
set -euo pipefail

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
CONF="$BREW_PREFIX/etc/cliproxyapi.conf"
AUTH_DIR="$HOME/.cli-proxy-api"
KEY_FILE="$AUTH_DIR/.local-api-key"
PORT=8317

log()  { printf '\033[1;36m[cliproxy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cliproxy]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[cliproxy]\033[0m %s\n' "$*" >&2; exit 1; }

api_key() { cat "$KEY_FILE"; }

models() {
  curl -s -m 10 "http://localhost:$PORT/v1/models" \
    -H "Authorization: Bearer $(api_key)" |
    python3 -c 'import json,sys; [print(" -", m["id"]) for m in json.load(sys.stdin).get("data", [])]' 2>/dev/null
}

alias_block() {
  cat <<'EOF'
# --- agent-mac-ops: claude via CLIProxyAPI (install-cliproxy.sh) ---
# xclaude            → Claude Code on gpt-5.6-sol through the local proxy
# CLIPROXY_MODEL=gpt-5.5 xclaude   → pick another model (see `install-cliproxy.sh status`)
xclaude() {
  ANTHROPIC_BASE_URL="http://localhost:8317" \
  ANTHROPIC_AUTH_TOKEN="$(cat ~/.cli-proxy-api/.local-api-key)" \
  ANTHROPIC_MODEL="${CLIPROXY_MODEL:-gpt-5.6-sol}" \
  ANTHROPIC_SMALL_FAST_MODEL="${CLIPROXY_SMALL_MODEL:-gpt-5.4-mini}" \
  claude "$@"
}
# --- end agent-mac-ops cliproxy ---
EOF
}

do_status() {
  command -v cliproxyapi >/dev/null || die "cliproxyapi not installed (run $0)"
  brew services list | grep cliproxyapi || true
  echo
  log "auth files in $AUTH_DIR:"
  ls "$AUTH_DIR"/*.json 2>/dev/null || echo "  (none — no provider logged in yet)"
  echo
  log "models exposed by the proxy:"
  models || warn "proxy not answering on :$PORT"
}

do_login() {
  local provider="${1:-codex}"
  log "starting $provider OAuth login (browser will open; on a remote box see docs/CLIPROXY.md § Remote)…"
  cliproxyapi "-${provider}-login"
}

case "${1:-install}" in
  status)          do_status; exit 0 ;;
  --login)         do_login "${2:-codex}"; exit 0 ;;
  --install-alias)
    if grep -q "agent-mac-ops: claude via CLIProxyAPI" ~/.zshrc.local 2>/dev/null; then
      log "alias already in ~/.zshrc.local"
    else
      alias_block >> ~/.zshrc.local
      log "appended xclaude alias to ~/.zshrc.local — open a new shell to use it"
    fi
    exit 0 ;;
  install) ;;
  *) die "unknown command: $1 (use: install | status | --login <provider> | --install-alias)" ;;
esac

# 1. Install the binary (homebrew-core formula, no tap needed).
if command -v cliproxyapi >/dev/null; then
  log "cliproxyapi already installed ($(cliproxyapi --help 2>&1 | head -1 | grep -o 'Version: [^,]*' || true))"
else
  log "installing cliproxyapi via Homebrew…"
  brew install cliproxyapi
fi
[ -f "$CONF" ] || die "expected config at $CONF after install — check 'brew info cliproxyapi'"

# 2. Generate a per-machine API key (the stock config ships unsafe template keys
#    and the proxy refuses to serve until they're replaced).
mkdir -p "$AUTH_DIR"
if [ -f "$KEY_FILE" ]; then
  log "reusing existing API key at $KEY_FILE"
else
  printf 'sk-cliproxy-%s' "$(openssl rand -hex 16)" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  log "generated API key at $KEY_FILE"
fi

# 3. Patch the config: replace the template api-keys block with our key.
CONF_CHANGED=0
if grep -q "your-api-key" "$CONF"; then
  python3 - "$(api_key)" "$CONF" <<'PYEOF'
import re, sys
key, path = sys.argv[1], sys.argv[2]
s = open(path).read()
new = re.sub(r'api-keys:\n(?:  - "your-api-key-\d"\n)+', f'api-keys:\n  - "{key}"\n', s)
assert new != s, "template api-keys block not found in expected shape"
open(path, "w").write(new)
PYEOF
  CONF_CHANGED=1
  log "replaced template api-keys in $CONF"
elif grep -q "$(api_key)" "$CONF"; then
  log "config already carries this machine's key"
else
  warn "config has custom api-keys that don't include $KEY_FILE — leaving it alone."
  warn "add the key manually or delete the api-keys block and re-run."
fi

# 4. Run as a service (survives reboots).
if brew services list | grep -q "cliproxyapi.*started"; then
  if [ "$CONF_CHANGED" = 1 ]; then brew services restart cliproxyapi >/dev/null; log "service restarted with new config"; else log "service already running"; fi
else
  brew services start cliproxyapi >/dev/null
  log "service started"
fi
sleep 2

# 5. Provider login — without one the proxy exposes zero models.
if ls "$AUTH_DIR"/*.json >/dev/null 2>&1; then
  log "provider auth already present: $(ls "$AUTH_DIR"/*.json | xargs -n1 basename | tr '\n' ' ')"
else
  do_login codex
fi

# 6. Verify end-to-end.
log "models now exposed on http://localhost:$PORT :"
models || die "proxy is not answering — check 'brew services info cliproxyapi' and $CONF"
echo
log "done. Launch Claude Code on a proxied model with:"
echo
alias_block
echo
log "(sourcing control/shell-snippet.sh in your zshrc? xclaude is already defined — just open a new shell."
log " otherwise append it permanently with: $0 --install-alias)"
