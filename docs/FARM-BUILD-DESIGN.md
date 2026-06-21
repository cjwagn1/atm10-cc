# Autonomous Sulfur-Farm Builder — Phase 2 Design + Runbook

`programs/farm.lua` is a ComputerCraft turtle that scans one existing Mystical
Agriculture sulfur plot, normalizes it into a blueprint, then replicates it up a
chunk-aligned vertical stack — pulling and crafting its own dirt, seeds,
fertilizer, water, and fuel from the cross-dimensional AE network. It self-tests
the risky primitives before any real plot and journals write-ahead so a chunk
unload / server restart at **any** instant resumes cleanly (the mining-dim daily
event: the computer is *killed*, not paused — claim C4).

Built on the source-verified Phase 1 study (`docs/FARM-RESEARCH.md`, Q1..Q6) and
the proven turtle-autonomy patterns in `programs/sled.lua`. Every turtle/AE
behavior relied on here is cited in the research; nothing was assumed.

---

## 1. What the operator does (the whole list)

1. **Point it at one reference plot.** In `farm.conf`, set `origin` to the plot's
   minimum corner (the soil layer Y), `size = { w, h, d }` (footprint w×d, h
   layers tall including the crop layer), and the `heading`/`lateral` axes.
2. **Point it at a build location.** Set `build = { x, y, z }` (the stack's
   minimum corner) and `plots` (how many to stack).
3. **Point it at AE.** Set `base = { bridge, park, staging, suck, export_side }`
   — the ME Bridge peripheral name, the restock park (clear air above the
   stack), the staging cell the bridge exports into, and the suck direction.
4. **Place the turtle** at `start` facing `start_heading`, install, run.

There is **one mandatory server-side setting** the turtle cannot do for you,
already flagged in Phase 1: **`force_load_mode: always`** in FTB-Chunks (so the
farm ticks while you are logged out). Everything else the turtle owns.

A worked `farm.conf`:

```lua
return {
  start  = { x = 100, y = 80, z = 100 }, start_heading = "east",
  origin = { x = 50,  y = 64, z = 50 },  size = { w = 9, h = 2, d = 9 },
  heading = "east", lateral = "south", scan_y = 67,
  build  = { x = 50, y = 100, z = 50 },  plots = 8,
  travel_y = 124,            -- ceiling for restock travel (above the stack)
  base = {
    bridge = "right",                       -- ME Bridge peripheral / side
    park    = { x = 50, y = 124, z = 48 },  -- restock park (clear air)
    -- the turtle sucks from `park` in the `suck` direction, so the staging
    -- chest MUST sit exactly one block that way (here: one block DOWN from
    -- park). `staging` is documentation of that cell; the code derives the
    -- suck target from park + suck, so keep them consistent.
    staging = { x = 50, y = 123, z = 48 },
    suck = "down", export_side = "up",
    scratch = { x = 47, y = 122, z = 50 },  -- self-test column (needs a floor)
    test_item = "minecraft:dirt",
    craft_probe = "farmingforblockheads:red_fertilizer",
  },
  fleet = "farm1",           -- telemetry source name (fluxwall shows it)
  -- token = "...",          -- optional: override the basectl courtesy token
}
```

## 2. How to run

```
farm capture     scan the reference plot -> farm.blueprint (one time)
farm build       self-test, then build the stack (resumes if interrupted)
farm selftest    run the startup self-tests only (not required separately)
farm             resume from the journal (what startup.lua runs after a reboot)
```

Install through the existing mesh — the role is wired into the deploy manifest:

```
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua farm
```

The installer writes `startup.lua = shell.run("farm")`, so after any reboot the
turtle resumes the build from its journal. `update-all` reaches it on the shared
`basectl` channel while it is idle.

## 3. Architecture

### 3.1 Capture (Q3) — column-probe, pure reads
Fly a serpentine over the footprint at `scan_y` (clear air above the plot); per
column descend through air calling `inspectDown`, recording the first solid
block. A crop implies fertilized farmland directly beneath it (a sulfur crop
only exists on farmland), so the soil under each crop is **inferred**, not dug
to. Capture writes a deterministic, `load()`-able `farm.blueprint`; a torn write
just re-captures (idempotent). **Fertilized farmland is normalized to a soil
recipe** `{ kind = "soil", tier = "fertilized" }` (build = dirt + till +
fertilize), never a placeable block (§4 of the research). Crop age is dropped —
the builder always plants fresh.

