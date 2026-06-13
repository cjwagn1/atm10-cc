# Project Sled — phase-1 signoff packet

Assembled 2026-06-11 for executive review. Contents, in your priority
order: (0) corrections + the two executive calls; (1) SLED-DESIGN.md
complete; (2) the five requested RESEARCH extracts — B1, C1
original-vs-correction, the cross-dimension telemetry resolution, A1's
full method list, and the complete [FALSE] summary; (3) INGAME-CHECKLIST
S1–S11 complete. Canon lives in docs/RESEARCH.md, docs/SLED-DESIGN.md,
docs/INGAME-CHECKLIST.md — this packet inlines them so nothing depends on
a paste surviving.

---

## 0.1 The telemetry contradiction — resolved against my report, not your README

You asked for the file:line that decides it. Verified now, at tag
`v1.21.1-1.117.1`:

- `vendor/CC-Tweaked/projects/common/src/main/java/dan200/computercraft/shared/peripheral/modem/wireless/WirelessNetwork.java:51-54`
  — the receiver-in-a-different-level branch of `tryTransmit`:

  ```java
  } else {
      if (interdimensional || receiver.isInterdimensional()) {
          receiver.receiveDifferentDimension(packet);
      }
  }
  ```

  Cross-dimension packets ARE delivered whenever **either** endpoint is
  an ender modem (`interdimensional` = sender transmitted via
  `transmitInterdimensional`, i.e. sender is ender, :38-40;
  `receiver.isInterdimensional()` = receiver is ender).

- `.../modem/ModemPeripheral.java:129-135` — `receiveDifferentDimension`
  queues the `modem_message` event **without the 5th (distance)
  argument**. That is the entire cross-dimension penalty: no distance.

- `.../rom/apis/rednet.lua:467-481` — the rednet daemon reads only
  `modem, channel, reply_channel, message` from `modem_message`
  (`local event, p1, p2, p3, p4 = os.pullEventRaw()` … `local modem,
  channel, reply_channel, message = p1, p2, p3, p4`). Grep for
  "distance" across rednet.lua: **zero hits**. Rednet never cares.

- `.../rom/apis/gps.lua:134` and `.../rom/programs/gps.lua:80` — GPS, by
  contrast, gates on `and nDistance` at both ends. GPS genuinely cannot
  cross dimensions. That is what C5 proved, and C5's ledger text was
  scoped to GPS all along.

**Verdict: my final-report "risk 3" was a synthesis error** — I
overgeneralized GPS's distance physics to all telemetry when writing the
report and SLED-DESIGN §8. Your README needs no correction (it never
claimed cross-dim GPS, and its ender-modem mesh is precisely what makes
sled telemetry work). RESEARCH.md C5 was correct as written. The two
documents that were wrong — SLED-DESIGN §8 and the in-chat risk list —
are now fixed: §8 rewritten with the citations above, and a dated
corollary added to C5 in RESEARCH.md recording the retraction.

**Consequence for the sled:** a mining-dim sled with a plain wireless
modem broadcasting `"telemetry"` envelopes is heard directly by the
historian/wall through their existing ender modems. The wall card, the
silence rule, and the stuck rule come free, exactly as the original
brief hoped. No relay computer. No new infrastructure.

## 0.2 The two executive calls

**Telemetry.** Your call was explicitly conditional — "If the cross-dim
finding holds" — and it does not hold for rednet (only for GPS). With
the corrected facts, the v1 default reverts to: **direct mesh telemetry,
zero new parts** — the sled broadcasts, the ender-modem mesh hears it,
headless operation is no longer the v1 posture. Your architectural point
stands on its own merits though: HTTP is the only transport that is
truly topology-independent, and the bridge is still the away-from-game
(Discord) path — it stays on the roadmap as originally scoped
(optional), rather than being promoted to load-bearing. If you want it
load-bearing anyway (e.g. as a redundant alert path), say so and phase 2
will scope it in; otherwise phase 2 proceeds with direct mesh telemetry.

