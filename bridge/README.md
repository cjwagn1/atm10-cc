# Telemetry bridge (staged — needs 3 facts from Carter)

The in-game half is done: the historian streams every envelope + alert as
JSON over a websocket *if* a `bridge.conf` file exists on its computer.
This folder is the out-of-game half: a tiny Node server that receives the
stream, forwards alerts to Discord, and serves `GET /status` (the future
MCP `get_power_status` data source).

## To wire it up

1. **Where does the Minecraft server run?** The bridge must be reachable
   from it. Same box = easiest.
2. **CC config edit** (server owner, one time): in
   `config/computercraft-server.toml`, CC denies private/LAN addresses by
   default. Add an allow rule for the bridge host **above** the
   `$private` deny rule in the `[[http.rules]]` list:

   ```toml
   [[http.rules]]
   host = "127.0.0.0/8"    # or the LAN IP / hostname of the bridge box
   action = "allow"
   ```

   (Rules evaluate in order — GitHub raw worked out of the box precisely
   because public URLs never hit the `$private` rule.)
3. **Run the bridge** wherever you chose:

   ```bash
   cd bridge && npm install ws
   DISCORD_WEBHOOK="https://discord.com/api/webhooks/..." node server.mjs 8466
   ```

4. **Point the historian at it**: on the historian computer,
   `edit bridge.conf`, first line `ws://<bridge-host>:8466`, save, reboot.

## Open questions

- Is the ATM10 server on this machine, another box you own, or rented
  hosting? (Decides the host in steps 2–3.)
- Discord webhook URL (server settings → integrations → webhooks).
- Fold this into the existing personal-hub/Hono app instead of running
  standalone? It's one ws route + one fetch — trivial either way.
