# Project Sled — verified design (phase 1, 2026-06-11; amended phase 2, 2026-06-12)

Self-relocating Digital Miner skid for bulk copper in the ATM10 mining
dimension. Every statement below is traceable to a tagged claim in
docs/RESEARCH.md ("Project Sled" + "phase-2" sections); claim IDs are
cited inline. Statements that are *choices* (not facts) are marked
**[design]**. **Phase 2 (2026-06-12) shipped the implementation** —
`programs/sled.lua`, `programs/sledctl.lua`, harness extensions, the wall
sled card — under the executive amendments AM-1..7; §12 records every
amendment and §2/§4/§5/§6/§7 carry dated inline corrections. The
operator-facing procedure now lives in **docs/SLED-RUNBOOK.md** (which
supersedes the S1–S11 checklist for deployment; still-load-bearing S-tests
are folded in there as inline verification moments).

## 1. The skid (corrected geometry)

The "two-block skid" from the design conversation is dead: the miner's
single eject target and its three energy ports are disjoint positions, and
the miner never pulls power (A4 [FALSE] parts). The skid is **three
machines + the turtle**:

```
side view (lane heading →)                 top view at miner layer (Y+1)
                                                 lane heading →
Y+2   [b][b][b]→[item QE]                        [b][b][b]
Y+1   [b][M][b]                       [energyQE]→[b][M][b]
Y+0    .  [T]→ . . . 64 . . . [T']               [b][b][b]
      grass/dirt surface (mining dim Y252, D2)
```

- **M** = miner main block, bottom-center of its 3×3×2 bounding volume
  (A2). Placed by `turtle.placeUp()` from directly below — the only
  placement that can ever succeed (C1 [FALSE]). The 17 bounding cells must
  be air; the superflat mining-dim surface provides that for free (D2).
- **Item QE** sits at `M + up + 2·back-of-miner` — the miner's one eject
  target (A4). A miner placed via placeUp faces the horizontal opposite of
  the turtle's facing (C1), so **[design]** the turtle faces *along* the
  lane during placeUp, making the miner's back — and therefore the item
  QE — point *forward* along the lane.
- **Energy QE** sits against the outer face of the left (or right)
  main-layer bounding block — one of the three insert-only energy ports
  (A4). **[design]** lateral side fixed in config.
- Both QEs are placed with `placeUp()` from below ⇒ they always face UP
  (C1) — a *deterministic* orientation, which is what matters: side config
  is stored relative to facing and rides the item (B2), so a placement
  that reproduces the same facing reproduces the working config.
  **Corrected 2026-06-12 (N1/AM-3):** QE side config and eject flags are
  computer-drivable — `sled commission` converges them on every side, so
  orientation is irrelevant and the two QE items are interchangeable. The
  only remaining QE hand step is selecting a PRIVATE frequency (computers
  can only manage PUBLIC ones, N1).
- One inventory frequency carries power in and items out simultaneously
  (B2); buffers live on the global frequency, so nothing is lost while the
  QEs ride in the turtle (B1). Frequency mode **PRIVATE or PUBLIC, never
  TRUSTED** (B1). Machine security mode: **PUBLIC on both machines**, and
  the Security Desk override stays off — otherwise `start()` and every
  other setter throws (A1, A3).
- The turtle is **hand-placed by Carter** so its fake player carries his
  GameProfile (A3) — this single fact is what lets it dig/place his
  machines (A3) and operate inside his FTB claim (D1).
- Turtle loadout **[design]**: advanced turtle (100k fuel tank, C4),
  diamond **pickaxe** upgrade (mandatory: wrong tool voids the machines,
  A2/C2; a sword refuses, an axe voids — C2), wireless modem upgrade for
  telemetry (C5: normal modem suffices… see §8 range note).

Slot map **[design]** (configured QEs never stack with anything, B1 —
slots are reliable identifiers):

| slot | contents |
|------|----------|
| 1 | Digital Miner (configured) |
| 2 | energy QE (configured) |
| 3 | item QE (configured) |
| 4 | coal blocks (fuel, ~1 stack = 800 hops, C4) |
| 5 | marker blocks (breadcrumbs, §6) |
| 6–7 | reserved empty — dig overflow protection (C2: full inventory drops loot on the ground silently) |
| 8 | scratch — surface blocks dug while setting markers, lane obstructions (amended 2026-06-12) |

## 2. Peripheral contract (real names only — A1, A3, C3)