**Lane: straight for v1 — locked.** SLED-DESIGN §4 now records the
decision verbatim: single straight leg, one axis, constant heading,
smallest reconciliation table; serpentine is v2 when a lane actually
ends. Config keeps the `stations_per_leg`/`legs` fields so v2 needs no
schema break.

S2/S10 results will come back to you with the rest of the checklist
numbers; B1 and C1 citations for your smell test are in §2 below.

---

# 1. SLED-DESIGN.md (complete, as corrected)


Self-relocating Digital Miner skid for bulk copper in the ATM10 mining
dimension. **Design only — no sled code exists yet.** Every statement below
is traceable to a tagged claim in docs/RESEARCH.md ("Project Sled" section);
claim IDs are cited inline. Statements that are *choices* (not facts) are
marked **[design]**. Items awaiting the manual session reference checklist
tests S1–S11 (docs/INGAME-CHECKLIST.md).

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
  that reproduces the same facing reproduces the working config. QEs are
  configured **once by hand** at commissioning (B2: per-tab eject flags
  default off) and never again.
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
| 6–8 | reserved empty — dig overflow protection (C2: full inventory drops loot on the ground silently) |

## 2. Peripheral contract (real names only — A1, A3, C3)

Types: `digitalMiner`, `quantumEntangloporter` (A1, C3). The turtle wraps
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
| `getEnergy()` / `getMaxEnergy()` | starvation detection (Joules! FE = J/2.5, A4) | none |
| `getEnergyUsage()` | live J/t while active | none |
| `getSecurityMode()` | preflight: detects desk-override lockout (A1) | none |
| `getMinY()/getMaxY()/getRadius()` | preflight sanity vs config | none |

Exhaustion predicate **[design, confirm in S9]**:
`getState()=="FINISHED" and getToMine()==0 and not isRunning()` — FINISHED
is the searcher's terminal state (A1); toMine drains as blocks are mined.

Attach semantics baked into every verify step (C3, all [SOURCE]):
peripheral appears exactly one turtle tick after placement; wait on the
`"peripheral"` event for the side (timeout ~20 ticks), never sleep-and-hope;
a nil wrap immediately after place is *expected*; stale handles silently
return nil (never error) — re-wrap after every `peripheral` event and
nil-check every return; one turnLeft+turnRight forces a synchronous rescan
as the last retry before declaring failure.

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
| MINING → MINING (warn) | `getEnergy()==0` persistently: power starvation — home-side problem, not a sled fault; telemetry warns, sled holds | A4 (50 kJ buffer, continuous supply required) |
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
- Every chunk the lane touches must be **claimed + force-loaded in
  advance** by Carter (D1: claims are a prerequisite of force-loading;
  the turtle cannot claim). Default budget 25 force-loaded chunks (D1) —
  a 64-pitch lane crosses ~4 chunks per station; budget the lane legs
  accordingly or raise the limit server-side (S2).

`sled.conf` **[design]**:

```lua
{
  fleet   = "sled1",              -- telemetry source + uniqueness (§7)
  origin  = { x=0, y=253, z=0 },  -- absolute park cell of station 0
  heading = "east",               -- leg axis
  lateral = "north",              -- energy-QE side; also serpentine shift dir
  spacing = 64,
  stations_per_leg = 20,          -- leg length; bound of travel
  legs    = 5,                    -- lane bound; beyond ⇒ RECOVER
  fuel_low = 1000,                -- refuel threshold (≈15 hops, C4)
  fuel_reserve = 200,             -- never start a hop below this (§6)
  cadence = 5,                    -- telemetry period, s (≥2.5 required by E2)
  slots = { miner=1, qe_energy=2, qe_item=3, fuel=4, marker=5 },
}
```

Scaling = second turtle, different `origin`/`fleet` ("sled2"), own lane.
Frequencies are global (B1) — both sleds share ONE inventory frequency
**[design]**: power fans out and items merge at home for free (B2: energy
uncapped; item slot is one stack per 11 ticks shared — fine at 0.25
blocks/s/miner, A4).

## 5. Intent log + boot reconciliation

Write-ahead journal at `/sled.journal` **[design]**, plain lines (the
harness fs mock supports open/r/w/a only — HARNESS):

