# First in-game session with fluxdash

Goal: wire it up, run `scan`, bring the dashboard online, and capture the two
data points that drive the next iteration.

## Wire-up

1. Craft: 1 computer (advanced if you have it), 2 wired modems, networking
   cable, 1+ monitors (optional), ME Bridge (optional, 1 channel).
2. Wired modem on the **Flux Accessor**, cable to a wired modem on the
   computer. Right-click each modem until its ring glows red — chat prints the
   peripheral name (expect `appflux:flux_accessor_0`).
3. If using the part version (`appflux:part_flux_accessor` on a cable), same
   idea — the network name may differ; `scan` will tell you.
4. ME Bridge: place touching the AE network, and either adjacent to the
   computer or on the wired network (modem + red ring again).
5. Monitors: place touching the computer or wire them up the same way.

## Install (quickest path today)

On the computer: `edit fluxdash` → paste contents of `programs/fluxdash.lua`
(Ctrl+V) → Ctrl, then S → Ctrl, then E to exit.

## Run

```
fluxdash scan
```

- Confirm the accessor line shows `types: ..., energy_storage` and
  `methods: getEnergy, getEnergyCapacity`.
- Confirm the bridge line (if present) shows `me_bridge`.
- It saves `fluxscan.txt` — share it back with:
  `pastebin put fluxscan.txt` (paste the URL into our chat).

```
fluxdash
```

- Terminal AND monitors should all show the dashboard; `q` quits cleanly.
- Watch the FE/t rate react when your generators kick in.

## Two data points to bring back

1. **Full `fluxscan.txt` contents** (pastebin URL is perfect) — verifies the
   mocks and reveals anything else juicy on your network.
2. ~~Probe ME Bridge getCells()~~ DONE differently — the clamp is beaten:
   place a Block Reader facing the flux-cell drive and fluxdash v3 shows
   true totals (see docs/RESEARCH.md "CONFIRMED int-clamp workaround").
   Keep all flux cells in drives that have a reader facing them.

## Known behaviors (not bugs)

- `Stored: 2.15G FE` + the orange "clamped" banner = working as intended;
  the Forge energy API caps at 2,147,483,647 FE and a single 4k flux cell
  exceeds that. The real total is higher than displayed.
