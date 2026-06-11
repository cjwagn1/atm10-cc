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