```
state=RELOCATE
station=12
step=TRAVEL          -- one of §5 step list
i=17                 -- step-internal counter (moves completed)
intent=MOVE 18       -- written BEFORE the action (C5: write-ahead)
```

Rewritten atomically (write temp + delete + rename is unavailable; the
mock and CC fs both make single open-"w"-write-close effectively atomic at
this size **[design, accepted risk: torn write ⇒ RECOVER]**).

RELOCATE steps, in order **[design]**:
`BREAK_QE_E → BREAK_QE_I → BREAK_MINER → TRAVEL(64) → PLACE_MINER →
VERIFY_MINER → PLACE_QE_E → PLACE_QE_I → START → VERIFY_RUN`
(machine break order puts the miner last so its peripheral remains
available for a final state check; placement order puts it first so its
bounding volume is established before QEs are placed against it — C1
backstop determinism).

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

## 6. Movement, markers, fuel

- Dead reckoning v1, **no GPS** (C5): position+heading mirrored in the
  journal; every move/turn journaled (intent before action). GPS deferred
  — if later wanted: 4 ender-modem hosts, non-coplanar, in one
  force-loaded mining-dim chunk serve the whole dimension (C5).
- **Markers**: before TRAVEL, `placeDown()` one marker block at the park
  cell **[design]**; left permanently (breadcrumb trail doubles as manual
  lane inspection). Sole consumer of the two-cell ambiguity resolution
  (§5 TRAVEL row). One stack ≈ 64 stations.
- Obstruction during travel (mining dim surface is empty, D2, but mobs/
  drift happen): `forward()` false + `detect()` true ⇒ dig (it is not a
  machine cell — lane cells are never machine cells, §1 geometry); false
  + `"Cannot leave loaded world"` ⇒ chunk-border sentinel (C4): hold,
  sleep 30 s, retry ×10, then RECOVER err="unloaded" **[design]**.
