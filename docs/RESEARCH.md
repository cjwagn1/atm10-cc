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
