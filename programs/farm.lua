--[[
farm.lua - autonomous sulfur-farm builder turtle (ATM10 / CC:Tweaked)

A turtle scans one existing Mystical Agriculture sulfur plot, normalizes it
into a blueprint, then replicates it up a chunk-aligned vertical stack -
pulling and crafting its own dirt, seeds, fertilizer, water, and fuel from the
cross-dimensional AE network. It self-tests the risky primitives before any
real plot and journals write-ahead so a chunk unload / server restart at ANY
moment resumes cleanly (the mining-dim daily event: the computer is killed,
not paused - claim C4).

Commands:
  farm capture     inspect-traversal of the reference plot -> farm.blueprint
  farm build       self-test, then build the stack (resumes if interrupted)
  farm selftest    run the startup self-tests only, build nothing
  farm             resume from the journal (what startup.lua runs)

Design + claim ledger: docs/FARM-BUILD-DESIGN.md, docs/FARM-RESEARCH.md
(Q1..Q6). Every turtle/AE behavior relied on here is cited there. No build
constants live in logic (AM-2): fuel-per-item is measured at refuel, AE need is
gated on observed stock, plot geometry comes from the scan + farm.conf.
]]

local CONF_PATH    = "farm.conf"
local BLUEPRINT    = "farm.blueprint"
local JOURNAL_PATH = "farm.journal"
local PROTOCOL     = "telemetry"
local CTL_PROTOCOL = "basectl"

local DIRV = {
  north = { x = 0, z = -1 }, south = { x = 0, z = 1 },
  east = { x = 1, z = 0 }, west = { x = -1, z = 0 },
}
local LEFTD = { north = "west", west = "south", south = "east", east = "north" }
local RIGHTD = { north = "east", east = "south", south = "west", west = "north" }

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- ------------------------------------------------------------------ config

local function loadConf()
  local f = fs.open(CONF_PATH, "r")
  if not f then return nil end
  local txt = f.readAll()
  f.close()
  local chunk = load(txt, "=farm.conf", "t", {})
  if not chunk then return nil end
  local ok, conf = pcall(chunk)
  if not ok or type(conf) ~= "table" then return nil end
  conf.slots = conf.slots or {}
  -- inventory plan: the builder pulls everything from AE, so slots are work
  -- buffers, not a hand-stocked loadout
  conf.slots.dirt = conf.slots.dirt or 1
  conf.slots.hoe = conf.slots.hoe or 2
  conf.slots.fertilizer = conf.slots.fertilizer or 3
  conf.slots.seed = conf.slots.seed or 4
  conf.slots.water = conf.slots.water or 5
  conf.slots.block = conf.slots.block or 6     -- accelerator/cable/pylon/chest
  conf.slots.fuel = conf.slots.fuel or 16
  conf.slots.scratch = conf.slots.scratch or 15
  conf.scan_y = conf.scan_y or
    (conf.origin and conf.size and conf.origin.y + conf.size.h + 1)
  conf.fuel_low = conf.fuel_low or 1000
  conf.fuel_reserve = conf.fuel_reserve or 200
  conf.plots = conf.plots or 1
  -- AE item ids the builder pulls/crafts. Seeds are derived per crop from the
  -- blueprint; these are the fixed ones.
  conf.items = conf.items or {}
  conf.items.dirt = conf.items.dirt or "minecraft:dirt"
  conf.items.hoe = conf.items.hoe or "minecraft:diamond_hoe"
  conf.items.fertilizer = conf.items.fertilizer
    or "farmingforblockheads:fertilizer_rich"
  conf.items.water = conf.items.water or "minecraft:water_bucket"
  conf.items.fuel = conf.items.fuel or "minecraft:coal_block"
  conf.base = conf.base or {}
  conf.base.suck = conf.base.suck or "down"
  conf.craft_timeout = conf.craft_timeout or 60
  conf.cadence = conf.cadence or 5
  conf.fleet = conf.fleet or "farm"
  -- ceiling for restock travel: above the whole stack so the corridor is clear
  if not conf.travel_y and conf.build and conf.size then
    conf.travel_y = conf.build.y + (conf.plots or 1) * conf.size.h + 4
  end
  return conf
end

local function writeFile(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local cfg = loadConf()

-- ------------------------------------------------------------- journal
-- S is the live state, mirrored to disk on every change during the build
-- phase. Write-ahead rule (claim C5): `intent` names a mutating turtle command
-- and is written BEFORE the command runs, so a boot that finds an intent knows
-- the world is in one of exactly two states. Position updates AFTER a move
-- succeeds, so a kill mid-move leaves journal.pos == the un-moved physical
-- position (the harness/CC abandon the command before it mutates the world).
-- Capture is pure reads and simply re-runs on a kill, so it does not journal.

local S            -- { pos={x,y,z}, heading, phase, plot, dy, intent, selftest }
local journaling = false

local function copyPos(p) return { x = p.x, y = p.y, z = p.z } end

-- The operator's single placement: cfg.start (defaulting to the scan origin for
-- a capture-only setup). Both capture and build dead-reckon from here.
local function startPose()
  local s = cfg.start or { x = cfg.origin.x, y = cfg.scan_y, z = cfg.origin.z }
  return { pos = copyPos(s), heading = cfg.start_heading or cfg.heading }
