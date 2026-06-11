# Telemetry bridge

The in-game half is live: the historian streams every envelope + alert as
JSON over a websocket *if* a `bridge.conf` file exists on its computer.
This folder is the out-of-game half: a small Node server that receives
the stream, forwards alerts to a Discord webhook, and serves
`GET /status?token=...` (the future MCP `get_power_status` data source).

## Topology (ATM10 server is rented — Kinetic Hosting)

The MC host can't run extra processes, so the bridge runs elsewhere and
must be **publicly reachable**. Good news: that means **no CC config edit
at all** — CC's default rules only block private/LAN addresses
(`DENY $private, ALLOW *`), and a public `wss://` URL passes. (Kinetic
gives SFTP/panel file access if a config edit is ever needed for
something else.)

## Hosting options, ranked

1. **Tiny always-on host (recommended).** Anything that runs Node 24/7:
   an AWS Lightsail nano ($3.50/mo — fits the personal-hub AWS habit), a
   Fly.io machine, or any $3–5 VPS. 60 lines, ~30 MB RAM.
2. **Fold into personal-hub.** It deploys via CDK to AWS, so "a ws route"
   really means API Gateway WebSocket + Lambda — a different shape than
   this standalone server. Worth doing as its own task if preferred.
3. **Home PC + cloudflared tunnel.** Free, but alerts only work while the
   PC is on, and stable URLs need a named tunnel. Fine for a trial run.

## Setup

```bash
cd bridge && npm install ws
export BRIDGE_TOKEN="$(openssl rand -hex 16)"     # shared secret
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
node server.mjs 8466
```

On the historian computer: `edit bridge.conf`, first line:

```
wss://<bridge-host>:8466/?token=<BRIDGE_TOKEN>
```

save, reboot. The historian streams everything it hears; alerts hit
Discord; `GET /status?token=...` returns the latest reading per source.

## Security posture

This endpoint is internet-facing, so: constant-time shared-secret check
on every upgrade and /status request, browser-origin upgrades rejected,
64 KiB payload cap, bounded in-memory state, and Discord output is
mention-disabled, markdown-stripped, and truncated. Rotate the token by
restarting with a new `BRIDGE_TOKEN` + updating `bridge.conf`.

## Still needed from Carter

- Pick a hosting option (1–3 above).
- A Discord webhook URL (server settings → integrations → webhooks).
