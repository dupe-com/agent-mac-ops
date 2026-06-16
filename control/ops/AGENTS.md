# Always-on Mac — ops runbook

Context for any AI coding agent (Claude Code, Codex, Cursor…) opened on this folder.
The job of this folder: let an agent operate an always-on Mac **without the human
typing SSH commands**. Open this folder and say *"check on the box"* — read this
file, run the scripts over SSH, and report back in plain language.

The remote is configured in `../../config.env` as `REMOTE_HOST` (an SSH host/alias).
All commands below reach it through that alias; you never need its IP.

## How to check on it

Run these from the repo (they ship the script to the remote over SSH via `remote-run.sh`,
so they always use the remote's environment, and the remote needs nothing installed):

```bash
control/ops/bin/remote-run.sh status.sh   # uptime, load, disk, tmux dev session, repo
control/ops/bin/remote-run.sh logs.sh     # recent dev-session output + check log + extra log
control/ops/bin/remote-run.sh revive.sh   # recreate the dev tmux session
control/ops/bin/remote-run.sh stop-dev.sh # stop the dev stack (window-safe — signals dev.ts, leaves tmux up)
```

When asked to "check on the box": run `status.sh`, summarize in one or two sentences,
and only surface lines with `⚠️`. If something looks down, propose `revive.sh` before
escalating.

`stop-dev.sh` is the one mutating command here (an explicit "stop my dev servers"
action) — it SIGTERMs the `bun scripts/dev.ts` multiplexer so its own shutdown reaps
every child, then sweeps any orphan and reports which ports (if any) are still held.
It deliberately does NOT touch the tmux session, so it's safe to run without dropping
the human's interactive `-CC` window. Use it instead of sending `q` to the pane.

## What "healthy" looks like

| Signal | Healthy | Investigate when |
|--------|---------|------------------|
| disk | < 85% used | ≥ 85% (`⚠️`) — big repos / agent artifacts; check `~` and caches |
| load | roughly ≤ core count | sustained high with no active work |
| tmux session | up | down — run `revive.sh` |
| daily-check log | recent `✅` line | old timestamp, or `🚨 could not reach` — SSH/network |

## Escalation (cheapest first)

1. Report back from `status.sh`.
2. SSH in and look directly: `ssh "$REMOTE_HOST"` (read `REMOTE_HOST` from `config.env`).
3. `revive.sh` for a wedged dev session.
4. Screen share (macOS Screen Sharing / `open vnc://<host>`) only if something graphical is broken.

## User provisioning

Two-step flow — generate the invite first, provision after you have their key:

```bash
# Step 1: generate a personalized setup script for the new user
./control/bin/generate-invite.sh <username> <index>
# → creates onboard/<username>-setup.sh — send this file to them

# They run it on their laptop: it generates their SSH key and shows it to them.
# They paste their public key to you (via Slack etc.).

# Step 2: provision them on the remote Mac (paste their key when prompted)
./control/bin/provision-user.sh <username> <index>

# Tell them to press Enter in their setup script — it connects and configures their Mac.
```

Each user gets their own Unix account, loopback IP (`127.0.0.<index>`), and named
host (`<username>.studio`). A LaunchDaemon keeps the loopback alias alive across reboots.
Everyone's dev servers run on standard ports (web :3000, api :8080) — no port offsets.

Taken indices are recorded in `docs/host-registry.md`. Index 1 is reserved for the
admin user (127.0.0.1 already exists; no alias or LaunchDaemon needed).

When asked to "add a user to the box": ask for their username, a port offset not in
`docs/port-registry.md`, and their SSH public key — then run the script above.

## Notes

- The human connects interactively with the `ALIAS_NAME` shell command (a `tmux -CC`
  session). For ops checks prefer the scripts above (plain `ssh`) so you don't hijack
  that interactive session.
- No secrets live in this folder. The only optional secret is the notify webhook in
  `config.env` (gitignored).
- Don't trigger anything destructive on the remote without asking — this runbook is
  read/observe/revive only.