- **Fuel** (C4, all numbers source-derived; item burn values S3):
  advanced turtle, tank 100,000 = 1,562 hops. Policy: at RELOCATE start,
  if `getFuelLevel() < fuel_low` (1,000) then
  `refuel(ceil((limit−level)/800))` from the coal-block slot (`refuel(n)`
  self-caps; clamp waste ≤799, C4). Never begin TRAVEL with
  `< spacing + fuel_reserve` fuel. One stack of coal blocks in slot 4 =
  800 hops ≈ months at ~5 hops/day (§10).

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
  },
}
```

E2-verified rendering: the wall's generic card shows these as alphabetical
`key: value` rows under a "SLED1" header, truncating to the band — order:
err, fuel, hops, miner, pos, state, step, targets — the critical fields
(err/state) sort early by construction **[design]**. The historian records
it and the existing wildcard silence rule (60 s) covers a dead sled with
zero changes (E2; caveat: only after its first-ever envelope).

Alert rules (next phase, E2's smallest extension — design only):

```lua
{ source = "sled1", key = "state", equals = "RELOCATE", forSeconds = 900 },
{ source = "sled1", key = "state", equals = "RECOVER",  forSeconds = 30  },
```

plus `checkStuckRules()` on the 1 s tick, cooldown keyed
`ruleIndex..":"..source`, and the ingest guard so `equals` rules never
populate numeric `v` (all four touch points pinned in E2 with line cites).
Cadence 5 s satisfies the ring-span constraint (E2: ≥2.5 s for 900 s).

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
| place returns false | retry after 1 s ×5; inspect target; item retained (C1) | clear obstruction if non-machine block, else RECOVER err="placeblocked" | C1, A2 |
| wrap timeout after place | no `peripheral` event in 20 ticks → turn-rescan → still nil | RECOVER err="wraptimeout" (placed-but-dead is not a state we mutate past) | C3 |
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

## 11. Harness extension plan (design only — implementation next phase)

Everything below maps to verified extension points in `harness/cc_env.lua`
(HARNESS finding; line refs there).

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

---

# 2. The five requested RESEARCH extracts

## 2.1 B1 — Quantum Entangloporter frequency + fake-player owner (the pre-identified sled-killer)

**Verdict: defused.** Tag [MIXED] — every Mekanism/CC:T link [SOURCE];
two vanilla-glue hops [IN-GAME] (closed by S4). Skeptic: HOLDS, all 22
citations re-read verbatim, plus four uncited load-bearing facts
verified *in the claim's favor* (listed at the end).

What is stored, where, and who resolves it — the citation chain:

| # | file:line | quote (verbatim) | proves |
|---|-----------|------------------|--------|
| 1 | `vendor/Mekanism/src/datagen/generated/mekanism/data/mekanism/loot_table/blocks/quantum_entangloporter.json:20-30` | `"function": "minecraft:copy_components", "include": [ "mekanism:ejector", "mekanism:inventory_frequency", "mekanism:owner", "mekanism:redstone_control", "mekanism:security", "mekanism:side_config", ...` | the drop carries frequency + owner + security components |
| 2 | `vendor/Mekanism/.../lib/frequency/TileComponentFrequency.java:300-304` | `builder.set(frequencyComponent, new FrequencyAware<>((FREQ) frequencyData.selectedFrequency));` | the selected frequency is written into the item component on collect |
| 3 | `vendor/Mekanism/.../attachments/FrequencyAware.java:40-43` | `frequencyType.getIdentitySerializer().codec().optionalFieldOf(SerializationConstants.IDENTITY)...` | the persistent codec serializes ONLY the FrequencyIdentity |
| 4 | `vendor/Mekanism/.../lib/frequency/Frequency.java:190` | `public record FrequencyIdentity(Object key, SecurityMode securityMode, @Nullable UUID ownerUUID)` | exactly what persists: name + public/private/trusted + owner UUID |
| 5 | `vendor/Mekanism/.../lib/frequency/TileComponentFrequency.java:273-275` | `setFrequencyFromData(type, frequencyAware.identity().get(), frequencyAware.getOwner());` — preceded by Mekanism's own comment `//TODO - 1.21: Do we need to be using the player placing it instead of the existing owner?` | **restore passes the identity's stored owner as the acting player — never the placer** |
| 6 | `vendor/Mekanism/.../lib/frequency/TileComponentFrequency.java:180-181` | `manager = type.getManager(data, player); freq = manager.getOrCreateFrequency(data, player);` | lookup hits the ORIGINAL owner's manager regardless of who places |
| 7 | `vendor/Mekanism/.../lib/frequency/FrequencyManager.java:161-169` | `FREQ freq = frequencies.get(identity.key()); if (freq == null) { freq = frequencyType.create(identity.key(), ownerUUID, identity.securityMode());` | deleted frequency is recreated under the original owner — never re-keyed |
| 8 | `vendor/Mekanism/.../tile/TileEntityQuantumEntangloporter.java:147-149` | `if (freq != null && freq.isValid() && !freq.isRemoved()) { freq.handleEject(level.getGameTime());` | runtime transfer checks only validity — no accessor identity, ever |
| 9 | `vendor/Mekanism/.../network/to_server/frequency/PacketSetTileFrequency.java:44` | `...IBlockSecurityUtils.INSTANCE.canAccess(player, player.level(), pos, tile))` | owner identity is checked at GUI selection time only |
| 10 | `vendor/Mekanism/.../lib/frequency/TileComponentFrequency.java:206-214` | `...selectedFrequency.getSecurity() == SecurityMode.TRUSTED)` | the ONLY periodic owner re-validation is TRUSTED-exclusive (hence: never use TRUSTED) |
| 11 | `vendor/Mekanism/.../attachments/FrequencyAware.java:84-91` | `if (frequency != null && frequency.getSecurity() == SecurityMode.TRUSTED && ...` → `stack.remove(type)` | the ONLY component-strip path is TRUSTED-exclusive, and its callers (QIO/teleporter/colored-item GUIs) are unreachable from the QE block item |
| 12 | `vendor/Mekanism/.../block/BlockMekanism.java:160-162` | `if (tile instanceof ISecurityTile securityTile && securityTile.getOwnerUUID() == null && placer != null) {` | placer UUID is only the fallback; the item's stored owner wins |
| 13 | `vendor/Mekanism/.../tile/component/TileComponentSecurity.java:87-89` | `securityMode = input.getOrDefault(...SECURITY...); setOwnerUUID(input.getOrDefault(...OWNER...));` | owner + mode restored from the item before any fallback applies |
| 14 | `vendor/CC-Tweaked/projects/common/.../turtle/core/TurtlePlayer.java:45-56` | `var profile = turtle.getOwningPlayer(); var player = new TurtlePlayer(PlatformHelper.get().createFakePlayer(world, getProfile(profile)));` | **the turtle's fake player carries the turtle owner's real GameProfile** (generic `[ComputerCraft]`/`0d0c4ca0-…` only when never player-placed, :29-32) |
| 15 | `vendor/CC-Tweaked/.../turtle/blocks/TurtleBlock.java:146-148` | `turtle.setOwningPlayer(player.getGameProfile());` | the owning profile is whoever places the turtle |
| 16 | `vendor/CC-Tweaked/.../turtle/core/TurtleBrain.java:180-187` | `nbt.put("Owner", owner); owner.putLong("UpperId", ...)` | the owner profile persists in turtle NBT across saves and self-moves |
| 17 | `vendor/CC-Tweaked/.../shared/util/InventoryUtil.java:130-134` | `return ItemStack.isSameItemSameComponents(stack1, stack2);` | CC never strips/mutates components in turtle inventories; configured QEs never stack with anything |
| 18 | `vendor/Mekanism/.../lib/frequency/FrequencyManager.java:131-133` | `//Always associate the world with the over world as the frequencies are global` | frequencies are global overworld SavedData — same frequency resolves in the mining dim |
| 19 | `vendor/Mekanism/.../tile/TileEntityQuantumEntangloporter.java:167-171` | `public boolean persists(ContainerType<?, ?, ?> type) { /* don't persist ANY substance types */ return false; }` | the tile holds no contents — buffers live on the frequency and survive the break window |

Skeptic's add-ons, all verified FOR the claim: (a) nothing auto-deletes
an idle frequency (`Frequency.java:77-83` — removal is explicit-only),
so the dig-to-place gap cannot orphan it; (b) transfer resumes because
`setFrequencyFromData` calls `freq.update(tile)` which re-registers the
QE in `activeQEs` (`TileComponentFrequency.java:187`,
`InventoryFrequency.java:208-214`); (c) the component glue
(`TileEntityMekanism.java:824-833,897-903`) delegates to every tile
component; (d) one precision fix — explicit owner deletion unsets a
PRIVATE frequency within 5 ticks too (`TileComponentFrequency.java:206`),
but re-place recreates it under the original owner (row 7), so the
conclusion stands.

[IN-GAME] residue (S4): the two vanilla hops — destroyBlock passing the
block entity into the loot context, and BlockItem applying components
before `setPlacedBy` — are not in any vendored tree. Note the ordering
doesn't actually matter for ownership: row 13's `getOrDefault(...,
ownerUUID)` keeps the current owner if the item has no component, and
row 12 only assigns when owner == null, so item-owner-wins holds under
either ordering.

Design rules that fall out: frequency PRIVATE or PUBLIC, **never
TRUSTED** (rows 10-11); the sled turtle is **hand-placed by Carter**
(rows 14-16); QEs configured once by hand, then the cycle is
self-sustaining; track QEs by slot, never assume stacking (row 17).

## 2.2 C1 — what the skeptic caught, and the corrected mechanism

**The claim:** "turtle.place() places an item preserving its data
components (the configured miner)."

**What the original finder concluded (REFUTED in part):** the component
half was right, but the finder asserted "Mekanism machine items are
plain BlockItems (ItemBlockMekanism extends BlockItem, no place/useOn
override for miner or QE)" and therefore that the sled could place the
miner FORWARD, even recommending "a solid block two ahead" as a backstop
for facing control. The finder cited `MekanismBlocks.java:338` to prove
the miner's item class is `ItemBlockTooltip` — **and never opened
ItemBlockTooltip itself.**

**What the skeptic found by reading the one file the finder skipped:**

- `vendor/Mekanism/src/main/java/mekanism/common/item/block/ItemBlockTooltip.java:72-80`
  — `ItemBlockTooltip` **overrides `BlockItem.placeBlock`**:

  ```java
  public boolean placeBlock(@NotNull BlockPlaceContext context, @NotNull BlockState state) {
      AttributeHasBounding hasBounding = Attribute.get(state, AttributeHasBounding.class);
      if (hasBounding == null) { return super.placeBlock(context, state); }
      return hasBounding.handle(..., (level, pos, ctx) -> WorldUtils.isValidReplaceableBlock(level, ctx, pos))
          && super.placeBlock(context, state);
  ```

- The miner's `AttributeHasBounding` spans the 3×3×2 volume
  (`MekanismBlockTypes.java:334-348` — x∈[-1,1], y∈[0,1], z∈[-1,1] minus
  origin = 17 cells), and every one of those 17 cells must pass
  `canBeReplaced` (`WorldUtils.java:808-815`).

- **The geometric corollary the finder missed entirely:** every CC
  deploy branch places the block in the cell adjacent to the turtle
  (`TurtlePlaceCommand.java:89-95` — branches 2/3/4 click neighbors of
  the front cell, so `getClickedPos()` is still the front cell). For
  `turtle.place()` the turtle sits at horizontal offset 1, y=0 from the
  main block — inside the bounding volume. For `placeDown()` it sits at
  (0,+1,0) — also inside (the volume extends y 0..1 above main).
  A turtle is not replaceable ⇒ `placeBlock` returns false ⇒
  **`turtle.place()` and `turtle.placeDown()` can NEVER place a Digital
  Miner.** Only `turtle.placeUp()` keeps the turtle outside (at
  (0,−1,0), below the volume) — and even then all 17 cells must be air.
  The finder's recommended "backstop two ahead" sits inside the volume
  and would itself have blocked placement.

**What survived the refutation (and is canon):** component preservation
is intact — place dispatches the actual inventory ItemStack by
reference through the standard path (`TurtlePlaceCommand.java:51-52` →
fake-player inventory load/unload by reference, `TurtlePlayer.java:
150-151,165-166` → `stack.useOn(new UseOnContext(...))`,
`TurtlePlaceCommand.java:223`), and `placeBlock` fails *before any
stack mutation*, so a failed miner placement leaves the configured item
safely in the turtle. The QE is unaffected throughout — no
AttributeHasBounding (`MekanismBlockTypes.java:500-508`), so it falls
through to `super.placeBlock`. The facing analysis also survived:
placeUp'd miner faces the horizontal opposite of the turtle's facing;
placeUp'd QE faces UP (deterministic — which is all the side-config
needs).

