# SETUP

The full setup, including the iTerm2 GUI steps that no amount of config files can do for you.
This is the part people get stuck on — it took several dead ends to get right, so it's spelled out.

**On Ghostty?** Sections 3–4 are iTerm2-only GUI steps — skip them. Do §1–2, then jump to
**[§4b. Ghostty](#4b-ghostty-instead-of-or-alongside-iterm2)** (no GUI clicking) and §5 to verify.

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

## 4b. Ghostty (instead of, or alongside, iTerm2)

Ghostty has **no `tmux -CC`** — Mitchell's building control mode incrementally (issue #1935) but it
isn't wired to the GUI yet, so the iTerm trick above can't render a remote tmux as native panes.
Ghostty's "native" is its *own* GPU splits, so the model is different: `<alias>` opens a new Ghostty
instance whose **every native split/tab auto-ssh's into the remote**. No GUI clicking, no profiles —
it's all in `shell-snippet.sh`, and `<alias>` auto-detects your terminal (`$TERM_PROGRAM`), so the
same command does the right thing in either app.

You get **two commands** (pick per session):

| Command | What you get | Trades off |
|---|---|---|
| `<alias>` | Native Ghostty splits — `Cmd+D` / `Cmd+T` each open a **fresh remote shell**, instantly (they ride a shared SSH master, no re-auth). Closest thing to the iTerm feel. | No layout survives disconnect — run `<alias>-tmux`, or `tmux` by hand, when you want that. |
| `<alias>-tmux` | One window running `tmux attach` — **survives disconnect** and reattaches as you left it. | tmux-drawn panes + tmux keybinds (`Ctrl-b`), not native Ghostty splits. |

### One-time bits

1. **Coloring (the APS replacement).** Ghostty has no Automatic Profile Switching. Instead the remote
   shell emits an `OSC 11` to tint the background, set by `GHOSTTY_REMOTE_COLOR` in `config.env`
   (default a dark purple; blank to disable). It's reset on logout by an `EXIT` trap, with a local
   safety-net reset in `ghostty-connect.sh` for hard drops — because, unlike iTerm APS, **Ghostty
   won't auto-revert the color.** Re-run `./setup.sh render && ./setup.sh remote` after changing it.
2. **Terminfo.** `<alias>` launches Ghostty with `shell-integration-features=ssh-env,ssh-terminfo`
   (Ghostty ≥ 1.2.0), which installs Ghostty's terminfo on the remote so you never hit
   `missing or unsuitable terminal: xterm-ghostty`. Nothing to configure.
3. **Forwards / browser handoff.** The first connection opens a shared SSH master carrying the same
   `-R`/`-L` forwards as the iTerm path, and every split rides it — so handoff and port forwarding
   work identically. (If you run `<alias>-fwd` *before* `<alias>` in a session, it makes a
   forward-less master first; just run `<alias>` once to establish the tunnel.)

That's it — no profile to create, no APS rule, none of §3 above. Skip to §5 to verify.

---

## 4c. mosh — snappy typing on a laggy link (either terminal)

Typing over SSH has no local echo: every keystroke round-trips to the remote and back, so your
felt latency is your network RTT. On a high-latency or jittery link that's the difference between
"native" and "sluggish." **mosh** fixes it with *predictive local echo* — characters appear instantly
and reconcile with the server asynchronously. It's the one thing that beats the round-trip floor.

```bash
<alias>-mosh
```

Works in **both** iTerm2 and Ghostty (it's a normal full-screen CLI session, not `-CC` or native
splits). The trade-offs and how it fits:

- **Single session, not native panes.** mosh can't do `tmux -CC` or shared-master splits, so
  `<alias>-mosh` runs `tmux attach` *inside* mosh — you get persistence + panes via tmux keybinds
  (`Ctrl-b`), and the session survives disconnect (mosh reconnects automatically when you roam).
- **Forwards/handoff still work.** mosh can't carry `-R`/`-L` forwards, but `<alias>-mosh` first
  brings up the same detached SSH master the other modes use (it holds the browser-handoff reverse
  tunnel + `FORWARD_PORTS`), so port forwarding and remote-auth handoff are unaffected.
- **Requirements:** mosh on both ends (`./setup.sh remote` installs it on the remote and records the
  `mosh-server` path in `config.env`; `brew install mosh` locally), and **UDP 60000–61000** reachable
  between the two. Tailscale carries UDP, so it works out of the box over a tailnet; on a plain LAN/VPN
  make sure those UDP ports aren't firewalled. The initial handshake still uses SSH (your existing
  keys/aliases), then it hands off to UDP.
- **Tinting:** mosh has its own terminal model and may not pass the `GHOSTTY_REMOTE_COLOR` background
  tint through — the tmux session + window title still mark it as the remote.

### Why no native panes (and the tmux keybinds you use instead)

