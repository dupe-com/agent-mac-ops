# Host Registry

Each developer on the shared Mac Studio gets a loopback IP and named hostname.
Dev servers run on standard ports — web :3000, api :8080 — bound to the user's IP.

| User | Index | Loopback IP | Hostname | Handoff port |
|------|-------|-------------|----------|--------------|
| _admin_ | 1 | 127.0.0.1 | (the remote itself) | 17999 (in use) |

No developer slots are assigned. bobby (2) and marko (3) were deprovisioned on
2026-09-18, so both indices — and their loopback IPs, hostnames and handoff ports —
are free to reuse. Only the admin's port is configured anywhere; a row added here is
claimed, not live, until the person sets both values below in their own `config.env`.

Their rows outlived the accounts, because until `./users remove` existed nothing took
a row back out. If a row here does not match a real account on the box, the row is
wrong — `./users list`, `./users add` and `provision-user.sh` all read this file and
nothing else, so a stale row silently costs you that slot.

## The two values every user must set

`provision-user.sh` creates the account, the loopback alias and the hostname. It does
**not** write anyone's `config.env` — that lives on each person's own laptop. Two values
there are per-user, and both fail quietly if left at the default:

- **`REMOTE_BIND="127.0.0.<index>"`** — where your `-L` forwards land on the remote.
  The default `localhost` resolves on the remote to *its* 127.0.0.1, which is the
  admin's slot 1. Leave it and your `localhost:3000` reaches the admin's dev server
  instead of your own — the tunnel opens and something answers, so nothing looks wrong.
- **`HANDOFF_PORT="1800<index>"`** — the browser-handoff reverse tunnel binds this port
  on the remote's 127.0.0.1. That is a single host-wide namespace; loopback aliases do
  **not** divide it, and neither do separate macOS accounts. Two people sharing a value
  means the second tunnel can never bind and re-dials forever.

Neither value has ever been set by a real second user — both slots were provisioned
before the per-user fix landed. The first teammate onboarded after it is also the
first real test of it.

Index 1 (`127.0.0.1`) is the admin — it always exists and needs no alias or LaunchDaemon.
The admin's handoff port is historically 17999, which predates the `18000 + index` rule;
it is left alone because the remote's `~/bin/open` shim has it baked in.

Slots run 1–9. Claim the next free row here before running `provision-user.sh`, and
run `./users remove <name>` when someone leaves so the slot comes back.
