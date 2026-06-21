# atm10-cc — a tested telemetry suite for All The Mods 10 (ComputerCraft)

## ⬇️ Install a computer (copy-paste this)

On a fresh CC:Tweaked computer, run **one** line for the role it should be.
This downloads everything, sets it to auto-start on reboot, and records the
manifest URL so `update` works forever after:

```
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua dash
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua me
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua wall
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua historian
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua console
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua chemwall
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua sledctl
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua sled
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua farm
```

| role | put it on | needs attached |
|------|-----------|----------------|
| `dash`      | the flux/energy computer | Block Reader facing the ME Drive of flux cells (+ wireless/ender modem) |
| `me`        | the AE-data computer (also reads the chemicals) | ME Bridge (+ modem) |
| `wall`      | a display computer | Advanced Monitor(s) (+ modem) |
| `historian` | the always-on brain | Advanced Peripherals **Chat Box** (+ modem) |
| `console`   | a wall panel near the AE terminal | Advanced (touch) Monitor (+ modem) |
| `chemwall`  | the dedicated chemical monitor wall | Advanced Monitor(s) (+ modem) |
| `sledctl`   | the sled fleet console | modem (+ `sledctl.conf` token) |
| `sled`      | a mining turtle | see docs/SLED-RUNBOOK.md |
| `farm`      | a sulfur-farm builder turtle (place-and-go) | Geo Scanner upgrade + an ME Bridge nearby; it finds/scans/builds on its own. See docs/FARM-BUILD-DESIGN.md |

Right after installing, **reboot** (or run the role program) to start it.

### Update every computer at once

Once installed, you never touch them individually again. Any of these
pushes the latest code to the whole stationary base (each box reboots into
its role; sleds are deliberately left to `sledctl`):

- **Type `update-all` in Minecraft chat** (locked to player `cjwagn1`) — the
  loud path: posts the target version and `ack <computer> vN` for each box.
- **Press `[u]` on the historian** — quiet (updates the base, no chat spam).
- **Tap `UPDATE ALL` on the console** — quiet; tap `VERSIONS` to see the
  roll-call on the panel.
- A plain `update` typed on one computer updates just that one (silent).

The shared courtesy token is `flux` (constant in the programs; see
`CHAT_OWNER` in `historian.lua` to change who may fire the chat trigger).
**Release flow:** edit programs → run tests → bump `version` in
`deploy/manifest.lua` → push → `update-all`.

---

In-game base telemetry for an **All The Mods 10 v7.0** server (Minecraft
1.21.1, CC:Tweaked 1.117.1, server rented from Kinetic Hosting): sensor
computers publish readings over a wireless pub/sub mesh, a monitor wall
renders everything on one screen, a historian records history and pings the
player in Minecraft chat, and a touch console fronts the whole fleet.

Two things make this repo unusual:

1. **Every program is tested before it ever touches the server** — in a
   purpose-built headless CC:Tweaked emulator (`harness/`), against mock
   peripherals whose APIs were verified by reading the actual mod sources
   (vendored under `vendor/`). **191 tests** across three suites
   (97 telemetry + 60 Project Sled + 34 Sulfur-Farm Builder), written
   TDD-style (red → green) — including kill-sweeps that reboot the turtles at
   every half-second of their work cycle and demand convergence.
2. **It reads the true network energy past the 32-bit API ceiling** — a
   source-verified workaround documented below, validated in-game to the
   exact FE.

---

## The system at a glance

```
 basement cave                              main base area
┌─────────────────────────────┐            ┌──────────────────────────┐
│ [dash computer]──fluxdash   │            │ [wall computer]──fluxwall│
│   ├─ Flux Accessor (FE cap) │  rednet    │   └─ monitor wall        │
│   └─ Block Reader → ME Drive│ "telemetry"│ [historian computer]     │
│        (true 64-bit totals) │ ═══════════│   ├─ history → disk      │
│ [me computer]──mesensor     │  (ender    │   ├─ alert rules         │
│   └─ ME Bridge (storage,    │   modems)  │   └─ Chat Box → MC chat  │
│        craft CPUs, AE grid) │            │ [console]──touch panel   │
└─────────────────────────────┘  "basectl"│   └─ UPDATE ALL/VERSIONS │
                                  (control)└──────────────────────────┘
```

What the wall shows (live render from the emulator, real numbers):

```
BASE TELEMETRY         |
FLUX 10.13G/281.47T FE 0%
 -------------------- 0%
-36.66k FE/t
empty in 3h 50m
 ------------
ME   612.00k/2.10M B 29%
 ######------------- 29%
CPU 1/4  AE 96/t
 ------------
```

