# Host Registry

Each developer on the shared Mac Studio gets a loopback IP and named hostname.
Dev servers run on standard ports — web :3000, api :8080 — bound to the user's IP.

| User | Index | Loopback IP | Hostname | Handoff port |
|------|-------|-------------|----------|--------------|
| _admin_ | 1 | 127.0.0.1 | (the remote itself) | 17999 (in use) |
| bobby | 2 | 127.0.0.2 | bobby.studio | 18002 _(reserved)_ |
| marko | 3 | 127.0.0.3 | marko.studio | 18003 _(reserved)_ |

Only the admin's port is actually configured anywhere. The other rows are what the
rule below reserves for those slots — nobody has set them in a `config.env` yet, so
treat them as claimed, not live, and set them the next time each person is onboarded.

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

Index 1 (`127.0.0.1`) is the admin — it always exists and needs no alias or LaunchDaemon.
The admin's handoff port is historically 17999, which predates the `18000 + index` rule;
it is left alone because the remote's `~/bin/open` shim has it baked in.

Slots run 1–9. Claim the next free row here before running `provision-user.sh`.
