#!/bin/bash
# Provision a new developer account on the always-on Mac.
# Each user gets their own loopback IP (127.0.0.<index>) and named host
# (<username>.studio), so everyone's dev servers run on standard ports
# (web :3000, api :8080) without conflicts.
#
# Usage:
#   ./control/bin/provision-user.sh <username> <index> [pubkey-file]
#
#   username    — Unix username for the new account (e.g. mariano)
#   index       — integer 1-9; sets loopback IP and hostname:
#                   IP:   127.0.0.<index>
#                   host: <username>.studio
#                 Check docs/host-registry.md for taken indices.
#   pubkey-file — path to their SSH public key (default: prompts to paste)
#
# Examples:
#   ./control/bin/provision-user.sh mariano 2 ~/keys/mariano.pub
#   ./control/bin/provision-user.sh lisa    3
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/config.env"

# ── args ──────────────────────────────────────────────────────────────────────
USERNAME="${1:-}"
INDEX="${2:-}"
PUBKEY_FILE="${3:-}"

if [[ -z "$USERNAME" || -z "$INDEX" ]]; then
  echo "usage: $(basename "$0") <username> <index> [pubkey-file]" >&2
  echo "       index 1-9 → loopback IP 127.0.0.<index> + hostname <username>.studio" >&2
  echo "" >&2
  echo "tip:   run generate-invite.sh first to send the user a setup script" >&2
  echo "       that walks them through generating their SSH key." >&2
  exit 1
fi

if ! [[ "$INDEX" =~ ^[1-9]$ ]]; then
  echo "index must be a single digit 1–9 (got: $INDEX)" >&2
  exit 1
fi

LOOPBACK_IP="127.0.0.${INDEX}"
STUDIO_HOST="${USERNAME}.studio"

# ── public key ────────────────────────────────────────────────────────────────
if [[ -n "$PUBKEY_FILE" ]]; then
  PUBKEY="$(cat "$PUBKEY_FILE")"
else
  echo "Paste the SSH public key for $USERNAME (single line, then Enter + Ctrl-D):"
  PUBKEY="$(cat)"
fi

if [[ -z "$PUBKEY" ]]; then
  echo "no public key provided — aborting" >&2
  exit 1
fi

# ── check registry for conflicts ──────────────────────────────────────────────
REGISTRY="$ROOT/docs/host-registry.md"
if [[ -f "$REGISTRY" ]] && grep -q "| $INDEX |" "$REGISTRY" 2>/dev/null; then
  echo "⚠️  index $INDEX already appears in docs/host-registry.md — check before proceeding."
  grep "| $INDEX |" "$REGISTRY"
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

# ── ship the remote payload ───────────────────────────────────────────────────
echo "→ provisioning '$USERNAME' on $REMOTE_HOST ($STUDIO_HOST → $LOOPBACK_IP) …"
echo ""

# NOTE: outer heredoc (<<REMOTE) is unquoted so local vars expand.
# Remote vars / content meant for files use \$ to survive to the remote.
# Inner heredocs that should not expand on the remote use <<'EOF' (quoted delimiters).

ssh -o BatchMode=yes -o ConnectTimeout=10 -t "$REMOTE_HOST" "bash -s" <<REMOTE
set -euo pipefail

USERNAME="$USERNAME"
LOOPBACK_IP="$LOOPBACK_IP"
STUDIO_HOST="$STUDIO_HOST"
INDEX="$INDEX"
PUBKEY="$PUBKEY"

# ── 1. loopback alias ─────────────────────────────────────────────────────────
# 127.0.0.1 already exists; only higher indices need an alias + LaunchDaemon.
if [ "\$INDEX" -eq 1 ]; then
  echo "  loopback: 127.0.0.1 already exists — skipping alias"
else
  if ifconfig lo0 | grep -q "\$LOOPBACK_IP"; then
    echo "  loopback: \$LOOPBACK_IP already active"
  else
    sudo ifconfig lo0 alias "\$LOOPBACK_IP" up
    echo "✓ loopback alias \$LOOPBACK_IP added (active now)"
  fi

  # LaunchDaemon so the alias survives reboots
  PLIST="/Library/LaunchDaemons/com.agent-mac-ops.loopback.\${USERNAME}.plist"
  if [[ ! -f "\$PLIST" ]]; then
    sudo tee "\$PLIST" > /dev/null <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.agent-mac-ops.loopback.$USERNAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/sbin/ifconfig</string>
        <string>lo0</string>
        <string>alias</string>
        <string>$LOOPBACK_IP</string>
        <string>up</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST_EOF
    sudo launchctl load "\$PLIST"
    echo "✓ LaunchDaemon installed — alias persists across reboots"
  else
    echo "  LaunchDaemon already exists — skipping"
  fi
fi

# ── 2. /etc/hosts entry ───────────────────────────────────────────────────────
if grep -qF "\$STUDIO_HOST" /etc/hosts; then
  echo "  /etc/hosts: \$STUDIO_HOST already present"
