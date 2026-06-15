# atm10-cc — a tested telemetry suite for All The Mods 10 (ComputerCraft)

In-game base telemetry for an **All The Mods 10 v7.0** server (Minecraft
1.21.1, CC:Tweaked 1.117.1, server rented from Kinetic Hosting): sensor
computers publish readings over a wireless pub/sub mesh, a monitor wall
renders everything on one screen, and a historian records history, detects
trouble ("flux dropped 45% in 5m"), and pings the player in Minecraft chat.

Two things make this repo unusual:

1. **Every program is tested before it ever touches the server** — in a
   purpose-built headless CC:Tweaked emulator (`harness/`), against mock
   peripherals whose APIs were verified by reading the actual mod sources
   (vendored under `vendor/`). 94 tests across two suites, written
   TDD-style (red → green) — including a kill-sweep that reboots the sled
   turtle at every half-second of its work cycle and demands convergence.
2. **It reads the true network energy past the 32-bit API ceiling** — a
   source-verified workaround documented below, validated in-game to the
   exact FE.

Everything through v8 is deployed and confirmed working in-game; v9
(Project Sled) is fully harness-verified and awaits its first in-game
deployment (docs/SLED-RUNBOOK.md).

---

## The system at a glance

```
 basement cave                              main base area
┌─────────────────────────────┐            ┌──────────────────────────┐
│ [dash computer]──fluxdash   │            │ [wall computer]──fluxwall│
│   ├─ Flux Accessor (FE cap) │  rednet    │   └─ monitor wall        │
│   └─ Block Reader → ME Drive│ "telemetry"│                          │
│        (true 64-bit totals) │ ═══════════│ [historian computer]     │
│ [me computer]──mesensor     │  (ender    │   ├─ history → disk      │
│   └─ ME Bridge (storage,    │   modems)  │   ├─ alert rules         │
│        craft CPUs, AE grid) │            │   ├─ Chat Box → MC chat  │
└─────────────────────────────┘            │   └─ (opt) ws → Discord  │
                                           └──────────────────────────┘
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
| `mesensor`  | `me`        | Reads an ME Bridge: item storage bytes, crafting CPU busy/total, AE grid draw; publishes source `me` |
| `fluxwall`  | `wall`      | Display client: unified card view of every source heard on the mesh |
| `historian` | `historian` | Records rolling history per source to disk, evaluates alert rules, announces via Chat Box (in-game chat) + broadcasts source `alerts`, optional websocket export |
| `fluxprobe` | —           | Diagnostic: dumps whatever a Block Reader sees, sums every `fe_energy` value at any depth, saves `fluxdump.txt` |
| `sled`      | `sled`      | **Project Sled**: a turtle that runs a self-relocating Digital Miner skid in the mining dimension — mines until exhausted, breaks the skid, walks the lane, rebuilds, restarts; journaled write-ahead state survives chunk unloads at any instant; turtle-led commissioning; publishes source `sled<N>` (docs/SLED-DESIGN.md, docs/SLED-RUNBOOK.md) |
| `sledctl`   | `sledctl`   | Fleet console: compact per-sled status table + token-gated fleet-wide `update` broadcast |
| `installer` / `update` | — | One-command bootstrap + self-update for every computer (below) |

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

Single rednet protocol **`"telemetry"`**. Every sensor broadcasts an
envelope once per refresh (1–2s):

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
| `sled<N>`| `state` (MINING/RELOCATE/RECOVER), `step`, `pos` (string), `hops`, `fuel`, `targets`, `miner` (0/1), `rate` (measured blocks/s), `eta`, `jpt`, `err`, `warn` |
| `alerts` | `msg` (historian-computed event; the wall shows it as a banner) |

**Adding a sensor = one small program**: read something, broadcast an
envelope with a new `source` name every few seconds. It appears on the
wall automatically (generic key/value card; numbers get human-formatted),
the historian records it, and the silence rule watches it — all with zero
changes to the wall or historian. Purpose-built wall cards and alert rules
can come later. Receivers treat a source silent >10s as stale
(`NO SIGNAL`); the historian alerts at >60s.

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
  -- sustained-condition + predictive rules (the useful, recurring ones)
  { source = "flux", metric = "pct", below = 5, forSeconds = 600,
    label = "flux power low (under 5% for 10m+)" },
  { source = "flux", runway = "empty", withinSeconds = 600, rateWindow = 30 },
  { source = "me", metric = "usedPct", above = 90, forSeconds = 60,
    label = "ME storage over 90% full" },
  { source = "me", runway = "full", withinSeconds = 1200, rateWindow = 120 },
}
```