Types: `digitalMiner` (A1), `quantumEntangloporter` (N1,
MekanismBlockTypes.java:507). The turtle wraps
the miner through the main block's DOWN face — i.e. `peripheral.wrap("top")`
from the park position (A1 skeptic / A4 port map; face sweep confirmed by
S8).

Methods the sled uses (all verified A1/A3; every call costs ≥1 server
tick — A1 — so polls are batched):

| call | use | gate |
|------|-----|------|
| `getState()` | "IDLE"/"SEARCHING"/"PAUSED"/"FINISHED" | none |
| `getToMine()` | remaining found-not-mined count | none |
| `isRunning()` | running flag | none |
| `start()` | begin search+mine after every re-place (A4: `running` does not ride the item) | **PUBLIC security** |
| `reset()` | only in commissioning / manual rescue | PUBLIC |
| `getEnergy()` | Joules! FE = J/2.5 (A4) | none |
| `getEnergyUsage()` | live J/t; THE stall probe — 0 the tick the machine gate fails (N4) | none |
| `getSecurityMode()` | preflight: detects desk-override lockout (A1) | none |
| `getMinY()/getMaxY()/getRadius()` | preflight sanity vs config | none |

Exhaustion predicate — **corrected 2026-06-12 (N4)**:
`getState()=="FINISHED" and getToMine()==0`, **debounced over two
confirmation re-reads**. The phase-1 `not isRunning()` clause is WRONG and
was dropped: `running` is operator intent (set by start(), cleared only by
stop()/reset()), never auto-cleared on exhaustion (N4). The debounce
exists because FINISHED is written before cachedToMine publishes — a
single poll can transiently read FINISHED+0 on a miner with work left
(N4 hazard a). A filterless start would read FINISHED+0 forever (hazard
b) — commissioning guarantees the tag filter before any start (N1b).
Additional setter surface for commissioning: the full miner config is
CC-settable while IDLE+PUBLIC, with throw-not-clamp validation and the
setMaxY-before-setMinY ordering rule (N1b).

Attach semantics baked into every verify step (C3, all [SOURCE]):
peripheral appears exactly one turtle tick after placement; wait on the
`"peripheral"` event for the side (timeout ~20 ticks), never sleep-and-hope;
a nil wrap immediately after place is *expected*; stale handles silently
return nil (never error) — re-wrap after every `peripheral` event and
nil-check every return. The turnLeft+turnRight synchronous-rescan trick
remains true (C3) but is **deliberately not used by unattended sled code**
(amended 2026-06-12): a kill between the two turns leaves the heading
untracked, and attach is guaranteed one tick after placement anyway — the
turn-rescan stays a human rescue tool.

## 3. State machine

Three operator-visible states; RELOCATE decomposes into journaled steps
(§5). Transitions cite their justification.

```
            ┌──────────────────────────────────────────────┐
 BOOT ──────┤ reconcile journal × world (§5) — every boot   │
 (startup.lua, C4: chunk reload/restart ⇒ fresh boot)       │
            └──┬───────────────┬───────────────┬────────────┘
               v               v               v
            MINING ──────→ RELOCATE ──────→ (next MINING)
               │   exhausted     │ any step fails after
               │   (§2 predicate)│ bounded retries
               v                 v
             RECOVER ←───────────┘
   (hold position, distress on "telemetry", await human)
```

| transition | trigger | justification |
|---|---|---|
| BOOT → MINING | journal says MINING, miner peripheral verified on `top` | C3, C4 |
| BOOT → RELOCATE(step k) | journal mid-relocation; world observation matches a row of the §5 table | C4, C5 |
| BOOT → RECOVER | journal × observation matches no row | C5 |
| MINING → RELOCATE | exhaustion predicate (§2) | A1 |
| MINING → RECOVER | peripheral lost > N polls (`peripheral_detach` or persistent nil, C3); or `getSecurityMode() ~= "PUBLIC"` (A1 desk override) | C3, A1 |
| MINING → MINING (warn) | `getEnergyUsage()==0` while running with `getToMine()>0` (corrected 2026-06-12, N4: an underfed buffer idles NONZERO below the per-tick cost, so energy==0 never fires): starvation/redstone/overflow stall — home-side problem; telemetry `warn="stalled"`, sled holds | A4/N4 |
| RELOCATE → MINING | final step: `start()` succeeded, state left IDLE | A4, A1 |
| RELOCATE → RECOVER | any step exhausts retries (catalog §9) | — |
| RECOVER → (manual) | human intervention; v1 has no automatic exit **[design]** | — |

