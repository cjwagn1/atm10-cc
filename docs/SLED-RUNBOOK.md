# Project Sled — deployment runbook (one evening, start to finish)

This document replaces docs/INGAME-CHECKLIST.md for Project Sled: the
still-load-bearing S-tests are folded in as **[verify]** moments, so
verification and first deploy are the same session. Every hand step
carries the claim ID proving it cannot be automated (docs/RESEARCH.md).

Conventions: `>` is something you type on a computer/turtle. "Park" =
the cell the turtle occupies, directly under the miner's main block.

---

## 0. Shopping list

Craft/collect before heading out:

| item | qty | why |
|---|---|---|
| **Advanced** turtle | 1 | 100k fuel tank (C4) |
| Diamond pickaxe (for the turtle) | 1 | wrong tool VOIDS machines — an axe breaks-with-no-drop, only a pickaxe is safe (A2/C2) |
| Wireless modem (for the turtle) | 1 | telemetry; plain wireless reaches the base's ender-modem mesh cross-dimension (C5) |
| Digital Miner | 1 | the business end |
| Quantum Entangloporter | 3 | 2 ride the sled, 1 stays home |
| Speed/Energy upgrades (optional) | up to 8+8 | installed once by hand, they ride the miner item forever (A2/N5) |
| Coal blocks | 1 stack | 800 fuel each measured at runtime; a stack ≈ months (C4/S3) |
| Cobblestone | 1–2 stacks | station markers (must differ from the grass surface, §6) |
| Mekanism Configurator | 1 | home-side cable config (AM-4) |
| Mekanism universal cable | a few | Flux Accessor → home QE link (AM-4) |
| Advanced computer + monitor(s) | 1+ | `sledctl` console; optional dedicated sled wall |

Pack/server preconditions (already true, zero changes): cross-dimension
rednet via the base's ender modems (C5); FTB claim+force-load ticks while
any player is online (D1/AM-1). **Nothing in this runbook edits a server
config.**

## 1. At base — frequency + home QE (~15 min)

1. Place the **home QE** next to your AE/storage input and the flux
   network.
2. Open its GUI → Frequency tab → create frequency `sled` as
   **PRIVATE** → select it.
   - **HAND STEP (N1):** computers can only create/select PUBLIC
     frequencies; a PRIVATE frequency must be selected by hand, once per
     QE. It then rides the item through every break/place forever (B1).
   - (Alternative: set `frequency_mode = "public-auto"` in sled.conf and
     the turtle creates/selects a PUBLIC frequency itself — but PUBLIC
     means any player can attach to it. On a shared server, PRIVATE by
     hand is the recommended default.)
3. Home QE side config (GUI): ENERGY tab → side facing the **cable from
   the Flux Accessor** = INPUT; ITEM tab → side facing **storage** =
   OUTPUT with that tab's **eject ON**. Leave energy eject OFF at home
   (energy output at home would back-feed the frequency, B2).
4. Security tab on the home QE: anything you like (home side is not
   computer-driven).
5. **AppFlux hookup (AM-4):** the Flux Accessor is a passive port — it
   needs an active puller. Run **Mekanism universal cable** from the
   accessor to the home QE's energy-input side; right-click the cable
   connection **at the accessor** with the Configurator until it shows
   **Extract** (pull mode).
6. **[verify — home power]** Watch the home QE's GUI energy buffer fill.
   If it doesn't: the cable end at the accessor isn't set to Extract, or
   the accessor face isn't connected.

## 2. At base — the two sled QEs (~10 min)

1. Place the two travelling QEs anywhere convenient.
2. GUI each: Frequency tab → select the **same `sled` PRIVATE
   frequency**. **HAND STEP (N1)** — same reason as above.
3. Security tab each: set **PUBLIC**. **HAND STEP (A1/A3):** every
   computer mutator throws unless effective security is PUBLIC; there is
   no computer method to change security. (Mekanism security still
   protects break/place against other players — PUBLIC only opens the
   *computer* surface; your Security Desk override must stay OFF, A1.)