All sources at once — no page rotation. Each source gets an equal vertical
band and renders as much detail as fits (headline → bar → rate/ETA →
sparkline), so the same program looks right on one monitor or a 4×3 wall.
Text auto-scales to the largest size that fits. A spinner ticks on every
received packet; a red banner crosses the top when the historian raises an
alert; a source that goes quiet shows `NO SIGNAL (Ns)` inline.

## Programs

| program     | role        | what it does |
|-------------|-------------|--------------|
| `fluxdash`  | `dash`      | Reads flux energy (true totals via Block Reader, clamped FE capability as fallback), renders a local dashboard on its terminal + adjacent monitors, publishes source `flux` |
| `mesensor`  | `me`        | Reads an ME Bridge: item storage bytes, crafting CPU busy/total, AE grid draw (source `me`); **also** reads the seven tracked Mekanism chemicals off the same bridge, derives each one's net rate of change (mB/t), and publishes source `chem` |
| `fluxwall`  | `wall`      | Display client: unified card view of every source heard on the mesh |
| `historian` | `historian` | Records rolling history per source, evaluates alert rules, announces via Chat Box (in-game chat) + broadcasts source `alerts`; hosts the base-control hub (chat `update-all`, `[u]`, post-update ack roll-call) |
| `console`   | `console`   | Touch panel: colored `UPDATE ALL` / `VERSIONS` / `UPDATE SLEDS` buttons + a version census shown on the monitor; auto-updates with the base |
| `chemwall`  | `chemwall`  | Dedicated full-monitor chemical-balance wall: one auto-scaled row per chemical (name, stored amount, signed net rate colored green/red/yellow, trend + sparkline), pooled-cell fill %, and a `LOW` flag on any chemical starved near empty; subscribes to source `chem` |
| `fluxprobe` | —           | Diagnostic: dumps whatever a Block Reader sees, sums every `fe_energy` value at any depth, saves `fluxdump.txt` |
| `sled`      | `sled`      | **Project Sled**: a turtle that runs a self-relocating Digital Miner skid in the mining dimension; journaled write-ahead state survives chunk unloads at any instant; publishes source `sled<N>` (docs/SLED-DESIGN.md, docs/SLED-RUNBOOK.md) |
| `sledctl`   | `sledctl`   | Fleet console: compact per-sled status table + token-gated fleet-wide `update` broadcast (separate `sledctl` channel) |
| `farm`      | `farm`      | **Sulfur-Farm Builder** (place-and-go): drop a turtle + an ME Bridge near your plot and it auto-discovers the rest — finds the plot by Geo Scanner, calibrates its heading with no GPS, scans it, and stacks copies above it, pulling/crafting dirt, seeds, fertilizer, water, and fuel from AE; self-tests then journals write-ahead to survive chunk unloads (docs/FARM-BUILD-DESIGN.md) |
| `installer` / `update` / `update-all` | — | Bootstrap, per-computer self-update, and base-wide push (below) |

## Base control (`update-all`)

A second rednet protocol, **`"basectl"`**, carries token-gated control
commands across the stationary base (`dash`, `wall`, `me`, `historian`,
`console`). Sleds are *not* on it — they keep their own `sledctl` channel so
one never reboots mid-relocation by surprise.

- **`{cmd="update", token, loud}`** — every listener acks, hands the
  terminal back (displays redirect to monitors), and runs the standard
  `update` (download → reboot into its role). The `update-all` program
  broadcasts this, then updates itself last.
- **`{cmd="version?", token}`** — a version census. Each box replies
  `{version, label}` (read from `.fluxversion`). The asker **re-pings every
  second** across the window so a busy box (the flux computer does heavy
  block-reader reads) isn't dropped by a single missed ping.