RECOVER is deliberately inert: hold position, broadcast
`state="RECOVER", err=<reason>` every cadence (§7). It performs no further
world mutation — every observed failure mode that reaches RECOVER has a
plausible cause where "keep trying" makes it worse (security lockout A3,
claim protection D1, voided machine A2).

## 4. Lane geometry + config schema

Boustrophedon over the copper band's surface (D2: band Y 65–247 under a
flat surface at Y252; the sled travels at surface+1 and never intersects
veins):

- Station pitch **64** along heading (radius 32 ⇒ 65-wide swath, 1-block
  overlap **[design]**: off-by-one safety over seam gaps).
- At `stations_per_leg`, shift 65 blocks lateral, reverse heading —
  **deferred to v2 by executive decision (2026-06-11): v1 ships a single
  straight leg** (one axis, constant heading, smallest reconciliation
  table; the mining dimension provides effectively unlimited runway).
- Claiming — **re-sized 2026-06-12 (N3)**: the miner reads unloaded scan
  chunks as void air (skipped at search, silently drained at mine), so
  the operator must claim + force-load the **full scan footprint per
  station** — radius 32 ⇒ 5×5 chunk columns; radius 16 ⇒ 3×3 — from
  before `start()` until exhaustion, not just a travel line. Against
  FTB's default budget of 25 force-loaded chunks (D1), radius 32 cannot
  cover two adjacent station footprints; the zero-config default plan is
  **radius 16 / spacing 32** (see SLED-RUNBOOK), with a
  `max_force_loaded_chunks` bump or (recipe permitting) an N2 anchor
  upgrade as the executive-approval alternatives (AM-7). The old "S2:
  force_load_mode always" requirement is **deleted** — AM-1 made offline
  operation a non-goal, and claim+force-load ticks while a player is
  online with zero config changes (D1).

`sled.conf` **[design]**:

```lua
{
  fleet   = "sled1",              -- telemetry source + uniqueness (§7)
  origin  = { x=0, y=253, z=0 },  -- absolute park cell of station 0
  heading = "east",               -- leg axis
  lateral = "north",              -- energy-QE side; also serpentine shift dir
  spacing = 64,
  stations_per_leg = 20,          -- lane bound; beyond ⇒ RECOVER "laneend"
  fuel_low = 1000,                -- refuel threshold (§6)
  fuel_reserve = 200,             -- never start a hop below this (§6)
  cadence = 5,                    -- telemetry period, s (≥2.5 required by E2)
  token = "...",                  -- sledctl courtesy lock (AM-5)
  miner = { radius = 16, min_y = 65, max_y = 247, silk = false,
            auto_eject = true, tag = "c:ores/copper" },  -- commission targets
  frequency = "sled",             -- QE frequency commission verifies (N1)
  frequency_mode = "verify",      -- or "public-auto" (creates a PUBLIC one)
  slots = { miner=1, qe_energy=2, qe_item=3, fuel=4, marker=5, scratch=8 },
}
```

(Amended 2026-06-12: the `legs` field was dropped — v1 is a single
straight leg bounded by `stations_per_leg`; code defaults follow the
runbook zero-config plan, radius 16 / spacing 32, per N3.)

Scaling = second turtle, different `origin`/`fleet` ("sled2"), own lane.
Frequencies are global (B1) — both sleds share ONE inventory frequency
**[design]**: power fans out and items merge at home for free (B2: energy
uncapped; item slot is one stack per 11 ticks shared — fine at 0.25
blocks/s/miner, A4).

## 5. Intent log + boot reconciliation

Write-ahead journal at `/sled.journal` **[design]**, plain lines (the
harness fs mock supports open/r/w/a only — HARNESS):

```
state=RELOCATE       -- MINING | RELOCATE | RECOVER
station=12
step=TRAVEL          -- one of the §5 step list (RELOCATE/RECOVER)
pos=768,253,0        -- believed position BEFORE any pending intent
heading=east
marker=minecraft:cobblestone
intent=M east        -- written BEFORE the move executes (C5 write-ahead)
err=unloaded         -- RECOVER only
mode=commission      -- commissioning runs only
```

(Format as shipped 2026-06-12; the step-internal counter from the
phase-1 sketch was dropped — steps are converge-style and redo from the
start, so only position needs sub-step precision. A backup copy is
written at every step boundary; a torn main journal falls back to it.)

