# atm10-cc — ComputerCraft dev workspace for ATM10

CC:Tweaked scripts for the All The Mods 10 (v7.0, MC 1.21.1) server, developed
and **tested headlessly before anything gets installed in-game**. Scripts run
inside a faithful emulator harness against mocked peripherals whose APIs are
verified from the actual mod sources vendored in `vendor/`.

## Layout

```
programs/        scripts ready to install in-game (fluxdash.lua)
reference/       upstream/original versions kept for comparison (untouched)
harness/         headless CC:Tweaked emulator (cc_env.lua) + demo runner
tests/           test suite; run before shipping anything to the server
vendor/          shallow clones of mod sources (ground truth for APIs)
toolchain/       Lua 5.2.4 built from source (matches CC's Cobalt semantics)
docs/            research findings + in-game checklist
```

## Dev loop

```bash
# run the full test suite (19 tests: v1 characterization + v2 contract)
toolchain/lua-5.2.4/src/lua tests/run_tests.lua

# eyeball what the dashboard renders in realistic scenarios
toolchain/lua-5.2.4/src/lua harness/demo.lua
```

The harness (`harness/cc_env.lua`) mirrors how CC:Tweaked really runs
programs: the program is a coroutine, `os.pullEventRaw` is `coroutine.yield`,
events are delivered through the same filter rules as the Java
ComputerThread (non-matching events are discarded, `terminate` always passes),
and `write`/`print`/`sleep` are lifted from the vendored `bios.lua` so word
wrapping matches in-game. Time is virtual (integer game ticks), so a
"10-second" dashboard run completes instantly and deterministically.

Mock peripherals provided: generic `energy_storage` blocks (FE capability with
the Java-int clamp), Advanced Peripherals `me_bridge` (real 0.7.62b API),
monitors, wired modems. Scenario hooks: `charAt`, `terminateAt`, `detachAt`,
`attachAt`, `snapshotAt`.

## fluxdash (v2)

Dashboard for the FE stored in AppFlux flux cells, read through the Flux
Accessor, plus AE-network stats via an ME Bridge. See header comments in
`programs/fluxdash.lua` for setup; see `docs/INGAME-CHECKLIST.md` for the
first-session walkthrough.

In-game usage:

```
fluxdash scan          -- inventory of peripherals; saves fluxscan.txt
fluxdash               -- dashboard on terminal + all attached monitors; q quits
fluxdash <peripheral>  -- pin a specific energy peripheral by name
```

Improvements over the first draft (all test-verified, see `tests/`):
renders to terminal *and* monitors simultaneously, event-driven loop
(quit key, peripheral attach/detach recovery, monitor resize), smoothed
FE/t rate over a 10s window, correct ME Bridge API (the draft called
methods that don't exist in AP 0.7.62b), scan reports generic types and
writes `fluxscan.txt` for sharing.

## Deployment (live)

This repo is the deploy source: https://github.com/cjwagn1/atm10-cc
`deploy/manifest.lua` lists every program; `installer.lua`/`update.lua`
consume it. Bootstrap any in-game computer with ONE command:

```
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua dash
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua wall
```

`dash` = the ME-side sensor computer (runs fluxdash, broadcasts over
rednet). `wall` = a monitor wall display (runs fluxwall). The installer
writes `startup.lua`, so computers auto-start after server restarts and
chunk reloads. Ship an update by pushing here + bumping the manifest
version; in-game, type `update` on any computer.

(Why GitHub raw: CC's default HTTP rules are `DENY $private, ALLOW *` —
public URLs work out of the box, LAN hosting would need a config edit.)

## fluxwall (monitor wall)

`fluxdash` broadcasts its state over rednet every refresh; `fluxwall`
listens (protocol "fluxdash") and renders a big auto-scaled layout on
every attached monitor: headline FE, capacity + percent, bar, rate, AE
stats if room, a spinner that ticks on each received packet, and a red
"NO SIGNAL (Ns)" banner if the feed goes quiet for 10s. Pair wireless or
ender modems on both computers (ender = unlimited range, cross-dimension).

## Roadmap

- [x] In-game validation (2026-06-11): scan + dashboard worked first try;
      CC:Tweaked 1.117.1 confirmed
- [x] Beat the 2.147G int clamp — DONE via AP Block Reader facing the flux
      drive: sums `appflux:fe_energy` cell components (64-bit), derives true
      capacity from cell types. Confirmed in-game on extendedae:ex_drive
      (51,847,398,108 FE read exactly). fluxdash v3 + fluxprobe ship it.
      (ME Bridge `getCells()` was a dead end — flux cells are invisible to it.)
- [ ] Monitor wall layout pass (bigger fonts/sections per monitor size)
- [ ] CraftOS-PC as a second-opinion emulator for UI-heavy programs
- [ ] Git init + GitHub remote + wget-based installer once we're happy
- [ ] Later: surface this as an MCP `get_power_status` tool (the UI-chat idea)
