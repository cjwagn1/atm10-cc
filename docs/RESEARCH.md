# Source-verified API facts (ATM10 / MC 1.21.1)

Everything below was read out of the vendored mod sources in `vendor/`,
2026-06-11. These are the facts fluxdash v2 and the harness mocks are built on.

## CC:Tweaked (branch mc-1.21.x, modVersion 1.119.0, Cobalt 0.9.9)

- Generic energy peripheral: any block with an FE capability gets Lua methods
  `getEnergy()` / `getEnergyCapacity()`, both returning **Java int** (so
  saturated at 2,147,483,647), under additional peripheral type
  `"energy_storage"`.
  `projects/forge/.../generic/methods/EnergyMethods.java:16-24`,
  `projects/common/.../AbstractEnergyMethods.java:27-29`
- Wired-network peripheral names are `type + "_" + id` — the accessor shows up
  as `appflux:flux_accessor_0`. `.../WiredModemLocalPeripheral.java:85-87`
- `peripheral.getType(name)` returns **multiple values** (primary + generic
  types); `peripheral.hasType(name, type)` is the proper membership check.
  `rom/apis/peripheral.lua:159-210`
- Colors on non-advanced terminals do **not** error (any valid color 1..32768
  is accepted; basic terminals just render greyscale). "Colour out of range"
  is only thrown for invalid values. `core/apis/TermMethods.java:335-340`
- `os.clock()` = computer uptime, tick-granular (`clock * 0.05`) — this is
  *game-tick time*, which makes it the correct base for FE/t math even under
  TPS lag (wall-clock would overestimate). `core/apis/OSAPI.java:271-274`
- Events on attach/detach are `"peripheral"` / `"peripheral_detach"` with the
  side/name as arg. `core/apis/PeripheralAPI.java:212,225`
- Default HTTP rules: `DENY $private, ALLOW *` — github raw works on a stock
  server; LAN hosts need a config edit. `core/CoreConfig.java:29-32`
- `_HOST` here ≈ `"ComputerCraft 1.119.0 (Minecraft 1.21.1)"`.
- Numbers are doubles (no 5.3 integers); `string.format("%d", 12.5)`
  truncates rather than erroring. Our Lua 5.2.4 toolchain matches this.

## AppFlux (GlodBlock, branch appflux/1.21.1-neoforge of ExtendedAE repo)

- Flux Accessor exists as full block `appflux:flux_accessor` **and** cable
  part `appflux:part_flux_accessor`.
- Its `IEnergyStorage` reads the **whole network's** flux (cached storage
  inventory keyed by `FluxKey.of(EnergyType.FE)`) — exactly what we want.
  `common/caps/NetworkFEPower.java:24-32`
- **Clamping is confirmed**: `AFUtil.clampLong(long) = (int) Math.min(value,
  Integer.MAX_VALUE)` — `util/AFUtil.java:18-20`. Internally everything is
  longs; only the capability read is clamped.
- **No ComputerCraft integration exists in AppFlux** (zero hits for
  computercraft/dan200/@LuaFunction). The generic FE capability is the only
  computer-facing API. The UI-chat hope for a richer native readout is dead
  unless GlodBlock adds one.
- Flux cell capacities (1,048,576 FE per byte, default config):
  1k = 1.07G FE (already half the int range), 4k = 4.29G, 16k = 17.2G …
  256M = 281T FE. **The clamp is the normal case, not the edge case.**
- `receiveEnergy`/`extractEnergy` are implemented bidirectionally;
  `flux_accessor.io_limit` config defaults to **0 = unlimited** I/O per tick.
  The accessor can legitimately power an entire base from the cells.
- Flux is stored as raw FE 1:1 (no AE-unit conversion on cell contents).

## Advanced Peripherals (dev/1.21.1, v0.7.62b)

- ME Bridge peripheral type: **`me_bridge`** (`MEBridgePeripheral.java:50`).
- Energy methods (all **AE units**; 1 AE = 2 FE):
  - `getStoredEnergy()` (long) — AE grid energy buffer
  - `getEnergyCapacity()` (long)
  - `getEnergyUsage()` (double) — rolling average AE/t drawn by the grid
  - `getAverageEnergyInput()` (double) — rolling average AE/t injected
- ⚠ These are the **AE energy buffer** (energy cells/controller), *not* the FE
  in flux cells. Two different numbers, both worth showing.
- ⚠ The original UI-chat draft called `getEnergyStorage`/`getMaxEnergyStorage`
  — **those methods don't exist** in this version; pcall ate the error and the
  AE section would have rendered permanently blank.
- ME Bridge enabled by default (`enableMeBridge=true`), idle draw 10 AE/t
  (`mePowerConsumption`).
- Inventory/monitoring surface worth exploring later: `getCells()`,
  `getDrives()`, `getCraftingCPUs()`, `getItems()`, storage-bytes getters.
  ~~Int-clamp loophole candidate: `getCells()`~~ **DEAD** — `getCells`/
  `getDrives` filter on AE2's `BasicStorageCell`/`IBasicCellItem`
  (`AEApi.java:394,963`); AppFlux's `ItemFECell` implements neither, so flux
  cells are invisible to the ME Bridge.

## CONFIRMED int-clamp workaround: Block Reader (in-game verified 2026-06-11)

- AP **Block Reader** (type `block_reader`, `enableBlockReader=true` default)
  `getBlockData()` returns the faced block entity's full saved NBT as a Lua
  table (`BlockReaderPeripheral.java:40-47`).
- AppFlux persists each cell's energy as item component **`appflux:fe_energy`**
  (`Codec.LONG` — `AFSingletons.java:27,76,128`), present in the drive's NBT.
- In-game dump shape on Carter's server (ExtendedAE Extended Drive):
  `inv.itemN.components["appflux:fe_energy"]` under block
  `extendedae:ex_drive`. Read exactly 51,847,398,108 FE while the capability
  reported 2,147,483,647.
- True capacity derives from cell item ids: bytes(size from id) × 1,048,576
  FE/byte (default `flux_cell.amount`).
- Shipped: `fluxprobe.lua` (shape-agnostic dump/sum) and fluxdash v3 (sums
  all attached block readers, true rate, accessor fallback + clamp banner
  only when no reader sees cells). Lua doubles are exact to 2^53 ≈ 9.0 PFE —
  headroom to ~32× a full 256M cell.

## Consequences baked into fluxdash v2

1. Detect by `peripheral.hasType(name, "energy_storage")` + name preference
   for `flux`/`accessor`; manual override arg for ambiguous rigs.
2. ME Bridge section uses the real method names and labels values `AE`.
3. The clamp banner is a first-class feature, and `scan` flags clamped
   readings explicitly.
4. Rate math stays on `os.clock()` (tick time), smoothed over 10s.

---

# Project Sled — claims ledger (research phase, 2026-06-11)