iTerm's native panes come from tmux `-CC` control mode, which needs a *transparent byte pipe* between
tmux and iTerm. mosh doesn't provide one — `mosh-client` is its own terminal emulator that syncs screen
*state* over UDP, so tmux's control sequences never reach iTerm. The two are fundamentally incompatible;
there's no flag that bridges them. That trade — native panes for predictive echo — is the whole reason
`<alias>-mosh` is a separate command. So inside it you split/navigate with tmux's own keybinds
(default prefix `Ctrl-b`):

| Action | Keys |
|--------|------|
| Split **vertically** (panes side-by-side) | `Ctrl-b %` |
| Split **horizontally** (panes stacked) | `Ctrl-b "` |
| Move between panes | `Ctrl-b ←/↑/→/↓` (or `Ctrl-b o` to cycle) |
| New window (≈ new tab) | `Ctrl-b c` |
| Next / previous window | `Ctrl-b n` / `Ctrl-b p` |
| Jump to window *N* | `Ctrl-b <0-9>` |
| Zoom the current pane (toggle fullscreen) | `Ctrl-b z` |
| Close the pane | `Ctrl-b x` (confirm `y`) |
| Detach (leave it running, reattach later) | `Ctrl-b d` |
| Scroll / copy mode (then arrows/PgUp; `q` to exit) | `Ctrl-b [` |

New panes and windows inherit the **active pane's cwd** — the `command-alias` fix in `dev-session.sh`
rewrites the built-in `split-window`/`new-window`, so `Ctrl-b %`/`"` open where you were, not `$HOME`.

> Prefer native iTerm panes? Use the default `<alias>` (it persists via `-CC`). Reach for `<alias>-mosh`
> only when the link is laggy enough that predictive echo is worth giving up native panes.

Re-source your shell snippet (or open a new terminal) after `./setup.sh remote` so `<alias>-mosh` is defined.

---

## 5. Verify

```bash
<alias>
```

**iTerm2:** a native iTerm2 window, resizable, colored as `Remote`, sitting in your `WORK_DIR` on the
remote. `Cmd+D` splits a pane that's also on the remote.

**Ghostty:** a new Ghostty window tinted with `GHOSTTY_REMOTE_COLOR`, sitting on the remote. `Cmd+D`
opens a native split that auto-ssh's into the remote (near-instant — it rides the shared master).
`<alias>-tmux` instead gives you a persistent tmux session.

**`<alias>-mosh` (either terminal):** a full-screen tmux session over mosh — type and characters appear
instantly even on a laggy link (predictive echo). If it hangs at connect, it's almost always UDP
60000–61000 being blocked (see §4c).

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

## 6. Remote auth & localhost forwarding

If you ever log into a CLI/tool on the remote or run a dev server, set this up — it's the difference
between Screen Sharing and "it just works":

```bash
control/bin/install-open-listener.sh   # browser handoff: remote auth pages open on YOUR Mac
```

`FORWARD_PORTS` in `config.env` are forwarded automatically on connect; use `box-fwd` for ad-hoc
ports (including random OAuth callbacks). Full details, recipes, and the security model are in
**[docs/REMOTE-AUTH.md](docs/REMOTE-AUTH.md)**.

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
| **(Ghostty)** `missing or unsuitable terminal: xterm-ghostty` | terminfo not installed on the remote. `<alias>` passes `ssh-terminfo` automatically (needs Ghostty ≥ 1.2.0); for a manual ssh, run `ghostty +ssh-cache` or set `shell-integration-features = ssh-env,ssh-terminfo` in `~/.config/ghostty/config`. |
| **(Ghostty)** background **stays tinted** after you disconnect | A hard ssh drop skipped the reset. Open a fresh `<alias>` split (each surface resets its own background), or set `GHOSTTY_REMOTE_COLOR=""` to disable tinting. |
| **(Ghostty)** new splits are **local**, not on the remote | You opened the split in a *different* Ghostty window/instance than the one `<alias>` launched. The auto-ssh only applies to surfaces inside the instance `<alias>` opened (its `command` is per-instance). |
| **(Ghostty)** `<alias>` did nothing / "couldn't launch Ghostty" | Ghostty isn't installed where `open -na Ghostty` can find it. Install it, or use iTerm2 — `<alias>` falls back to the iTerm path automatically when `$TERM_PROGRAM` isn't `ghostty`. |
| **(mosh)** `<alias>-mosh` hangs at "Connecting…" then times out | UDP 60000–61000 blocked between you and the remote. Over Tailscale it should just work; on a plain network open those UDP ports. The SSH handshake working but UDP not = this. |
| **(mosh)** `mosh-server: command not found` | The remote `mosh-server` path isn't pinned. Re-run `./setup.sh remote` (it discovers it and bakes `MOSH_SERVER` into `config.env`), or `brew install mosh` on the remote. |
| **(mosh)** typing is snappy but the **background isn't tinted** | Expected — mosh's terminal model may drop the OSC-11 tint. The tmux session + window title still mark it as remote. |

> All of the above is **per-machine iTerm2 GUI state** — it can't be shipped in this repo. A rebuilt
> Mac needs steps 3–4 redone. Everything else (`config.env`, scripts, dev-session.sh) is reproducible
> from the repo.
