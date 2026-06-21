# Autonomous Sulfur-Farm Builder — Phase 1 Research

Source-verified feasibility study for a ComputerCraft turtle that scans your
existing mining-dim sulfur plot, replicates it, and stacks copies vertically,
pulling materials from the cross-dimensional AE network. **Build nothing until
this is signed off.**

Read out of the vendored mod sources in `vendor/` on 2026-06-20. Every claim is
grounded in `file:line` (paths relative to repo root; the long
`vendor/<Mod>/src/main/java/...` prefixes are abbreviated where obvious).
Tags mirror `docs/RESEARCH.md`: **[SOURCE]** = settled in code, **[IN-GAME]** =
needs a cheap in-game check (NeoForge/vanilla layer not vendored), **[MIXED]** =
partly each.

---

## 0. Ground truth (corrected) — what this is built on

The original brief was **Claude-UI-generated and is treated as *vibe*, not
spec.** It carried at least one load-bearing error (below). The authoritative
inputs are (a) the operator's statements about a base that demonstrably works,
and (b) the in-game **scan** of the real plot — *not* the brief. The build
design is robust to brief errors precisely because the turtle copies the blocks
that are physically there.

**Confirmed by the operator:**
- Crop: Mystical Agriculture **sulfur**, in the **mining dimension**.
- Accelerators: **AE2 Crystal Growth Accelerator** (`ae2:growth_accelerator`),
  **powered**, fed **FE directly by Mekanism Ultimate Universal Cables** (no AE
  channels in the *power* path).
- Soil: **vanilla farmland → FfB red (Healthy) fertilizer** → FfB Fertilized
  Farmland. One-and-done.
- Harvest: an **unpowered Harvester Pylon from the Pylons mod** collects output
  (→ ender chest). **Builder scope = build + plant first seeds only.** No
  harvest/replant logic.
- The AE network already reaches the mining dim (quantum-bridged).

**Vibe / to be settled by the scan (not assumed):** 9×9 size, the exact center
water source, pylon contents/height, ender-chest position, the precise cross-dim
AE link.

