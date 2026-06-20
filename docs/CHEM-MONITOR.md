# Chemical Production Monitor

Live, per-chemical production **balance** for the seven tracked Mekanism
chemicals, on a dedicated Advanced Monitor. Each row shows the chemical's stored
amount and its **net rate of change** (mB/t) — positive = producing faster than
consuming (surplus), negative = falling behind (a bottleneck, add producers).
Watch a chemical's rate climb from red through zero into green as you add
generation.

**Folded into the AE sensor.** The `me` computer already has an ME Bridge, so it
does double duty: `mesensor` reads the chemicals off that same bridge and
publishes them as a second telemetry source, `chem`. No second ME Bridge, no
extra sensor computer. The only new box is the dedicated wall:

- **`mesensor`** (role `me`, the AE-data computer you already run) publishes
  `me` **and** `chem`.
- **`chemwall`** (role `chemwall`, the new monitor computer) subscribes to
  `chem` and renders the dedicated wall.

Tracked (registry IDs, verified at runtime): `mekanism:oxygen`,
`mekanism:hydrogen`, `mekanism:chlorine`, `mekanism:hydrogen_chloride`,
`mekanism:sulfur_dioxide`, `mekanism:sulfur_trioxide`, `mekanism:sulfuric_acid`.
Liquids are out of scope — chemicals only.

---

## 1. ME Bridge methods used (and the quirks)

All seven chemicals live in Applied Mekanistics chemical cells on the AE
network, so the one ME Bridge reads them all. `mesensor` uses:

| method | returns | used for |
|--------|---------|----------|
| `getChemicals()` | list of `{ name="mekanism:oxygen", count=<mB>, displayName="Oxygen", … }` | **the** read — one call covers all seven (preferred over seven `getChemical` lookups) |
| `getTotalChemicalStorage()` | pooled cell capacity, **bytes** | the "CELLS NN% full" line |
| `getUsedChemicalStorage()` | pooled cell usage, **bytes** | same |

Quirks worth knowing:

- **The amount field is `count`, not `amount`** — same shape as items/fluids.
  `displayName` gives the human name ("Sulfur Dioxide"); we fall back to a
  prettified registry id if a chemical is absent from the network.
- **No 32-bit clamp here.** The AppFlux workaround elsewhere in this repo exists
  because the Forge *energy capability* (`getEnergy()`) returns a 32-bit `int`
  capped at 2,147,483,647. Chemicals are different: AE returns each amount as a
  64-bit `long` (`getLongValue()` → `count`), so millions — even billions — of
  mB pass through intact. No Block Reader / NBT walking is needed. (A test pins
  a 9 G mB chemical surviving un-clamped.)
- **`getChemicals()` returns only what's *in* the network.** A chemical with
  zero stored simply isn't in the list, so the sensor maps the result against
  the tracked list and reports a missing one as `0` (never an error).
- **A *failed* read is not the same as "all zero."** If `getChemicals()` errors
  (transient AE hiccup) or returns nil (Applied Mekanistics not loaded),
  `mesensor` skips the `chem` broadcast entirely rather than publish a screen of
  fake zeros (which would otherwise flash huge phantom deficits). Its `me`
  telemetry keeps flowing.
- **Storage totals are bytes, not mB** (`cell.getBytes()`), exactly like item
  storage. AE pools chemicals across cells, so there is no clean *per-chemical*
  fill %. We surface the **pooled** fill instead, which disambiguates a rate of
  ~0 (see below).

**The "rate ≈ 0" trap.** A rate near zero means one of two opposite things. The
monitor disambiguates with the pooled CELLS line + a `LOW` flag:

- `~0` rate **and** cells near full → producers throttled by back-pressure
  (**surplus**, good).
- `~0` rate **and** the chemical sits near empty → consumers starving it
  (**bottleneck**, bad — the row is flagged `LOW`).

The net rate is a sliding-window delta of the stored amount:
`rate = (newest − oldest) / (Δt · 20)` mB/t, over `CHEM_WINDOW` seconds
(default 10).