**Loud vs quiet.** Typing `update-all` in chat runs it *loud*: the historian
narrates to chat. The `[u]` key and the console button run it *quiet* — they
push the base but stay out of chat (you're at a screen). A manual `update`
is silent too. Chat acks are posted **one line per computer, spaced out** —
a tight send-loop trips Minecraft's chat throttle and silently drops lines,
so each `ack <computer> vN` is sent on its own beat (and rolls in nicely):

```
<cjwagn1> update-all
[base] base updating to v22...
[base] ack ae_telemetry v22
[base] ack base_monitor v22
[base] ack console v22
[base] ack historian v22
[base] ack power_telemetry v22
```

The console's `VERSIONS` button shows the same census on its monitor,
color-coded — lime for in-sync, orange `<- check` for an out-of-date box.

## The headline hack: true totals past 2,147,483,647 FE

**Problem.** The Forge/NeoForge energy API is `int`-typed. CC:Tweaked's
generic `energy_storage` peripheral (`getEnergy`/`getEnergyCapacity`)
therefore saturates at 2,147,483,647 FE. AppFlux (the AE2 addon storing FE
in ME "flux cells") clamps explicitly — `AFUtil.clampLong = (int)
Math.min(value, Integer.MAX_VALUE)` — and a **single 4k flux cell holds
4.29G FE**, so the clamp is the *normal* case, not an edge case. Verified
dead ends (by reading the mod sources, not guessing):

- AppFlux has **zero ComputerCraft integration** — the generic FE
  capability is its only computer-facing API.
- The Advanced Peripherals ME Bridge cannot see flux cells at all: its
  `getCells()`/`getDrives()` only parse AE2's `BasicStorageCell` /
  `IBasicCellItem`, and AppFlux's `IFluxCell` implements neither.

**Solution.** AppFlux persists each cell's energy as the item component
**`appflux:fe_energy` — a 64-bit long** — on the cell item, which lives
inside the ME Drive's saved NBT. An Advanced Peripherals **Block Reader**
(`block_reader`, enabled by default) faced at the drive returns that whole
NBT via `getBlockData()`. Sum every `fe_energy` value: the true network
total, no ceiling that matters (Lua doubles are exact to 2^53 ≈ 9 peta-FE).
True **capacity** is derived from the cell item ids: cell bytes ×
1,048,576 FE/byte (`fe_1k_cell` = 1.07G … `fe_256m_cell` = 281.47T).

**Validated in-game:** the probe read **51,847,398,108 FE** exactly while
the capability reported 2,147,483,647. The dump walker is shape-agnostic
(it found the values on an `extendedae:ex_drive`, key path
`inv.itemN.components."appflux:fe_energy"`, without knowing that layout in
advance).

**Operational rule:** flux cells only count if they sit in a drive that has
a Block Reader facing it — one reader per drive, or keep all FE cells in
one drive. True rate (FE/t) is computed from deltas of the true total over
a 10s window using `os.clock()` (game-tick time, so it stays honest under
TPS lag), and feeds "full in 2h 14m" / "empty in 30m" ETAs.

## Telemetry mesh protocol

Telemetry rides one rednet protocol **`"telemetry"`** (control is the
separate `"basectl"`/`"sledctl"`). Every sensor broadcasts an envelope once
per refresh (1–2s):

```lua
{
  v = 1,              -- schema version
  source = "flux",    -- unique sensor name; becomes a card on the wall
  tick = os.clock(),  -- sender uptime (debug)
  data = { ... },     -- source-specific payload
}
```

Current sources:

| source   | data fields |
|----------|-------------|
| `flux`   | `trueE`, `trueCap`, `cells` (via block reader); `e`, `cap` (clamped capability fallback); `rate` (FE/t, smoothed 10s); `srcName`; `ae`, `aeMax`, `aeUse`, `aeIn` (ME Bridge AE-unit grid stats, 1 AE = 2 FE) |
| `me`     | `usedBytes`, `totalBytes`, `availBytes` (item storage cells); `cpus`, `cpusBusy` (crafting CPUs); `aeUse` (AE/t) |
| `chem`   | `chems` = list of `{ id, label, amount (mB), rate (mB/t, net) }` (one per tracked chemical); `usedBytes`, `totalBytes` (pooled chemical-cell storage); `up` (sensor uptime) |
| `sled<N>`| `state` (MINING/RELOCATE/RECOVER), `step`, `pos` (string), `hops`, `fuel`, `targets`, `miner` (0/1), `rate` (measured blocks/s), `eta`, `jpt`, `err`, `warn` |
| `alerts` | `msg` (historian-computed event; the wall shows it as a banner) |

**Adding a sensor = one small program**: read something, broadcast an
envelope with a new `source` name every few seconds. It appears on the
wall automatically (generic key/value card; numbers get human-formatted),
the historian records it, and the silence rule watches it — all with zero
changes to the wall or historian. Receivers treat a source silent >10s as
stale (`NO SIGNAL`); the historian alerts at >60s.

## Historian + alerts

A dedicated computer subscribes to everything and keeps a rolling ring
(360 samples) per source, flushed to `telemetry/<source>.log` every 10s
(`telemetry/alerts.log` is append-only). Alert rules are a table at the top
of `historian.lua`:

```lua
local ALERTS = {
  { source = "flux", key = "energy", dropPct = 40, window = 300 },
  { source = "*", silentFor = 60 },
  { source = "sled*", key = "state", equals = "RELOCATE", forSeconds = 900 },
  { source = "sled*", key = "state", equals = "RECOVER", forSeconds = 30 },
  { source = "flux", runway = "empty", withinSeconds = 600, rateWindow = 30 },
  { source = "me", metric = "usedPct", above = 90, forSeconds = 60,
    label = "ME storage over 90% full" },
  { source = "me", runway = "full", withinSeconds = 1200, rateWindow = 120,
    minPct = 75 },
}
```

Rule types: **dropPct** (newest vs the window's oldest), **silentFor**
(sensor offline), **equals/forSeconds** (a string field STUCK on one
value), **metric+below/above+forSeconds** (a computed number held past a
threshold), and **runway** (the level is *projected* to hit 0 or capacity
within N seconds at its measured rate — lead time, not a post-mortem; the
ME-full runway has a `minPct` floor so a transient climb at 50% doesn't cry
wolf). Rule sources accept exact names, `*`, or a trailing-`*` prefix.

A periodic **heartbeat** posts a digest to chat (proves the historian is
alive; not a red alert). On a trillions-capacity Applied Flux Drive a fill
*percentage* is information-free (550G of 281T reads 0%), so the digest
shows the **absolute stored, the capacity, and the throughput** instead:

```
[base] flux 550G / 281.47T +2.49M/t · ME 50%
```

On an alert firing, the historian (1) sends in-game chat via an adjacent
**Chat Box**, (2) broadcasts the alert as source `alerts` so every wall
shows the red banner, (3) appends to the alert log, (4) optionally streams
to the bridge. Everything has a 5-minute cooldown.

## Deployment & self-update

Bootstrap any fresh computer with the one-liner at the top of this README
(roles live in `deploy/manifest.lua`, so new roles never require installer
changes). The installer downloads every program, writes a `startup.lua` for
the role (computers auto-start after server restarts and chunk reloads), and
records `.fluxdeploy` (role + manifest URL) and `.fluxversion` (so a fresh
box reports its version in a census immediately).

`update` re-fetches the manifest and every file, then reboots. It stamps
`.fluxversion`, and on a base-wide push (`update fromall`) leaves a one-shot
`.fluxupdated` breadcrumb that makes the historian post its post-reboot ack
roll-call. Fetches are **cache-busted** (unique query string per request)
because GitHub's raw CDN caches ~5 minutes; pushes apply instantly.

This works on an unmodified server because CC:Tweaked's default HTTP rules
are `DENY $private, ALLOW *` — public URLs pass; only LAN/localhost
addresses are blocked.

## Bridge (staged, optional — nothing in-game depends on it)

`bridge/server.mjs` is a small Node websocket server: the historian
streams JSON to it (`bridge.conf` on the historian holds the URL), it
forwards alerts to a **Discord webhook** (phone pings while away from the
game) and serves `GET /status` with the latest reading per source — the
intended data substrate for a future MCP `get_power_status` tool. It's
hardened for internet exposure (constant-time shared-secret token, origin
checks, payload caps, Discord output sanitized). Status: code ready;
waiting on a hosting choice and a webhook URL.

## Development: the headless CC:Tweaked emulator

The reason everything worked first-try in-game. `harness/cc_env.lua`
(pure Lua) mirrors how CC:Tweaked actually runs programs:

- **The program is a coroutine; `os.pullEventRaw` is `coroutine.yield`.**
  The scheduler honors the real yield-filter rules (non-matching events are
  *discarded*, `terminate` always passes).
- **Time is virtual, in integer game ticks** (1 tick = 0.05s): a 75-second
  scenario runs in milliseconds, deterministically. `os.clock()` matches
  the real tick-granular implementation.
- **`write`/`print`/`sleep` are lifted from the vendored ROM `bios.lua`**,
  and `shell.run` forwards arguments — so chained programs (`update-all` →
  `update`) and word-wrapping match in-game behavior exactly.
- **Runs on Lua 5.2.4 built from source** — CC's Cobalt VM (0.9.9) targets
  5.2 semantics, so version-specific bugs surface here, not in-game.
- **Mock peripherals match the real APIs** (verified from source): generic
  `energy_storage` with the Java-int clamp, `me_bridge` (real AP 0.7.62b
  method names), `block_reader` with drive NBT, scale-aware monitors,
  modems + rednet, `chat_box`, http, an in-memory `fs`.
- **Scenario hooks** drive tests: `charAt`, `keyAt`, `chatAt` (Chat Box
  `chat` events), `touchAt` (monitor touches), `detachAt`/`attachAt`,
  `rednetAt`, `snapshotAt`/`monitorSnapshotAt`, plus rendered-screen text
  assertions and per-cell color tracking.

```bash
toolchain/lua-5.2.4/src/lua tests/run_tests.lua       # 97 tests (telemetry + base control)
toolchain/lua-5.2.4/src/lua tests/run_sled_tests.lua  # 60 tests (Project Sled)
toolchain/lua-5.2.4/src/lua tests/run_farm_tests.lua  # 34 tests (Sulfur-Farm Builder)
toolchain/lua-5.2.4/src/lua harness/demo.lua          # eyeball rendered screens
```

## Verified API facts (ATM10 / MC 1.21.1) — from source, not memory

- CC:T generic energy peripheral: methods `getEnergy`/`getEnergyCapacity`,
  additional type `"energy_storage"`, returns **Java int**.
- `peripheral.getType(name)` returns **multiple values**;
  `peripheral.hasType(name, type)` is the membership check.
- Advanced Peripherals 0.7.62b: ME Bridge type **`me_bridge`**; energy
  methods in **AE units** (1 AE = 2 FE; `getEnergyStorage`/
  `getMaxEnergyStorage` do **not** exist). Block Reader type
  **`block_reader`**. Chat Box type **`chat_box`** (`sendMessage`,
  `sendMessageToPlayer`) — and it fires a **`chat` event**
  `(event, username, message, uuid, isHidden)` the historian listens for.
  Advanced Monitors fire **`monitor_touch`** `(event, name, x, y)`.
- AppFlux: cells store FE 1:1 as longs; component `appflux:fe_energy`;
  capability clamped via `AFUtil.clampLong`.
- Events: `peripheral` / `peripheral_detach`. `os.clock()` = uptime in
  ticks × 0.05. Default HTTP rules: `DENY $private, ALLOW *`.

## Repo layout

```
programs/    the CC programs (deployable)
deploy/      manifest.lua (files + roles + version; the release unit)
harness/     cc_env.lua emulator + demo.lua scenario renderer
tests/       run_tests.lua (97) + run_sled_tests.lua (60) + run_farm_tests.lua (34)
vendor/      shallow clones: CC-Tweaked, AdvancedPeripherals, AppFlux,
             ExtendedAE (API ground truth; gitignored)
toolchain/   Lua 5.2.4 built from source (gitignored)
bridge/      staged Node websocket → Discord bridge + setup notes
docs/        RESEARCH.md (file:line evidence), SLED-DESIGN.md,
             SLED-RUNBOOK.md, INGAME-CHECKLIST.md
```

## Version history

- **v1–v2** — original dashboard rewritten against tests: render to terminal
  *and* monitors, event-driven loop, real ME Bridge API.
- **v3** — the Block Reader hack: true totals + true capacity + true rate.
- **v4** — rednet broadcast + first monitor-wall client.
- **v5** — ETA ("full in / empty in") on wall and dashboard.
- **v6** — telemetry mesh, `mesensor`, `historian` with drop/silence alerts.
- **v7** — installer roles come from the manifest.
- **v8** — unified single-screen wall (cards, no page rotation).
- **v9** — Project Sled: `sled`, `sledctl`, wall sled card, stuck rules.
- **v10** — flux robustness (empty cell reads 0, failed read clears stale).
- **v11** — useful historian alerts: sustained-condition + predictive
  **runway** warnings + a periodic **heartbeat**.
- **v12** — heartbeat shows absolute flux + capacity + rate (a fill % is
  meaningless at trillions of capacity); removed the false "flux power low"
  alert that the same dead ratio was firing.
- **v13–v16** — base-wide **`update-all`**: token-gated `basectl` protocol,
  ack tally, version census; chat trigger locked to the owner; per-box
  census in chat.
- **v17** — the touch **command console** (new role).
- **v18** — ME-full runway gains a high-fill floor (no false "full in ~2m"
  at 50%).
- **v19** — colored console buttons + multi-line results panel; `update-all`
  loud (chat) vs quiet (`[u]`/console); installer stamps `.fluxversion`.
- **v20–v21** — census re-pings (catches the busy flux computer); chat acks
  posted one spaced line per computer (a tight loop hit the chat throttle
  and dropped lines).
- **v22** — the console auto-updates with the base (no more version drift),
  while its own button still never reboots it.

## Roadmap

- More sensors (one-file each): induction matrix / any FE bank, mob farm
  kill rates, essence throughput via delta polling.
- Wall layout niceties: per-card minimum heights, configurable card order.
- Stand up the bridge (hosting + Discord webhook), then an MCP
  `get_power_status` tool backed by `GET /status`.
- Per-realistic-range bar scaling on the wall (a 281T cell still makes 10G
  read as 0% there, the way the heartbeat once did).
```