**Why this didn't sink the ledger:** claim A2's finder independently
derived the same placeUp-only constraint from the Mekanism side
(`ItemBlockTooltip.java:72-80` cited there from the start), and its
skeptic re-verified it. Two independent paths converged; C1's refutation
made the convergence explicit. This is the catch that would have cost
three in-game debugging sessions — the design (§1, §5) now assumes
placeUp from directly below, full stop.

## 2.3 The cross-dimension telemetry claim (risk 3) — deciding lines

Resolved in §0.1 above against my report. One-line version for the
ledger margin: **GPS needs distance (`gps.lua:134`, `programs/gps.lua:
80`); cross-dim delivery exists but carries no distance
(`WirelessNetwork.java:51-54`, `ModemPeripheral.java:129-135`); rednet
never reads distance (`rednet.lua:467-481`).** Sled telemetry flows
directly to the existing ender-modem mesh; README unchanged; RESEARCH.md
C5 gained a dated corollary; SLED-DESIGN §8 rewritten.

## 2.4 A1 — the verified miner peripheral surface (mock contract, verbatim)

Peripheral type **`digitalMiner`** (`MekanismBlockTypes.java:353` →
`MekanismPeripheral.java:32-43`); wired-network name `digitalMiner_N`
(CC:T `WiredModemLocalPeripheral.java:86`). Every method below is
annotation-verified at the cited lines; Lua name = Java name unless
overridden (`ComputerHandlerBuilder.java:373`). All run as main-thread
tasks — **each call costs ≥1 server tick** (`CCMethodCaller.java:29-33`).