---

## 2. What to place and wire in-game

You already have the sensor side — it's your existing `me` computer with the ME
Bridge. The only thing to build is the wall:

**Wall computer (role `chemwall`)** — the empty one you set up:

- The computer wired to your **Advanced Monitor** array (any size — the text
  auto-scales to fill it; a 1-block monitor or a 4×3 wall both work).
- A **wireless or ender modem** on it, on the same network as the rest of the
  base, so it hears the `chem` broadcasts. No ME Bridge here.

```
   your existing AE computer                  your empty wall
 ┌──────────────────────────┐            ┌──────────────────────────┐
 │ [me computer] mesensor    │  rednet    │ [chemwall computer]      │
 │   ├─ ME Bridge ─ AE net   │ "telemetry"│   └─ Advanced Monitor(s) │
 │   ├─ reads me + chemicals │ ═════════► │   └─ ender/wireless modem│
 │   └─ ender/wireless modem │  source    └──────────────────────────┘
 └──────────────────────────┘  "chem"
```

*If you ever DO want a separate chemical bridge* (you generally won't): just run
`mesensor` on that other computer too — it is the chemical sensor now. Both ME
computers would publish, so run only one to avoid duplicate `chem` packets.

---

## 3. How to run it

**Install the wall** (the sensor side updates itself — see below):

```
wget run https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua chemwall
```

Then **update the base** so your `me` computer picks up the new chemical-reading
`mesensor` — type `update-all` in Minecraft chat, press `[u]` on the historian,
or tap `UPDATE ALL` on the console. Reboot the wall (or run `chemwall`) to start
it. Everything joins `update-all` and the console census like every other box.

**Configure:**

- *Sensor side* — the tracked chemical list and the rate window are constants at
  the top of `programs/mesensor.lua` (`TRACK` and `CHEM_WINDOW`); edit and push
  to change them.
- *Wall side* — `chemwall.conf` (one `key=value` per line) or args
  (`chemwall near=5000`):

  | key | default | meaning |
  |-----|---------|---------|
  | `source` | `chem` | mesh source to render (matches `mesensor`) |
  | `title`  | `CHEMICAL BALANCE` | header title |
  | `unit`   | `B` | amount unit — `B` (Buckets, matching the game) or `mB` |
  | `sort`   | `fixed` | row order — `fixed` (tracked order, stable) or `rate` |
  | `products` | `mekanism:sulfuric_acid,mekanism:hydrogen_chloride` | registry ids that count as **END PRODUCTS**; the rest are **FEEDSTOCK** |
  | `prodtitle` / `feedtitle` | `END PRODUCTS` / `FEEDSTOCK` | section header text |
  | `near`   | `1` | a chemical at/below this many **Buckets** is flagged `LOW` |
  | `stale`  | `10` | seconds of silence before `NO SIGNAL` |

  Rows are split into **END PRODUCTS** (what you want out — sulfuric acid,
  hydrogen chloride) and **FEEDSTOCK** (the creation chemicals). Order is
  **fixed** (the tracked order) by default so rows don't jump around as rates
  swing — important for just-in-time chemicals whose buffers cycle empty↔full.
  Set `sort=rate` to order each group by net rate instead. To change the actual
  order, edit `TRACK` in `mesensor.lua`.

  The net rate is a **least-squares slope** over `CHEM_WINDOW` seconds (20 by
  default, in `mesensor.lua`), not a raw last-minus-first — so a buffer that
  merely cycles (production keeping up with demand) reads ~0 instead of spiking.

  The base telemetry wall (`fluxwall`) does **not** show the `chem` source —
  chemicals live only on this dedicated wall.

**Verify without Minecraft** — the headless emulator runs the real `mesensor`
and `chemwall` end-to-end against a mock ME Bridge carrying all seven chemicals:

```
toolchain/lua-5.2.4/src/lua harness/chemdemo.lua   # renders the wall for 3 scenarios
toolchain/lua-5.2.4/src/lua tests/run_tests.lua    # the test suite (incl. the chem tests)
```