Rewritten atomically (write temp + delete + rename is unavailable; the
mock and CC fs both make single open-"w"-write-close effectively atomic at
this size **[design, accepted risk: torn write ⇒ RECOVER]**).

RELOCATE steps, in order **[design — QE placement order swapped
2026-06-12]**:
`BREAK_QE_E → BREAK_QE_I → BREAK_MINER → TRAVEL(spacing) → PLACE_MINER →
VERIFY_MINER → PLACE_QE_I → PLACE_QE_E → START → VERIFY_RUN`
(machine break order puts the miner last so its peripheral remains
available for a final state check; placement order puts it first so its
bounding volume is established before QEs are placed against it — C1.
PLACE_QE_I now precedes PLACE_QE_E so that during BOTH lateral steps —
the only steps containing turns — the item QE stands at park+2·heading,
giving boot recovery an absolute directional fingerprint; see the
recovery note below).

Boot reconciliation (C4: every restart is a fresh boot; C5: an in-flight
queued command may or may not have executed — exactly two candidate cells;
crash skew can also roll the *world* back one step vs the journal, both
directions). The journal names the step; `turtle.inspect()/inspectUp()/
inspectDown()/detect()` observations select the row:

| journal step | observation (cheap probes) | resolution |
|---|---|---|
| MINING | `digitalMiner` wraps on `top` (C3) | resume MINING |
| MINING | nothing above | machines gone/unloaded mid-mine ⇒ RECOVER |
| BREAK_QE_E / BREAK_QE_I | expected QE block still present at its cell | dig not executed ⇒ redo step (dig is idempotent) |
| BREAK_QE_* | cell empty + QE item in its slot | step done ⇒ advance |
| BREAK_QE_* | cell empty + slot empty | drop lost (C2 overflow) ⇒ try `suck()`, else RECOVER |
| BREAK_MINER | bounding/main still above (`detect("up")`) | redo dig |
| BREAK_MINER | air above + miner item in slot 1 | advance to TRAVEL |
| TRAVEL, intent=MOVE k | position ∈ {k−1, k} unknowable locally (C5) | walk back along −heading counting moves until `inspectDown()` finds the station marker (§6); count = true offset; walk forward and resume |
| PLACE_MINER | `detect("up")` false | placeUp not executed ⇒ redo (place is idempotent; on false-with-item-retained C1, retry) |
| PLACE_MINER | `digitalMiner` wraps on top | advance |
| PLACE_QE_* | wrap at the QE cell from below = `quantumEntangloporter` | advance |
| START / VERIFY_RUN | `isRunning()` or `getToMine()>0` | done ⇒ MINING |
| START | `start()` throws security error (A1) | RECOVER err="security" |
| any | observation matches neither pre- nor post-state of the step | RECOVER err="reconcile" |

Dig and place are safe to redo because both are observably idempotent at
this granularity: dig of an absent block is a no-op returning false; place
into an occupied cell fails with the item retained (C1).

**Implementation note (2026-06-12)** — the shipped reconciliation
generalizes the table: every step body is converge-style (observes the
world, does only what is missing), so "redo the current step from its
start" is the universal resume action; the rows above became guards
inside the step bodies. Boot first RE-LOCALIZES, then redoes:

- TRAVEL / BREAK_QE_I / PLACE_QE_I (moves but never turns): height-
  normalize, then walk `back()` along −heading until the station marker
  is below (§6) — position re-anchored at a known cell, heading from the
  journal.
- BREAK_QE_E / PLACE_QE_E (the only steps containing turns, so the
  ACTUAL facing after a mid-turn kill is unknowable from the journal):
  a facing-agnostic probe finds the park (marker below + miner main
  above), then fingerprints the QE columns — a block 2 cells out at
  park-level+1 is the energy QE (that direction = lateral), at
  park-level+2 the item QE (that direction = heading; guaranteed present
  in both steps by the order swap). The probe resolves the turtle's true
  facing absolutely, with no GPS (C5/C6).
- BREAK_MINER / PLACE_MINER / VERIFY_MINER / START / VERIFY_RUN: no
  moves, no turns — the journal holds. (waitAttach deliberately does NOT
  use the C3 turn-rescan pair: it would create untracked-facing kill
  windows; attach is guaranteed one tick after placement anyway.)

The kill-sweep test boots the sled from a restart at every 0.5 s of the
full mining+relocation cycle and requires convergence to the same
terminal state — the AM-1 "logout is routine" contract.

## 6. Movement, markers, fuel