A turtle-managed skid (Digital Miner + Quantum Entangloporters) that
relocates itself along a lane in the mining dimension. Everything below was
read out of vendored, pack-pinned mod sources by a 16-agent verification
pass, then adversarially re-read citation-by-citation by a second set of
agents. Tags: `[SOURCE]` proven from source; `[IN-GAME]` needs the numbered
manual test in docs/INGAME-CHECKLIST.md; `[MIXED]` sub-facts split;
`[FALSE]` the assumption was wrong (what's actually true is recorded).

## D3. Version pins [SOURCE]

Derived from the modpack's own repo (AllTheMods/ATM-10 @ `71abe87`, the
commit that added the 7.0 changelog, 2026-05-15), vendored as
`vendor/ATM-10-config` (sparse: config/, defaultconfigs/, changelogs/):

- **Mekanism 10.7.19** — `changelogs/CHANGELOG-ATM10-6.6-7.0.md:158`
  ("(10.7.18) -> (10.7.19)"). Vendored: `vendor/Mekanism` @ tag
  `v1.21.1-10.7.19.85`.
- **FTB Chunks 2101.1.14** — `changelogs/CHANGELOG-ATM10-5.5-6.0.md:225`;
  no later bump in any 6.x→7.0 changelog. Vendored @ `v2101.1.14`.
- **FTB Teams 2101.1.10** (`...6.4-6.5.md:23`), **FTB Library 2101.1.31**
  (`...6.1-6.2.md:50`). Vendored at matching tags.
- **CC:Tweaked 1.117.1** (`...6.1-6.2.md:35`, matches README).
  `vendor/CC-Tweaked` was floating on branch `mc-1.21.x` (1.119.0!) and has
  been **re-pinned to tag `v1.21.1-1.117.1`** — all C-claims verified there.
- ⚠ Discrepancy: changelogs say AP 0.7.61b at 7.0 (`...6.2-6.3.md:17`,
  nothing later) but the server demonstrably runs **0.7.62b** (prior phases,
  in-game verified). The live server can deviate from stock pack — checklist
  test S1 eyeballs the mods folder for the Mekanism/FTB jars before trusting
  these pins.
- The pack ships **no ftbchunks config** (nothing in config/ or
  defaultconfigs/) — FTB Chunks mod defaults apply unless the live server's
  generated `config/ftbchunks-world.snbt` / `world/serverconfig/
  ftbchunks-world.snbt` (the latter wins: FTB-Library
  `ConfigManager.java:203-209`) was hand-edited. Checklist S2.

## A. Mekanism Digital Miner

### A1. CC peripheral + method surface [SOURCE]

- Peripheral type is **`digitalMiner`**: block type built
  `.withComputerSupport("digitalMiner")`
  (`vendor/Mekanism/src/main/java/mekanism/common/registries/MekanismBlockTypes.java:353`),
  exposed through CC's `PeripheralCapability` via `MekanismPeripheral`
  whose `getType()` returns that name (`.../integration/computer/computercraft/
  MekanismPeripheral.java:32-43`, `CCCapabilityHelper.java:24-28`). Wired
  names are `digitalMiner_N` (CC:T `WiredModemLocalPeripheral.java:86`).
- The methods the sled needs (declared in
  `.../tile/machine/TileEntityDigitalMiner.java` unless noted):
  - **`getToMine()`** — count of blocks found-but-not-yet-mined (:1233);
    **`isRunning()`** (:1238); **`getState()`** → IDLE/SEARCHING/PAUSED/
    FINISHED (:1338, enum `ThreadMinerSearch.java:130-134`).
  - **`start()` / `stop()` / `reset()`** (:1365-1381).
  - `getRadius()/getMinY()/getMaxY()/getSilkTouch()` (:316-349),
    `getMaxRadius()`, `getAutoEject()/getAutoPull()`,
    `getEnergyUsage()` → live J/t, 0 when inactive (:1319-1322),
    `getEnergy()/getMaxEnergy()` in **Joules** (TileEntityMekanism
    :1668-1711), `getSecurityMode()/getOwnerUUID()/getOwnerName()`
    (TileComponentSecurity :47-64,148-156).
  - Setters `setRadius/setMinY/setMaxY/...` exist but also require searcher
    state IDLE (`validateCanChangeConfiguration`, :1388-1394) — the sled
    doesn't need them (config rides the item, A2).
- **Every mutating method (incl. `start`/`stop`/`reset`) throws unless the
  machine's *effective* security mode is PUBLIC**:
  `validateSecurityIsPublic()` → "Setter not available due to machine
  security not being public." (TileEntityMekanism :1647-1651). Getters are
  never security-gated. Pack ships security on (`allowProtection = true`,
  ATM-10-config `config/Mekanism/general.toml:179`).
- ⚠ Skeptic finding: the *effective* mode can be raised above the tile's
  own PUBLIC by the owner's **Security Desk frequency override**
  (`SecurityUtils.java:154-166`) — keep the desk override OFF or all
  setters silently start failing. Detectable: `getSecurityMode()` returns
  the effective mode.
- Every method call dispatches to the main thread (`CCMethodCaller.java:
  29-33`) — **each call costs ≥1 server tick**; batch polls.
- Peripheral reachability on the multiblock: only via the main block or
  the port faces of bounding blocks (offset capability gate,
  TileEntityDigitalMiner :1147-1183) — see A4 geometry. Exact face sweep:
  checklist **S8**.

### A2. Break retains config in the item; works under turtle.dig [MIXED]

- Loot table is datagen `dropSelfWithContents` → vanilla
  `minecraft:copy_components` with `source: block_entity`
  (`src/datagen/.../MekanismBlockLootTables.java:27-28`,
  `BaseBlockLootTables.java:158`). The shipped
  `digital_miner.json:15-33` copies **17 components** incl.
  `mekanism:filters`, `min_y`, `max_y`, `radius`, `eject`, `pull`,
  `silk_touch`, `owner`, `security`, `upgrades`, **`energy`**, **`items`**.
  Zero `conditions` keys → **harvester-agnostic** [SOURCE].
- Components registered in `MekanismDataComponents.java:72-81,167-169,
  260-262`; filters codec `FilterAware.java:23-26`.
- Re-place restore: `TileEntityDigitalMiner.applyImplicitComponents`
  (:1087-1094) restores radius (clamped to maxRadius=32 — pack ships 32,
  `general.toml:126`), minY/maxY; `TileEntityMekanism:841-852` restores
  containers + filters. The invoking vanilla hop (BlockItem.place →
  applyComponentsFromItemStack) is not vendored → **[IN-GAME] S9**.
- **Geometry**: the miner is 1 main block + **17 bounding blocks** filling
  x∈[-1,1], y∈[0,1], z∈[-1,1] minus origin — main block is **bottom-center
  of a 3×3×2 volume** (`MekanismBlockTypes.java:334-351`). Breaking main
  removes all bounding blocks with no drops (`BlockMekanism.java:131-138`,
  `AttributeHasBounding.java:36-38`, bounding has no loot table). Breaking
  a *bounding* block proxies destroy+drop to main (`BlockBounding.java:
  222-233`; drop lands at main pos, still inside CC's ±2 DropConsumer AABB,
  `DropConsumer.java:40-46`).