Built-ins (`BoundMethodHolder.java:24-28,44-45`):
`help()`, `help(methodName)`.

Inherited, `TileEntityMekanism.java:1668-1711` (+ :1024,1074,1166):
`getDirection()`, `getRedstoneMode()`, `getComparatorLevel()`,
`getEnergy()`, `getMaxEnergy()`, `getEnergyNeeded()`,
`getEnergyFilledPercentage()` — energy values in **Joules** (FE = J/2.5),
and `setRedstoneMode(mode)` [PUBLIC-gated].

Miner getters, `TileEntityDigitalMiner.java:316-349, 1233-1248,
1319-1341` (+ `getEnergyItem` via wrapper, :171-172):
`getSilkTouch()`, `getRadius()`, `getMinY()`, `getMaxY()`,
`getInverseMode()`, `getInverseModeRequiresReplacement()`,
`getInverseModeReplaceTarget()`, **`getToMine()`** (found-not-yet-mined
count), **`isRunning()`**, `getAutoEject()`, `getAutoPull()`,
**`getEnergyUsage()`** (live J/t, 0 when inactive), `getSlotCount()`,
`getItemInSlot(slot)`, **`getState()`** → `"IDLE" | "SEARCHING" |
"PAUSED" | "FINISHED"` (`ThreadMinerSearch.java:130-134`),
`getMaxRadius()` (config cap; ATM10 = 32), `getFilters()`,
`getEnergyItem()`.