4. Do **not** bother with side config or eject flags — `sled commission`
   converges those from the turtle (N1/AM-3).
5. Break both QEs with a pickaxe and keep the items. Config + frequency
   ride the items (B1/B2).
   - **[verify — S4 remnant, QE round-trip]** Hover one item: tooltip
     should still show the frequency. Place it again, GUI → frequency
     still `sled` (private, you) → break it again. That's the loot-table
     round trip working.

## 3. At base — miner prep (~10 min)

1. Place the Digital Miner (by hand, anywhere).
2. GUI → Security → **PUBLIC** (HAND STEP, A1/A3 — same as the QEs).
3. (Optional, recommended) GUI → upgrade window → insert **Speed** and/or
   **Energy** upgrades. **HAND STEP (N5):** the upgrade slot is GUI-only —
   no computer method, no automation face reaches it, and a turtle's
   right-click can't sneak. Upgrades ride the miner item across every
   relocation (A2), so this is once, ever.
   - (Optional automation for later: an Advanced Peripherals **Weak
     Automata Core** can `useOnBlock({sneak=true})` upgrades in — N5
     skeptic finding, needs an in-game confirm and a free turtle
     equipment slot. Not needed for v1.)
4. Do **not** configure radius/Y/filters — the turtle does that
   (N1b/AM-3).
5. Charge it a little if convenient (not required — the QE will feed it).
6. Break it with a pickaxe; keep the item.

## 4. Mining dimension — claim the lane (~10 min)

**Sizing (N3):** the miner reads unloaded chunks as void air — skipped at
search, silently drained at mine. The **full scan footprint of each
station must be claimed AND force-loaded** from before `start()` until
that station is exhausted:

| radius | swath | footprint/station | spacing |
|---|---|---|---|
| 16 | 33 wide | **3×3 chunks** | 32 |
| 32 | 65 wide | **5×5 chunks** | 64 |

FTB Chunks defaults allow **25 force-loaded chunks** (D1). Radius 32
cannot hold two adjacent 5×5 footprints (45 chunks with overlap), so:

- **Default plan (zero server changes): radius 16, spacing 32.** Claim
  the lane corridor 3 chunks wide; force-load a window of 24 chunks
  (3 wide × 8 long ≈ 4 stations of runway). Every few days, shift-click
  the window forward on the FTB map (M) as the sled advances — claims
  stay, only the force-load marks move.
- **Comfort plan (needs your call, AM-7):** raise
  `max_force_loaded_chunks` in the server's `ftbchunks-world.snbt` to
  ~100 and run radius 32 / spacing 64 with two full 5×5 windows loaded.
  Cheaty-assessment: a server-admin capacity setting; no gameplay
  mechanic is changed — not cheaty, but it is a server edit, so it waits
  for your approval.
- (If the N2 anchor-upgrade recipe turns out to exist in-game — check
  JEI — an anchor in the miner self-loads the scan region at start() and
  the active mining chunk; the claim footprint then shrinks to the lane
  line. If the pack deliberately removed the recipe, obtaining one
  anyway would be the cheaty part. Optional either way.)

Claim + force-load now: FTB map (M) → claim the corridor → shift-click
the first window force-loaded (lightning icon).

## 5. Mining dimension — drop the sled (~15 min)

Pick the origin: a spot on the flat surface (Y253 cell over the Y252
grass), lane heading in +X or −X or ±Z — note the direction.

1. **Place the turtle YOURSELF at the origin cell** facing along the
   lane. **HAND STEP (A3):** the turtle's fake player carries the
   GameProfile of whoever placed it — your profile is what lets it dig
   and place your machines and edit inside your claim (A3/D1).
