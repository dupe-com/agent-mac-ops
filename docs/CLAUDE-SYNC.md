# Claude sync between your laptop and the remote (optional)

## What it does

Claude Code keeps every conversation as a file on the Mac where it ran. Start a
conversation on the remote, and your laptop has never heard of it.

Claude sync copies those files between the two Macs in both directions, usually
within 10 to 20 seconds. If it misses a change, its 10-minute rescan catches it. Handoff notes from `/handoff` travel too.

`claude --resume` lists the conversations for the folder you are in. So a synced
conversation can be resumed on the other Mac when that folder exists there too, at the
same path: the repo checkout, `~/dotfiles`, your home folder. A conversation from a git
worktree that exists on only one Mac is copied, but you need that worktree on the other
Mac before you can resume it there.

A conversation still *runs* on one Mac at a time. This copies the files it leaves
behind. It does not move a live session.

It is off by default, and it is per person. On a shared remote, turning it on for
yourself changes nothing for anyone else.

## What is copied, and what is not

| Copied | Not copied |
|---|---|
| `~/.claude/projects` (conversation transcripts) | `~/.claude/projects/*/memory`, which iCloud already shares (see below) |
| `~/.claude/handoffs`, only the notes (`latest.md`, `archive-*.md`, `.picked-up`) | anything else saved inside a handoff folder: work files, scripts, git checkouts |
| any extra folder you list in `CLAUDE_SYNC_FOLDERS` | credentials, `~/.claude.json`, settings (your dotfiles handle those) |
| | sessions started in temporary folders (`/private/tmp/...`), which belong to their Mac |
| | `.git` and `node_modules` in extra folders |

Each project's `memory` folder is a link into iCloud Drive, made by
`dotfiles/bin/link-memory.sh`. The sync skips those links completely, so iCloud
stays the only thing that shares memory.

## How it works

It uses [Syncthing](https://syncthing.net), a free, open-source file sync program.
Each Mac runs its own copy for your user, started at login by launchd (macOS's
background-service manager).

The two Macs talk directly over your Tailscale link. Syncthing's usual ways of finding
other devices (its public discovery servers, local network broadcasts, and public
relays) are all turned off before it first starts. So your transcripts never pass
through anyone else's server. Syncthing does listen on every network interface (port
22000 by default), but it only accepts the one device it was paired with. Syncthing's control page is on a private file
(`~/.claude-sync/gui.sock`) that only your user can open, not on a network port.

## Turning it on

Run these from the repo on your laptop. Allow 15 to 30 minutes, most of it waiting
for the first copy.

```bash
control/bin/claude-sync.sh plan      # read-only: sizes, and what the first sync will do
control/bin/claude-sync.sh install   # installs Syncthing on both Macs (asks first); folders start paused
control/bin/claude-sync.sh backup    # snapshot of every synced folder on both Macs
control/bin/claude-sync.sh start     # the first real sync
```

`plan` changes nothing. It lists, for each folder, which files exist only on one
Mac (those get copied over) and which exist on both with different content. The
second kind turns into a conflict copy on the first sync (see below).

`backup` uses APFS clones: copies that share disk space with the original until
one of them changes, so even 11 GB costs almost nothing. They land in
`~/.claude-sync/backup-<time>/` on each Mac. `start` refuses to run without a backup
from the same day.

On a shared remote, set your own `CLAUDE_SYNC_PORT` first (22000 + your index; see
[host-registry.md](host-registry.md)).

## Day to day

Nothing to do. Check on it with:

```bash
control/bin/claude-sync.sh status
```

"Check on the box" (`status.sh`) includes one `sync:` line for anyone who has it on.
It warns only about conflict copies, folder errors, or a stopped service. A sleeping
laptop is normal. The report says when it was last seen and how many files are
waiting for it.

## Conflict copies

If the same file changes on both Macs before they talk, Syncthing keeps both. The
newer one keeps the real name. The other is renamed with `.sync-conflict-<date>-...`
in the middle.

For a conversation, this happens if it is open on both Macs at once. The conflict copy
still ends in `.jsonl`, so `claude --resume` may list it as an extra session. A
conflict copy of a handoff note stays on the Mac where it appeared, because only
`latest.md`, `archive-*.md` and `.picked-up` travel. The health check flags every
conflict copy. To move them out of the way:

```bash
control/bin/claude-sync.sh conflicts          # list them
control/bin/claude-sync.sh conflicts --park   # move them to ~/.claude-sync/conflicts/
```

## Handoffs

The `/handoff` pickup loads a note once, then writes the note's timestamp into
`.picked-up` next to it. That marker syncs too. So a handoff is served once in total,
by whichever Mac first starts a session in that folder, not once on each Mac.

## Deleted files

Claude Code deletes conversations older than 30 days (`cleanupPeriodDays`) on its
own. With sync on, a deletion on one Mac also deletes the file on the other Mac.
Both Macs would delete the same files at about the same time anyway. In case of
mistakes, each Mac keeps deleted or overwritten files for 30 days in
`~/.claude-sync/versions/<folder>/`.

One exception: if a project folder is deleted on one Mac while the other Mac has a
`memory` folder or link inside it, the other Mac keeps that folder. The sync never
deletes memory. `status` lists these as "kept here", without a warning.

The snapshots from `backup` are never deleted automatically. Once you trust the sync,
remove them with `rm -rf ~/.claude-sync/backup-*` on each Mac.

## Pausing and removing

```bash
control/bin/claude-sync.sh pause       # stop syncing; resume with `start`
control/bin/claude-sync.sh uninstall   # stop and remove the services on both Macs
```

`uninstall` keeps every file, plus `~/.claude-sync` (keys, versions, backups). It
prints the commands to remove the rest.

## Files

| Where | What |
|---|---|
| `control/bin/claude-sync.sh` | what you run, on the laptop; drives both Macs |
| `remote/claude-sync-node.sh` | the per-Mac half; copied to `~/.agent-mac-ops/` on both |
| `~/.claude-sync/` (each Mac) | Syncthing config and keys, API key, versions, backups, parked conflicts |
| `~/Library/LaunchAgents/com.agent-mac-ops.claude-sync.plist` | the login service |
| `~/Library/Logs/agent-mac-ops-claude-sync.log`, `~/.claude-sync/syncthing.log` | logs |
| `.stignore`, `.stfolder` in each synced folder | Syncthing's ignore rules and folder marker |
