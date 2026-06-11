# SETUP

The full setup, including the iTerm2 GUI steps that no amount of config files can do for you.
This is the part people get stuck on — it took several dead ends to get right, so it's spelled out.

Throughout, `<alias>` = the connect command you chose (default `box`), `<host>` = your `REMOTE_HOST`,
and `<Hostname>` = your `REMOTE_HOSTNAME` (the remote's `hostname -s`).

---

## 1. Remote prep (on the always-on Mac)

Do these once, on the remote itself (or over an existing SSH session):

1. **Enable SSH:** System Settings → General → Sharing → **Remote Login = ON**.
2. **Install tmux:** `brew install tmux`.
3. **Keep it awake:**
   ```bash
   sudo pmset -a sleep 0           # never sleep
   sudo pmset -a disablesleep 1    # laptops only: stay awake with the lid closed
   ```
4. **(Recommended) Tailscale:** install it on both machines and sign in, so the remote is reachable
   from anywhere without exposing SSH to the internet.

Then add a Host alias on the **control** machine in `~/.ssh/config`, so `ssh <host>` just works:

```sshconfig
Host <host>
    HostName <Tailscale-IP-or-hostname>
    User <your-remote-username>
```

Verify: `ssh <host> 'hostname -s && tmux -V'` should print the hostname and a tmux version.

---

## 2. Control prep (on your laptop)

```bash
./setup.sh          # writes config.env, renders shell-snippet.sh + remote/dev-session.sh
./setup.sh remote   # scp's dev-session.sh to the remote
```

Add the snippet to your `~/.zshrc` — **before** the line that sources iTerm2 shell integration:

```bash
source /path/to/agent-mac-ops/control/shell-snippet.sh
# ... your existing iTerm2 shell integration line comes AFTER ...
[ -f ~/.iterm2_shell_integration.zsh ] && source ~/.iterm2_shell_integration.zsh
```

Why the order matters: the snippet exports `ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX=1`, and that
flag must be set *before* the integration script is sourced. See step 4 for what it fixes.

Open a fresh terminal so the new `~/.zshrc` is loaded.

---

## 3. The iTerm2 "Remote" profile (the coloring)

This is what makes the remote window obviously *not* localhost.

1. iTerm2 → **Settings → Profiles → `+`** to add a profile. Name it whatever you set as
   `PROFILE_NAME` (default `Remote`).
2. **Colors** tab → pick a **Color Preset** that's clearly different from your default (a dark teal
   or purple reads well as "this is the remote").
3. Leave everything else default. You do **not** need to set a Command or login shell on this
   profile — the `<alias>` handles connecting; this profile only supplies the *look*.

### Wire it to the host with Automatic Profile Switching (APS)

This is the magic that recolors the window the moment you're on the remote:

1. Still in the `Remote` profile → **Advanced** tab → **Automatic Profile Switching** → **Edit Rules**.
2. Add a rule:
   ```
   <your-remote-username>@<Hostname>*
   ```
   - Example: `ramin@Ramins-Mac-Studio*`
   - **The trailing `*` is load-bearing** — iTerm matches against the FQDN, which is usually
     `<Hostname>.local`, so a rule without the `*` silently never fires.
3. Close settings.

APS is driven by iTerm2 shell integration reporting the remote host. Which is exactly why step 4 exists.

---

## 4. Why `tmux -CC` (and the one flag that makes it all work)

The `<alias>` runs `ssh -t <host> '~/dev-session.sh'`, and that script does **`tmux -CC attach`**.

- **`tmux -CC` is iTerm2 control mode.** iTerm2 renders the remote tmux session as **native iTerm
  windows, tabs, and panes** — resizable, `Cmd+D` / `Cmd+T` create real splits/tabs that are
  connected to the remote, and normal keys work. Plain `tmux attach` instead gives you a single
  full-screen pane with tmux keybindings and no native splits. `-CC` is the whole point.
- **The non-obvious part:** iTerm2's shell integration *self-disables inside tmux* (it checks
  `$TERM` and bails when it's `tmux-256color` / `screen`). With integration off, the remote host is
  never reported, so **APS has nothing to match and your window stays the default color.** That was
  the multi-dead-end bug.
- **The fix** (already in `shell-snippet.sh`): `export ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX=1`
  before sourcing integration. Now the host is reported from inside the `-CC` session and APS flips
  the window to your `Remote` profile.

Connect **once** per session — re-running `<alias>` spawns a second tmux client and dumps raw
control-mode protocol. Use iTerm's own shortcuts (`Cmd+D`, `Cmd+T`) after you're in.

---

## 5. Verify

```bash
<alias>
```

You should get a native iTerm2 window, resizable, colored as `Remote`, sitting in your `WORK_DIR` on
the remote. `Cmd+D` splits a pane that's also on the remote.

```bash
control/ops/bin/remote-run.sh status.sh
```

Prints host/uptime/disk/tmux/repo. Then point your agent at `control/ops/` and ask it to *"check on
the box."*

Optional daily digest:

```bash
control/ops/bin/install-launchd.sh   # runs daily-check.sh at config.env's CHECK_HOUR:CHECK_MIN
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Window opens but stays the **default color** | APS not firing. Check the rule has the trailing `*` and matches `whoami@$(hostname -f)` on the remote. Confirm the integration flag: `echo $ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX` should print `1` in a local shell, and the snippet must be sourced *before* integration. |
| **First** pane is default-colored until you press a key | Known APS startup-timing gap — the first keystroke triggers the host report and it flips. Zero-flash fix: open iTerm Settings while a `-CC` window is up, find the auto-created **`tmux`** profile, and apply the same Color Preset to it (it's the base profile for all `-CC` windows). |
| `Cmd+D` prints a `|` (or other) instead of splitting | Your `Remote` (or `tmux`) profile has **Keys → Key Mappings** that hijack `Cmd+D` for a tmux prefix. Delete those mappings so native iTerm shortcuts work under `-CC`. |
| Stuck on raw `%output … %layout-change …` text | You attached twice. Close the extra window; press `q`/`Ctrl-C`/Enter in the gateway to recover. Connect once and use iTerm shortcuts. |
| A **`tmux`** profile keeps reappearing after you delete it | Expected — iTerm2 recreates it on every `-CC` connect as the base profile. Don't fight it; color it (see above) instead. |
| `could not reach <host>` in the digest | SSH/network. Test `ssh <host> true`; check Tailscale is up on both ends and Remote Login is on. |

> All of the above is **per-machine iTerm2 GUI state** — it can't be shipped in this repo. A rebuilt
> Mac needs steps 3–4 redone. Everything else (`config.env`, scripts, dev-session.sh) is reproducible
> from the repo.