> **Prior-error correction (logged so it isn't repeated).** An earlier pass read
> Mystical Agriculture's unrelated, identically-named `GrowthAcceleratorBlock`
> (which *is* powerless) and wrongly concluded "the accelerators need no power /
> the brief is wrong." That was doubly wrong: it was the **wrong block**, and the
> **right** block (AE2's) accelerates `#minecraft:crops` out of the box. The
> operator's working base is ground truth; source explains it, it does not get to
> contradict it. Every claim below was re-verified by two independent skeptics
> (source-correctness + reconcile-with-base); both agreed on all eight.

**Version pins (cloned at exact ATM10 7.0 builds):** Mystical Agriculture
8.0.26, Farming for Blockheads 21.1.13, Applied Energistics 2 19.2.12, Applied
Mekanistics 1.6.3 (newly vendored); Advanced Peripherals 0.7.62b, CC:Tweaked
1.117.1, Mekanism 10.7.19.85, FTB-Chunks 2101.1.14 (already vendored).

---

## 1. Decision summary

| # | Brief question | Verdict | Risk | Hinges on |
|---|----------------|---------|------|-----------|
| 1 | Turtle builds the soil+plant chain (till → fertilize → plant) | **GO** | LOW | own-claim fake-player interaction (verify in-game) |
| 1w| Turtle places the center water source | **GO** | LOW | bucket path is real; one-line in-game smoke test |
| 2 | Pull mats + trigger autocraft across the dim bridge | **GO** | LOW | one spare AE channel for the bridge |
| 3 | Auto-capture the existing plot into a blueprint | **GO** | LOW | inspect-traversal (zero extra hardware) |
| 4 | Chunk-load build column + running farms | **GO\*** | LOW | **`force_load_mode: always`** (one server setting) |
| 5 | Fuel: does the pack burn it, cleanest supply | **GO** | LOW | confirm vanilla burn values (1-min test) |
| 6 | Power to the mining-dim accelerator pylon | **GO** | LOW | existing FE source has headroom (sizing) |

**No NO-GOs. No HIGH risks.** The whole system is feasible. The two real action
items are a single server-side setting (`force_load_mode: always`, Q4) and a
handful of cheap in-game confirmations of non-vendored NeoForge/vanilla layers.

The brief flagged **the fertilizer as the most likely failure point** — it is
**not** a failure point: FfB's `FertilizerItem.useOn` has *no* fake-player guard,
only a `player != null` check, which the turtle's `FakePlayer` passes.

---

## 2. Claim ledger

Paths abbreviated: `CC` = `vendor/CC-Tweaked/projects/common/src/main/java/dan200/computercraft`,
`FfB` = `vendor/FarmingForBlockheads/common/src/main/java/net/blay09/mods/farmingforblockheads`,
`MA` = `vendor/MysticalAgriculture/src/main/java/com/blakebr0/mysticalagriculture`,
`AE2` = `vendor/AppliedEnergistics2/src/main/java/appeng`,
`AP` = `vendor/AdvancedPeripherals/src/main/java/de/srendi/advancedperipherals`,
`MEK` = `vendor/Mekanism/src/main/java/mekanism`.

### Q1. Per-cell build chain: till → red fertilizer → plant sulfur — **GO / LOW** [SOURCE + one IN-GAME]

All three steps are USE-on-block actions that `turtle.place()` performs by
dispatching the inventory stack through `stack.useOn(UseOnContext)`
(`CC/shared/turtle/core/TurtlePlaceCommand.java:223`), using a **non-null**
NeoForge `FakePlayer` (`.../TurtlePlayer.java:45-56`,
`.../platform/PlatformHelperImpl.java:201-203`).

- **(a) Hoe-till** → vanilla `HoeItem.useOn` tills dirt → `minecraft:farmland`. [SOURCE]
- **(b) Red fertilizer** → `FfB/item/FertilizerItem.java:114-132`. Its **only**
  player guard is `if (player == null) return PASS` (`:116-117`) — the turtle's
  fake player is non-null, so it applies. **RED = the HEALTHY type**
  (`:28,42-45,89-91`) → `fertilizedFarmlandHealthy`. One-and-done: it
  `setBlockAndUpdate`s the block once; it stays. [SOURCE]
- **(c) Sulfur seed** → `MA/item/MysticalSeedsItem.java:17` is an
  `ItemNameBlockItem` (a `BlockItem`), placed via the same `useOn` path; the
  crop survives because FfB `FertilizedFarmlandBlock extends FarmBlock` and
  `canSustainPlant` returns `true` unconditionally
  (`FfB/block/FertilizedFarmlandBlock.java:38-39`). [SOURCE]

**Why sulfur specifically grows on this soil** (skeptic-surfaced, both agreed):
`MA/block/MysticalCropBlock.java:136-159` gates growth on two things only —
(i) a **crux block** below, which **sulfur has none of**
(`MA/lib/ModCrops.java:84` constructs `SULFUR` with no `setCruxBlock`;
`Crop.java:36,503` default null), and (ii) **`requiresEffectiveFarmland`**,
which **defaults `false`** (`MA/config/ModConfigs.java:51-53`) and is **not
overridden** by the pack (`vendor/ATM-10-config/config/mysticalagriculture-common.toml`).
So growth is *not* gated on farmland tier — vanilla or fertilized farmland both
work.

**Permanence, precisely:** Healthy fertilized farmland never reverts via the
moisture/`turnToDirt` path (gated on the `STABLE_FARMLAND` tag, which Healthy
lacks — `FertilizedFarmlandBlock.java:58-71`). There is a *second*
revert path — **regression on harvest** (`FfB/FarmlandHandler.java:28,35-41`) —
but it is **inert**: `fertilizerRegressionChance` defaults `0f`
(`FarmingForBlockheadsConfigData.java:43`) and the pack **ships no FfB config
file** to raise it, and it only fires on harvest (outside builder scope).

**The single caveat → in-game [IN-GAME]:** every step fires NeoForge
`PlayerInteractEvent.RightClickBlock` via `CommonHooks.onRightClickBlock`
(`PlatformHelperImpl.java:228-240`) with the turtle fake player. A claim mod
(**FTB-Chunks**) *can* cancel that for fake players. FTB-Chunks' own claim
behavior was researched for Project Sled (`docs/RESEARCH.md` D1: owner-placed
turtle, `allow_fake_players_by_id=true`, members are allies → **allowed in the
owner's own claim by default**), so in your own mining-dim claim this is **LOW**
risk — but it is the one thing to confirm.

**Cheapest test:** load a turtle with `[hoe, red fertilizer, sulfur seeds]`
inside the plot's claim; from a Lua prompt, `select`+`placeDown` each in turn;
confirm the block becomes "Fertilized Farmland — Healthy" and the planted crop
ticks under a powered accelerator. A `false`/"Cannot place item here" return
means the FTB-Chunks fake-player veto bit.

**Build-mechanics notes for Phase 2:** reach is clamped to **2 blocks**
(`TurtlePlayer.java:37`) — keep the turtle adjacent to each target cell; the seed
must land on a farmland **top face**; the hoe takes 81 till-ops per 9×9, so
track/repair or restock hoe durability.

### Q1-water. Place the center water source — **GO / LOW** [SOURCE + one IN-GAME]

The bucket — the one item I expected to fail — **works**. After `useOn` PASSes
(a water bucket is `Item.use`, not a consuming `useOn`), `TurtlePlaceCommand`
hits an explicit **`item instanceof BucketItem`** branch
(`TurtlePlaceCommand.java:230-232`) routing to `gameMode.useItem(...)` →
`BucketItem.use` → emits a **water source block**; the emptied bucket is written
back to the turtle inventory. CC's changelog even records a reach-distance bugfix
specifically for "turtle placing water buckets" — proof it is real, exercised
behavior. [SOURCE]

The center water is **load-bearing, not cosmetic**: FfB farmland decays
`MOISTURE` each random tick when not `isNearWater` (vanilla 4-block radius),
and `isFertile` requires `MOISTURE > 0` (`FertilizedFarmlandBlock.java:43-71`).
One center source hydrates the 9×9, matching the working plot.

**Mechanics:** aim the bucket at a **solid** adjacent block (e.g. `placeDown`
against the floor) — `canDeployOnBlock` won't engage on pure air
(`TurtlePlaceCommand.java:121`); vanilla `BucketItem.use` then deposits the
source into the resolved air cell. Refill the bucket from any source between
layers, or carry enough for the stack height.

**Caveat → in-game [IN-GAME]:** a server-side protection mod hooking
`RightClickItem`/`FluidPlaceBlockEvent` on fake players is not visible in
vendored source. **One-line test:** water bucket in slot 1, `turtle.placeDown()`
over a floor cell; success + empty bucket returned = whole path proven on this
server. **Fallback** if it ever fails: hand-seed the one center block per plot
(trivial) — the turtle builds everything else.

### Q2. AE supply + cross-dim autocraft — **GO / LOW** [SOURCE + one IN-GAME]

The AP **ME Bridge is a first-class AE2 in-world grid node**, not a snapshot
reader: every method resolves services off `node.getGrid()`, so it operates on
whatever `IGrid` the bridge belongs to (`AP/.../blockentities/MEBridgeEntity.java`;
sets `GridFlags.REQUIRE_CHANNEL` at `:65`). AE2's **`QuantumCluster` fuses the
two quantum-bridge nodes into ONE `IGrid`** via `GridHelper.createConnection`
**regardless of dimension** (`AE2/me/cluster/implementations/QuantumCluster.java`).
So an ME Bridge on the mining-dim subnet sees **base storage, base crafting
CPUs, and base patterns**. [SOURCE]

Full surface exists in `AP/.../peripheral/MEBridgePeripheral.java`: read stock
`getItem`/`getItems` (`:173,225`); craftability `isCraftable` (`:833`); start a
job `craftItem` (`:680`, **async** — not `mainThread`); export to an adjacent
side or a named wired peripheral `exportItem` (`:356-372`); `getCraftingCPUs`
(`:871`). Item moves are **machine-sourced** (`MEBridgeEntity.java:84-92`,
`IActionSource` `player()=empty, machine()=this`) → **no fake-player path** for
reads/crafts/exports. [SOURCE]

**Mechanics:** run AE2 cable from the mining-dim subnet to an ME Bridge beside a
staging chest the turtle pulls from. Lua: `if getItem(spec).count < need and
isCraftable(spec) then job = craftItem(spec); wait for 'ae_crafting' /
poll getCraftingTask(job).isDone() end; exportItem(spec, side); turtle.suck()`.
**Gate on completion before exporting** (craftItem is async).

**Caveats (operational, not blocking):** the bridge needs **one spare AE
channel** + idle power; if `isConnected()` is false in-game, that's the cause,
not a code limit. Fluid/chemical recipe inputs remain only readable as merged-grid
contents (consistent with `[[chemical-flow-not-readable-via-cc]]`), but
item/seed crafting doesn't need that.

### Q3. Auto-capture the plot into a blueprint — **GO / LOW** [SOURCE]

**Inspect-traversal is recommended** and needs **zero extra hardware**.
`turtle.inspect/inspectUp/inspectDown` return **name + full blockstate + tags**
(`CC/.../core/TurtleInspectCommand.java:30`; `docs/RESEARCH.md` C6/C7). That is
**strictly richer** than the AP **Geo Scanner**, which returns name + tags but
**no blockstate** and skips air (`AP/.../blockentities/GeoScannerEntity.java`,
`ScanUtils`; turtle-usable, radius ≤ 8 is free). All seven cell types are
distinguishable from name+state alone:

| Cell | Distinguisher |
|------|---------------|
| vanilla farmland | `minecraft:farmland` |
| fertilized farmland | `farmingforblockheads:fertilized_farmland_healthy` (distinct block) |
| sulfur crop | MA `..._crop`, `state.age` (re-plant fresh at build, ignore captured age) |
| AE2 accelerator | `ae2:growth_accelerator`, `state.facing` + `state.powered` |
| Mek cable | `mekanism:ultimate_universal_cable` (tier in the name) |
| water / ender chest / air | trivial |

**Mechanics:** park at a known origin corner; fly a boustrophedon serpentine per
Y-layer recording `{dx,dy,dz,name,state}`; air on inspect-failure. Optional: one
`scan(8)` Geo Scanner pre-pass to enumerate occupied cells fast, then inspect
those to recover blockstate. Pure reads — no fake-player, no placement.

### Q4. Chunk-loading — **GO-WITH-CAVEAT / LOW** [MIXED]

Both needs collapse to **one requirement: the chunk must be ENTITY/BE-ticking.**
- Crop acceleration is driven by the **accelerator's AE grid tick**, not the
  `randomTickSpeed` gamerule: `GrowthAcceleratorBlockEntity.java:60-72` is an
  `IGridTickable` that, when powered, calls `adjState.randomTick(...)` on each
  adjacent crop every grid tick (`:104-113`). AE2 only ticks that node while its
  BE is loaded-and-ticking, gated on the chunk being entity-ticking
  (`AE2/hooks/ticking/TickHandler.java:366-367`, "equivalent to
  `ServerLevel#isPositionTickingWithEntitiesLoaded`"). [SOURCE]
- FTB Chunks registers **every** force-load ticket `ticking=true` and purges
  non-ticking ones (`vendor/FTB-Chunks/.../ForceLoading.java:34-57`,
  `FTBChunksExpectedImpl.java:13`). [SOURCE]
- CC:Tweaked **never self-loads** (`docs/RESEARCH.md` C4, SOURCE-by-absence). [SOURCE]

**THE ONE SERVER-SIDE SETTING → `force_load_mode: always`.** Default `DEFAULT`
requires an FTB-Ranks `ftbchunks.chunk_load_offline` permission and otherwise
yields **false offline** (`ChunkTeamDataImpl.java:488-496`; `docs/RESEARCH.md`
D1). Set `always` (or grant that permission) so the farm runs while you're
logged out.

**Footprint:** a 9×9 grid-aligned plot = **1 chunk** (≤ 4 if it straddles
boundaries); **vertical stacking shares the X/Z column, so chunk count is
independent of stack height** — trivial vs FTB's default 25 force-load / 500
claim budget.

**Caveat → in-game [IN-GAME]:** "a *ticking* FTB ticket ⇒ NeoForge
`ENTITY_TICKING` level" is the NeoForge ticket contract, not vendored
(`docs/RESEARCH.md` S10). Your base **already** runs these accelerators while
loaded, so the only untested surface is *offline*. **Test:** set
`force_load_mode: always`, claim+force-load the plot, log out 15–30 min, log
back in — an accelerated plot should be visibly ahead of an unaccelerated
control. (Also eyeball the live `ftbchunks-world.snbt` `force_load_mode` — a
hand-edited server value wins over pack defaults.)

### Q5. Fuel — **GO / LOW** [SOURCE + one IN-GAME]

Pack burns fuel: `need_fuel=true`, limits **20,000 / 100,000** (normal/advanced),
**1 fuel/move, turns free** (`CC/.../core/TurtleMoveCommand.java:58-61`;
`Config.java`; pack `computercraft-server.toml`). `fuel = burnTime/20` via the
single registered `FurnaceRefuelHandler`, which delegates to
`stack.getBurnTime(null)` (`PlatformHelperImpl.java:182`) → vanilla values
(coal/charcoal 80, **coal block 800**, lava bucket 1000). Refuel self-caps;
overfill impossible. [SOURCE]

**Autonomous refuel (zero hand-feeding):** advanced turtle (100k tank); keep
**coal blocks** (best per-slot, 800 ea, 51,200/stack; avoid lava buckets — don't
stack); at a low watermark, `exportItem({name='minecraft:coal_block',...}, side)`
from the ME Bridge → `turtle.suck()` → `turtle.refuel()`. **Budget ≈ 10³
fuel/plot** (a couple coal blocks); an advanced turtle builds ~50 plots/tank.

**One gap → in-game [IN-GAME]:** vanilla burn constants aren't in CC source
(delegated). Test S3 (~1 min): `refuel(1)` one coal, expect Δ80; one coal block,
expect Δ800. The refuel routine is value-agnostic anyway (probes Δ at runtime).

### Q6. Power to the mining-dim accelerator pylon — **GO / LOW** [SOURCE + one IN-GAME]

*(Reframed: this is not "cross-dimensional power" — your base already has FE in
the mining dim feeding the current plot. The builder just **extends cable from
the existing source** up each new pylon.)*

**The accelerator** (`AE2/blockentity/misc/GrowthAcceleratorBlockEntity.java`):
draws **8 AE/t** (`:52,59`), **inert unpowered** (`onTick: if(!powered) return`,
`:97-99`), random-ticks all **6** adjacent `#ae2:growth_acceleratable` blocks
(`:104-113`) — and that tag **ships including `#minecraft:crops`**
(`vendor/AppliedEnergistics2/src/generated/resources/data/ae2/tags/block/growth_acceleratable.json`),
into which MA registers its crops (`MA .../data/minecraft/tags/block/crops.json`)
— so it accelerates sulfur with **stock data**. It accepts **FE** via the
NeoForge `EnergyStorage.BLOCK` capability (`ForgeEnergyAdapter`, FE→AE), exposed
**only on the FRONT/BACK faces** (`AEBasePoweredBlockEntity.java:172-180`,
`getPowerSides` = FRONT+BACK, `GrowthAcceleratorBlockEntity.java:81-83`) — which
is exactly how your Mek cables power it. [SOURCE]

**The cable** (`MEK/common/.../transmitter`): Mek Universal Cable (all tiers) is
a plain `BlockItem` placed via the vanilla path — **no orientation, no useOn, no
fake-player/permission guard** (grep of the transmitter block+item packages =
zero hits). It **auto-connects all 6 neighbors** by default
(`Transmitter.java:73-74,669-678`) and the `EnergyNetwork` pushes FE into
adjacent acceptors automatically (`EnergyCompatUtils.java:41` registers
`ForgeEnergyCompat`; `EnergyNetwork.java:104,123`). Ultimate throughput
8,192,000 J/t (`CableTier.java:15`) ⋙ 16 FE/t per accelerator. [SOURCE]

**Mechanics:** place one cable per Y-level up the pylon (auto-merges with the
existing run on adjacency — no join action), and a cable on each accelerator's
FRONT or BACK face. **Decoupling trick:** since acceleration hits all 6 faces but
power only FRONT/BACK, place each accelerator with `placeUp`/`placeDown` so its
power axis is **vertical** → a single cable column up the pylon powers the whole
stack deterministically, with crops on the horizontal faces.

**Caveats:** (i) the exact `facing` a turtle place produces depends on vanilla
`BlockHitResult` internals (not vendored) → confirm with a one-block in-game test,
or just use the vertical-axis `placeUp` trick which is orientation-proof. (ii)
**Sizing** [IN-GAME]: does your existing FE source have headroom for `N×K×16
FE/t`? Tap one extra accelerator off the existing cable and watch all stay
powered. Fallback if a column outruns the source: one **Mek Energy Cube** buffer
(plain auto-connecting block) — no new generation.

---

## 3. Consolidated action items (what *you* do)

1. **`force_load_mode: always`** in FTB Chunks world config (or grant
   `ftbchunks.chunk_load_offline`). The single mandatory server-side change.
2. **In-game smoke tests** (all cheap, settle the non-vendored layers):
   - Build chain inside your claim (`[hoe, fertilizer, seeds]` → 3 placeDowns).
   - Water bucket → `placeDown` over a floor cell (proves fluid placement).
   - `force_load_mode: always` → 30-min offline growth vs control plot.
   - `refuel(1)` Δ check (coal = 80, coal block = 800).
   - ME Bridge `getItem` on a base-only item from the mining dim (proves the
     grid merge); then `craftItem`+`exportItem` round-trip.
   - One accelerator placed by turtle → confirm a Mek cable on its facing axis
     powers it.
3. **Sizing sanity:** confirm the existing mining-dim FE source can feed the
   accelerators of however many stacked plots you want.

---

## 4. Proposed architecture (for sign-off, not yet built)

- **Capture:** turtle inspect-traversal of one existing plot → 3D
  `{dx,dy,dz} → {name,state}` blueprint; re-plant fresh seeds (ignore captured
  crop age); replicate fertilized-farmland by *place vanilla farmland + apply
  red fertilizer* (matches your build, and avoids assuming the fertilized block
  is item-placeable).
- **Replicate + extend:** stack copies up one chunk-aligned column; per cell run
  the till→fertilize→plant chain; erect the accelerator pylon (vertical power
  axis) + cable run tied into the existing FE source; place the water source;
  place the Pylons Harvester Pylon + ender chest from the blueprint.
- **Supply:** mining-dim ME Bridge beside a staging chest; read/craft/export mats
  + fuel on demand; no hand-stocked chest.
- **Orchestrate:** reuse the existing mesh — `rednet` telemetry over ender modems
  (cross-dim delivery confirmed, `docs/RESEARCH.md` C5 corollary), `basectl`
  update channel, manifest role, `installer`/`update` path. An Advanced Computer
  at base can supervise.
- **Build-time self-tests:** before any real plot, the turtle verifies the risky
  primitives on a scratch block (till, place water, fertilize, plant, ME pull,
  craft request) and aborts loudly on any failure.
- **Validation gate:** the harness (`harness/cc_env.lua`) already mocks a
  turtle + voxel world + ME bridge (Project Sled). Phase 2 extends it with:
  ME-Bridge crafting methods (`craftItem`/`isCraftable`/`getItem`/`exportItem`),
  a Geo-Scanner mock (optional), and item-use semantics for hoe/bucket/
  fertilizer/seed — then the full scan→plan→build→restock runs headless before
  you touch it in-game.

## 5. Open decisions for you

1. **Replicate strategy:** capture-and-copy one plot (recommended), or a
   parameterized 9×9 template you confirm once?
2. **Accelerator pylon geometry:** vertical-power-axis column (orientation-proof,
   recommended) vs replicate the exact facings from the scan?
3. **One turtle or a small fleet** for taller stacks (fuel/time per plot is cheap
   either way)?
4. **Cross-dim AE link** — confirm it's an AE2 quantum bridge (vs P2P/other) so
   the supply hardware note is exact.
5. **Pylons mod** — vendor it and verify the Harvester Pylon drops cleanly from a
   fake-player place? (It's a plain block to replicate; low risk, but un-checked.)

---

*Phase 1 complete. Built on your working base, not the brief. Nothing built until
you sign off on §4/§5.*