Miner mutators — ALL gated on effective security == PUBLIC via
`validateSecurityIsPublic()` (`TileEntityMekanism.java:1647-1651`,
throws verbatim `"Setter not available due to machine security not being
public."`), declared `TileEntityDigitalMiner.java:1345-1470`:
`setAutoEject(bool)`, `setAutoPull(bool)`, `setSilkTouch(bool)`,
**`start()`**, **`stop()`**, **`reset()`** — and these nine additionally
require searcher state IDLE (`validateCanChangeConfiguration`,
:1388-1394, throws `"Miner must be stopped and reset…"`):
`setRadius(int)` (range-checked 0..maxRadius, :1396-1403),
`setMinY(int)`, `setMaxY(int)`, `setInverseMode(bool)`,
`setInverseModeRequiresReplacement(bool)`,
`setInverseModeReplaceTarget(item)`, `clearInverseModeReplaceTarget()`,
`addFilter(filter)`, `removeFilter(filter)`.

From components — security (`TileComponentSecurity.java:47-64,148-156`):
`getOwnerUUID()`, `getOwnerName()`, `getSecurityMode()` (returns the
EFFECTIVE mode — detects desk-override lockout). Upgrades
(`TileComponentUpgrade.java:51-52,181-183`): `getInstalledUpgrades()`,
`getSupportedUpgrades()`.

Gating facts for the mock: `requiresPublicSecurity` never *hides* a
method — binding filters only on MethodRestriction
(`ComputerMethodFactory.java:75-81`, `MethodData.java:19-20`); the
security check happens at call time. A null-owner machine is always
effectively PUBLIC (`SecurityUtils.java:168-170`); an owned machine can
be locked above PUBLIC by the owner's Security Desk override
(`SecurityUtils.java:154-166`) even when the tile says Public.
Peripheral reachable only via the main block or port faces (offset-cap
gate `TileEntityDigitalMiner.java:1147-1183`) — the sled wraps `"top"`
from directly below main.

## 2.5 The complete cross-cutting [FALSE] summary (un-mangled)