2. Equip it: pickaxe one side, wireless modem the other. Fuel it:
   `> lua` → `turtle.refuel(...)` not needed — just put coal blocks in
   slot 4; the sled refuels itself, measuring burn value at runtime
   (AM-2). Drop ~10 coal blocks in slot 4 for now.
   - **[verify — S3 remnant, fuel values]** optional spot check:
     `> lua` `turtle.select(4) local b=turtle.getFuelLevel()
     turtle.refuel(1) print(turtle.getFuelLevel()-b)` → expect 800. A
     different number is fine (the sled measures), but report it.
3. Load the slots (§1 slot map): 1 = miner item, 2+3 = the two QE items,
   4 = coal blocks, 5 = cobblestone markers. Leave 6–8 empty (C2
   overflow guard).
4. Install the software — the one wget:
   `> wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua sled`
5. Write the config: `> edit sled.conf`

   ```lua
   return {
     fleet   = "sled1",
     origin  = { x = <X>, y = <Y>, z = <Z> },  -- the turtle's cell (F3)
     heading = "east",            -- your lane direction
     lateral = "north",           -- which side the energy QE goes
     spacing = 32,                -- 2 x radius (claim plan, runbook §4)
     stations_per_leg = 20,       -- how far before it asks for more lane
     cadence = 5,
     token   = "<pick-a-fleet-password>",
     miner = { radius = 16, min_y = 65, max_y = 247,
               silk = false, auto_eject = true, tag = "c:ores/copper" },
     frequency = "sled",          -- the PRIVATE frequency you created
   }
   ```

   (Y window 65–247 is the D2 copper band; the tag covers stone and
   deepslate variants.)

## 6. Commission, then start (~10 min)

1. `> sled commission`
   The turtle places the miner above itself (the only legal placement is
   placeUp — C1), places both QEs, converges every CC-settable knob, and
   prints **READY** or **NOT READY** with reasons.
   - **[verify — S8 remnant, placement]** while it works: the 3×3×2
     structure appears with the main block directly over the turtle; the
     energy QE lands two cells to `lateral` at miner height; the item QE
     two cells along `heading`, one higher.
   - **[verify — S5/C3 remnant, attach timing]** commissioning itself is
     the attach-timing test: if wraps were broken you'd get
     `wraptimeout`-style NOT READY lines.
   - NOT READY lines name exactly what to fix (usually: security not
     PUBLIC, or the frequency hand step from §2).
2. **[verify — S9 remnant, energy path]** Open the miner GUI: its energy
   bar should be FILLING (home accessor → frequency → energy QE → side
   port). Negative check: pull the energy QE for a second — the bar
   stops — put it back. The eject column alone carries no power (A4).
3. `> sled start`
   The miner starts searching, then mining. Copper begins arriving in
   base storage through the same frequency.
4. **[verify — wall, within two minutes]** Back at base (or on the
   sledctl console): the `SLED1` card shows `MINING`, a falling
   `targets` count, a measured rate like `7.2/s`, an eta, hops `0`,
   and fuel. The historian records `telemetry/sled1.log`.

## 7. Base console + dedicated monitor (~5 min)

- Console: any advanced computer →
  `> wget run .../installer.lua sledctl`, then
  `> edit sledctl.conf` → `return { token = "<same-token>" }`.
  `sledctl` shows the fleet table; `u` pushes a fleet-wide update
  (token-gated; courtesy lock, not cryptography — AM-5).
- Dedicated sled wall (optional, AM-6): on a wall computer,
  `> edit fluxwall.conf` → first line `sources=sled*` → reboot. That
  monitor now renders only sled cards (alerts still pass).

## 8. Day-2 operations

- **Logout/restart anytime** — that's the designed-for case (AM-1). The
  computer dies with the chunk and reconciles at next login; relocations
  resume mid-step. Nothing to do.
- **Extend the lane**: as the sled advances, shift the force-load window
  (§4) and, when it reaches `stations_per_leg`, raise the bound in
  sled.conf and `> sled` (it parks in RECOVER `laneend` with the skid
  intact — extend, then reboot the turtle or push an update).