- **Tool gate**: `requiresCorrectToolForDrops` (`BlockTile.java:37-38` —
  skeptic corrected the constructor path) + `mineable/pickaxe`
  (`pickaxe.json:59`; bounding block too, `:3`). Wrong tool ⇒ block breaks
  with **no drop = miner destroyed**. Vanilla no-drop semantics not
  vendored → **[IN-GAME] S9e**.

### A3. Security doesn't block the owner's turtle [MIXED]

- **The turtle fake player carries the turtle owner's GameProfile** — the
  single most load-bearing fact of the project: `TurtlePlayer.create` uses
  `turtle.getOwningPlayer()` (CC:T `TurtlePlayer.java:45-56`), set when a
  player places the turtle (`TurtleBlock.java:146-148`) and persisted in
  NBT (`TurtleBrain.java:180-187`). Fallback profile `[ComputerCraft]`
  (UUID `0d0c4ca0-...`) only when never player-placed. **The sled turtle
  must be hand-placed by Carter** [SOURCE].
- Break protection = `getDestroyProgress` returning 0 on `canAccess` fail
  (`BlockMekanism.java:235-237`; CC checks it: `TurtleTool.java:139-142`)
  **plus** a `BlockEvent.BreakEvent` cancel (`CommonWorldTickHandler.java:
  101-113`) — both pure UUID-vs-owner checks (`SecurityUtils.java:116-122`),
  no FakePlayer special-casing in Mekanism security (grep: zero hits).
  Owner's turtle digs its machines in any mode.
- Placement is never security-gated; item's stored owner wins, placer UUID
  only a fallback when none (`BlockMekanism.java:160-162`,
  `TileComponentSecurity.java:87-90`).
- Operation matrix (owner-placed turtle): dig ✓/✓/✓, place ✓/✓/✓,
  wrap+getters ✓/✓/✓, computer **setters ✗/✗/✓** for Private/Trusted/Public.
- **Rule: both sled machines stay PUBLIC** (mode persists on the item via
  loot components, one-time setup), Security Desk override off. Pack also
  flips `opsBypassRestrictions = true` (`general.toml:181`; mod default
  false) — failsafe only. Smoke test: checklist **S6** (optional).

### A4. Radius / energy / eject / power geometry [MIXED — two FALSE parts]

- Radius cap **32** [SOURCE]: `GeneralConfig.java:227-228` default,
  `general.toml:126` pack. Horizontal-only confirmed: scan volume =
  `(2r+1)² × (maxY-minY+1)`, start `(x-r, minY, z-r)`
  (`TileEntityDigitalMiner.java:919-929`, iterated by
  `ThreadMinerSearch.java:60-70`). minY/maxY clamp to dimension build
  limits (:411-432).
- Energy [SOURCE formula, IN-GAME absolute]: per-tick J/t =
  `ceil(1000 × (×12 if silk) × (1 + (r-10)/(maxR-10)) ×
  (1 + (maxY-minY-60)/(dimHeight-1-60)))`
  (`MinerEnergyContainer.java:46-75`, baselines
  TileEntityDigitalMiner :124-125; usage default 1000 J/t
  `UsageConfig.java:58` = pack `machine-usage.toml:24`; silk ×12 and
  80 ticks/block `general.toml:123-129`; FE = J/2.5 `general.toml:81`).
  Full per-tick cost drains **every tick while running** and the miner
  idles unless the full amount is available (:256-268); buffer is only
  50 kJ ≈ 12.5 ticks (`machine-storage.toml:24`) — supply must be
  continuous. With D2's real band (minY 65, maxY 247, dim height 384,
  r=32, silk off): **2,756 J/t = 1,102 FE/t; 80 ticks/block ⇒
  ~88.2k FE per mined block; 0.25 blocks/s** (no upgrades). Dim height
  confirm: **S9**.
- **[FALSE] "auto-eject pushes into an adjacent entangloporter":** eject
  targets exactly ONE position — `mainPos.above().relative(back, 2)`
  (1 up, 2 behind main; :277-286), every 10 ticks, `doEject` defaults OFF
  (:145). It is not "any adjacent inventory".
- **[FALSE] "pulls power from the same block":** the miner **never pulls**
  — energy container is insert-only (`MinerEnergyContainer.java:23-24`,
  canExtract=notExternal) and exposed at exactly three ports: main block
  DOWN face, and the outer faces of the left/right bounding blocks at
  main-block height (:1167-1182; container sides :182-183; bounding
  proxying `TileEntityBoundingBlock.java:193-202`,
  `Capabilities.java:108-111`). Item ports: top-center UP face (input) and
  top-back-center back face (output) only (:1154-1164); the main block has
  **no item capability at all** (`MekanismTileEntityTypes.java:222-223`).
- **Design consequence: one QE cannot serve both roles** — the eject
  target touches only the item-output port; the energy ports are disjoint.
  The skid is **miner + 2 QEs on one frequency** (or QE + cable run).
- ⚠ Skeptic: `running` is NBT-only, **not** in the item components
  (:904 vs :1071-1084), and a fresh placement is IDLE — **the sled must
  call `start()` after every re-place** (auto-restart only fires from
  state FINISHED, :233-243). Each `start()` triggers a full volume re-scan
  (1.62M positions at r=32/384-tall) — budget search latency.

## B. Quantum Entangloporter

### B1. Frequency survives the cycle, owner-scoped correctly [MIXED]

The feared sled-killer is **defused**, with two vanilla hops left to S4:

- Drop copies `mekanism:inventory_frequency` + `owner` + `security`
  (`quantum_entangloporter.json:20-30`). The component stores only a
  **FrequencyIdentity = (name, SecurityMode, ownerUUID)**
  (`Frequency.java:190`, codecs `FrequencyAware.java:40-43`,
  `IdentitySerializer.java:19-23`).
