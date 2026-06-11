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
```

When asked to "check on the box": run `status.sh`, summarize in one or two sentences,
and only surface lines with `⚠️`. If something looks down, propose `revive.sh` before
escalating.

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

## Notes

- The human connects interactively with the `ALIAS_NAME` shell command (a `tmux -CC`
  session). For ops checks prefer the scripts above (plain `ssh`) so you don't hijack
  that interactive session.
- No secrets live in this folder. The only optional secret is the notify webhook in
  `config.env` (gitignored).
- Don't trigger anything destructive on the remote without asking — this runbook is
  read/observe/revive only.
