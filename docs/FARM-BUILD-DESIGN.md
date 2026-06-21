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

## 1. What the operator does (the whole list — place-and-go)

1. **Drop a turtle** (Advanced) **right next to / on top of the farm** — the Geo
   Scanner's free reach is **8 blocks** (16 max, but a radius-16 scan costs
   ~5274 fuel, so the turtle scans at the free radius). A **Geo Scanner** upgrade
   lets it find the plot from any nearby spot; without one, set it **on top of
   the farm** and it searches on foot (Task #18).
2. **Slap an ME Bridge directly on the turtle** (any face), on the AE network
   that reaches the mining dim. A turtle can only call a peripheral that's
   touching it, so the bridge exports **straight into the turtle's inventory** —
   no chest needed. (Alternatively: turtle on a chest with the bridge wired to
   the turtle and feeding that chest; the turtle probes both handoffs — Task #17.)
3. **Run the installer** and `farm`. On first run it auto-discovers everything,
   tells you what it found, and starts building. It may ask the copy count. If a
   setup goes wrong, **`farm reset`** wipes its state back to first-run.

That's it — no coordinates, no config file, no in-game Lua. On first run the
turtle:
- **finds the plot itself** — with a Geo Scanner by scanning (`peripheral.find` a
  `geo_scanner` → scan a radius → keep the plot-signature blocks → bounding box);
  with no scanner by flying a bounded spiral and inspecting down,
- **works out its own heading with no GPS** (scanner path: steps one block,
  watches the scanned plot's offset shift; on-foot path: works in its own local
  frame so no calibration is needed),
- **discovers the ME Bridge** (`peripheral.find` `me_bridge`) and **calibrates
  the supply handoff** — it probes which export side feeds the chest and which
  way to suck, so the bridge can sit on any side of the chest,
- **writes its own `farm.conf`** in a turtle-relative frame (the drop point is
  the origin), so reboots resume,
- **scans your plot and stacks the copies above it.**

> **Note on the Geo Scanner type.** AP registers it as `geo_scanner` (underscore)
> — `peripheral.find("geoScanner")` silently misses an equipped upgrade. The
> turtle now tries `geo_scanner`, then `geoScanner`, then any peripheral exposing
> `scan()`, so an equipped scanner is never reported missing again.

Your AE network just needs the materials in stock or craftable: dirt, a diamond
hoe, `farmingforblockheads:red_fertilizer`, `mysticalagriculture:sulfur_seeds`,
water buckets, coal blocks. The **one server-side setting** the turtle can't do
(Phase 1): **`force_load_mode: always`** in FTB-Chunks, only if you want it to
run while you're logged out.

> **Power-user fallback.** If you'd rather pin everything by hand (no Geo
> Scanner, exact build location, separate staging chest), write a `farm.conf`
> with explicit `origin`/`size`/`build`/`base = { bridge, park, suck,
> export_side }` coordinates (the drop point is the park) and the wizard is
> skipped entirely.

## 2. How to run

```
farm             first run: auto-setup wizard, then build (startup runs this)
farm setup [N]   force the auto-setup, stacking N copies (default 8)
farm find [r]    dry run: scan (free r=8; up to 16 costs fuel) and report + diagnose
farm reset       wipe config/blueprint/journal back to first-run (clean slate)
farm capture     (manual config) scan the reference plot -> farm.blueprint
farm build       (manual config) self-test, then build the stack
farm selftest    run the startup self-tests only
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

**Handoff calibration (Task #17).** A real `exportItem(filter, side)` resolves
`side` as a direction from the *bridge* (and the adjacent block there is the
target). Crucially, a turtle can only call a peripheral that is **touching it**
(or wired to it), and no single chest can be face-adjacent to *both* the turtle
and a bridge that is itself adjacent to the turtle. So the primary zero-extra-
block setup is the **bridge mounted on the turtle, exporting straight into the
turtle's inventory** (`getHandlerFromDirection` returns the adjacent turtle's
`IItemHandler` — source-verified). The wizard probes each export side with one
dirt probe: if the turtle's own inventory grows, it records `suck = "self"` and
restock **gathers** the pulled stack into the work slot (`transferTo`); if the
probe instead lands in a chest directly above/below, it records that suck dir.
`suck = "self"` gather doubles as the stranded-export recovery (a kill between
export and gather leaves the items already in the turtle). If nothing is
collectable it falls back to a chest-below handoff, and the self-test still gates
the real build.

**Scan cost + reach.** `scan(radius)` is **free at radius ≤ 8** and costs fuel
∝ radius³ above that (radius 16 ≈ 5274 fuel). The turtle scans at the free
radius 8 by default — a costly radius drains it after a few scans and then every
scan fails. Place the turtle within 8 blocks (on the farm). **Heading
calibration** steps one block and reads the plot's offset shift; at the range
edge the bbox-min can stick on the boundary, so it cross-correlates the two scans
(the cardinal step that maps the most plot offsets onto the post-step scan) and
retries up to 4 facings, surviving a blocked step (the bridge in front) too.

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
`isCraftable`/`craftItem` async/`exportItem` side-aware + direct-into-turtle).
`tests/run_farm_tests.lua` is **45/45 green** headless, covering: primitive
fidelity + negative preconditions; **Geo Scanner detection under the real
`geo_scanner` type + a `scan()`-method fallback**; **free radius-8 default scan**;
auto-find (scanner and **on-foot spiral**) + **supply handoff calibration**
(chest-suck and **bridge-on-turtle direct export**) + **edge-of-range heading via
scan cross-correlation** + **`farm reset`**; capture round-trip + idempotency;
single-plot and 2-plot
builds; idempotent converge; AE supply with on-demand crafting; the self-test
gate (pass → builds, fail → builds nothing); kill-resume across a 5-point kill
sweep (no double-fertilize/plant, write-ahead pos invariant), stranded-export
recovery (no double-pull), a 2-plot mid-ascent kill; and telemetry + basectl.
The 97 telemetry and 60 sled regression tests stay green.

```
toolchain/lua-5.2.4/src/lua tests/run_farm_tests.lua    # 34
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
- **On-foot search reach (no Geo Scanner).** The scanner-less search only sees
  the block directly below it, so the plot must be one block under the drop
  altitude (set the turtle *on top of* the farm) and within the spiral radius. A
  Geo Scanner removes both constraints — find it from any nearby position, at any
  altitude. Equipping one is the robust path; the on-foot search is the
  zero-upgrade floor.
- **Supply handoff** is auto-calibrated: bridge mounted on the turtle (exports
  straight in) is the simple path; a chest **directly above/below** the turtle
  (bridge wired in, feeding the chest) also works. A chest only reachable by a
  *horizontal* suck is not probed (vertical sucks stay correct across re-parks
  without tracking a park heading); mount the bridge on the turtle, or put the
  chest above/below.
- **Scanner reach is 8 free / 16 max blocks** (an AP hardware cap; radius 16 also
  costs ~5274 fuel). The turtle must sit on/beside the farm; it cannot find a
  plot farther than 16 blocks no matter what. A fly-and-scan search (spiral the
  scanner toward a distant farm) is a possible future pass.
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