- On placement the tile resolves the frequency **by the stored identity's
  owner — never the placer**: `TileComponentFrequency.java:273-275`
  (`setFrequencyFromData(type, identity, frequencyAware.getOwner())`,
  with Mekanism's own TODO confirming the placer is unused), manager
  lookup by name under the original owner (:178-182), recreated under the
  original owner if deleted (`FrequencyManager.java:161-169`).
- Runtime transfer checks only frequency validity — no accessor identity
  (`TileEntityQuantumEntangloporter.java:147-149`). Owner identity is
  checked at GUI selection time only (`PacketSetTileFrequency.java:44-46`).
- **Never use TRUSTED frequencies**: the only periodic owner re-validation
  (:206-214) and the only item-component strip path
  (`FrequencyAware.java:84-91`) are both TRUSTED-exclusive. PRIVATE or
  PUBLIC are safe (private freq deleted by owner unsets in 5 ticks but
  re-creates on next place).
- Frequencies are **global overworld SavedData**
  (`FrequencyManager.java:131-133`) — same frequency resolves in the
  mining dimension; buffers live on the frequency, the tile persists
  nothing (`TileEntityQuantumEntangloporter.java:167-171`), so in-flight
  contents survive the break window (no auto-delete of idle frequencies,
  `Frequency.java:77-83`).
- CC:T never touches components in turtle inventories (storage merges via
  `ItemStack.isSameItemSameComponents`, `InventoryUtil.java:130-134`) —
  and differently-configured QEs therefore never stack: track by slot.
- Round-trip smoke test: checklist **S4**.

### B2. One frequency = power in + items out; side config persists [MIXED]

- One `InventoryFrequency` holds **five simultaneous buffers** (fluid,
  chemical, 1 item slot, energy, heat — `InventoryFrequency.java:138-142`).
- Side configs are independent per TransmissionType
  (`MekanismBlockTypes.java:505`, `TileComponentConfig.java:63-68`); item
  eject is the tile ejector, energy/fluid/chemical eject is frequency-side
  once per tick, up to the whole buffer (`InventoryFrequency.java:281`,
  255-258). Per-tab auto-eject (`ejecting`) defaults **OFF**
  (`ConfigInfo.java:38-43`) — one-time GUI setup.
- Side config + ejector + frequency + redstone mode all ride the item
  (`mekanism:side_config` etc., `quantum_entangloporter.json:20-28`;
  collect/apply `TileComponentConfig.java:282-284`,
  `TileEntityMekanism.java:831-833`). ⚠ Side config is stored in
  **RelativeSide (relative to FACING)** — re-placement must reproduce
  orientation (see C1).
- Throughput: energy buffer 256 MJ with **no rate cap**
  (`GeneralConfig.java:259-261`, `EnergyCubeTier.java:16`,
  `BasicEnergyContainer.java:27-29`; pack = defaults `general.toml:166-174`)
  ⇒ up to ~102.4M FE/t — never the bottleneck. Items: one stack per
  **11 ticks** (skeptic-corrected: `TileComponentEjector.java:90,150-154,
  329`) ≈ 116 items/s for 64-stackables — ample vs 0.25 blocks/s mining.
- A QE in a non-ticking chunk neither sends nor receives
  (`InventoryFrequency.java:244-247`) — ties to D1. QE supports an ANCHOR
  upgrade (`MekanismBlockTypes.java:503`) — optional belt-and-braces
  chunkloading while placed.

## C. CC:Tweaked turtle mechanics (verified @ v1.21.1-1.117.1)

### C1. turtle.place() preserves components; placement geometry [MIXED — one FALSE part]

- Components survive [SOURCE]: place dispatches the **actual inventory
  ItemStack by reference** through the standard path —
  `TurtleAPI.java:228-229` → `TurtlePlaceCommand.java:51-52` (real stack),
  fake-player inventory load/unload by reference (`TurtlePlayer.java:
  150-151,165-166`), `stack.useOn(new UseOnContext(...))`
  (`TurtlePlaceCommand.java:223`) with NeoForge events first
  (`PlatformHelperImpl.java:228-230`). On failure the unchanged stack
  returns to the turtle; Lua gets `false, message` (`TurtleBrain.java:
  620-621`). Mekanism restore hook: A2. The vanilla BlockItem.place hop →
  **[IN-GAME] S4/S9**.
- **[FALSE] "the sled places the miner in front of itself":**
  `turtle.place()`/`placeDown()` can **never** place the Digital Miner —
  all four deploy branches put the target cell adjacent to the turtle
  (`TurtlePlaceCommand.java:89-95`), the turtle then occupies one of the
  17 bounding cells, and `ItemBlockTooltip.placeBlock` requires **all 17**
  bounding positions replaceable (`ItemBlockTooltip.java:72-80`,
  `WorldUtils.java:808-815`). **Only `turtle.placeUp()`** (turtle directly
  below the future main block, 3×3×2 air above) can succeed. Caught by the
  adversarial pass; converges with A2's independent derivation.
- Facing [SOURCE]: fake-player yaw per deploy branch (`TurtlePlaceCommand
  .java:164-166`, `TurtlePlayer.java:121-124`, `DirectionUtil.java:32-36`);
  Mekanism FACING from player yaw/pitch, toward the placer
  (`AttributeStateFacing.java:110-128`; miner horizontal-only
  `Machine.java:27`, QE 6-way `MekanismBlockTypes.java:504`).
  Consequences: **placeUp'd miner faces the horizontal opposite of the
  turtle's facing** (yaw = turtle facing for vertical deploys); **a
  placeUp'd or floor-branch QE faces UP** (pitch ≥ 65 → UP), a
  forward-with-backstop QE faces the turtle. Since QE side config is
  facing-relative (B2), the sled must place QEs **forward with a
  deterministic backstop** (the miner structure itself qualifies).
  Confirm facings: **S8/S9**.

### C2. turtle.dig() loot parity [MIXED]

- Dig = `turtlePlayer.player().gameMode.destroyBlock(pos)` — the standard
  survival path (`TurtleTool.java:288-289`), drops captured in a ±2 AABB
  and inserted from the selected slot (`TurtleUtil.java:59-66`,
  `DropConsumer.java:40-46,61-64`). CC's own gametest proves loot+tool
  parity (`Turtle_Test.kt:318-322`). Vanilla destroyBlock internals not
  vendored → **[IN-GAME] S9**.
- **Full inventory does NOT fail the dig** — overflow drops on the ground
  behind the turtle, command still succeeds: the sled must keep guaranteed
  free slots or it can silently drop a configured machine on the floor.
- Tool: shipped diamond-pickaxe upgrade has **no `breakable` tag**
  (`diamond_pickaxe.json`) ⇒ digs anything breakable instantly (no mining
  time, `TurtleTool.java:139-146`); machines are hardness 3.5, any pickaxe
  tier harvests with drops (`MekanismTagProvider.java:729-779`). Skeptic
  correction: a **sword** turtle *refuses* (sword has a breakable tag of
  wool/cobweb only) — it's an **axe** that would break-and-void. There is
  **no `turtle_disabled_actions` config** in 1.117.1 (claim part FALSE;
  `ConfigSpec.java:315-335`).
- Events fired during dig: `getDestroyProgress` gate + `BlockEvent.
  BreakEvent` — exactly the hooks Mekanism security (A3) and FTB Chunks
  protection (D1) use.

### C3. Peripheral attach timing [SOURCE]

- Attach is **exactly one turtle tick after placement**, never same-tick:
  capability-cache invalidation only sets a dirty bit
  (`AbstractComputerBlockEntity.java:60,296-298`), re-query happens at the
  START of the next serverTick (:102-104), and `super.serverTick()` (the
  refresh) runs **before** `brain.update()` (which executes the queued
  place) — `TurtleBlockEntity.java:104-106`.
- On change, **`"peripheral"` / `"peripheral_detach"` events** fire with
  the side name (`Environment.java:135-137`, `PeripheralAPI.java:209-225`).
  Wait on the event, not a sleep. Too-early `peripheral.wrap` returns
  nil; a stale wrapped handle **silently returns nil from every method**
  (no error — `peripheral.lua:255-268,284-287`) and transparently rebinds
  after re-place; re-wrap on each `peripheral` event and nil-check every
  return.
- Mekanism's peripheral has no loaded/first-tick gating
  (`CCCapabilityHelper.java:24-26`); miner bounding blocks are created
  synchronously inside setPlacedBy (`BlockMekanism.java:151-153`), so the
  port proxy resolves by the N+1 refresh.
- Forced rescan primitive: a turn (`setDirection`) runs
  `updateInputsImmediately()` — synchronous full 6-side rescan
  (`TurtleBrain.java:276-277`, `TurtleBlockEntity.java:212-213`).
- Verify-with-retry pattern (each element source-grounded): after
  `place()` returns true, pull `peripheral` events filtered by side with a
  ~20-tick timeout; on timeout do turnLeft+turnRight (forced rescan); if
  still absent, `turtle.detect()` distinguishes "place failed" from
  "wrong/non-port face". Timing confirm: **S5**.

### C4. Chunk behavior + fuel [MIXED]

- **CC:T never chunk-loads** [SOURCE-by-absence]: zero ticket-creating code
  (greps over the tree; only passive unload listeners,
  `CommonHooks.java:110-121`, `TickScheduler.java:43-46`); no config
  option (`ConfigSpec.java`, pack toml).
- Move into unloaded chunk: **fails cleanly** — `turtle.forward()` returns
  `false, "Cannot leave loaded world"` (`TurtleMoveCommand.java:84`), no
  fuel consumed (consume only after successful teleport, :55-61). Cheap
  sentinel for "my chunkloader lapsed": detect, hold, retry.
- Own chunk unloads: **the computer is closed, not paused** — BE removal
  → `unload()` → `ServerComputer.close()` → Lua machine destroyed
  (`AbstractComputerBlockEntity.java:71-83`, `Computer.java:113-115`,
  `ComputerExecutor.java:430-431`); a merely non-ticking chunk kills it
  within ~100 ticks via the registry timeout (`ServerComputer.java:
  128-134`). On reload it **boots fresh and runs startup.lua** (NBT "On"
  → turnOn, :109-111,174; `shell.lua:742-745`). The sled's whole recovery
  model is therefore disk-journal + startup.lua, as designed.
- Moves are **atomic within one main-thread tick** (`TurtleBrain.java:
  260-278,592-597`) — a graceful save sees old or new position, never
  half-done. (Hard-kill mid-save chunk-vs-filesystem skew is real and
  bidirectional → C5 journal semantics; optional test S11.)
- Fuel [SOURCE formula, IN-GAME constants]: limits **20,000 / 100,000**
  (normal/advanced; `Config.java:28-30` = pack `computercraft-server.toml:
  200-210`); `fuel = burnTime/20` (`FurnaceRefuelHandler.java:36-38`, the
  only registered handler, `ModRegistry.java:610`; burn-time constants not
  vendored → S3): coal 80, **coal block 800**, lava bucket 1000 expected.
  1 fuel/move, **turns free** (`TurtleMoveCommand.java:61` sole consume
  site, `TurtleTurnCommand.java:20-31`). Overfill is clamped & wasted
  (`TurtleBrain.java:365-366`) but `refuel(n)` self-caps consumption
  (`FurnaceRefuelHandler.java:21-23`).
- **Napkin corrected**: 64-block hop = 64 fuel ⇒ normal tank 312 hops,
  advanced 1,562 hops; 25/125 coal blocks fill normal/advanced; 64 coal
  blocks = 800 hops (carried as items, refueled incrementally) — the old
  "≈700" was 14% low *and* ignored that it can't fit a normal tank.

### C5. GPS is per-dimension; dead reckoning suffices for v1 [SOURCE]

- Cross-dimension messages arrive **without the distance argument** (nil;
  `ModemPeripheral.java:117-135`) and both gps.locate and the gps host
  filter on `and nDistance` (`gps.lua` api :134, program :80) — overworld
  GPS can never serve the mining dimension (normal-modem cross-dim packets
  aren't even delivered, `WirelessNetwork.java:52-54`).
- Ender modem = interdimensional + `Integer.MAX_VALUE` range
  (`WirelessModemPeripheral.java:26-33`); in-dimension delivery always
  carries true distance regardless of receiver modem
  (`WirelessNetwork.java:43-55`) ⇒ **4 ender-modem hosts (non-coplanar,
  pairwise ≥2 apart) in one force-loaded chunk give whole-dimension GPS**,
  turtle needs only a normal wireless modem (pack ranges 64/384,
  `computercraft-server.toml:170-182`). Trilateration: ≥3 distinct fixes,
  collinear rejected, 4th resolves the mirror pair (`gps.lua:27,141-161,
  187-192`).
- Dead reckoning for v1 is **sound with one caveat**: command queue is
  in-memory only (`TurtleBrain.java:70,398-404` — never serialized), so
  after any restart the position is ambiguous between exactly **two cells
  one block apart** along the journaled heading (queued-but-dropped vs
  executed; plus crash skew where the real-FS journal is ahead of the
  chunk save — **both directions possible**). One landmark
  `turtle.inspect()` of a block guaranteed adjacent to exactly one
  candidate resolves it. v1: journaled dead reckoning + landmark probe;
  GPS constellation later as an oracle, not a dependency. Skew demo
  (optional): **S11**.
- **Corollary, verified at executive review (2026-06-11): rednet
  telemetry DOES cross dimensions when either endpoint is an ender
  modem.** Cross-level delivery happens iff the transmit was
  interdimensional OR the receiver is (`WirelessNetwork.java:51-54`);
  such messages arrive via `receiveDifferentDimension` **without** the
  distance argument (`ModemPeripheral.java:129-135`); and rednet's
  daemon reads only modem/channel/replyChannel/message — distance is
  never used (`rednet.lua:467-481`; grep "distance" over rednet.lua = 0
  hits). Only GPS depends on distance. The mesh's existing ender-modem
  receivers therefore hear a mining-dim sled that carries a plain
  wireless modem. (The phase-1 final report's "risk 3: telemetry gap"
  was a synthesis error — GPS physics overgeneralized to rednet — and is
  retracted; the README and this C5 entry were both correct as written.)

## D. World / pack layer

### D1. FTB Chunks offline force-loading [MIXED — FALSE under defaults]

- Claiming: any dimension claimable by default (blacklist+whitelist empty,
  `FTBChunksWorldConfig.java:62-65`, `DimensionFilter.java:18-21`);
  defaults **500 claimed / 25 force-loaded** per player (:60-61,76-77);
  force-load requires the chunk be claimed first
  (`ChunkTeamDataImpl.java:216-217`).
- Tickets are registered **ticking=true** (`FTBChunksExpectedImpl.java:13`,
  controller `ForceLoading.java:26`, non-ticking purged :37-43). That a
  ticking forced ticket ⇒ ENTITY_TICKING chunk (computers run) is NeoForge
  side, not vendored → **[IN-GAME] S10 clock test**.
- **[FALSE] "force-loaded chunks stay loaded with everyone offline" under
  pack defaults**: `force_load_mode` defaults to DEFAULT
  (`ForceLoadMode.java:10`), which requires a team member with the
  `ftbchunks.chunk_load_offline` permission (`ChunkTeamDataImpl.java:
  490-494`, `FTBChunksWorldConfig.java:143-146`); without a permission
  mod the fallback returns **false**
  (`FallbackPermissionProvider.java:11-14`) and tickets are removed at
  last-member logout (`FTBChunks.java:255-258`). **Mandatory server-side
  change: set `force_load_mode: "always"`** (or grant the permission via a
  permission mod) — checklist **S2**. With it, offline loading survives
  restarts (re-forced at level load, `ClaimedChunkManagerImpl.java:
  100-102`) and nothing expires under defaults
  (`ClaimExpirationManager.java:41-44` + forceLoadExpiryTime defaults 0).
- Claim protection vs the turtle: fake players are policy-checked
  (`ClaimedChunkManagerImpl.java:207-209`); defaults
  `allow_fake_players_by_id=true`, `block_edit_mode=ALLIES`
  (`FTBChunksWorldConfig.java:92-103`), members count as allies
  (`ChunkTeamDataImpl.java:281,313-314`) ⇒ **an owner-placed turtle may
  dig/place inside the owner's claim by default**; an unowned
  `[ComputerCraft]`-profile turtle is blocked (add to
  `allow_named_fake_players` if ever needed). Whether turtle dig/place
  fires the wrapped events at all is the same non-vendored NeoForge layer
  → folded into S7.

### D2. Copper Y-band in the mining dimension [MIXED, wiki-grade allowed]

- The pack's mining dim is **`allthemodium:mining`** (ftbquests
  `chapters/allthemodium.snbt:193`), Allthemodium 3.0.1
  (`CHANGELOG-ATM10-6.6-7.0.md:96`); the pack ships no worldgen datapack
  (datapacks/ holds one empty zip). From the AllTheModium repo @ the last
  3.0.1 commit (`40f500e`; copper JSONs unchanged since 2022): superflat
  layers bedrock/end_stone(-63..0)/netherrack(1..64)/deepslate(65..128)/
  stone(129..247)/dirt/grass(252), height -64..319; copper feature
  16/chunk, trapezoid -16..312 (triangular, peak Y≈148), replacing only
  stone/deepslate ore-replaceables ⇒ **effective band Y 65–247, densest
  ~148** (deepslate variant below 129, regular above). Corroborated by the
  ATM guides oredistro page (wiki-grade).
- **The vanilla-overworld window (-16..112, peak 48) from the design
  conversation is wrong here** — it would capture ~24% of the band, all
  deepslate variant. Miner config: **minY 65, maxY 247**, filter must
  match **both** `copper_ore` and `deepslate_copper_ore` (use a tag
  filter, e.g. `c:ores/copper`). The surface (Y252) sits above the whole
  band — sled travel never intersects veins. Calibration: **S10b**.

## E. Telemetry integration

### E1. `sled` envelope schema — design, see docs/SLED-DESIGN.md §7

(Constrained by E2's verified wall/historian behavior: flat number/string
fields only — booleans and nested tables are invisible on the generic card
(`fluxwall.lua:193-196`); keys render alphabetically and truncate to the
per-source band (:285,295-297); numbers are fmt()-abbreviated (:199-200);
source name must not be `alerts` (`historian.lua:237`).)

### E2. Historian "stuck" rule [SOURCE]

- Current engine: exactly two rule types — `dropPct` (numeric, exact
  source, `historian.lua:174-200`) and `silentFor` (lastSeen age,
  wildcard, :202-216, 1 s tick :310-313). A stuck-but-broadcasting sled
  refreshes lastSeen every envelope (:243-244) — **neither type can
  express it**; new rule type required (claim's premise confirmed).
- The ring already stores the **full data table** per sample
  (`{t, v, d = envelope.data}`, :253-254) — string-state history is
  visible; **no storage change needed**. Smallest extension (4 touch
  points, design only): rule `{ source="sled1", key="state",
  equals="RELOCATE", forSeconds=900 }`; new `checkStuckRules()` scanning
  the ring backwards for the contiguous trailing run, called from the 1 s
  tick branch; cooldown keyed `ruleIndex..":"..source` (today's `fired`
  is per-rule only, :121); guard the ingest v-extraction (:246-249) with
  `not rule.equals` so the string state never lands in `v`.
- Constraint: ring spans cadence×360 s ⇒ stuck detection at 900 s needs
  cadence ≥2.5 s (sled cadence 5 s ⇒ 30 min span, comfortable).
- Skeptic nuances: a sled dead-from-boot (never one envelope) never enters
  `sources` — the silence rule covers it only after first contact; silence
  alerts re-fire per outage (no COOLDOWN).
- Test pattern to mirror: `tests/run_tests.lua:607-620` (silence rule;
  simulated clock makes 900 s tests instant, `cc_env.lua:628`).

# Project Sled — phase-2 claims ledger (2026-06-12)

Closed by a 12-agent workflow (one finder + one adversarial skeptic per
claim) against the same vendored pins as phase 1 (D3). Paths below are
relative to `vendor/Mekanism/src/main/java/mekanism/` unless noted.

## N1. Quantum Entangloporter CC surface [SOURCE]

- Peripheral type **`quantumEntangloporter`** —
  `.withComputerSupport("quantumEntangloporter")`,
  `common/registries/MekanismBlockTypes.java:507` (phase-2.1 addendum:
  previously implied by SLED-DESIGN §2 without a citation).
- **50 Lua methods** (+ built-in `help()`). Wiring:
  `TileEntityMekanism.getComputerMethods` binds the tile class hierarchy
  plus **every ITileComponent** via `FactoryRegistry.bindTo`
  (`common/tile/base/TileEntityMekanism.java:1653-1661`).
  TileComponentFrequency and TileComponentChunkLoader carry **no** computer
  annotations — frequency ops exist only as the tile's own methods.
- **Frequency ops, PUBLIC manager ONLY** (computers can never create,
  select, list, or re-secure PRIVATE/TRUSTED frequencies):
  `createFrequency(name)` (PUBLIC-gated; verbatim "Unable to create public
  inventory frequency with name '%s' as one already exists."),
  `setFrequency(name)` (verbatim "No public inventory frequency with name
  '%s' found."), `getFrequency()` (throws "No frequency is currently
  selected." when none), `getFrequencies()`. Frequencies convert to Lua as
  `{key, security_mode, owner}` (frequency methods live at
  `common/tile/TileEntityQuantumEntangloporter.java:161-322`; create/set
  at :280-298).
- **Side config is fully computer-drivable**: `getConfigurableTypes`,
  `getSupportedModes(type)`, `getMode(type, side)`, `setMode(type, side,
  mode)`, `incrementMode`/`decrementMode`, `canEject`, `isEjecting`,
  `setEjecting`. Enum args pass as **case-insensitive strings** matched
  against Java `name()`: TransmissionType `ITEM/FLUID/CHEMICAL/ENERGY/
  HEAT`; RelativeSide `FRONT/LEFT/RIGHT/BACK/TOP/BOTTOM`; DataType
  `NONE/INPUT/OUTPUT/INPUT_OUTPUT`. Every tab supports all four modes
  except HEAT = `{NONE, INPUT_OUTPUT}` — NONE is always seeded
  (`common/tile/component/config/ConfigInfo.java:97-107`). ⚠ These live on
  TileComponentConfig/TileComponentEjector, which **the Digital Miner does
  not have** — none of them exist on the `digitalMiner` peripheral.
- ⚠ Skeptic: `requiresPublicSecurity` on `@ComputerMethod` is **help-text
  metadata only** — enforcement is always the in-body
  `validateSecurityIsPublic()` call (`annotation-processor/.../
  ComputerHandlerBuilder.java:648-650`; no check in `CCMethodCaller`).
  `getMode`/`getSupportedModes` are flagged but ungated at runtime.
- Invalid enum strings reject through CC:Tweaked, not Mekanism (phase-2.1
  addendum): Mekanism's `CCComputerHelper.getEnum` delegates to CC's
  `IArguments.getEnum` → `LuaValues.checkEnum`, verbatim **"bad argument
  #N (unknown option X)"** (1-based index, raw value echoed) —
  `vendor/CC-Tweaked/projects/core/.../lua/LuaValues.java:161-166`,
  `common/integration/computer/computercraft/CCComputerHelper.java:21-27`,
  `CCMethodCaller.java:52-56` (rethrows the original LuaException).
- ⚠ Skeptic: `getEnergyFilledPercentage` with **no frequency returns 1.0**,
  not 0 (`api/math/MathUtils.java:119-121` divideToLevel(0,0)=1; empty
  container list `common/capabilities/holder/energy/
  QuantumEntangloporterEnergyContainerHolder.java:31-38`).
- Hand steps with no computer path: setting block security to PUBLIC,
  PRIVATE-frequency creation/selection, frequency deletion, anchor-upgrade
  installation (N5).

## N1b. Digital Miner config-setter surface [SOURCE]

- Exact Lua names: `setRadius/setMinY/setMaxY/setSilkTouch/setAutoEject/
  setAutoPull/setInverseMode*/addFilter/removeFilter` + getters
  (`getRadius/getMinY/getMaxY/getSilkTouch/getAutoEject/getAutoPull/
  getFilters/getState/getMaxRadius/...`), all on
  `common/tile/machine/TileEntityDigitalMiner.java:121-147,316-349`.
- Gates: every setter calls `validateSecurityIsPublic()` (A1 verbatim);
  `setRadius/setMinY/setMaxY/setInverseMode*/addFilter/removeFilter`
  additionally require searcher **IDLE** via
  `validateCanChangeConfiguration()` — verbatim **"Miner must be stopped
  and reset before its targeting configuration is changed."**
  `setSilkTouch/setAutoEject/setAutoPull/start/stop/reset` are
  security-gated only.
- **The CC path throws instead of clamping**: "Radius '%d' is out of range
  must be between 0 and %d. (Inclusive)" (maxRadius=32 in the pack); "Min
  Y '%d' is out of range must be between %d and %d. (Inclusive)" (bounds:
  build-min .. **current maxY**); "Max Y" likewise (current minY ..
  build-max-1). A successful set always reads back exact ⇒
  converge-by-readback is sound. **Ordering**: a fresh miner ships
  minY=0/maxY=60, so commission must `setMaxY` before `setMinY`.
- **Tag filter Lua shape**: `{type = "MINER_TAG_FILTER", tag = "c:ores/
  copper"}`; optional `enabled` (default true), `requires_replacement`
  (false), `replace_target` ("minecraft:air"). `getFilters()` returns a
  1-based list with exactly those five keys; tag is lowercased on decode
  (`common/integration/computer/SpecialConverters.java:79-88`). Decode
  errors verbatim: "Missing 'type' element", "Unknown 'type' value",
  "Invalid or missing tag specified for Tag filter". `addFilter` returns
  false on an exact duplicate; `removeFilter` removes only an
  exactly-equal filter; **no bulk filter method exists**.
- ⚠ Skeptic: `stop()` during SEARCHING interrupts the searcher and
  internally `reset()`s (→ IDLE), but `stop()` at FINISHED only clears
  `running` — **state stays FINISHED and the IDLE-gated setters stay
  locked until `reset()`** (`TileEntityDigitalMiner.java:810-835`).

## N2. Mekanism Anchor Upgrade in ATM10 [MIXED]

- Config layer: the pack ships **`allowChunkloading = true`**
  (`vendor/ATM-10-config/config/Mekanism/general.toml`) — the single
  master gate for the TICKET component
  (`common/tile/component/TileComponentChunkLoader.java:61-62`).
- Recipe removal **cannot be confirmed from the sparse checkout** (kubejs/
  is not vendored). Circumstantial: the 5.x glass→structural-glass kubejs
  rebalance touched five upgrade recipes; the anchor is the only
  **glass-using** upgrade recipe absent from that set → likely removed.
  **[IN-GAME]: JEI check.**
- What it does: max 1 per machine; QE → its own chunk; **Digital Miner →
  its own chunk + the chunk currently being mined** (NeoForge ticket
  controller `mekanism:chunk_loader`, forceTicks=false; persists across
  restarts). ⚠ Skeptic: on the miner the anchor ALSO makes `start()`
  **synchronously load/generate the entire search region** for the
  snapshot (`TileEntityDigitalMiner.java:803` →
  `common/content/miner/MinerRegionCache.java:64-67`) — gated only on the
  upgrade, NOT on allowChunkloading. Both skid machines support ANCHOR
  (`MekanismBlockTypes.java:331` miner, `:503` QE).
- Recommendation (AM-7): **don't use by default** — FTB claim+force-load
  covers the online-only posture with zero server changes. If the recipe
  turns out to exist in-game, an anchor on the miner is a legitimate
  optional upgrade that shrinks the claim footprint (it self-loads the
  scan region and the active mining chunk; see N3). If the recipe was
  deliberately removed by the pack, obtaining one anyway would be the
  cheaty part; the config key itself needs no change either way.

## N3. Miner search/mine vs unloaded chunks [SOURCE]

- The search never touches the live world from its thread: `start()`
  snapshots **chunk references** on the main thread into a
  MinerRegionCache (`TileEntityDigitalMiner.java:803`). Without an anchor,
  unloaded chunks come back null from getChunkNow (server log verbatim
  "Failed to load chunk for searcher cache: {}, {}") and are substituted
  with a void-air EmptyLevelChunk (`MinerRegionCache.java:57-104`) — every
  position in them **reads as air and is permanently skipped for that
  search**. Mid-search unloads do NOT truncate results (references are
  retained); loadedness matters at the instant of `start()`.
- The mining tick re-checks targets with `WorldUtils.getBlockStateIfLoaded`;
  a target chunk that unloaded since the search has its entries **silently
  deleted** — no retry, debug-only log, consecutive unloaded chunks drain
  in a handful of ticks, each still consuming the full tick energy first
  (`TileEntityDigitalMiner.java:484,533-548,:256-269`).
- A re-search picks up newly loaded chunks, but only via `reset()` +
  `start()` (both CC-callable, PUBLIC security).
- **Runbook consequence: a thin travel-line claim is NOT sufficient.** Per
  radius-32 station, claim + force-load the full 65×65 scan footprint —
  exactly **5×5 chunk columns** — from before `start()` until exhaustion.
  (Radius 16 ⇒ 33-wide ⇒ 3×3 chunks; see runbook for the budget math vs
  FTB's default 25 force-loaded chunks.)

## N4. getState() semantics — the executive's question [SOURCE]

- **State is real and event-driven; it cannot drift under speed
  upgrades.** Write sites: IDLE at construction
  (`common/content/miner/ThreadMinerSearch.java:39`), SEARCHING as the
  search thread's first statement (`:54`), FINISHED on exactly two
  completion events — the no-enabled-filters early-out (`:55-58`) and the
  end of the full volume scan (`:104`) — plus `reset()` swapping in a
  fresh searcher (IDLE, `TileEntityDigitalMiner.java:823-835`) and NBT
  load coercing a saved SEARCHING to FINISHED so the first tick after a
  restart re-runs the search via reset()+start() (`:871-877`, `:233-243`).
  No timer/duration math exists; upgrades only rescale delayLength and
  energy/tick (`common/util/MekanismUtils.java:311-328`).
- **CORRECTION to phase-1 A1 / design §2: the exhaustion predicate is
  `getState()=="FINISHED" and getToMine()==0` — `not isRunning()` must be
  DROPPED.** `running` is operator intent (true via start() `:806`;
  cleared only by stop() `:815`, reset() `:828`, NBT load `:868`, restart
  restore `:240`) and is **never auto-cleared on exhaustion**. Two
  hazards: (a) FINISHED (`:104`) is written before cachedToMine publishes
  (`:109-112` → `:305-310`, non-volatile) ⇒ a single poll can transiently
  read FINISHED+0 — **debounce the predicate**; (b) a filterless
  non-inverse start hits the early-out and reads FINISHED+0+running
  forever — commission must guarantee a filter before start.
- PAUSED is **dead code** in 10.7.19.85 (no assignment path exists);
  telemetry treats it as an anomaly.
- Power starvation / redstone-disable / overflow: the tick gate just calls
  setActive(false) — state stays FINISHED, isRunning() stays true,
  toMine freezes. The purpose-built probe is **`getEnergyUsage()`**
  (`:1319-1322`, returns `getActive() ? energyPerTick : 0`, flips the same
  tick the gate fails; server-side active is immediate,
  `TileEntityMekanism.java:1556-1577`): usage==0 with toMine>0 = stalled.

## N5. Programmatic upgrade installation [MIXED — finder overturned]

- Within Mekanism + CC:Tweaked the path is closed [SOURCE]: the only
  computer methods are read-only (`getInstalledUpgrades`,
  `getSupportedUpgrades`, `common/tile/component/TileComponentUpgrade.java:
  51,181`); the upgrade slots are GUI-only virtual slots, absent from the
  item capability on every face (`TileEntityDigitalMiner.java:189-211`;
  `common/inventory/container/tile/MekanismTileContainer.java:75-79`); and
  `ItemUpgrade.useOn` requires a **sneaking** player
  (`common/item/ItemUpgrade.java:55`) while CC's turtle fake player never
  sneaks ⇒ `turtle.place()` fails "Cannot place item here".
- ⚠ Skeptic overturn: **AdvancedPeripherals provides a programmatic
  path.** The Weak Automata Core (`useOnBlock({sneak=true})`) drives a
  sneaking, owner-profile fake player through the full right-click
  pipeline (`vendor/AdvancedPeripherals/.../AutomataBlockHandPlugin.java:
  82-93`, `APFakePlayer.java:143-151,241-278`) ⇒ ItemUpgrade.useOn
  installs a whole stack instantly, **no security gate**, and the miner's
  bounding blocks proxy IUpgradeTile so any face of the 3×3×2 works
  (`common/tile/TileEntityBoundingBlock.java:110-122`). Gates to confirm
  [IN-GAME]: live `enableWeakAutomataCore` (mod default true; pack repo
  doesn't override), vanilla useOn layers, FTB fake-player policy.
- Default plan stays **hand-install at commissioning** — seconds of work,
  once: upgrades persist on the dropped item as `mekanism:upgrades`
  (`TileComponentUpgrade.java:196-209`, A2) and ride every relocation. The
  automata core is an optional automation (it also competes with the
  pickaxe/modem for the turtle's two upgrade slots).

## C6. inspect() exposes blockstate properties (phase-2 addition) [SOURCE]

- `turtle.inspect*` returns `data.state` containing **every blockstate
  property** by name (CC `common/details/BlockDetails.java:15-26`, wired
  via `ModRegistry.java:629`). The miner's facing is vanilla
  `HORIZONTAL_FACING` (property name `facing`,
  `common/block/attribute/AttributeStateFacing.java:32`) ⇒
  `inspectUp().state.facing` from the park cell reads the miner's facing
  string. As shipped, boot recovery uses `inspect().name` to identify the
  park (miner main above + marker below) and derives the turtle's ACTUAL
  facing from the QE-column fingerprint (SLED-DESIGN §5) — the facing
  blockstate remains available as a reserve lane-orientation anchor
  (combined with C1, miner facing = opposite of placement heading).

## C7. Turtle API surface used by the sled (phase-2 addition) [SOURCE]

- Beyond the C1-C5 commands, the sled uses CC's core turtle inventory and
  fuel API: `detect/detectUp/detectDown` (TurtleDetectCommand),
  `select`/`getSelectedSlot`/`getItemCount`/`getItemDetail`
  (`vendor/CC-Tweaked/projects/common/.../apis/TurtleAPI.java` —
  inventory accessors), `refuel(n)` (C4: `FurnaceRefuelHandler.java:
  21-38`, self-capping; "No items to combust"/"Items not combustible"
  verbatim `TurtleRefuelCommand.java:24,27`), `suck/suckUp/suckDown`
  ("No items to take" `TurtleSuckCommand.java:55,68`), and
  `inspect/inspectUp/inspectDown` (C6). All are vanilla CC:T core API at
  the pinned tag; the harness mock implements each with the cited
  verbatim strings.

## Cross-cutting [FALSE] summary (design deltas)

1. **Two-block skid → three-block skid**: eject port and power ports are
   disjoint; miner never pulls power (A4). Skid = miner + energy-QE +
   item-QE on one inventory frequency.
2. **Forward placement of the miner is impossible** (C1): the turtle
   always sits inside the 3×3×2 bounding volume except directly below ⇒
   `placeUp()` only; lane runs with the turtle one block under the miner
   main position.
3. **Offline force-loading is off by default** (D1): without
   `force_load_mode: "always"` (or a permission mod grant) the lane
   unloads at last logout and the sled (computer killed, not paused — C4)
   freezes until someone logs in.
4. **Vanilla copper Y-window is wrong in the mining dim** (D2): use
   65–247, tag filter covering both ore variants.
5. **Miner needs `start()` after every re-place** (A4 skeptic): `running`
   doesn't ride the item — which in turn hard-requires PUBLIC security
   (A1/A3) for the computer `start()` call.
6. Minor: no `turtle_disabled_actions` config exists (C2); sword refuses
   rather than voids (axe voids); QE item eject is per-11-ticks not 10
   (B2); full-inventory digs silently drop loot on the ground (C2).