- Dead reckoning v1, **no GPS** (C5): position+heading mirrored in the
  journal; every move/turn journaled (intent before action). GPS deferred
  — if later wanted: 4 ender-modem hosts, non-coplanar, in one
  force-loaded mining-dim chunk serve the whole dimension (C5).
- **Markers — amended 2026-06-12**: the marker is set into the ground
  directly below the park (`digDown` the surface block into the scratch
  slot, `placeDown` the marker) at **station establishment**
  (PLACE_MINER, and by `sled start`/`sled commission` at station 0) —
  not merely before TRAVEL — so every step of the cycle has the anchor
  the §5 recovery probes re-localize on. Left permanently; the trail
  doubles as manual lane inspection. One stack ≈ 64 stations; the marker
  block must be distinguishable from the surface (cobblestone on grass).
- Obstruction during travel (mining dim surface is empty, D2, but mobs/
  drift happen): `forward()` false + `detect()` true ⇒ dig (it is not a
  machine cell — lane cells are never machine cells, §1 geometry); false
  + `"Cannot leave loaded world"` ⇒ chunk-border sentinel (C4): hold,
  sleep 30 s, retry ×10, then RECOVER err="unloaded" **[design]**.
- **Fuel** (C4; amended 2026-06-12 per AM-2): advanced turtle, tank
  100,000. Policy at TRAVEL start: when below `max(fuel_low,
  remaining + fuel_reserve)`, burn ONE item from the fuel slot, MEASURE
  the per-item value from the level delta (the pack can override burn
  values — S3), then top up with the computed count (`refuel(n)`
  self-caps, C4). Never begin a hop below `remaining + fuel_reserve`.
  No burn-value constant exists in the code. One stack of coal blocks ≈
  months (§10).

## 7. Telemetry (E1) + alerts (E2)

Envelope on the existing `"telemetry"` protocol, v1 schema (README):

```lua
{
  v = 1, source = cfg.fleet --[["sled1"]], tick = os.clock(),
  data = {
    state   = "MINING",          -- MINING | RELOCATE | RECOVER
    step    = "TRAVEL 17/64",    -- string; "" outside RELOCATE
    pos     = "-4710,253,-5280 E", -- STRING: numbers would render fmt()-abbreviated (E2)
    hops    = 12,                -- stations completed this lifetime
    fuel    = 83000,
    targets = 3122,              -- last getToMine() (0 when unplaced)
    miner   = 1,                 -- isRunning as 0/1: booleans are invisible on the wall (E2)
    err     = "unloaded",        -- present only in RECOVER
    -- added 2026-06-12 (AM-2, all MEASURED at runtime — no rate
    -- constants exist in sled.lua):
    rate    = 7.2,               -- blocks/s from getToMine() deltas over tick time
    eta     = "7m",              -- span string derived from targets/rate
    jpt     = 2756,              -- live J/t straight from getEnergyUsage()
    warn    = "power",           -- present while stalled (energy==0; N4 probe)
  },
}
```

Rendering — **superseded 2026-06-12 (AM-6)**: the wall now has a
purpose-built `sled*` card (state line, red `! reason` in RECOVER, step
progress, `targets left + rate + eta`, `hops + fuel`, sparkline) instead
of the generic key/value dump. The historian records the envelope and the
existing wildcard silence rule (60 s) covers a dead sled with zero
changes (E2; caveat: only after its first-ever envelope).

Alert rules — **shipped 2026-06-12** (E2's smallest extension, all four
touch points): `historian.lua` now carries

```lua
{ source = "sled*", key = "state", equals = "RELOCATE", forSeconds = 900 },
{ source = "sled*", key = "state", equals = "RECOVER",  forSeconds = 30  },
```

with `checkStuckRules()` on the 1 s tick, cooldown keyed
`ruleIndex..":"..source`, the ingest guard so `equals` rules never
populate numeric `v`, and trailing-`*` prefix matching on rule sources so
one rule covers the whole fleet. Cadence 5 s satisfies the ring-span
constraint (E2: ≥2.5 s for 900 s). The wall got a purpose-built `sled*`
card (state line, red reason in RECOVER, step progress, targets +
measured rate + ETA, hops + fuel, sparkline) and a `sources=` filter
(argument or fluxwall.conf) so one monitor can be dedicated to the fleet
(AM-6).

## 8. Power + range notes