end

local function writeJournalTo(path)
  local f = fs.open(path, "w")
  f.write("phase=" .. tostring(S.phase) .. "\n")
  f.write("plot=" .. tostring(S.plot or 0) .. "\n")
  f.write("dy=" .. tostring(S.dy or 0) .. "\n")
  f.write("pos=" .. S.pos.x .. "," .. S.pos.y .. "," .. S.pos.z .. "\n")
  f.write("heading=" .. S.heading .. "\n")
  if S.selftest then f.write("selftest=" .. S.selftest .. "\n") end
  if S.intent then f.write("intent=" .. S.intent .. "\n") end
  if S.err then f.write("err=" .. S.err .. "\n") end
  f.close()
end

local function saveJournal()
  if not journaling then return end
  writeJournalTo(JOURNAL_PATH)
end

-- A torn journal write (kill mid-save; C5 accepted risk) must not strand the
-- builder with "no journal": a backup is written at coarse boundaries (plot /
-- layer), and the recovery tolerates its staleness by re-converging.
local function saveBak()
  if not journaling then return end
  writeJournalTo(JOURNAL_PATH .. ".bak")
end

local function parseJournal(path)
  local f = fs.open(path, "r")
  if not f then return nil end
  local j = {}
  while true do
    local line = f.readLine()
    if not line then break end
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then j[k] = v end
  end
  f.close()
  if not j.pos then return nil end
  local x, y, z = j.pos:match("^(-?%d+),(-?%d+),(-?%d+)$")
  if not x then return nil end
  return {
    phase = j.phase, plot = tonumber(j.plot) or 0, dy = tonumber(j.dy) or 0,
    heading = j.heading, intent = j.intent, selftest = j.selftest, err = j.err,
    pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) },
  }
end

local function readJournal()
  return parseJournal(JOURNAL_PATH) or parseJournal(JOURNAL_PATH .. ".bak")
end

local function intent(name)
  S.intent = name
  saveJournal()
end

local function clearIntent()
  S.intent = nil
  saveJournal()
end

