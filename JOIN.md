# Joining a team Mac

Someone on your team runs an always-on Mac (for example a Mac Studio under a desk), and they've
offered you an account on it. Once you're set up, your Claude Code sessions run on that Mac instead
of your laptop. They keep running when you close the lid, and your laptop fan stays quiet.

You don't need to read this whole page. Your coding agent does the setup and stops when it needs you.

## What you need first

- **From your admin:** your username, your slot number, and the team Mac's Tailscale name. Your
  admin also sends you a Tailscale invite.
- **On your laptop:** macOS, Claude Code (or another coding agent), iTerm2 or Ghostty, and the
  Xcode Command Line Tools (`xcode-select --install`, if `git --version` asks you to install them).

## Copy and paste this into Claude Code on your laptop

Your admin usually sends you this with the blanks already filled in.

```text
Set me up on our team's always-on Mac.
My username is <username>, my slot is <slot>, and the Mac's Tailscale name is <mac-name>.
Clone https://github.com/dupe-com/agent-mac-ops into ~/Work/agent-mac-ops (or pull it if it's
already there), read JOIN.md, and follow "Steps for the agent" one at a time.
Tell me in plain language what each step does, and stop whenever a step needs me.
```

It takes about 20 minutes. You'll be asked to do three things yourself:

1. Install Tailscale and accept the invite.
2. Send your public SSH key to your admin. The key is safe to share.
3. Log in to Claude Code on the team Mac, in a browser window that opens on your laptop.

---

## Steps for the agent

You are setting up a teammate's laptop to use a shared always-on Mac. The teammate's prompt gives
you three values: `USERNAME`, `SLOT` (a number from 2 to 9), and `MAC` (the Tailscale name). If any
of them is missing, ask for it. Don't guess.

Rules for the whole run:

- Do one step at a time. Before each step, say in one plain sentence what it does.
- A step marked **YOU** needs the human. Say exactly what to do, then wait for them to confirm.
- You can't type a password. If anything needs `sudo`, give the human the full command to run as
  `! <command>` in the prompt.
- Every step can be run again safely. Check first and skip whatever is already done.
- Don't touch anything on the team Mac outside the teammate's own account.

Derived values:

- `LOOPBACK` = `127.0.0.<SLOT>`
- `HANDOFF_PORT` = `18000 + SLOT`, for example 18002 for slot 2

### 1. Tailscale (YOU)

Check whether the Mac is reachable: `ping -c 1 -t 3 <MAC>`. If it is, skip this step.

If it isn't, tell the human to do the following:

1. Install the **Standalone** Tailscale app from tailscale.com/download, not the App Store build.
2. Sign in with the email their admin invited.
3. Accept the invite.

Then check again.

### 2. SSH key (YOU)