> **Limitation (be blunt).** v1 captures from a bounded box you specify
> (`origin` + `size`) and column-probes from above; fully-enclosed sub-cells of
> *tall* multi-block structures are recorded at their top and inferred from the
> build recipe. For the canonical soil + crop + center-water + accelerators +
> harvester-pylon + ender-chest plot this captures the build-relevant structure.
> Eyeball the first built copy against your real plot.

### 3.2 Build — layer-by-layer, observe-then-act
Bottom-up: for each layer `dy`, the turtle works each cell from the stance one
block **above** it (`placeDown`), serpentine, water cells last. A `placeDown`
water bucket braces only against the cell **directly below** the target (a
vertical deploy), so before placing the source the turtle descends into the
water cell and lays a dirt **sub-floor** beneath it if that cell is open — which
makes the center water autonomous on every stacked plot (where the cell below is
the prior plot's air center). The emptied bucket is then evacuated from the work
slot so the next plot's water restock can refill. The obstruction-free approach
into each layer uses a rise-to-ceiling `navSafe` corridor (P1-2); in-plot moves
stay at the clear stance layer. Plot `N+1` base = plot `N` base + `size.h`.

Every cell step is **converge-style** — it inspects the cell first and acts only
on the observed-block delta:

| sub-step | guard |
|---|---|
| place dirt | skip if the cell is already a soil id |
| till | only hoe `dirt`; skip if `farmland`/`fertilized_*` |
| fertilize | **skip if already `fertilized_*`** — never double-spend |
| plant | skip if a crop is present; else require farmland below |
| water | skip if `minecraft:water`; else braced-empty |
| accelerator/cable/pylon/chest | skip if the expected block id is present |

So the journal names *which cell*; the inspected world decides *what op*. "Redo
this cell" is the universal recovery, and a kill-redo never double-fertilizes or
re-tills (P0-2).

### 3.3 Kill-safety (C4/C5) — write-ahead journal
`intent` (the name of a mutating turtle command) is written to disk **before**
the command runs; position is journaled **after** a move succeeds, so a kill
mid-move leaves `journal.pos == the un-moved physical cell`. On boot the dead-
reckoned pose is restored from the journal and the build re-runs converge-style,
resuming at the first incomplete cell. A `.bak` at coarse boundaries survives a
torn main-journal write.

### 3.4 Supply (Q2) — gate on observed stock, never double-pull
`getItem` → `isCraftable` → `craftItem` → poll **observed** `getItem` count
(value-agnostic, AM-2) → `exportItem` to the staging cell → `turtle.suck`. Coal-
block fuel at a low watermark with an empirical Δ-probe refuel (no burn-value
constant). The hoe is restocked before it breaks mid-plot (durability read from
`getItemDetail`). Two double-spend guards: a boot re-crafts only if observed
`stock < need` (never re-issues on a job id), and every restock first sucks the
staging cell (`recoverDrop`) so a kill between export and suck re-collects rather
than re-pulls.

### 3.5 Self-test gate — abort loudly, build nothing
Once per `build` (journaled `selftest=done`, skipped on resume so reboots do not
waste materials): prove the cross-dim AE pull, a craft request, and the
till/fertilize/plant/water chain on a scratch column. Any failure aborts before
the first real plot. The scratch test is no-dig and converge-style (it builds a
tiny persistent structure and skips it on re-run) so it never pollutes the
material slots.

### 3.6 Orchestration — the existing mesh
Telemetry (source = `fleet`) on protocol `telemetry` so `fluxwall` shows build
progress; token-gated `update`/`version?` on the shared `basectl` channel so
`update-all` refreshes an idle builder. No modem → telemetry is a no-op and
`farm build` returns when done.

## 4. Validation gate — emulator results

The harness (`harness/cc_env.lua`) was extended with turtle item-use semantics
(hoe/fertilizer/seed/water bucket, all source-verified return values + tool
durability) and the ME-Bridge crafting surface (`getItem`/`getItems`/
`isCraftable`/`craftItem` async/`exportItem`). `tests/run_farm_tests.lua` is
**30/30 green** headless, covering: primitive fidelity + negative preconditions;
capture round-trip + idempotency; single-plot and 2-plot builds; idempotent
converge; AE supply with on-demand crafting; the self-test gate (pass → builds,
fail → builds nothing); kill-resume across a 5-point kill sweep (no double-
fertilize/plant, write-ahead pos invariant), stranded-export recovery (no double-
pull), a 2-plot mid-ascent kill; and telemetry + basectl. The 97 telemetry and
60 sled regression tests stay green.

```
toolchain/lua-5.2.4/src/lua tests/run_farm_tests.lua    # 30
toolchain/lua-5.2.4/src/lua tests/run_tests.lua         # 97 (regression)
toolchain/lua-5.2.4/src/lua tests/run_sled_tests.lua    # 60 (regression)
```

## 5. In-game confirmations (the non-vendored layers)

The emulator proves the *logic*; these settle the layers vendored source can't
reach. The self-test catches all of them at startup before any real plot.

1. **Water-placement stance — the one I could not fully settle from source**
   (vanilla `BucketItem` raytrace is non-vendored). Modeled as a vertical
   `placeDown` braced by the dirt sub-floor the turtle lays beneath each water
   cell, which should make it autonomous. If `placeDown` still fails on your
   server the turtle logs a `needs hand-seeding` warning and keeps going —
   hand-seed the one center block per plot, the turtle builds everything else.
2. **FfB fertilizer fake-player path** inside your claim — source shows no
   fake-player guard (only `player == null`), LOW risk in your own claim; the
   self-test's scratch fertilize confirms it.
3. **AE cross-dim grid merge + one spare channel** — the self-test ME-pull of a
   base-only item proves the quantum bridge merge in one shot.
4. **Accelerator facing** — orientation-proof by the vertical-power-axis trick;
   the builder replicates the scanned accelerator *positions* (capture-and-copy)
   and does not reason about acceleration coverage (that is your proven design).
5. **`force_load_mode: always`** — the single server-side setting (Phase 1 Q4).

## 6. Known v1 limits / next iterations

- **Boot re-anchor (the headline kill-safety gap).** The turtle dead-reckons its
  pose from the journal with no *physical* re-anchor (unlike `sled`, which
  relocalizes on a marker / blockstate fingerprint). Two rare windows can then
  diverge the build: a **torn main-journal write** (a kill during the fs flush)
  that falls back to a slightly stale `.bak` (now bounded to one cell, written
  at each cell stance), and a **turn-kill** (a kill in the few ops between
  `turnRight()` returning and the journal updating) that leaves the physical
  facing one turn ahead of the journal. Either can rotate/offset the remaining
  build with no self-correction. Mitigation today: the `.bak` is per-cell and a
  read-back guard halts loudly on an un-tilled/unplaced cell rather than
  silently completing. **Next iteration:** port `sled`'s `relocalize` (place a
  directional marker at the build base; on boot, re-anchor pose + heading from a
  physical fingerprint before trusting the journal). Until then, **eyeball the
  first stack after any hard kill.**
- **Auto-size detection** — v1 takes the footprint from `farm.conf` (`origin` +
  `size`); a future pass can probe the extent so the scan settles the size.
- **Mid-cell restock travel** is lazy (a park round trip when a slot runs dry);
  a per-plot batch pre-load would cut trips on tall stacks.
- **Emptied water buckets** are dropped (a cheap consumable) after each source
  is placed rather than returned to AE; the base should keep full water buckets
  craftable/fillable. A future pass can `importItem` the empties back.
- **Re-run assumes completed plots below the resume point.** A fresh `farm build`
  over an existing stack skips to the first plot above the built height; a
  *partial* lower plot (only possible if its journal was manually deleted) would
  be skipped. Normal partial builds keep their journal and resume precisely.
- **Fleet** — architected for it (stateless per-turtle config, shared mesh); a
  small fleet is a later drop-in (one journal/blueprint per turtle).