-- --------------------------------------------------------- position + nav
-- Like sled, the turtle dead-reckons its pose from a known start (the
-- operator's single placement at cfg.start). CC has no GPS here.

local function faceTo(dir)
  while S.heading ~= dir do
    if RIGHTD[S.heading] == dir then
      turtle.turnRight(); S.heading = RIGHTD[S.heading]
    elseif LEFTD[S.heading] == dir then
      turtle.turnLeft(); S.heading = LEFTD[S.heading]
    else
      turtle.turnRight(); S.heading = RIGHTD[S.heading] -- 180: two rights
    end
    saveJournal()
  end
end

local function goFwd()
  local ok, err = turtle.forward()
  if ok then
    S.pos.x = S.pos.x + DIRV[S.heading].x
    S.pos.z = S.pos.z + DIRV[S.heading].z
    saveJournal()
  end
  return ok, err
end

local function goUp()
  local ok, err = turtle.up()
  if ok then S.pos.y = S.pos.y + 1; saveJournal() end
  return ok, err
end

local function goDown()
  local ok, err = turtle.down()
  if ok then S.pos.y = S.pos.y - 1; saveJournal() end
  return ok, err
end

-- Free-form navigation by dead reckoning: vertical first (the scan/transit
-- layers are clear air), then X then Z. Returns false if a move is obstructed
-- (the caller decides whether that is fatal). Assumes a clear corridor at the
-- target layer - the elevator shaft and scan layer guarantee this (Q3/§build).
local function navTo(tx, ty, tz)
  while S.pos.y < ty do if not goUp() then return false end end
  while S.pos.y > ty do if not goDown() then return false end end
  if S.pos.x < tx then faceTo("east") elseif S.pos.x > tx then faceTo("west") end
  while S.pos.x ~= tx do if not goFwd() then return false end end
  if S.pos.z < tz then faceTo("south") elseif S.pos.z > tz then faceTo("north") end
  while S.pos.z ~= tz do if not goFwd() then return false end end
  return true
end

-- Travel between the build column and the restock park without crashing
-- through the partially-built stack: rise to a clear ceiling above everything,
-- move horizontally, then descend onto the target. The ceiling is cfg.travel_y
-- (above plot count * height), guaranteeing an obstruction-free corridor.
local function navSafe(tx, ty, tz)
  local ceil = math.max(S.pos.y, ty, cfg.travel_y or ty)
  while S.pos.y < ceil do if not goUp() then return false end end
  if S.pos.x < tx then faceTo("east") elseif S.pos.x > tx then faceTo("west") end
  while S.pos.x ~= tx do if not goFwd() then return false end end
  if S.pos.z < tz then faceTo("south") elseif S.pos.z > tz then faceTo("north") end
  while S.pos.z ~= tz do if not goFwd() then return false end end
  while S.pos.y > ty do if not goDown() then return false end end -- lands by descent
  return true
end

-- ------------------------------------------------------------- classify

-- Map an inspected block to a normalized blueprint cell. Fertilized farmland is
-- recorded as a SOIL RECIPE (build = dirt + till + fertilize), never a
-- placeable block (FARM-RESEARCH Q3/§4 - the fertilized block is not item-
-- placeable). Crop age is dropped: the builder always plants fresh seeds.
local function classify(name, state)
  if name == "minecraft:water" then return { kind = "water" } end
  if name == "farmingforblockheads:fertilized_farmland_healthy" then
    return { kind = "soil", tier = "fertilized" }
  end
  if name == "minecraft:farmland" then return { kind = "soil", tier = "plain" } end
  if name:find("crop", 1, true)
    and (name:find("agriculture", 1, true) or name:find("mystical", 1, true)) then
    return { kind = "crop", id = name }
  end
  -- accelerator / cable / harvester pylon / ender chest / anything else: copy
  -- verbatim, keeping a vertical power axis if the captured facing has one
  local c = { kind = "block", id = name }
  if state and (state.axis == "y" or state.facing == "up" or state.facing == "down") then
    c.axis = "y"
  end
  return c
end

-- ----------------------------------------------------------- serialize

-- Deterministic blueprint serializer (sorted keys) so a re-capture of the same
-- plot is byte-identical - capture stays idempotent and torn-write-safe (a bad
-- write just re-captures, since capture is pure reads).
local function quote(s) return ("%q"):format(s) end

local function serializeBlueprint(bp)
  local out = { "return {" }
  out[#out + 1] = ("  size = { w = %d, h = %d, d = %d },")
    :format(bp.size.w, bp.size.h, bp.size.d)
  out[#out + 1] = "  cells = {"
  local keys = {}
  for k in pairs(bp.cells) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local c = bp.cells[k]
    local parts = { "kind = " .. quote(c.kind) }
    if c.tier then parts[#parts + 1] = "tier = " .. quote(c.tier) end
    if c.id then parts[#parts + 1] = "id = " .. quote(c.id) end
    if c.axis then parts[#parts + 1] = "axis = " .. quote(c.axis) end
    out[#out + 1] = ("    [%s] = { %s },"):format(quote(k), table.concat(parts, ", "))
  end
  out[#out + 1] = "  },"
  out[#out + 1] = "}"
  return table.concat(out, "\n") .. "\n"
end

local function loadBlueprint()
  local f = fs.open(BLUEPRINT, "r")
  if not f then return nil end
  local txt = f.readAll()
  f.close()
  local chunk = load(txt, "=farm.blueprint", "t", {})
  if not chunk then return nil end
  local ok, bp = pcall(chunk)
  if not ok or type(bp) ~= "table" then return nil end
  return bp
end

-- ------------------------------------------------------------- capture
-- Column-probe inspect-traversal (Q3): fly a serpentine over the footprint at
-- scan_y (clear air above the plot); per column, descend through air calling
-- inspectDown, recording the first solid block. A crop implies fertilized
-- farmland directly beneath it (a sulfur crop only exists on farmland), so the
-- soil cell under each crop is inferred rather than dug to. Pure reads.

local function probeColumn(ix, iz, cells)
  local y = cfg.scan_y
  while y > cfg.origin.y do
    local has, info = turtle.inspectDown()
    if has then
      local dy = (y - 1) - cfg.origin.y
      local c = classify(info.name, info.state)
      cells[key(ix, dy, iz)] = c
      if c.kind == "crop" and dy - 1 >= 0 then
        cells[key(ix, dy - 1, iz)] = { kind = "soil", tier = "fertilized" }
      end
      return
    end
    if not goDown() then return end
    y = y - 1
  end
end

local function capture()
  local w, h, d = cfg.size.w, cfg.size.h, cfg.size.d
  local cells = {}
  for iz = 0, d - 1 do
    local xs = {}
    if iz % 2 == 0 then
      for ix = 0, w - 1 do xs[#xs + 1] = ix end
    else
      for ix = w - 1, 0, -1 do xs[#xs + 1] = ix end
    end
    for _, ix in ipairs(xs) do
      if not navTo(cfg.origin.x + ix, cfg.scan_y, cfg.origin.z + iz) then
        print("farm: capture blocked navigating to column " .. ix .. "," .. iz)
        return false
      end
      probeColumn(ix, iz, cells)
    end
  end
  navTo(cfg.origin.x, cfg.scan_y, cfg.origin.z) -- park back at the scan origin
  local n = 0
  for _ in pairs(cells) do n = n + 1 end
  writeFile(BLUEPRINT, serializeBlueprint{ size = { w = w, h = h, d = d },
    cells = cells })
  print(("farm: captured %d cells (%dx%d, h=%d) -> %s")
    :format(n, w, d, h, BLUEPRINT))
  return true
end

-- --------------------------------------------------------------- supply
-- The builder pulls/crafts every material from the cross-dim AE network
-- (FARM-RESEARCH Q2). ensureItem keeps a work slot stocked; restock() (filled
-- in with the ME-bridge wiring) gates on OBSERVED stock, never on the craft
-- job (AM-2). For the pure build/converge path the slots are pre-stocked, so
-- ensureItem's fast path returns without touching AE.

local bridge          -- wrapped ME Bridge peripheral, or nil
local broadcast       -- forward decl (telemetry; defined in orchestration)

local function findBridge()
  if cfg.base and cfg.base.bridge and peripheral.isPresent(cfg.base.bridge) then
    return peripheral.wrap(cfg.base.bridge)
  end
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType and peripheral.hasType(n, "me_bridge") then
      return peripheral.wrap(n)
    end
  end
  return nil
end

-- Pull whatever the bridge dropped at the staging cell into `slot`. Run BEFORE
-- any export (recoverDrop, sled.lua:386): if a kill struck between a prior
-- export and the suck, the stack is on the ground - collect it rather than
-- re-export and double-pull from AE.
local function collectStaging(slot)
  turtle.select(slot)
  local sd = cfg.base.suck or "down"
  for _ = 1, 16 do
    local ok
    if sd == "up" then ok = turtle.suckUp()
    elseif sd == "down" then ok = turtle.suckDown()
    else ok = turtle.suck() end
    if not ok then break end
  end
end

-- Restock `slot` to >= minCount of spec.name from AE: park, recover any stranded
-- export, craft if AE can't cover the request (gate on OBSERVED stock, AM-2),
-- export a batch to the staging cell, suck it, return to the build cell. All AE
-- actions are machine-sourced - no fake-player path (Q2).
local function restock(slot, spec, minCount, batch)
  if not bridge or not cfg.base.park then return false end
  batch = batch or 64
  local saved, savedHeading = copyPos(S.pos), S.heading
  intent("restock " .. spec.name)
  if not navSafe(cfg.base.park.x, cfg.base.park.y, cfg.base.park.z) then
    return false
  end
  turtle.select(slot)
  collectStaging(slot)
  local function slotCount()
    local d = turtle.getItemDetail(slot)
    return (d and d.name == spec.name) and turtle.getItemCount(slot) or 0
  end
  local function aeCount()
    local it = bridge.getItem({ name = spec.name })
    return it and it.count or 0
  end
  if slotCount() < minCount then
    -- craft only if observed AE stock can't cover the request and a pattern
    -- exists; never re-issue on a job id (idempotent on observed stock)
    if aeCount() < minCount and bridge.isCraftable({ name = spec.name }) then
      bridge.craftItem({ name = spec.name, count = batch })
      local deadline = os.clock() + cfg.craft_timeout
      while aeCount() < minCount and os.clock() < deadline do os.sleep(0.5) end
    end
    local want = math.min(batch, aeCount())
    if want >= minCount then
      local n = bridge.exportItem({ name = spec.name, count = want },
        cfg.base.export_side or cfg.base.suck)
      if n and n > 0 then collectStaging(slot) end
    end
  end
  local got = slotCount()
  navSafe(saved.x, saved.y, saved.z)
  faceTo(savedHeading)
  clearIntent()
  return got >= minCount
end

local function ensureItem(slot, spec, minCount, batch)
  turtle.select(slot)
  local d = turtle.getItemDetail(slot)
  if d and d.name == spec.name and turtle.getItemCount(slot) >= minCount then
    return true
  end
  return restock(slot, spec, minCount, batch)
end

-- Burn fuel from the fuel slot up to `target`, measuring fuel-per-item at
-- runtime (S3/AM-2: the pack can override burn values, so no constant appears
-- here - the first refuel(1) probes the delta).
local function measuredRefuel(target)
  turtle.select(cfg.slots.fuel)
  local lvl = turtle.getFuelLevel()
  if lvl == "unlimited" or lvl >= target then return true end
  if turtle.getItemCount(cfg.slots.fuel) == 0 then return false end
  if not turtle.refuel(1) then return false end
  local per = turtle.getFuelLevel() - lvl
  if per <= 0 then return false end
  local need = math.ceil((target - turtle.getFuelLevel()) / per)
  if need > 0 then
    turtle.refuel(math.min(need, turtle.getItemCount(cfg.slots.fuel)))
  end
  return turtle.getFuelLevel() >= target
end

-- Top up fuel when below the low watermark by pulling coal blocks from AE
-- (best per-slot fuel; Q5) and burning to fuel_low + reserve.
local function refuelIfLow()
  local lvl = turtle.getFuelLevel()
  if lvl == "unlimited" or lvl >= cfg.fuel_low then return true end
  ensureItem(cfg.slots.fuel, { name = cfg.items.fuel }, 1, 64)
  return measuredRefuel(cfg.fuel_low + cfg.fuel_reserve)
end

local function ensureHoe()
  turtle.select(cfg.slots.hoe)
  local d = turtle.getItemDetail(cfg.slots.hoe, true)
  if d and d.name == cfg.items.hoe then
    -- restock before the hoe breaks mid-plot (Q1: ~one till-op per soil cell).
    -- A worn hoe still NAME-matches the slot, so restock's slotCount gate would
    -- keep it; evacuate it first so a fresh hoe can be pulled into the slot.
    if d.maxDamage and (d.maxDamage - (d.damage or 0)) <= 1 then
      turtle.select(cfg.slots.hoe); turtle.dropUp() -- discard the worn hoe
      return restock(cfg.slots.hoe, { name = cfg.items.hoe }, 1, 1)
    end
    return true
  end
  return restock(cfg.slots.hoe, { name = cfg.items.hoe }, 1, 1)
end

-- ----------------------------------------------------------- build cells
-- Stance: the turtle stands one block ABOVE the target cell and works it with
-- placeDown (FARM-RESEARCH §build geometry). Each step is CONVERGE-style: it
-- inspects the cell FIRST and acts only on the observed-block delta, so the
-- journal names WHICH cell and the world decides WHAT op. "Redo this cell" is
-- the universal recovery, and a kill-redo never double-fertilizes or re-tills
-- (P0-2). intent() writes the mutating op to disk before it runs (C5).

local bp              -- loaded blueprint

local function nameBelow()
  local h, i = turtle.inspectDown()
  return h and i.name or nil
end

local FERTILIZED_SOIL = "farmingforblockheads:fertilized_farmland_healthy"

local function doSoil(tier)
  local cur = nameBelow()
  if cur == nil then
    if not ensureItem(cfg.slots.dirt, { name = cfg.items.dirt }, 1) then
      return false, "no-dirt"
    end
    intent("dirt"); turtle.placeDown(); clearIntent()
    cur = nameBelow()
    if cur == nil then return false, "place-dirt" end -- placement did not stick
  end
  if cur == "minecraft:dirt" or cur == "minecraft:grass_block" then
    if not ensureHoe() then return false, "no-hoe" end
    turtle.select(cfg.slots.hoe)
    intent("till"); turtle.placeDown(); clearIntent()
    cur = nameBelow()
    -- a broken/vetoed hoe leaves the cell un-tilled: halt loudly rather than
    -- silently reporting an un-tilled cell as done (P0-2 read-back)
    if cur ~= "minecraft:farmland" and cur ~= FERTILIZED_SOIL then
      return false, "till"
    end
  end
  -- only plain farmland is fertilized; an already-fertilized cell is skipped
  -- (no double-spend) - the load-bearing converge guard (P0-2)
  if tier == "fertilized" and cur == "minecraft:farmland" then
    if not ensureItem(cfg.slots.fertilizer, { name = cfg.items.fertilizer }, 1) then
      return false, "no-fertilizer"
    end
    intent("fertilize"); turtle.placeDown(); clearIntent()
    if nameBelow() ~= FERTILIZED_SOIL then return false, "fertilize" end
  end
  return true
end

local function doCrop(cropId)
  local cur = nameBelow()
  if cur == cropId then return true end       -- already planted (converge skip)
  if cur then return true end                 -- unexpected block: leave it
  local seedId = cropId:gsub("_crop$", "_seeds")
  if not ensureItem(cfg.slots.seed, { name = seedId }, 1) then return false, "no-seed" end
  intent("plant"); turtle.placeDown(); clearIntent()
  return true
end

local function doWater()
  local cur = nameBelow()
  if cur == "minecraft:water" then return true end -- already placed (converge)
  if cur then return true end
  -- A placeDown water bucket braces only against the cell DIRECTLY BELOW the
  -- target (vertical deploy; Q1-water), so guarantee a solid sub-floor there:
  -- descend into the water cell, place a dirt block beneath if the cell below
  -- is open, then return to the stance. This is what makes water on a STACKED
  -- plot autonomous (the cell below is the prior plot's air center).
  if not navTo(S.pos.x, S.pos.y - 1, S.pos.z) then return false, "water-nav" end
  if not turtle.detectDown() then
    if not ensureItem(cfg.slots.dirt, { name = cfg.items.dirt }, 1) then
      navTo(S.pos.x, S.pos.y + 1, S.pos.z)
      return false, "no-subfloor"
    end
    turtle.select(cfg.slots.dirt)
    intent("subfloor"); turtle.placeDown(); clearIntent()
  end
  if not navTo(S.pos.x, S.pos.y + 1, S.pos.z) then return false, "water-nav" end
  -- water buckets do not stack: pull one at a time (batch 1)
  if not ensureItem(cfg.slots.water, { name = cfg.items.water }, 1, 1) then
    return false, "no-water"
  end
  intent("water")
  local ok = turtle.placeDown()
  clearIntent()
  if ok then
    -- the bucket emptied IN PLACE (-> minecraft:bucket); evacuate it so the
    -- work slot is free for the next plot's water restock (a stale empty bucket
    -- would strand the slot and halt the next water cell)
    local d = turtle.getItemDetail(cfg.slots.water)
    if d and d.name ~= cfg.items.water then
      turtle.select(cfg.slots.water); turtle.dropUp()
    end
  else
    -- the bucket stance is the top in-game-verify item (Q1-water); if it still
    -- fails on the real server, hand-seed the one center block per plot
    print(("farm: water at %d,%d,%d needs hand-seeding (bucket stance failed)")
      :format(S.pos.x, S.pos.y - 1, S.pos.z))
  end
  return true
end

local function doBlock(id)
  local cur = nameBelow()
  if cur == id then return true end           -- already placed (converge skip)
  if cur then return true end
  if not ensureItem(cfg.slots.block, { name = id }, 1) then
    return false, "no-block:" .. id
  end
  intent("block"); turtle.placeDown(); clearIntent()
  return true
end

local function buildCell(Y0, dx, dy, dz, cell)
  local ax, ay, az = cfg.build.x + dx, Y0 + dy, cfg.build.z + dz
  -- in-plot moves stay at the (clear) stance layer above the building layer;
  -- the obstruction-free approach into the layer is done by buildLayer
  if not navTo(ax, ay + 1, az) then return false, "nav" end -- stance ABOVE target
  saveBak() -- snapshot the backup at each cell stance (bounds torn-write staleness)
  if cell.kind == "soil" then return doSoil(cell.tier)
  elseif cell.kind == "crop" then return doCrop(cell.id)
  elseif cell.kind == "water" then return doWater()
  elseif cell.kind == "block" then return doBlock(cell.id) end
  return true
end

-- One layer, serpentine; water cells are built LAST so the ring soil is in
-- place to brace the source (P0-1).
local function buildLayer(Y0, dy)
  local w, d = bp.size.w, bp.size.d
  local others, waters = {}, {}
  for iz = 0, d - 1 do
    local xs = {}
    if iz % 2 == 0 then
      for ix = 0, w - 1 do xs[#xs + 1] = ix end
    else
      for ix = w - 1, 0, -1 do xs[#xs + 1] = ix end
    end
    for _, ix in ipairs(xs) do
      local c = bp.cells[key(ix, dy, iz)]
      if c then
        local e = { ix = ix, iz = iz, cell = c }
        if c.kind == "water" then waters[#waters + 1] = e
        else others[#others + 1] = e end
      end
    end
  end
  -- obstruction-free approach to the layer's first cell (the turtle may be at
  -- the park, the scratch column, or the previous plot); thereafter in-plot
  -- navTo at the clear stance layer is safe (P1-2 elevator corridor)
  local first = others[1] or waters[1]
  if first then
    navSafe(cfg.build.x + first.ix, Y0 + dy + 1, cfg.build.z + first.iz)
  end
  for _, e in ipairs(others) do
    local ok, why = buildCell(Y0, e.ix, dy, e.iz, e.cell)
    if not ok then return false, why end
  end
  for _, e in ipairs(waters) do
    local ok, why = buildCell(Y0, e.ix, dy, e.iz, e.cell)
    if not ok then return false, why end
  end
  return true
end

local function buildPlot(plot)
  local Y0 = cfg.build.y + plot * bp.size.h
  refuelIfLow() -- top up before a plot's worth of moves (Q5)
  for dy = S.dy, bp.size.h - 1 do
    S.dy, S.plot = dy, plot
    saveJournal(); saveBak()
    broadcast{ state = "BUILD" }
    local ok, why = buildLayer(Y0, dy)
    if not ok then return false, why end
  end
  S.dy = 0
  return true
end

-- ----------------------------------------------------------- self-test
-- Before any real plot, prove the risky primitives on a scratch column and the
-- AE link (the in-game-settled layers: FfB fertilizer fake-player path, water
-- fluid-place, the cross-dim grid merge). Abort LOUDLY and build nothing on any
-- failure. Runs once per `build` (journal selftest=done), so a reboot mid-build
-- does not re-run it and waste materials.

local function selfTestFail(msg)
  print("farm: SELF-TEST FAILED - " .. msg)
  print("farm: building nothing. Fix the cause, then re-run 'farm build'.")
  return false, msg
end

local function belowName()
  local h, i = turtle.inspectDown()
  return h and i.name or nil
end

local function selfTest()
  if S.selftest == "done" then return true end
  bridge = bridge or findBridge()
  if not bridge then
    -- no AE wired (e.g. hand-stocked dev run): nothing to prove, allow build
    S.selftest = "done"; saveJournal()
    return true
  end
  -- (1) cross-dim AE pull proves the quantum grid merge (Q2)
  local probe = cfg.base.test_item or cfg.items.dirt
  if not restock(cfg.slots.scratch, { name = probe }, 1, 1) then
    return selfTestFail("ME pull failed for " .. probe
      .. " (AE grid merge / spare channel?)")
  end
  -- (2) craft request: a craftable item must materialize into stock
  if cfg.base.craft_probe then
    local function ae() local it = bridge.getItem({ name = cfg.base.craft_probe })
      return it and it.count or 0 end
    if not bridge.isCraftable({ name = cfg.base.craft_probe }) then
      return selfTestFail("craft request: " .. cfg.base.craft_probe
        .. " not craftable from the mining dim")
    end
    local was = ae()
    bridge.craftItem({ name = cfg.base.craft_probe, count = 1 })
    local deadline = os.clock() + cfg.craft_timeout
    while ae() <= was and os.clock() < deadline do os.sleep(0.5) end
    if ae() <= was then return selfTestFail("craft request did not complete") end
  end
  -- (3) build-chain primitives on a scratch column (till/fertilize/plant/water).
  -- No digging: building tiny persistent scratch structures avoids polluting the
  -- material slots with dug blocks; a re-run converges (each step skips what is
  -- already there). The scratch needs floors at sc and the cell one east of sc.
  local sc = cfg.base.scratch
  if sc then
    -- soil column at (sc.x, sc.z): dirt -> till -> fertilize -> plant
    if not navSafe(sc.x, sc.y + 2, sc.z) then return selfTestFail("scratch nav") end
    local cur = belowName()
    if cur == nil then
      if not ensureItem(cfg.slots.dirt, { name = cfg.items.dirt }, 1) then
        return selfTestFail("no dirt available")
      end
      turtle.select(cfg.slots.dirt); turtle.placeDown(); cur = belowName()
    end
    if cur == "minecraft:dirt" then
      if not ensureHoe() then return selfTestFail("no hoe available") end
      turtle.select(cfg.slots.hoe); turtle.placeDown(); cur = belowName()
      if cur ~= "minecraft:farmland" then return selfTestFail("till (hoe)") end
    end
    if cur == "minecraft:farmland" then
      if ensureItem(cfg.slots.fertilizer, { name = cfg.items.fertilizer }, 1) then
        turtle.select(cfg.slots.fertilizer); turtle.placeDown(); cur = belowName()
        if cur ~= "farmingforblockheads:fertilized_farmland_healthy" then
          return selfTestFail("fertilize (FfB fake-player veto?)")
        end
      end
    end
    -- plant on the fertilized farmland (crop one above it)
    local seedId = cfg.base.scratch_seed or "mysticalagriculture:sulfur_seeds"
    if not navSafe(sc.x, sc.y + 3, sc.z) then return selfTestFail("scratch up") end
    if belowName() == nil and ensureItem(cfg.slots.seed, { name = seedId }, 1) then
      turtle.select(cfg.slots.seed); turtle.placeDown()
      local b = belowName()
      if not (b and b:find("crop", 1, true)) then
        return selfTestFail("plant (seed on farmland)")
      end
    end
    -- water column one east of sc, braced by its own floor below
    if not navSafe(sc.x + 1, sc.y + 2, sc.z) then return selfTestFail("water nav") end
    if belowName() == nil then
      if ensureItem(cfg.slots.water, { name = cfg.items.water }, 1, 1) then
        if not turtle.placeDown() then
          return selfTestFail("water bucket (fluid-place veto?)")
        end
        if belowName() ~= "minecraft:water" then
          return selfTestFail("water bucket did not place a source")
        end
      end
    end
  end
  S.selftest = "done"; saveJournal()
  print("farm: self-test passed.")
  return true
end

-- On a FRESH build (no journal), an operator re-run over an already-built or
-- extended stack must not descend into a plot buried under finished plots above
-- it (navSafe can't pass through them) and must not re-converge a finished plot
-- (whose soil-layer stance is its own occupied crop layer). Probe the corner
-- column from the top: the highest solid block tells how many plots are already
-- built, so resume at the FIRST plot above them. A partial build keeps its
-- journal and resumes via that instead, so a fresh build only ever sees empty
-- or completed plots below the resume point.
local function skipBuiltPlots()
  if not navSafe(cfg.build.x, cfg.travel_y, cfg.build.z) then return end
  while not turtle.detectDown() and S.pos.y > cfg.build.y do
    if not goDown() then break end
  end
  if not turtle.detectDown() then return end -- nothing built: stay at plot 0
  local built = math.floor((S.pos.y - 1 - cfg.build.y) / bp.size.h) + 1
  S.plot, S.dy = math.min(built, cfg.plots), 0
  if S.plot >= cfg.plots then
    print("farm: stack already complete - nothing to build.")
  else
    print(("farm: %d plot(s) already built, extending from plot %d")
      :format(built, S.plot))
  end
  saveJournal()
end

local function runBuild()
  bp = loadBlueprint()
  if not bp then
    print("farm: no blueprint - run 'farm capture' first.")
    return
  end
  bridge = findBridge()
  local ok, why = selfTest()
  if not ok then S.err = "selftest:" .. tostring(why); saveJournal(); return end
  if S.fresh then skipBuiltPlots() end -- re-run over an existing stack (P1 #6)
  for plot = S.plot, cfg.plots - 1 do
    local ok, why = buildPlot(plot)
    if not ok then
      S.err = why
      saveJournal()
      print("farm: build halted at plot " .. plot .. ": " .. tostring(why))
      return
    end
  end
  fs.delete(JOURNAL_PATH)
  fs.delete(JOURNAL_PATH .. ".bak")
  print("farm: build complete (" .. cfg.plots .. " plot(s)).")
end

-- Boot reconciliation: a journal means a build was interrupted - restore the
-- dead-reckoned pose (pos is journaled AFTER each move, so a killed move left
-- pos == the physical cell) and re-run; every cell step is converge, so
-- re-running resumes at the first incomplete cell. No journal => fresh build.
local function boot()
  journaling = true
  local j = readJournal()
  if j and j.phase == "build" then
    S = j
    S.err = nil -- a reboot means the human is retrying; re-set only if it re-fails
    print(("farm: resuming build at plot %d, layer %d"):format(S.plot, S.dy))
    return true
  end
  local sp = startPose()
  S = { pos = sp.pos, heading = sp.heading, phase = "build", plot = 0, dy = 0,
    fresh = true }
  saveJournal(); saveBak()
  return true
end

-- -------------------------------------------------------- orchestration
-- Reuse the existing mesh: rednet telemetry (source = cfg.fleet) so fluxwall
-- shows build progress, and the shared `basectl` channel so `update-all` can
-- refresh this turtle when it is idle. Telemetry is fire-and-forget; with no
-- modem (headless emulator) it is a no-op and the build returns normally.

local hasModem = false
local CTL_TOKEN = "flux" -- courtesy lock matching the base mesh (mesensor.lua)

local function openModems()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType and peripheral.hasType(n, "modem") then
      if pcall(rednet.open, n) then hasModem = true end
    end
  end
  return hasModem
end

broadcast = function(extra)
  if not hasModem then return end
  local data = {
    state = (extra and extra.state) or (S and S.phase) or "idle",
    plot = S and S.plot, plots = cfg.plots, dy = S and S.dy,
    pos = S and (S.pos.x .. "," .. S.pos.y .. "," .. S.pos.z),
    fuel = turtle.getFuelLevel(), err = S and S.err,
  }
  if extra then for k, v in pairs(extra) do data[k] = v end end
  pcall(rednet.broadcast,
    { v = 1, source = cfg.fleet, tick = os.clock(), data = data }, PROTOCOL)
end

local function handleCtl(msg)
  if type(msg) ~= "table" or msg.token ~= (cfg.token or CTL_TOKEN) then return end
  if msg.cmd == "update" then
    pcall(rednet.broadcast, { ack = true, id = os.getComputerID(),
      label = os.getComputerLabel() }, CTL_PROTOCOL)
    if shell and shell.run then
      if msg.loud then shell.run("update", "fromall") else shell.run("update") end
    end
  elseif msg.cmd == "version?" then
    local v
    local vf = fs.open(".fluxversion", "r")
    if vf then v = (vf.readLine() or ""):gsub("%s+", ""); vf.close() end
    pcall(rednet.broadcast, { version = v or "?", id = os.getComputerID(),
      label = os.getComputerLabel() }, CTL_PROTOCOL)
  end
end

-- After the build finishes or halts, stay alive on the mesh: broadcast status
-- and accept token-gated updates (so update-all reaches an idle builder). With
-- no modem this returns immediately and the program ends.
local function serveIdle(finalState)
  if not hasModem then return end
  broadcast{ state = finalState }
  local timer = os.startTimer(cfg.cadence)
  while true do
    local ev = { os.pullEventRaw() }
    if ev[1] == "terminate" then return
    elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
      and type(ev[3]) == "table" then
      handleCtl(ev[3])
    elseif ev[1] == "timer" and ev[2] == timer then
      broadcast{ state = finalState }
      timer = os.startTimer(cfg.cadence)
    end
  end
end

-- ---------------------------------------------------------------- main

local args = { ... }
local cmd = args[1]

local function confError()
  if not cfg then return "no farm.conf - write one first (see FARM-BUILD-DESIGN)." end
  local o = cfg.origin
  if type(o) ~= "table" or type(o.x) ~= "number" or type(o.y) ~= "number"
    or type(o.z) ~= "number" then
    return "farm.conf: origin must be { x=, y=, z= } numbers."
  end
  local s = cfg.size
  if type(s) ~= "table" or type(s.w) ~= "number" or type(s.h) ~= "number"
    or type(s.d) ~= "number" then
    return "farm.conf: size must be { w=, h=, d= } numbers."
  end
  if not DIRV[cfg.heading] then
    return "farm.conf: heading must be north/south/east/west."
  end
  return nil
end

local cerr = confError()
if cerr then
  print("farm: " .. cerr)
  return
end

local function buildConfError()
  local b = cfg.build
  if type(b) ~= "table" or type(b.x) ~= "number" or type(b.y) ~= "number"
    or type(b.z) ~= "number" then
    return "farm.conf: build must be { x=, y=, z= } numbers (the stack base)."
  end
  return nil
end

if cmd == "capture" then
  local sp = startPose()
  S = { pos = sp.pos, heading = sp.heading, phase = "capture" }
  navTo(cfg.origin.x, cfg.scan_y, cfg.origin.z)
  capture()
  return
elseif cmd == "build" or cmd == nil then
  -- build (self-test then build the stack) / resume from the journal (startup)
  local berr = buildConfError()
  if berr then print("farm: " .. berr); return end
  if not openModems() then
    print("farm: no modem - telemetry disabled, building blind.")
  end
  boot()
  local ok, err = pcall(runBuild)
  if not ok and tostring(err):find("Terminated", 1, true) then
    print("farm: stopped.")
    return
  elseif not ok then
    error(err, 0)
  end
  -- stay on the mesh: serve telemetry + accept token-gated updates while idle
  serveIdle(S and S.err and "HALTED" or "DONE")
  return
elseif cmd == "selftest" then
  -- run the startup self-tests only and build no real plot (journaling stays
  -- off, so this scratch check never writes the build journal)
  local berr = buildConfError()
  if berr then print("farm: " .. berr); return end
  local sp = startPose()
  S = { pos = sp.pos, heading = sp.heading, phase = "selftest", plot = 0, dy = 0 }
  bridge = findBridge()
  if not bridge then
    print("farm: no ME bridge found - cannot self-test the AE link.")
    return
  end
  selfTest() -- prints "self-test passed" or "SELF-TEST FAILED ..." itself
  return
else
  print("farm: unknown command '" .. tostring(cmd) .. "'")
  print("usage: farm [capture|build|selftest]")
  return
end