- **Update the fleet**: edit code → bump manifest version → push →
  press `u` on sledctl.
- **Refill**: coal blocks slot 4, markers slot 5, every few weeks.

## 9. Troubleshooting — RECOVER reason codes

The sled never digs/places its way out of trouble it doesn't understand
(§3): it holds position and broadcasts `err=<code>` until you intervene.
After fixing the cause: reboot the turtle (`Ctrl+R` or break/replace —
YOU must place it, A3) and it reconciles from the journal.

| err | meaning | likely fix |
|---|---|---|
| `laneend` | reached stations_per_leg; skid intact and mined out | claim+load more lane, raise `stations_per_leg`, reboot |
| `security` | start()/setter threw the A1 security error | machine GUI → Security → PUBLIC; check the Security Desk override is OFF |
| `fuel` | below `spacing + fuel_reserve` with the fuel slot empty | put coal blocks in slot 4, reboot |
| `unloaded` | "Cannot leave loaded world" ×10 — force-load window ran out (C4) | extend the force-load window on the map, reboot |
| `lostdrop` | a machine item vanished after a dig (C2 overflow) | look on the ground near the indicated station; put the item back in its slot (miner=1, QEs=2/3), reboot |
| `protected` | dig refused — claim/protection regression (D1) | check the chunk is YOUR claim; fake-player policy unchanged |
| `placeblocked` | place kept failing — something occupies the volume | clear the 3×3×2 above the park (mob, drifted block), reboot |
| `wraptimeout` | placed but the peripheral never attached (C3) | inspect by hand; if the block looks wrong, break+replace it manually, reboot |
| `minerlost` | miner peripheral vanished mid-MINING | someone/something broke the skid; rebuild via `sled commission` |
| `startfail` | start() accepted but the miner never left IDLE | check power reaches the miner (§6 step 2); then `sled start` |
| `reconcile` | journal × world matched no recovery row | the catch-all: stand at the station, look around, fix the obvious, reboot; worst case delete `sled.journal` (+ `.bak`) and recommission |
| `blocked` | a QE-path move stayed blocked (mob/drifted block) | clear the cells beside the miner, reboot |
| `travel` | a move failed repeatedly for a non-border reason | check for bedrock-level weirdness/mobs on the lane |

Wall/console signals without an err code:
- `warn=stalled` on the card: the miner is gated off (usually power
  starvation — home-side problem, §1 steps 5/6; also redstone or a full
  internal buffer). The sled holds and resumes when the gate clears.
- `NO SIGNAL` / historian silence alert: the sled's chunk isn't loaded
  (expected when nobody is online — AM-1) or the turtle is gone.
- Stuck alerts: `RELOCATE for 900s` / `RECOVER for 30s` come from the
  historian (E2) — go look.

**Mid-lane recommissioning caveat:** `sled commission` and `sled start`
anchor at `origin` from sled.conf. If you ever rebuild mid-lane, first
set `origin` to the CURRENT park's coordinates (and station numbering
restarts from 0 there).

## Appendix — optional experiments (not required for v1)

- **S10 (offline ticking clock)**: demoted by AM-1 to curiosity. If you
  ever want offline operation, run the old S10 from
  docs/INGAME-CHECKLIST.md and revisit `force_load_mode`.
- **S11 (crash-skew demo)**: the kill-sweep test exercises this in the
  harness at every 0.5s offset; the in-game demo remains a fun verify.
- **N5 automata install**: Weak Automata Core + `useOnBlock({sneak=true})`
  to install miner upgrades programmatically — confirm
  `enableWeakAutomataCore` and FTB fake-player policy in-game first.
- **N2 anchor**: if JEI shows a craftable Anchor Upgrade, one in the
  miner shrinks the claim footprint to the lane line (it self-loads the
  scan region at start() and the active mining chunk).