1. **Two-block skid → three-block skid.** The original design assumed
   the miner auto-ejects into an adjacent entangloporter and pulls power
   from that same block. Both halves are false: eject targets exactly
   ONE position — `mainPos.above().relative(back, 2)`, i.e. one up and
   two behind the main block, directly behind the top-back output port
   (`TileEntityDigitalMiner.java:277-286`, every 10 ticks, `doEject`
   default OFF :145) — and the miner **never pulls power**: its energy
   container is insert-only (`MinerEnergyContainer.java:23-24`,
   canExtract=notExternal) and reachable at exactly three ports — the
   main block's DOWN face plus the outer faces of the left/right
   bounding blocks at main-block height (:1167-1182, :182-183) — which
   are disjoint from the eject target, and the eject-target face carries
   items only (:1154-1164). **The third block is a second entangloporter.**
   Corrected flow — items: miner ejects every 10 ticks into the ITEM-QE
   parked at `main + up + 2·back` (its miner-facing side set ITEM
   Input) → shared frequency buffer → home QE (ITEM Output, eject ON) →
   base storage. Power: flux network → home QE (ENERGY Input) → same
   frequency → ENERGY-QE parked against a side power port (ENERGY
   Output, eject ON) → pushed into the miner's insert-only 50 kJ buffer,
   drained 2,756 J/t while running. One frequency carries both
   directions simultaneously (B2); the relocation choreography therefore
   breaks/places THREE machines per hop, QEs placed placeUp from below
   (deterministic facing-UP), miner last-broken/first-placed.
2. **Forward placement of the miner is impossible** (C1, §2.2 above):
   the turtle always occupies one of the 17 bounding cells except
   directly below ⇒ `placeUp()` only; the turtle parks one block under
   the miner main position and wraps the peripheral through `"top"`.
3. **Offline force-loading is OFF by pack default** (D1). FTB Chunks'
   `force_load_mode` defaults to `default`, which requires a team member
   holding the `ftbchunks.chunk_load_offline` permission
   (`ChunkTeamDataImpl.java:490-494`, `FTBChunksWorldConfig.java:
   143-146`); with no permission mod the fallback answers false
   (`FallbackPermissionProvider.java:11-14`) and **tickets are removed
   the moment the last team member logs out** (`FTBChunks.java:
   255-258`). Since a turtle's chunk unloading KILLS its Lua VM rather
   than pausing it (C4), the sled would freeze at every last-logout
   until someone logs back in. Fix is one server-side line —
   `force_load_mode: "always"` (checklist S2) — after which tickets
   survive restarts (`ClaimedChunkManagerImpl.java:100-102`) and nothing
   expires under defaults.
4. **The vanilla copper Y-window is wrong in the mining dimension**
   (D2): the band is Y 65–247 (deepslate variant below 129), triangular
   peak ≈ Y 148; miner config minY 65 / maxY 247 with a tag filter
   covering BOTH `copper_ore` and `deepslate_copper_ore`.
5. **`running` does not ride the item** (A4 skeptic): the sled must
   call `start()` after every re-place — which is what hard-requires
   PUBLIC security (A1/A3) and a full async re-scan per station.
6. Minor corrections: no `turtle_disabled_actions` config exists in
   CC:T 1.117.1 (C2); a sword-turtle *refuses* to dig machines (axe
   voids them) (C2); QE item eject cadence is 11 ticks, not 10 (B2);
   a dig with a full inventory still succeeds and silently drops loot
   on the ground (C2) — hence the reserved empty slots in the loadout.

---

# 3. INGAME-CHECKLIST — Project Sled session, S1–S11 (complete)

Note for S2, since Kinetic has the same override trap as the CC HTTP
rules: the key is `force_load_mode`, the value is the string `"always"`,
inside the `force_loading { }` block of **`ftbchunks-world.snbt`** — and
there are two candidate files: `<instance>/config/ftbchunks-world.snbt`
(pack-level) and `<instance>/world/serverconfig/ftbchunks-world.snbt`
(world-level). **The world/serverconfig copy wins when it exists**
(FTB-Library `ConfigManager.java:203-209` loads the override path last),
so edit the one that exists in world/serverconfig — or both. S10's clock
experiment is the go/no-go pivot: it is the only test that can prove
NeoForge honors FTB's ticking tickets with zero players online, which no
vendored source can.

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