- Miner draw at the verified config (r=32, Y 65–247, silk off, no
  upgrades): **1,102 FE/t continuous, ~88.2k FE/block, 0.25 blocks/s**
  (A4 + D2; absolute number confirmed by S9's `getEnergyUsage()` read).
  Silk ×12 — leave silk OFF **[design]**. The QE frequency is never the
  bottleneck (B2: effectively uncapped energy, ~116 items/s).
- Home side: feed the shared frequency from the flux network (existing
  capacity dwarfs 1,102 FE/t per sled); home QE: energy Input on the
  powered side, item Output + eject ON toward storage, **no energy output
  at home** or the frequency back-feeds (B2).
- Telemetry range — **corrected at executive review (2026-06-11)**: the
  mesh CAN hear the sled across dimensions. Cross-level packets are
  delivered whenever **either endpoint is an ender modem**
  (`WirelessNetwork.java:51-54`); they arrive without the distance
  argument (`ModemPeripheral.java:129-135`), and rednet never reads
  distance (`rednet.lua:467-481`; grep "distance" = 0 hits) — only GPS
  does (C5). The wall/historian already use ender modems (README), so a
  sled with a plain wireless modem broadcasts `"telemetry"` envelopes
  that the overworld mesh receives directly. No relay computer, no
  bridge dependency: alerts and the wall card come free, as originally
  hoped. (The earlier "risk 3 / telemetry gap" in the phase-1 final
  report was a synthesis error — GPS physics overgeneralized to rednet —
  and is hereby retracted. The HTTP bridge stays on the roadmap as the
  optional Discord/away-from-game path, not load-bearing for the sled.)

## 9. Failure-mode catalog

| failure | detection | response | claims |
|---|---|---|---|
| dig returns false ("Cannot break unbreakable block"/"protected") | return value + message | RECOVER err="protected" (security/claim regression) | A3, C2, D1 |
| dig true, machine item absent from expected slot | slot count check after dig | `suck()` retry ×3 (ground drop), else RECOVER err="lostdrop" | C2 |
| machine voided (wrong tool) | impossible by loadout (pickaxe), guarded at commissioning | — (axe/no-tool never shipped) | A2, C2 |
| place fails | occupied target cell ⇒ RECOVER err="placeblocked" immediately (the sled never digs at a machine cell — amended 2026-06-12); place-false with air above retries ×5 then RECOVER | C1, A2 |
| wrap timeout after place | no `peripheral` event within the timeout (no turn-rescan — see §2 amendment) | RECOVER err="wraptimeout" (placed-but-dead is not a state we mutate past) | C3 |
| `start()` throws | pcall error containing "security not being public" | RECOVER err="security" (desk override / mode flipped) | A1, A3 |
| fuel below reserve | checked before TRAVEL, after refuel attempt | RECOVER err="fuel" (never strand mid-hop) | C4 |
| chunk boundary | `forward()` false "Cannot leave loaded world" | hold + retry ×10 over 5 min, then RECOVER err="unloaded" | C4, D1 |
| server restart / chunk reload mid-step | startup.lua runs (C4); journal present | §5 reconciliation table | C4, C5 |
| restart mid-TRAVEL, ±1 ambiguity | journal intent vs done | marker walk-back (§6) | C5 |
| miner energy starvation | `getEnergy()==0` across polls while placed | stay MINING, telemetry warn (home-side fault) | A4, B2 |
| remote chunk not ticking (QE silent) | same symptom as starvation | same; root cause via S10 clock methodology | B2, D1 |
| sled dead (any cause) | historian silence rule 60 s; wall `NO SIGNAL` | human | E2 |
| sled stuck in RELOCATE | stuck rule 900 s | human | E2 |

## 10. Honest throughput + alternatives (from the ALT scout, wiki-grade)

Base rate 0.25 blocks/s ⇒ a ~4k-target station takes **≈4.4 h**; ~5
relocations/day ⇒ ~20k raw copper/day/sled unattended (upgrades are an
unverified multiplier — they persist on the item via `mekanism:upgrades`
(A2), but Mekanism upgrade math wasn't pinned this phase). The pack offers
two simpler "never touch copper again" routes — IF Laser Drill arrays
(stationary, infinite, modest rate) and scaling the MA farm (Botany
Pots/Pylon automation shipped; seeds hand-crafted, `secondarySeedDrops =
false`) — and the one machine that would dominate the sled (QuarryPlus
Chunk Destroyer) is **disabled in the pack** (`adv_quarry = false`). The
sled is the max-throughput-per-machine option plus the engineering value;
it is not the only path. Full comparison in the final report.

## 11. Harness extension plan — **shipped 2026-06-12**

Everything below was implemented as designed (deltas noted inline below
and in §12); the red-to-green list grew to **47 sled tests** in
`tests/run_sled_tests.lua` (the original 47 in `tests/run_tests.lua`
untouched and green). Notable deltas from the plan: `os.reboot` ends a
run as `{reason="shutdown", reboot=true}` (the pre-sled suite pins the
reason string); test 10's chunk-boundary framing became the kill-sweep
(every 0.5 s across the full cycle, per AM-1); tests for the AM
amendments were added (rate measurement + no-constants scan, commission
converge/no-op, sledctl fleet/update/token, wall sled card + sources
filter, historian stuck rules).

**New env capabilities:**

1. **`turtle` global** in `buildSandbox` (it is a global, not a
   peripheral), backed by env state initialized in `M.new`: `world`
   (pos→block voxel map), `turtlePos/Facing/Fuel/Inv` (16 slots),
   selected slot. Time-consuming actions (move/dig/place ≈0.4 s) advance
   virtual time via the existing `osT.startTimer` + yield machinery.
2. **Voxel world lifecycle**: `turtle.place*/dig*` mutate `env.world` AND
   `env.periph`, pushing `peripheral`/`peripheral_detach` **one tick
   late** to honor C3's attach semantics (tests must catch same-tick wrap
   bugs). placeUp of the miner mock checks all 17 bounding cells (C1).
3. **Mock peripherals** beside `addMeBridge`: `Env:addDigitalMiner(name,
   o)` with the A1 surface (`getToMine`, `isRunning`, `getState`,
   `start/stop/reset` throwing the verbatim security error unless
   `o.security=="PUBLIC"`, `getEnergy`, `getEnergyUsage`,
   `getSecurityMode`, `getRadius/getMinY/getMaxY`) and
   `Env:addEntangloporter(name, o)`. Item-form state: the mock carries a
   `components` table that survives env dig/place round-trips (A2).
4. **Scenario hooks**: `chunkUnloadAt(t)` (fn-hook: detach peripherals,
   then force-end the run) and `restartAt(t)` — needs a clean abort path
   in `Env:run` returning `{reason="reboot"}` (the skeptic's
   queue-flush hack proves it's reachable but the reason code must be
   real), plus splitting `os.reboot` from `os.shutdown`.
5. **Multi-boot driver fixes** (HARNESS skeptic): `opts.maxTime` is an
   absolute deadline on the persistent tick clock — either pass
   monotonically increasing values or make run() relative; add
   `opts.fromVirtualFs` so a `startup.lua` written into `env.files` can
   be executed on the next run; decide queue flush at boot (real CC drops
   the event queue).
6. The intent log uses a hand-rolled line format (§5) so **no `textutils`
   addition is required** (the fs mock's open/r/w/a surface suffices).

**Test list, red-to-green order** (each fails before its feature exists):

1. turtle mock basics: forward/turn mutate pos/facing; fuel decrements;
   `"Out of fuel"` at 0 (C4 strings verbatim).
2. world model: place into occupied cell fails item-retained; dig moves
   block to inventory; dig with full inventory drops to ground (C2).
3. attach timing: wrap immediately after place is nil; `peripheral` event
   exactly next tick; stale handle returns nil silently (C3).
4. miner mock surface + security: `start()` errors verbatim unless
   PUBLIC; getters always work (A1).
5. miner bounding volume: placeUp fails when any of 17 cells blocked;
   forward/down placement always fails (C1/A2).
6. component round-trip: dug miner item re-placed restores
   radius/filters/energy on the mock (A2).
7. journal write-ahead: snapshotAt mid-step shows intent line written
   before the world mutation (C5).
8. reconciliation, table-driven: for each §5 row, seed journal + world,
   boot the program, assert the resolved action.
9. restart mid-TRAVEL: `restartAt` between intent and move; marker
   walk-back recovers exact position (C5).
10. chunk boundary: forward fails with the C4 string; hold/retry; RECOVER
    after bound; **no fuel consumed** by failed moves.
11. lost-drop: dig succeeds, slot empty, suck() recovers / RECOVER path
    (C2).
12. telemetry: envelope schema fields + cadence; historian stuck rule
    fires at simulated 900 s; RECOVER rule at 30 s; wall renders the
    sled card with pos as string (E1/E2).
13. fuel policy: refuels at threshold by computed block count; refuses
    TRAVEL below reserve (C4).
14. end-to-end: 3 stations happy-path; placements counter, journal, and
    final position consistent; existing 47 tests untouched.

## 12. Phase-2 executive amendments (2026-06-12) — decisions of record

- **AM-1 — Offline operation is a non-goal.** The sled runs while players
  are online; it freezes at last logout (VM killed, C4) and resumes via
  boot reconciliation at next login. Consequences applied throughout this
  doc: S10 demoted to an optional appendix experiment; the
  `force_load_mode:"always"` server edit (old S2 action) deleted; chunk
  strategy needs only standard FTB claim + force-load (§4); the
  chunk-unload-mid-step reboot is the ROUTINE case — the kill-sweep test
  treats it as such.
- **AM-2 — No timing assumptions anywhere.** Base-rate constants
  (0.25 blocks/s, station duration, FE/block) are illustration only
  (§10) and do not appear in logic — a source-scan test enforces it. The
  exhaustion predicate is purely state-based (§2, corrected per N4); the
  sled measures its own rates at runtime (targets/s from getToMine()
  deltas over tick time, J/t from getEnergyUsage()) and publishes them in
  telemetry (§7); ETAs derive from measurement. Fuel-per-item is measured
  at refuel time (one item burned, delta read) rather than assumed.
  Upgrades persist on the dropped item via `mekanism:upgrades` (A2/N5),
  so they ride relocations for free.
- **AM-3 — Turtle-led commissioning, maximized.** `sled commission`
  places whatever is missing, converges the full miner config (N1b
  setters: radius/Y-window/silk/auto-eject + the `c:ores/copper` tag
  filter, read back after every set, maxY before minY) and the full QE
  config (N1: side modes + eject flags on every side — placeUp'd QEs
  face UP (C1) and RelativeSide is facing-relative (B2), so converging
  ALL sides makes orientation irrelevant and the two QE items
  interchangeable), verifies wraps, and reports READY/NOT READY with a
  named hand step for anything unreachable. Idempotent: a second run
  makes zero mutating calls. Remaining hand steps are enumerated in the
  runbook with their claim IDs (security PUBLIC, PRIVATE frequency,
  upgrade insertion per N5 — or the optional AP automata path).
- **AM-4 — Home side is AppFlux.** Flux Accessor → active puller →
  home QE energy-input side; items eject home to storage on the same
  frequency. Exact hookup + verification moments are runbook §"home
  side"; the accessor is passive, so the puller is a Mekanism universal
  cable set to Extract (Configurator) on the accessor face.
- **AM-5 — Deployment = installer role + manager console.** Manifest v9
  ships roles `sled` and `sledctl`; a turtle bootstraps with the existing
  one-liner. `sledctl` (advanced computer at base) renders the fleet
  (state/step/hops/fuel/age/err per `sled*` source) and broadcasts a
  token-gated `update` command on protocol `"sledctl"`; sleds verify the
  token (from sled.conf) and run the standard wget updater, as does the
  console itself. Rednet carries commands only; file transfer stays
  HTTP-from-GitHub. The token is a courtesy lock, not cryptography.
- **AM-6 — Dedicated base monitor.** fluxwall gained (a) the purpose-
  built `sled*` card and (b) a `sources=` filter (argument or
  fluxwall.conf first line; exact names or trailing-`*` prefixes; alert
  banners always pass) so one wall can be sled-only. Multi-sled: one
  card per fleet id comes free from the per-source card model.
- **AM-7 — Survival legitimacy protocol.** v1 as shipped needs ZERO
  server-side changes (cross-dim rednet and online force-loading are
  stock). Proposals awaiting the executive's call, each with a
  cheaty-assessment, live in the final report: (1) raising FTB
  `max_force_loaded_chunks` (enables radius 32; assessment: server-admin
  capacity setting, not cheaty); (2) the N2 anchor upgrade IF its recipe
  exists in-game (assessment: legitimate item if obtainable; crafting
  around a deliberate pack removal would be cheaty). Nothing in design
  or code assumes either.

Other phase-2 design deltas (all [design], dated 2026-06-12): RELOCATE
stops BEFORE striking the skid when the lane bound is reached (`laneend`
RECOVER leaves the machines placed for the human); `sled start` writes
the journal as its first act so a kill at any instant resumes; the
exhaustion confirmation debounce (§2); commission uses a `mode=commission`
journal so an interrupted commissioning asks to be re-run rather than
resuming blind; the conf gains `miner = {radius, min_y, max_y, silk,
auto_eject, tag}`, `frequency`, `frequency_mode` ("verify" default |
"public-auto"), and `token` fields.