1. Use `~/.ssh/id_ed25519` if it exists. If that key has a passphrase and isn't loaded yet
   (`ssh-add -l` doesn't list it), ask the human to run `! ssh-add --apple-use-keychain ~/.ssh/id_ed25519`.
   Otherwise the `BatchMode` checks below fail even after the account exists.
2. If it doesn't, create one: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "<USERNAME>@team"`.
3. Copy the public key to the clipboard with `pbcopy < ~/.ssh/id_ed25519.pub`.

Show the key to the human. Ask them to send it to their admin (for example in the Slack thread) and
to tell you once the admin says they're provisioned.

### 3. Test the connection

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -i ~/.ssh/id_ed25519 <USERNAME>@<MAC> 'hostname -s'
```

Save the output as `REMOTE_HOSTNAME`.

If the test fails, the admin probably hasn't provisioned the account yet. Say so and wait. Don't
retry in a loop.

### 4. SSH shortcut

If `~/.ssh/config` has no `Host studio` block, add this one:

```sshconfig
# Team Mac, added by agent-mac-ops JOIN.md
Host studio
    HostName <MAC>
    User <USERNAME>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 10
```

If a `Host studio` block already exists but points somewhere else, stop and ask the human what to do.

Check it with `ssh -o BatchMode=yes studio true`.

### 5. Write config.env and render

Work in the repo you cloned. Copy `config.env.example` to `config.env` and set these values. Leave
everything else at its default.

| Key | Value | Why |
|---|---|---|
| `REMOTE_HOST` | `studio` | the SSH shortcut from step 4 |
| `REMOTE_HOSTNAME` | the value from step 3 | colors the remote window |
| `WORK_DIR` | `~/Work` | where new sessions open on the team Mac |
| `REMOTE_BIND` | `<LOOPBACK>` | **required.** If you leave the default, the human's `localhost:3000` reaches the admin's dev server instead of their own, and nothing warns them. |
| `HANDOFF_PORT` | `<HANDOFF_PORT>` | **required.** It must be unique on the team Mac. If two people share it, the second person's browser handoff never connects. |
| `HANDOFF_TOKEN` | the output of `uuidgen` | the shared secret for the browser handoff |

If `config.env` already exists, edit it in place. Keep its `HANDOFF_TOKEN` only if it isn't empty.
An empty token turns off the handoff listener's authentication, which would let other users on the
team Mac reach this laptop's listener through the tunnel. `./setup.sh render` doesn't generate one,
so if it's empty, set it to `uuidgen` output yourself.

Then run:

```bash
ssh studio 'mkdir -p ~/Work'
./setup.sh render    # builds the shell snippet from config.env, with no prompts
./setup.sh remote    # installs the session launcher and the `open` shim on the team Mac
```

`./setup.sh remote` may print that tmux or mosh is missing on the remote. Ignore that. Its check
runs without Homebrew on the PATH, and the teammate's real shell has both. Never run `brew install`
on the team Mac: Homebrew belongs to the admin, and the teammate can't write to it.

### 6. Shell snippet

Add `source <repo>/control/shell-snippet.sh` to `~/.zshrc`, unless it's already there.

If `~/.zshrc` sources iTerm2 shell integration, the snippet line must come **before** that line.
Read the file and put it in the right place.

### 7. Browser and editor handoff

```bash
control/bin/install-open-listener.sh
control/bin/install-handoff-tunnel.sh
```

With these installed, login pages that a tool opens on the team Mac open in the human's own browser.
Claude Code's login in step 9 depends on this.

Check that the tunnel is up: `ssh studio "nc -z 127.0.0.1 <HANDOFF_PORT>"` should exit 0. It can
take up to a minute after installing.

### 8. Health check

Run `control/ops/bin/remote-run.sh status.sh` and summarize the result in a sentence. `tmux: dev down`
is normal here, because the session starts the first time the human runs `box`.

### 9. Hand over (YOU)

Tell the human to:

1. Open a **new** terminal window, so the shell snippet loads.
2. Connect to the team Mac:
   - **iTerm2:** type `box`. A native, resizable window opens, and `Cmd+D` splits it. Sessions keep
     running when the laptop disconnects, and `box` reattaches to them.
   - **Ghostty:** type `box-tmux`, not `box`. Plain `box` gives native splits that end when the
     laptop disconnects, so Claude sessions there wouldn't survive a closed lid. In `box-tmux`, the
     panes are tmux panes (prefix `Ctrl-b`), and SETUP.md §4c lists the keys.
3. Install Claude Code for their account on the team Mac:
   `curl -fsSL https://claude.ai/install.sh | bash`, then open a new pane. It installs into their
   home folder, so it doesn't need the admin.
4. Run `claude` and log in. The login page should open in their laptop's browser.
5. Run `gh auth login` and clone their repos into `~/Work`.
6. Start dev servers on `<LOOPBACK>`, not on every address. Their shell already has
   `DEV_HOST=<LOOPBACK>`, and `~/.env.local.template` holds the matching values to copy into a
   project's `.env.local`. A server on `0.0.0.0` collides with the admin's ports. While `box` is
   connected, `http://localhost:3000` and `:8080` on the laptop reach the teammate's own servers.

**Optional, iTerm2 only:** to give remote windows a different color from local ones, set up the
profile in SETUP.md §3. It takes about 5 minutes of clicking, and nothing breaks without it.

Finish by telling the human what was set up and what is still optional. If any step was skipped or
failed, say which one.