Rule types: **dropPct** (newest vs the window's oldest), **silentFor**
(sensor offline), **equals/forSeconds** (a string field STUCK on one
value — a stuck-but-broadcasting sled refreshes lastSeen, so silence
rules can't see it), **metric+below/above+forSeconds** (a computed number
— `pct`, `usedPct`, `rate` — held past a threshold: the chronic
deficit / too-full alerts), and **runway** (the level is *projected* to
hit 0 or capacity within N seconds at its measured rate — lead time, not a
post-mortem). Rule sources accept exact names, `*`, or a trailing-`*`
prefix. Separately, a periodic **heartbeat** posts a `base: flux 71%
+1.20k/t, ME 30%` digest to chat (proves the historian is alive; not a red
alert). Drop rules compare newest to the window's oldest ("flux energy
dropped 45% in 5m (10.00G -> 5.50G)"); silence rules fire once per outage;
everything has a 5-minute cooldown. On fire, the
historian (1) sends in-game chat via an adjacent Advanced Peripherals
**Chat Box**, (2) broadcasts the alert as source `alerts` so every wall
shows the red banner, (3) appends to the alert log, (4) optionally streams
to the bridge.

## Deployment

Bootstrap any fresh computer with one command (roles: `dash`, `wall`,
`me`, `historian`, `sled`, `sledctl` — the role list lives in
`deploy/manifest.lua`, so new roles never require installer changes):

```
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua <role>
```

The installer fetches the manifest, downloads every program, writes a
`startup.lua` for the role (computers auto-start after server restarts and
chunk reloads), and records the manifest URL. From then on, typing
`update` on any computer pulls the latest release and reboots. Fetches are
**cache-busted** (unique query string per request) because GitHub's raw
CDN caches ~5 minutes; pushes apply instantly. Release flow: edit
programs → run tests → bump `version` in `deploy/manifest.lua` → push.

This works on an unmodified server because CC:Tweaked's default HTTP rules
are `DENY $private, ALLOW *` — public URLs pass; only LAN/localhost
addresses are blocked.

## Bridge (staged, optional — nothing in-game depends on it)

`bridge/server.mjs` is a small Node websocket server: the historian
streams JSON to it (`bridge.conf` on the historian holds the URL), it
forwards alerts to a **Discord webhook** (phone pings while away from the
game) and serves `GET /status` with the latest reading per source — the
intended data substrate for a future MCP `get_power_status` tool, so an
MCP layer would query the bridge, never the game.

Because the MC server is rented (no extra processes), the bridge must run
on some always-on public host — which conveniently means **no CC config
edits at all** (public URLs already pass the default rules). It's hardened
for internet exposure: constant-time shared-secret token on every
connection and `/status` hit, browser-origin upgrades rejected, payload
and state caps, Discord output mention-disabled/markdown-stripped/
truncated. Status: code ready; waiting on a hosting choice and a webhook
URL.

## Development: the headless CC:Tweaked emulator

The reason everything worked first-try in-game. `harness/cc_env.lua`
(~1800 lines, pure Lua) mirrors how CC:Tweaked actually runs programs:

- **The program is a coroutine; `os.pullEventRaw` is `coroutine.yield`.**
  The scheduler honors the real yield-filter rules (non-matching events
  are *discarded*, `terminate` always passes) — the subtle semantics that
  make naive `sleep()` loops eat keypresses in-game.
- **Time is virtual, in integer game ticks** (1 tick = 0.05s): a 75-second
  scenario runs in milliseconds, deterministically. `os.clock()` matches
  the real tick-granular implementation.
- **`write`/`print`/`sleep` are lifted from the vendored ROM `bios.lua`**,
  so word-wrapping and scrolling match in-game rendering exactly.
- **Runs on Lua 5.2.4 built from source** — CC's Cobalt VM (0.9.9) targets
  5.2 semantics (doubles, `%d` truncates instead of erroring like 5.3+),
  so version-specific bugs surface here, not in-game.
- **Mock peripherals match the real APIs** (verified from source): generic
  `energy_storage` with the Java-int clamp, `me_bridge` (real AP 0.7.62b
  method names — the original draft of fluxdash called ME Bridge methods
  that *don't exist*; pcall ate the error and the feature silently never
  worked — caught here), `block_reader` with drive NBT, scale-aware
  monitors (text scale changes the character grid like real ones),
  modems + rednet, `chat_box`, http, an in-memory `fs`.
- **Scenario hooks** drive tests: `charAt(t, "q")`, `detachAt`/`attachAt`
  (peripheral events), `rednetAt` (incoming mesh traffic),
  `snapshotAt`/`monitorSnapshotAt` (mid-run screen captures), plus
  rendered-screen text assertions and per-cell color tracking.

```bash
toolchain/lua-5.2.4/src/lua tests/run_tests.lua       # 47 tests (telemetry suite)
toolchain/lua-5.2.4/src/lua tests/run_sled_tests.lua  # 47 tests (Project Sled)
toolchain/lua-5.2.4/src/lua harness/demo.lua          # eyeball rendered screens
```

The sled suite adds to the emulator: a `turtle` global over a voxel
world (moves/digs/places with real fuel + verbatim error strings),
one-tick-late peripheral attach (C3 semantics — it caught a real
same-tick-wrap bug in review), Digital Miner and Quantum Entangloporter
mocks built method-by-method from the vendored Mekanism source (verbatim
security/validation errors, the corrected FINISHED/`running` semantics,
the toMine publish-lag hazard), `restartAt`/`chunkUnloadAt` scenario
hooks, and a multi-boot driver (relative deadlines, boot queue flush,
virtual-fs startup).

## Verified API facts (ATM10 / MC 1.21.1) — from source, not memory

- CC:T generic energy peripheral: methods `getEnergy`/`getEnergyCapacity`,
  additional type `"energy_storage"`, returns **Java int**.
- `peripheral.getType(name)` returns **multiple values** (primary +
  generic types); `peripheral.hasType(name, type)` is the membership
  check. Wired-network names are `type_N` (e.g.
  `appflux:flux_accessor_0`); adjacent blocks attach as side names
  (`bottom`).
- Advanced Peripherals 0.7.62b: ME Bridge type **`me_bridge`**; energy
  methods `getStoredEnergy`/`getEnergyCapacity`/`getEnergyUsage`/
  `getAverageEnergyInput` in **AE units** (1 AE = 2 FE) — these are the AE
  grid buffer, *not* flux cells. (`getEnergyStorage`/`getMaxEnergyStorage`
  do not exist.) Block Reader type **`block_reader`**; Chat Box type
  **`chat_box`** (`sendMessage`, `sendMessageToPlayer`). Crafting CPUs:
  `{storage, coProcessors, isBusy, name}`.
- AppFlux: cells store FE 1:1 as longs; component `appflux:fe_energy`;
  capability clamped via `AFUtil.clampLong`; accessor I/O unlimited by
  default (`flux_accessor.io_limit = 0`); exists as block
  `appflux:flux_accessor` and cable part.
- Events: `peripheral` / `peripheral_detach`. `os.clock()` = uptime in
  ticks × 0.05. Default HTTP rules: `DENY $private, ALLOW *`.

## Repo layout

```
programs/    the nine CC programs (deployable)
deploy/      manifest.lua (files + roles + version; the release unit)
harness/     cc_env.lua emulator + demo.lua scenario renderer
tests/       run_tests.lua (47) + run_sled_tests.lua (Project Sled; TDD)
vendor/      shallow clones: CC-Tweaked, AdvancedPeripherals, AppFlux,
             ExtendedAE (API ground truth; gitignored)
toolchain/   Lua 5.2.4 built from source (gitignored)
bridge/      staged Node websocket → Discord bridge + setup notes
docs/        RESEARCH.md (file:line evidence), SLED-DESIGN.md,
             SLED-RUNBOOK.md, INGAME-CHECKLIST.md
```

## Version history

- **v1–v2** — original dashboard draft rewritten against tests: render to
  terminal *and* monitors, event-driven loop (quit key, peripheral
  detach/reattach recovery), real ME Bridge API, scan that saves
  `fluxscan.txt`.
- **v3** — the Block Reader hack: true totals + true capacity + true rate.
- **v4** — rednet broadcast + first monitor-wall client.
- **v5** — ETA ("full in / empty in") on wall and dashboard.
- **v6** — telemetry mesh (envelope protocol), `mesensor`, `historian`
  with drop/silence alerts → Chat Box + wall banner, staged Discord
  bridge.
- **v7** — installer roles come from the manifest.
- **v8** — unified single-screen wall (cards, no page rotation).
- **v9** — Project Sled: `sled` (self-relocating Digital Miner skid,
  journal + boot reconciliation, turtle-led commissioning, measured-rate
  telemetry), `sledctl` fleet console, wall sled card + `sources=`
  filter, historian stuck rules (`RELOCATE` 900s / `RECOVER` 30s).
- **v10** — flux robustness: an empty flux cell (0 FE, whose
  `appflux:fe_energy` component AppFlux omits) is detected by cell id and
  reads as a real `0` instead of flickering the dash between "block reader"
  and "(no energy peripheral)"; a failed accessor read clears the stale
  value instead of broadcasting it; the wall renders a sensor that can't
  read its source as "no reading" rather than `? FE` + a frozen sparkline.
- **v11** — useful, recurring historian alerts: sustained-condition rules
  (flux under 5% for 10m+; ME over 90% full), predictive **runway**
  warnings ("flux empty in ~6m", "ME full in ~20m" — lead time, not a
  post-mortem), and a periodic **heartbeat** digest so you can tell it's
  alive. Built around what the wall *can't* show: trends, projections, and
  off-site push (via the existing bridge).

## Roadmap

- More sensors (one-file each): induction matrix / any FE bank via the
  generic energy peripheral, mob farm kill rates, essence/mystical
  agriculture throughput via delta polling.
- Wall layout niceties: per-card minimum heights, configurable card order.
- Stand up the bridge (hosting + Discord webhook), then an MCP
  `get_power_status` tool backed by `GET /status`.
- Per-realistic-range bar scaling (a 281T cell makes 10G read as 0%).
