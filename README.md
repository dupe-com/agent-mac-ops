# agent-mac-ops

**Operate your always-on Mac by talking to an AI agent — and connect to it as native, resizable iTerm2 or Ghostty windows.**

You have a Mac that stays on (a Studio under the desk, an old MacBook on a shelf). Two things you
always wished were easy:

1. **Drive it from your laptop.** Open a folder, tell Claude/Codex *"check on the box,"* and it SSHes
   in, reports uptime/disk/load/dev-session health in plain language, and revives a wedged session —
   no SSH commands typed by you. Plus an optional daily digest to Slack/Discord.
2. **Actually work on it.** Type one command and the remote opens as **native windows and panes** —
   resizable, real `Cmd+D` / `Cmd+T` splits connected to the remote, normal keys — and auto-colored
   so you never confuse it with localhost.

That second part is the hard-won bit, and it differs by terminal. With **iTerm2**, `tmux -CC` (control
mode) plus a non-obvious shell-integration flag plus Automatic Profile Switching is the only combination
that gives a *native* remote session that also recolors itself. **Ghostty** has no `-CC`, so `box`
instead opens a Ghostty instance whose native splits each auto-ssh into the remote (tinted via OSC for
the "not localhost" cue), with `box-tmux` for a persistent session. `box` auto-detects which terminal
you're in. It's all documented step-by-step in **[SETUP.md](SETUP.md)** — honestly the most valuable
thing in this repo.

3. **Log in without Screen Sharing.** The classic remote-Mac pain: a CLI opens an auth page *on the
   remote*, and the OAuth callback wants `localhost` — the wrong machine from your laptop. agent-mac-ops
   forwards ports automatically and can **hand remote browser opens back to your Mac**, so logins and
   local dev servers Just Work. See **[docs/REMOTE-AUTH.md](docs/REMOTE-AUTH.md)**.

## Requirements

- **macOS + iTerm2 _or_ Ghostty** on the control machine — for the native-window magic. iTerm2 uses
  `tmux -CC` (Terminal.app won't do it, WezTerm only partially); Ghostty (≥ 1.2.0) uses native splits
  that each auto-ssh in. `box` auto-detects which you're using. *(The agent-ops half —
  status/logs/revive/digest — is plain SSH + bash and works against any host.)*
- **tmux** on the remote (`brew install tmux`).
- **SSH reachability** to the remote. [Tailscale](https://tailscale.com) is the recommended way (no
  public exposure, works from anywhere) but anything your `ssh` can reach is fine — just put a Host
  alias in `~/.ssh/config` and use its name.
- `python3` and `curl` on the control machine (both ship with macOS) for the optional webhook digest.

## Quickstart

```bash
git clone https://github.com/<you>/agent-mac-ops && cd agent-mac-ops
./setup.sh            # prompts for host, hostname, dirs, alias, webhook → writes config.env
./setup.sh remote     # pushes the dev-session launcher to the remote

# add to ~/.zshrc, BEFORE your iTerm2 shell-integration line:
source /path/to/agent-mac-ops/control/shell-snippet.sh

# iTerm2: follow SETUP.md for the profile + Automatic Profile Switching (the coloring)
# Ghostty: nothing else to do — see SETUP.md §4b
```

Now:

- **`box`** (or whatever alias you chose) → native, colored window into the remote (iTerm2 `-CC`
  panes, or Ghostty native splits — auto-detected). Ghostty adds **`box-tmux`** for a persistent
  session that survives disconnect.
- **Point your agent at `control/ops/`** and say *"check on the box."*
- **Browser handoff:** `control/bin/install-open-listener.sh` so remote auth pages open on your Mac.
- **Optional:** `control/ops/bin/install-launchd.sh` for a daily health digest.

## How it works

```
control machine (your laptop)                     always-on Mac (the remote)
─────────────────────────────                     ──────────────────────────
shell-snippet.sh  → `box` ───────── ssh -t ───▶   ~/dev-session.sh
   (iTerm2)                                          └─ tmux -CC attach  ──▶ native iTerm2 windows
   (Ghostty) ghostty-connect.sh ─── ssh -t ───▶      └─ login shell / tmux ─▶ native Ghostty splits
control/ops/AGENTS.md  ← your agent reads this
control/ops/bin/remote-run.sh ── ssh + stdin ──▶   status.sh / logs.sh / revive.sh (run, then gone)
control/ops/bin/daily-check.sh ── launchd ──▶      webhook digest (Slack/Discord/…)
open-listener.py  ◀── reverse tunnel (-R) ─────    ~/bin/open shim (opens auth URLs on your Mac)
your localhost:3000  ◀── forward (-L) ─────────    remote dev server / OAuth callback
```

- **Config lives in one file.** `config.env` (gitignored, written by `setup.sh`) holds the host,
  hostname, work dir, alias, webhook, etc. Every script sources it; the two `*.tmpl` files are
  rendered from it.
- **The remote stays stateless.** Only `~/dev-session.sh` lives there. The health scripts are
  *shipped over SSH on stdin* with config prepended, so there's nothing to install or keep in sync.
- **No secrets in git.** The only optional secret is the notify webhook, and it lives in the
  gitignored `config.env`. Use a webhook URL, never a bare token.

## What this is *not*

Deliberately small. It does **not** sync dotfiles, manage packages, or sync editor settings — use
[`chezmoi`](https://github.com/twpayne/chezmoi) / [`yadm`](https://yadm.io) / GNU `stow` for that.
This repo is just the two things above: agent-operable + native remote session.

## License

MIT — see [LICENSE](LICENSE).
