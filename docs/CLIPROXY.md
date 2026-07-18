# CLIProxyAPI — other models inside Claude Code (optional)

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) is a local Go proxy that wraps
CLI-tool OAuth sessions (ChatGPT/Codex, Gemini, Kimi, xAI, Claude) and re-exposes them as a
unified, **Anthropic-compatible** endpoint on `localhost:8317`. Point Claude Code at it with
`ANTHROPIC_BASE_URL` and it happily runs `gpt-5.6-sol`, Gemini, Kimi, … — riding whatever
subscription you already pay for (ChatGPT Plus/Pro, etc.), no per-token API keys needed.

## Quickstart

```bash
./control/bin/install-cliproxy.sh
```

Idempotent — safe to re-run. It:

1. `brew install cliproxyapi` (homebrew-core formula, no tap)
2. generates a per-machine API key at `~/.cli-proxy-api/.local-api-key` (chmod 600) and
   replaces the stock config's unsafe template keys (the proxy refuses to serve until
   they're replaced)
3. starts it as a Homebrew service (`brew services`) so it survives reboots
4. runs the ChatGPT/Codex OAuth login if no provider is connected yet (browser flow)
5. verifies the model list end-to-end and prints the `claude-gpt` shell alias

Then either paste the printed alias into your shell config, or:

```bash
./control/bin/install-cliproxy.sh --install-alias   # appends to ~/.zshrc.local
```

## Daily use

```bash
claude-gpt                          # Claude Code on gpt-5.6-sol
CLIPROXY_MODEL=gpt-5.5 claude-gpt   # any other exposed model
./control/bin/install-cliproxy.sh status   # service / auth / model list
```

The alias only sets env vars for that one invocation — plain `claude` sessions stay on
Anthropic, untouched. `ANTHROPIC_SMALL_FAST_MODEL` is routed to `gpt-5.4-mini` so Claude
Code's internal background calls work too.

More providers:

```bash
./control/bin/install-cliproxy.sh --login gemini   # also: codex, claude, kimi, xai, antigravity
```

## On the remote box (Mac Studio)

Run the same installer over an agent-mac-ops session. The only wrinkle is the OAuth
browser flow: the login opens a browser and listens on the **remote's** `localhost:1455`.
With the [browser handoff](REMOTE-AUTH.md) installed this Just Works — the auth URL opens
on your laptop and the callback port is auto-forwarded. Without it, the manual fallback:

```bash
box-fwd 1455                      # forward the Codex callback port
cliproxyapi -codex-login -no-browser   # on the remote; paste the printed URL into your laptop browser
```

Once logged in, agents on the box can use `claude-gpt` like any other command.

## Caveats (read before relying on it)

- **Tool-call fidelity is the known weak spot.** Claude Code depends on tool calls for
  every edit/command, and CLIProxyAPI's cross-protocol translation has open issues:
  deferred-tool loading can 400 on Codex-routed requests
  ([#1725](https://github.com/router-for-me/CLIProxyAPI/issues/1725)) — if a proxied
  session throws 400s, MCP servers are the likely trigger; JSON-Schema translation to
  Gemini drops fields ([#1424](https://github.com/router-for-me/CLIProxyAPI/issues/1424)).
  Treat proxied sessions as an evaluation surface, not a workhorse.
- **Local-only by design.** The proxy binds localhost and requires the generated bearer
  key. Don't expose the port (Tailscale-serve it if you must share) — the key guards your
  ChatGPT session, and there's no multi-user scoping.
- **Terms of service.** This rides your personal ChatGPT/Codex subscription through an
  unofficial client. Fine for personal experimentation; make your own call for anything
  beyond that.

## Files

| File | Purpose |
|------|---------|
| `control/bin/install-cliproxy.sh` | installer / status / login / alias |
| `$(brew --prefix)/etc/cliproxyapi.conf` | proxy config (port, api-keys) |
| `~/.cli-proxy-api/` | OAuth tokens + generated API key (never commit) |
