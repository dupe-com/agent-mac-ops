# agent-mac-ops — scope / plan

> Status: **v1 BUILT (2026-06-11).** Public open-source target. Local git repo, pushed to GitHub.
> **v1.1 (2026-06-11): Ghostty support added** — `box` auto-detects iTerm2 vs Ghostty; Ghostty uses
> native splits (each auto-ssh's via a shared SSH master) + `box-tmux` for a persistent session, with
> OSC-11 tinting standing in for iTerm's APS and remote terminfo install to fix keystroke doubling.
> Decisions resolved: cross-terminal (iTerm2 + Ghostty), ops half portable; runbook = `AGENTS.md` (cross-tool).
> Tier 2 remote-auth feature added (port forwarding + browser handoff) per user request.
>
> Built so far: README, SETUP.md, docs/REMOTE-AUTH.md, config.env.example, setup.sh (init/remote),
> control/shell-snippet.sh.tmpl, control/ops/AGENTS.md, control/ops/bin/{remote-run,status,logs,revive,daily-check,install-launchd}.sh,
> control/bin/{box-fwd.sh,open-listener.py,install-open-listener.sh}, remote/{dev-session,open-handoff}.sh.tmpl, LICENSE (MIT).
> All scripts syntax-checked; templates render clean; listener token/scheme guards tested (403/400).
> Not yet done: push to GitHub; real end-to-end test against a live remote + iTerm2 GUI; optional CI/shellcheck.

## What it is (one line)
A drop-in `ops/` folder + connection recipe that turns any always-on Mac into something you
operate by talking to Claude ("check on my box") and connect to as native, resizable panes —
iTerm2 (`tmux -CC`) or Ghostty (native splits), auto-detected.

## Origin
Extracted from a private dotfiles repo (`github.com/i8ramin/sys-dotfiles`). Only the two genuinely
novel, hard-won pieces are being packaged:
1. **Agent-operable always-on Mac** — open a folder, say "check on the Studio," agent SSHes in,
   runs status/logs/revive scripts, reports in plain language + posts a daily digest.
2. **The `studio` → native-iTerm tmux recipe** — `tmux -CC` + `ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX=1`
   + iTerm Automatic Profile Switching for auto-coloring. Took 3 dead ends + a root-cause dig to land.

## Repo layout
```
agent-mac-ops/
├── README.md                 # the pitch + 60-second quickstart
├── SETUP.md                  # the iTerm2 GUI clicks (the part everyone gets stuck on) + §4b Ghostty
├── config.env.example        # all the knobs; copied → config.env (gitignored)
├── setup.sh                  # prompts, templatizes, optionally preps the remote over SSH
├── control/                  # lives on your laptop
│   ├── shell-snippet.sh      # `box`/`box-tmux` (terminal-detecting) + ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX=1
│   ├── bin/ghostty-connect.sh # Ghostty's per-surface auto-ssh launcher (native | tmux)
│   └── ops/                  # the agent runbook — point Claude/Codex at this folder
│       ├── AGENTS.md         # generic twin of studio-ops/CLAUDE.md
│       └── bin/{status,logs,revive,daily-check}.sh
└── remote/
    └── dev-session.sh        # scp'd to the always-on Mac; iTerm -CC / Ghostty native / Ghostty tmux modes
```

## What gets templatized (the de-personalizing)
Every hardcoded value becomes a key in `config.env`, sourced by every script.

| Knob | Private origin | Public default |
|---|---|---|
| `REMOTE_HOST` | `studio` (ssh alias) | prompted; any reachable SSH host |
| `REMOTE_HOSTNAME` | `Ramins-Mac-Studio` | from `hostname -s`; feeds the APS rule `…*` |
| `WORK_DIR` | `~/Work/dupe-com/...` | `~` default, prompted |
| `TMUX_SESSION` | `dev` | `dev` |
| `PROFILE_NAME` | `Studio` | prompted (iTerm profile name) |
| `NOTIFY_WEBHOOK` | Slack | optional; "any webhook URL — Slack/Discord/etc." |
| `ALIAS_NAME` | `studio` | prompted (the shell command you'll type) |

Connection layer is **Tailscale-recommended-but-optional** — scripts only ever do `ssh $REMOTE_HOST`,
so it works over any SSH reachability; Tailscale is just one suggested way to get there.

## SETUP.md outline (the high-value doc — what's missing from the internet)
1. **Remote prep:** enable Remote Login, disable sleep (`sudo pmset -a sleep 0` / `disablesleep 1` for
   a laptop lid), install tmux, drop in `dev-session.sh`.
2. **Control prep:** `./setup.sh`, add the shell snippet, `source`.
3. **iTerm2 profile + native-tmux recipe** (with screenshots):
   - Create a profile; pick a distinct Color Preset.
   - Profile → Advanced → **Automatic Profile Switching** → add rule `user@REMOTE_HOSTNAME*`
     (the trailing `*` is load-bearing for the `.local` FQDN from `hostname -f` — call this out).
   - Why `tmux -CC` (native windows/panes, resizable, real Cmd+D/Cmd+T) and **not** plain `tmux attach`.
   - **Root-cause fix:** iTerm shell integration self-disables inside tmux (`$TERM=tmux-256color`),
     so `RemoteHost` is never emitted and APS never fires. `export ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX=1`
     BEFORE sourcing the integration is the unlock.
   - **Gotcha to delete:** profile key-mappings that hijack Cmd+D under tmux (emit a literal `|`).
   - **Note:** first pane shows Default until first keystroke (APS startup-timing gap; the re-prompt
     emits RemoteHost → flips). Optional zero-flash = color the auto-created "tmux" base profile to match.
4. **Verify:** type the alias → native colored window; `daily-check.sh` → webhook ping.

## Explicitly NOT in the package (keeps it small + honest)
- **Dotfiles sync** (`sync.sh`, symlinks, launchd, Brewfile-source-host, secret-gates) — that's
  `chezmoi`/`yadm`/`stow` territory, done better, and ours is welded to our setup. Out.
- **Claude-memory iCloud sync** — Claude-specific and personal. Out.
- **Secret-handling layer** — package needs only one optional webhook; document "put it in
  gitignored `config.env`, use a webhook URL not a token," and stop.

## Effort & risks
- **Effort:** ~an afternoon once the two open questions are decided (scripts already exist in
  the private repo; the work is genericizing + the SETUP.md screenshots).
- **Main risk / honesty note:** the killer feature (native colored remote windows) needs **macOS +
  iTerm2 or Ghostty**. iTerm2 uses `tmux -CC` (WezTerm partial, Terminal.app none); Ghostty has no
  `-CC` so it uses native splits that each auto-ssh (≥ 1.2.0 for the ssh-terminfo fix). README is
  upfront about this; the agent-ops half (status/logs/revive/webhook) is portable to any SSH host.
- **Naming:** `agent-mac-ops`; tagline "operate your always-on Mac with Claude."

## Open questions (resolved)
1. **iTerm2-only vs cross-terminal?** → **Cross-terminal.** Shipped iTerm2-only in v1, added Ghostty in
   v1.1. `box` auto-detects `$TERM_PROGRAM`; the iTerm path is untouched, so it stayed clean + honest.
2. **Runbook target: `AGENTS.md` (cross-tool: Claude Code, Codex, Cursor) vs `CLAUDE.md`?** →
   `AGENTS.md`, for public reach.

## Source material (private repo, for the build session)
- `~/dotfiles/studio-ops/CLAUDE.md` → becomes `control/ops/AGENTS.md`
- `~/dotfiles/studio-ops/bin/{status,logs,revive,daily-check}.sh` → `control/ops/bin/`
- `~/dev-session.sh` on the Mac Studio (NOT in any repo) → `remote/dev-session.sh`
- zshrc studio block (~L188) + shell-integration block (~L348) → `control/shell-snippet.sh`
- Memory file `project_dotfiles_multi_mac_sync.md` holds the full iTerm2/`studio` saga for SETUP.md.