else
  printf '\n%s  %s\n' "\$LOOPBACK_IP" "\$STUDIO_HOST" | sudo tee -a /etc/hosts > /dev/null
  echo "✓ /etc/hosts: \$LOOPBACK_IP  \$STUDIO_HOST"
fi

# ── 3. user account ───────────────────────────────────────────────────────────
if id "\$USERNAME" &>/dev/null; then
  echo "  user '\$USERNAME' already exists — skipping"
else
  NEXT_UID=\$(dscl . -list /Users UniqueID | awk '{print \$2}' | sort -n | \
    awk -v min=501 'BEGIN{n=min} \$1==n{n++} END{print n}')
  sudo dscl . -create /Users/\$USERNAME
  sudo dscl . -create /Users/\$USERNAME UserShell /bin/zsh
  sudo dscl . -create /Users/\$USERNAME RealName "\$USERNAME"
  sudo dscl . -create /Users/\$USERNAME UniqueID "\$NEXT_UID"
  sudo dscl . -create /Users/\$USERNAME PrimaryGroupID 20
  sudo dscl . -create /Users/\$USERNAME NFSHomeDirectory /Users/\$USERNAME
  sudo createhomedir -c -u "\$USERNAME"
  echo "✓ user '\$USERNAME' created (uid \$NEXT_UID)"
fi

# ── 4. SSH key ────────────────────────────────────────────────────────────────
SSH_DIR="/Users/\$USERNAME/.ssh"
AUTH_KEYS="\$SSH_DIR/authorized_keys"
sudo mkdir -p "\$SSH_DIR"
sudo chmod 700 "\$SSH_DIR"
if sudo grep -qF "\$PUBKEY" "\$AUTH_KEYS" 2>/dev/null; then
  echo "  SSH key already present — skipping"
else
  printf '%s\n' "\$PUBKEY" | sudo tee -a "\$AUTH_KEYS" > /dev/null
  echo "✓ SSH key installed"
fi
sudo chmod 600 "\$AUTH_KEYS"
sudo chown -R "\$USERNAME":staff "\$SSH_DIR"

# ── 5. .zshrc ─────────────────────────────────────────────────────────────────
ZSHRC="/Users/\$USERNAME/.zshrc"
if [[ -f "\$ZSHRC" ]]; then
  echo "  .zshrc already exists — skipping (add DEV_HOST/DEV_HOSTNAME manually if missing)"
else
  sudo -u "\$USERNAME" tee "\$ZSHRC" > /dev/null <<'ZSHRC_EOF'
# Homebrew (Apple Silicon)
[ -f /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

# Bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# nvm (lazy-loaded)
export NVM_DIR="$HOME/.nvm"
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && source "/opt/homebrew/opt/nvm/nvm.sh" --no-use

alias ll='ls -lah'
alias gs='git status'
ZSHRC_EOF

  # Append the user-specific vars (these need local expansion, so outside the quoted heredoc)
  printf '\n# Dev identity — set at provisioning time\nexport DEV_HOST="%s"\nexport DEV_HOSTNAME="%s"\n' \
    "$LOOPBACK_IP" "$STUDIO_HOST" | sudo tee -a "\$ZSHRC" > /dev/null
  echo "✓ .zshrc written"
fi

# ── 6. .env.local template ────────────────────────────────────────────────────
ENV_TMPL="/Users/\$USERNAME/.env.local.template"
sudo -u "\$USERNAME" tee "\$ENV_TMPL" > /dev/null <<ENVEOF
# Copy into your dupe-com worktree's .env.local
# Your named host: $STUDIO_HOST
HOSTNAME=$LOOPBACK_IP
PORT=3000
API_PORT=8080
ENVEOF
echo "✓ ~/.env.local.template written"

echo ""
echo "✅  \$USERNAME is ready."
echo ""
echo "    SSH:          ssh \$USERNAME@$REMOTE_HOST"
echo "    Web:          http://$STUDIO_HOST:3000"
echo "    API:          http://$STUDIO_HOST:8080"
echo ""
echo "    To reach the dev server from your laptop, forward the loopback IP:"
echo "    ssh -L 3000:$LOOPBACK_IP:3000 -L 8080:$LOOPBACK_IP:8080 $REMOTE_HOST"
echo "    Then add '$LOOPBACK_IP  $STUDIO_HOST' to your laptop's /etc/hosts too."
REMOTE

# ── update local host registry ────────────────────────────────────────────────
mkdir -p "$ROOT/docs"
if [[ ! -f "$REGISTRY" ]]; then
  cat > "$REGISTRY" <<'EOF'
# Host Registry

Each developer on the shared Mac Studio gets a loopback IP and named hostname.
Dev servers run on standard ports — web :3000, api :8080 — bound to the user's IP.

| User | Index | Loopback IP | Hostname |
|------|-------|-------------|----------|
EOF
fi

if ! grep -q "| $USERNAME " "$REGISTRY" 2>/dev/null; then
  printf '| %s | %s | %s | %s |\n' "$USERNAME" "$INDEX" "$LOOPBACK_IP" "$STUDIO_HOST" >> "$REGISTRY"
  echo "→ recorded in docs/host-registry.md"
fi