- Rate shows `+0` while clamped (the reading literally can't move).
- AE network section is the AE *energy buffer* in AE units (energy cells),
  not your flux cells — different number on purpose.

---

# Project Sled — manual verification session (2026-06-11)

One session, ordered to minimize walking: S1–S2 need only the Kinetic
panel; S3–S6 happen at the base; S7–S10 in the mining dimension; S10/S11
end with everyone logged out. Each test names the ledger claims it closes
(docs/RESEARCH.md "Project Sled"). Bring: 1 advanced turtle + diamond
pickaxe + wireless modem, 1 Digital Miner, 2 Quantum Entangloporters,
coal / charcoal / coal block / blaze rod / lava bucket (1 each), a few
stacks of cobblestone, an energy cube with charge.

## S1 — version pins (closes D3 residue)             [panel, 2 min]

1. Open the server's `mods/` folder listing. Confirm jar versions:
   Mekanism **10.7.19**, FTB Chunks **2101.1.14**, FTB Teams 2101.1.10,
   FTB Library 2101.1.31, CC-Tweaked 1.117.1, Advanced Peripherals
   (record: changelog says 0.7.61b, we believe 0.7.62b).
2. Any mismatch ⇒ tell Claude before phase 2; the vendored pins must move.

## S2 — FTB Chunks live config (closes D1 config gate)  [panel, 5 min]

1. Read `config/ftbchunks-world.snbt` AND `world/serverconfig/
   ftbchunks-world.snbt` (the second wins if present). Record
   `force_load_mode`, `max_force_loaded_chunks`, `max_claimed_chunks`.
2. Grep the latest server log for `Setting permissions provider` — tells
   us whether FTB Ranks/LuckPerms exists (expected: none).
3. **Action**: set `force_load_mode: "always"` in the winning file,
   restart the server. (Without this the sled lane unloads at last
   logout — D1 [FALSE]-by-default finding.)

## S3 — turtle fuel values (closes C4 burn-time residue)  [base, 5 min]

1. Place an *empty* turtle. Slot 1 coal, 2 charcoal, 3 coal block,
   4 blaze rod, 5 lava bucket.
2. `lua> for i=1,5 do turtle.select(i) local b=turtle.getFuelLevel()
   turtle.refuel(1) print(i, turtle.getFuelLevel()-b) end`
3. EXPECT exactly: `1 80, 2 80, 3 800, 4 120, 5 1000`, and an empty
   bucket left in slot 5. Any deviation ⇒ the pack overrode furnace
   fuels; report numbers (fuel = burnTime/20).

## S4 — QE component round-trip + facing (closes B1/B2/C1 vanilla hops)  [base, 15 min]

1. By hand: place QE#1, create + select a **PRIVATE** Inventory frequency
   `sledtest`; Side Config: ENERGY tab Top=Input; ITEM tab Back=Output
   with the tab's eject button ON; ENERGY tab eject ON with
   Bottom=Output; redstone mode Ignored. Place QE#2 nearby on the same
   frequency, feed it from the energy cube; confirm QE#1 outputs energy.
2. Hand-place a turtle (YOU place it — owner profile matters) facing
   QE#1. `turtle.dig()` then `sleep(2)` then `turtle.place()`.
3. EXPECT without opening any GUI: transfer resumes by itself. Then open
   the GUI: frequency still `sledtest` (Private, your name); Security
   owner = YOU (not `[ComputerCraft]`); both eject toggles still ON;
   sides as configured; redstone still Ignored. — closes B1/B2 restore +
   C1 component-apply.
4. Facing branches (C1): (a) re-place with a solid block exactly 2 ahead
   of the turtle → F3: QE faces *toward the turtle*; (b) remove that
   backstop, floor only → faces **UP**; (c) `turtle.placeUp()` under an
   open cell → faces **UP**. Record all three.
5. Repeat dig/place 4×: no degradation.

## S5 — peripheral attach timing (closes C3 latency confirm)  [base, 10 min]

1. Turtle facing an empty cell, QE in selected slot. Run:
   `local ok=turtle.place() local w0=peripheral.wrap("front")
   local t=os.startTimer(2) while true do local e,a=os.pullEvent()
   if e=="peripheral" and a=="front" then print("attached") break
   elseif e=="timer" and a==t then print("TIMEOUT") break end end
   print(tostring(w0), peripheral.getType("front"))`
2. EXPECT: `ok=true`; `w0` prints `nil` (too-early wrap is nil by
   design); `attached` within a few ticks; type
   `quantumEntangloporter`.
3. Stale handle: `q=peripheral.wrap("front")` → `turtle.dig()` →
   `q.getEnergy()` EXPECT **nil silently, no error** → re-place, wait for
   the event → `q.getEnergy()` EXPECT a number (transparent rebind).

## S6 — security matrix smoke (optional; A1/A3 are [SOURCE])  [base, 10 min]

1. Hand-place a Digital Miner, GUI → Security → **Private**. Turtle
   (yours) facing it: `peripheral.wrap("front").getRadius()` EXPECT a
   number; `.start()` EXPECT error containing *"Setter not available due
   to machine security not being public."*; `turtle.dig()` EXPECT true,
   item retains owner/mode (hover).
2. Set Public → `start()` EXPECT success. Leave both sled machines
   **PUBLIC** from here on. If you own a Security Desk: confirm its
   override toggle is OFF.

## S7 — claim + fake-player edit (closes D1 protection)  [mining dim, 10 min]

1. In the mining dimension, claim a 2×2 of chunks on the FTB map (M),
   shift-click them force-loaded.
2. Inside the claim, YOUR turtle: `turtle.place()` a cobblestone, then
   `turtle.dig()` it. EXPECT both succeed (owner-profile fake player is
   an ally by default).
3. Negative: have a dispenser or a *turtle-placed turtle* (no owner) try
   the same. EXPECT failure + "claimed area" warning. (Skip if no second
   actor handy — the positive case is the load-bearing one.)

## S8 — miner placement + port sweep (closes A1 faces, C1 placeUp)  [mining dim, 15 min]

1. Configure the miner by hand first: radius 12, minY 65, maxY 247, a
   **tag filter** `c:ores/copper`, Auto-Eject ON, silk OFF. Set Security
   Public. Charge it a little.
2. Put the turtle in a pit so the cell above it is clear with 3×3×2 air
   above that. Select the miner item:
   - `turtle.place()` (forward) EXPECT **false** ("Cannot place block
     here") — the turtle sits inside the bounding volume (C1 [FALSE]).
   - `turtle.placeUp()` EXPECT **true**; full 3×3×2 structure appears,
     main block directly above the turtle.
3. `peripheral.getType("top")` EXPECT `digitalMiner` (within ticks).
   Record the miner's FACING vs the turtle's facing at placeUp (design
   says: horizontal opposite — confirm!).
4. Port sweep: move a spare turtle against (a) UP face of top-center
   block, (b) back face of top-back-center, (c) outer faces of the two
   main-layer side blocks, (d) anything else (corner, top side faces).
   EXPECT `digitalMiner` on a–c, nil on d. Record which faces wrapped.

## S9 — miner round-trip + skid layout + energy (closes A2/A4/C1/C2 residues)  [mining dim, 30 min]

1. With S8's placed miner: note GUI config + stored energy exactly.
2. `turtle.digUp()` EXPECT: whole structure vanishes, exactly one miner
   item in the selected slot, nothing else dropped. Move 5 blocks,
   `placeUp()` again, open GUI: radius 12, Y 65/247, tag filter,
   auto-eject ON, energy within a few J of noted — closes the A2/C1
   vanilla hops.
3. Skid layout (A4 geometry): place QE-item at *main+up, 2 toward the
   miner's BACK* (the eject column, behind the top-back port); place
   QE-energy against an outer face of a main-layer side block. Configure
   per S4 conventions (frequency `sledtest`). Feed the frequency from
   the home QE + energy cube.
4. EXPECT: miner charges through the side port (energy bar fills); with
   ONLY the item-QE attached and no energy QE, EXPECT the miner stays
   dead (eject port carries no power — A4 [FALSE] confirmation).
5. Wrap the miner, `start()`. While actively mining run
   `getEnergyUsage()`. EXPECT **2756** (J/t) if the dimension is 384
   tall with Y 65–247 settings; record the number and the F3 build
   height (closes A4's [IN-GAME] height residue). Watch mined copper
   arrive in the home frequency/storage.
6. Exhaustion predicate (design §2): when it finishes, record
   `getState()`, `getToMine()`, `isRunning()` — expected
   `FINISHED, 0, false`.
7. (e) Tool-gate negative, use a junk QE not the configured one: break
   it with a diamond **axe** turtle. EXPECT block breaks, NO drop
   (voided — why the sled must never lose its pickaxe). A **sword**
   turtle EXPECT refuses ("Cannot break block with this tool").

## S10 — copper band + offline ticking (closes D2, D1 ticking)  [mining dim, 20 min + logout]

1. (b) Band calibration: miner placed at the surface, radius 32, tag
   filter: set Y 65–247 → record To-Mine count N1 (thousands). Set
   Y −60..64 → EXPECT **0**. Set Y 110–190 → EXPECT ≈ 0.5×N1. Set
   Y 248–312 → EXPECT 0. (Confirms band 65–247, peak ~148; any nonzero
   in the empty bands means another mod injects copper — report.)
2. Offline ticking (the decisive D1 residue): in a force-loaded claimed
   chunk, computer with startup:
   `while true do local f=fs.open("clock.txt","a")
   f.writeLine(os.epoch("utc")) f.close() os.sleep(5) end`
   plus a furnace mid-smelt. **Everyone logs out 15+ min**, log back in,
   read `clock.txt`. EXPECT continuous ~5 s timestamps across the whole
   window (chunks fully entity-ticking offline). A gap = sled-fatal ⇒
   report immediately.
3. Restart the server with nobody online, wait 10 min, join: EXPECT
   timestamps resume shortly after boot (tickets survive restarts).

## S11 — crash-skew demo (optional, closes C5 journal nuance)  [any, 15 min]

1. Turtle loop: append `"moving i"` → `turtle.forward()` → append
   `"moved i"` to a file. While running, **hard-kill** the server (panel
   kill, not /stop). Restart, compare the file's last line to the
   turtle's actual position.
2. EXPECT (at least sometimes): journal says `moved i` but the turtle
   sits at i−1 — the world rolled back, the file didn't. This is why
   boot reconciliation trusts landmarks over the journal's last line.

### Reporting back

For each test: number, PASS/FAIL, and the recorded values (S3 fuel
numbers, S8 facing + port faces, S9 getEnergyUsage + build height, S10
counts + clock gaps). Paste-friendly format or screenshots both fine.
