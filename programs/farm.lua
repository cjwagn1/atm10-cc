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
  farm ae          diagnose the AE link (stock pull + a real craft probe)
  farm log         show the debug log (on|off step trace, clear); share it with
                   `pastebin put farm.log`
  farm hold        park at the shell; don't auto-build on boot (for inspecting)
  farm go          clear the hold and build now
  farm release     clear the hold, stay at the shell
  farm             resume from the journal (what startup.lua runs); on a fresh
                   boot, a 3s keypress window holds it before it moves

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
local LOG_PATH     = "farm.log"
local VERBOSE_FLAG = "farm.verbose"
local LOG_CAP      = 50000 -- ~50KB; the log self-trims to the last half past this

-- Persistent logging. The CC terminal can't scroll and a run's output is long,
-- so EVERYTHING the turtle prints is mirrored to farm.log (capped). In verbose
-- mode (the farm.verbose flag, set by `farm log on`) every real-world step
-- (move/turn/build/AE) is traced too - a full record to debug from and to model
-- the emulator against what actually happened. Share it: `pastebin put farm.log`.
local VERBOSE = fs.exists(VERBOSE_FLAG)
local function logRaw(s)
  local f = fs.open(LOG_PATH, "a")
  if not f then return end
  f.writeLine(s)
  f.close()
  if fs.getSize and fs.getSize(LOG_PATH) > LOG_CAP then
    local rf = fs.open(LOG_PATH, "r")
    if rf then
      local all = rf.readAll(); rf.close()
      local keep = all:sub(-math.floor(LOG_CAP / 2)):gsub("^[^\n]*\n", "")
      local wf = fs.open(LOG_PATH, "w")
      if wf then wf.write("...[log trimmed]\n" .. keep); wf.close() end
    end
  end
end
local _print = print
print = function(...)
  _print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  logRaw(("[%8.2f] %s"):format(os.clock(), table.concat(parts, "\t")))
end
-- a verbose-only real-world step trace (no-op unless `farm log on`)
local function trace(msg)
  if VERBOSE then logRaw(("[%8.2f] [t] %s"):format(os.clock(), msg)) end
end

local DIRV = {
  north = { x = 0, z = -1 }, south = { x = 0, z = 1 },
  east = { x = 1, z = 0 }, west = { x = -1, z = 0 },
}
local LEFTD = { north = "west", west = "south", south = "east", east = "north" }
local RIGHTD = { north = "east", east = "south", south = "west", west = "north" }
local OPPD = { north = "south", south = "north", east = "west", west = "east" }

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
    or "farmingforblockheads:red_fertilizer"
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
  local from = S.heading
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
  if from ~= dir then trace(("turn %s -> %s"):format(tostring(from), dir)) end
end

local function goFwd()
  local ok, err = turtle.forward()
  if ok then
    S.pos.x = S.pos.x + DIRV[S.heading].x
    S.pos.z = S.pos.z + DIRV[S.heading].z
    saveJournal()
    trace(("fwd -> %d,%d,%d (%s)"):format(S.pos.x, S.pos.y, S.pos.z, S.heading))
  else
    trace("fwd BLOCKED: " .. tostring(err))
  end
  return ok, err
end

local function goUp()
  local ok, err = turtle.up()
  if ok then
    S.pos.y = S.pos.y + 1; saveJournal()
    trace(("up -> %d,%d,%d"):format(S.pos.x, S.pos.y, S.pos.z))
  else
    trace("up BLOCKED: " .. tostring(err))
  end
  return ok, err
end

local function goDown()
  local ok, err = turtle.down()
  if ok then
    S.pos.y = S.pos.y - 1; saveJournal()
    trace(("down -> %d,%d,%d"):format(S.pos.x, S.pos.y, S.pos.z))
  else
    trace("down BLOCKED: " .. tostring(err))
  end
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

-- The restock park / drop cell must NEVER be a build cell. With the bridge ON
-- the turtle (suck=self) the stack is centred over a ground-floor ender chest,
-- so the drop column (cfg.start, mirrored by cfg.base.park) can sit INSIDE the
-- horizontal build footprint, and on the on-foot path build.y == park.y, so the
-- park is inside the vertical span too. Plot 0 then places a block AT the park
-- cell; thereafter every restock rises to travel_y, moves over, and tries to
-- descend onto the now-occupied park -> goDown "Movement obstructed" -> restock
-- false -> the build mislabels the strand "no-seed". Detect that overlap
-- (horizontal AND vertical - necessary and sufficient) and slide the park one
-- cell at a time off the stack along the bridge axis (bridge_facing for an
-- on-turtle bridge, else export_side), keeping it reachable beside the bridge.
local function parkInFootprint(park)
  if not (park and cfg.build and cfg.size) then return false end
  local bx, bz, w, d = cfg.build.x, cfg.build.z, cfg.size.w, cfg.size.d
  local horiz = park.x >= bx and park.x < bx + w and park.z >= bz and park.z < bz + d
  local vSpan = cfg.build.y + (cfg.plots or 1) * cfg.size.h
  local vert = park.y >= cfg.build.y and park.y < vSpan
  return horiz and vert
end

local function relocatePark()
  local park = cfg.base and cfg.base.park
  if not parkInFootprint(park) then return true end
  -- slide horizontally along the bridge axis until clear of the footprint
  local axis = (cfg.base.suck == "self" and cfg.base.bridge_facing)
    or cfg.base.export_side or cfg.base.bridge_facing
  local v = DIRV[axis]
  if v and (v.x ~= 0 or v.z ~= 0) then
    local np = { x = park.x, y = park.y, z = park.z }
    for _ = 1, math.max(cfg.size.w, cfg.size.d) + 1 do
      np.x = np.x + v.x; np.z = np.z + v.z
      if not parkInFootprint(np) then cfg.base.park = np; return true end
    end
  end
  return false -- couldn't find a safe cell off the stack
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
  -- verbatim, keeping a vertical power axis if the captured facing has one.
  -- NOTE: `state` is only ever populated on the inspectDown/probe path - the Geo
  -- Scanner's scan() returns name/x/y/z/tags ONLY, NEVER a blockstate
  -- (GeoScannerPeripheral.scan), so on the 3D scan path `state` is nil and axis
  -- is unrecoverable. Do NOT rely on axis after a scanner capture; derive any
  -- vertical orientation from name/tags instead if a future build needs it.
  local c = { kind = "block", id = name }
  if state and (state.axis == "y" or state.facing == "up" or state.facing == "down") then
    c.axis = "y"
  end
  return c
end

-- --------------------------------------------------------- autonomous find
-- The operator never tells the turtle where the plot is. With a Geo Scanner it
-- scans a radius, keeps the blocks that signal a sulfur plot (fertilized
-- farmland, an MA crop, an AE2 accelerator), and takes their bounding box as
-- the plot - all in coords RELATIVE to the turtle, so no GPS or coordinates are
-- needed. (A search-by-flying fallback for a turtle with no scanner is a v1
-- TODO; with a scanner the find is one call.)

-- Mod-agnostic plot signature: a sulfur (or any MA) plot is farmland + crops,
-- usually ringed by growth accelerators. Match by SUBSTRING, not exact ids, so a
-- different soil tier, crop mod, or accelerator still registers - the operator's
-- pack chooses the blocks, not us. (The build's classify() still keys on the
-- exact captured ids; this is only the find heuristic.)
local function isPlotBlock(name)
  if type(name) ~= "string" then return false end
  return name:find("farmland", 1, true) ~= nil
    or name:find("_crop", 1, true) ~= nil
    or name:find("accelerat", 1, true) ~= nil
    or name:find("fertiliz", 1, true) ~= nil
end

-- AP's Geo Scanner peripheral type is "geo_scanner" (GeoScannerPeripheral
-- .PERIPHERAL_TYPE), NOT "geoScanner" - an equipped upgrade is found by the
-- underscore name. Older builds/test-mods used the camelCase string, so try
-- both; then, so a future rename can never resurrect the "no Geo Scanner"
-- false alarm, fall back to ANY peripheral that exposes scan(). An equipped
-- turtle upgrade IS a peripheral on the left/right side, so find() reaches it.
local function findScanner()
  if not peripheral or not peripheral.find then return nil end
  local s = peripheral.find("geo_scanner") or peripheral.find("geoScanner")
  if s then return s end
  for _, n in ipairs(peripheral.getNames()) do
    local ok, m = pcall(peripheral.wrap, n)
    if ok and type(m) == "table" and type(m.scan) == "function" then return m end
  end
  return nil
end

-- The AP Geo Scanner: radius <= 8 is FREE (0 fuel), radius > 8 costs fuel that
-- scales with the cube of the radius (a radius-16 scan is ~5274 fuel!). The
-- wizard scans several times, so a costly radius drains the turtle and then every
-- scan fails. Default to the free radius; `farm find <r>` can pay for a wider one.
local SCAN_RADIUS = 8

local function scanBlocks(radius)
  local scanner = findScanner()
  if not scanner then return nil, "no Geo Scanner equipped" end
  radius = radius or SCAN_RADIUS
  for _ = 1, 30 do -- the scanner may be charging / on cooldown: retry briefly
    local b = scanner.scan(radius)
    if type(b) == "table" then return b end
    sleep(1)
  end
  return nil, "scan failed (scanner out of fuel / on cooldown?)"
end

-- Returns { rx, ry, rz (relative min corner), w, h, d, blocks } or nil + reason.
local function findPlot(radius)
  local blocks, err = scanBlocks(radius)
  if not blocks then return nil, err end
  local minx, miny, minz, maxx, maxy, maxz, n
  n = 0
  for _, b in ipairs(blocks) do
    if isPlotBlock(b.name) then
      n = n + 1
      minx = math.min(minx or b.x, b.x); maxx = math.max(maxx or b.x, b.x)
      miny = math.min(miny or b.y, b.y); maxy = math.max(maxy or b.y, b.y)
      minz = math.min(minz or b.z, b.z); maxz = math.max(maxz or b.z, b.z)
    end
  end
  if n == 0 then return nil, "no plot in range" end
  return { rx = minx, ry = miny, rz = minz,
    w = maxx - minx + 1, h = maxy - miny + 1, d = maxz - minz + 1, blocks = n }
end

-- Diagnostic: what does the scanner actually see? A name->count histogram plus
-- how many matched the plot signature, so a failed find can say whether the farm
-- is out of range or simply built from blocks we don't yet match.
local function scanReport(radius)
  local blocks, err = scanBlocks(radius)
  if not blocks then return nil, err end
  local hist, matched = {}, 0
  for _, b in ipairs(blocks) do
    hist[b.name] = (hist[b.name] or 0) + 1
    if isPlotBlock(b.name) then matched = matched + 1 end
  end
  -- sort distinct names by count desc, plot-matches first so the farm blocks
  -- surface even when terrain dominates the count
  local names = {}
  for nm in pairs(hist) do names[#names + 1] = nm end
  table.sort(names, function(a, b)
    local pa, pb = isPlotBlock(a), isPlotBlock(b)
    if pa ~= pb then return pa end
    if hist[a] ~= hist[b] then return hist[a] > hist[b] end
    return a < b
  end)
  return { count = #blocks, matched = matched, hist = hist, names = names }
end

-- Print the "why didn't you find my plot" diagnostic: what the scanner saw and
-- the 16-block reach, so the operator can tell range vs. block-id mismatch.
-- Used by `farm find` and by the wizard when its own scan comes up empty.
local function printPlotDiagnostic(radius)
  radius = radius or SCAN_RADIUS
  local rep, err = scanReport(radius)
  if not rep then
    print("farm: couldn't scan (" .. tostring(err) .. ").")
    print("  Equip a Geo Scanner, or set me ON TOP of the farm to search on foot.")
    return
  end
  print(("farm: scanned radius %d - saw %d blocks, %d look like a plot.")
    :format(radius, rep.count, rep.matched))
  print("farm: the most notable blocks in range:")
  for i = 1, math.min(12, #rep.names) do
    local nm = rep.names[i]
    print(("  %s x%d%s"):format(nm, rep.hist[nm],
      isPlotBlock(nm) and "  <- plot-like" or ""))
  end
  print("farm: I match any *farmland* / *_crop* / *accelerat* / *fertiliz* block.")
  print("  My free scan reaches ~8 (16 blocks max, costs fuel) - set me ON the farm.")
end

-- Deduce the turtle's real WORLD facing with no GPS/compass: the Geo Scanner
-- reports world-aligned offsets, so when the turtle steps one block forward, a
-- fixed reference (the plot) shifts in offset by exactly -forward. Reading that
-- shift gives the world direction "forward" points. The turtle ends facing the
-- direction it measured (any turns taken to find a clear step are kept).
local function headingFromDelta(dx, dz)
  if dx == 1 and dz == 0 then return "east" end
  if dx == -1 and dz == 0 then return "west" end
  if dx == 0 and dz == 1 then return "south" end
  if dx == 0 and dz == -1 then return "north" end
  return nil
end

-- The set of plot-signature block offsets currently in scan range, keyed "x,y,z".
local function plotOffsetSet(blocks)
  local set, n = {}, 0
  for _, b in ipairs(blocks or {}) do
    if isPlotBlock(b.name) then set[b.x .. "," .. b.y .. "," .. b.z] = true; n = n + 1 end
  end
  return set, n
end

-- After the turtle steps forward by world-vector V, every plot block's offset
-- becomes (old - V). The cardinal V that maps the most BEFORE offsets onto AFTER
-- offsets is the step direction = the turtle's facing. Robust to the few blocks
-- that leave/enter range at the boundary (they only cost a little overlap),
-- where the old "bbox min shift" silently broke. Returns dir, overlap-score.
local function bestStepDir(before, after)
  local best, bestScore
  for _, d in ipairs({ "north", "south", "east", "west" }) do
    local v, score = DIRV[d], 0
    for kpos in pairs(before) do
      local x, y, z = kpos:match("(-?%d+),(-?%d+),(-?%d+)")
      if after[(tonumber(x) - v.x) .. "," .. y .. "," .. (tonumber(z) - v.z)] then
        score = score + 1
      end
    end
    if not bestScore or score > bestScore then bestScore, best = score, d end
  end
  return best, bestScore
end

-- Deduce my world facing with no GPS: scan, step one block, scan again, and read
-- which way the plot shifted. Try up to 4 facings so a blocked step (e.g. the
-- bridge in front) or an edge-of-range step just gets retried in another
-- direction. I end back where I started, facing the direction I measured.
-- Find the nearest ground-floor ender chest (the harvest anchor under each plot)
-- in scan range, as a turtle-relative (world-aligned) offset. The stack is then
-- centred over it instead of an arbitrary bbox corner, so copies line up with the
-- existing plot grid below. nil if none in range (or no scanner).
local function findEnderChest()
  local blocks = scanBlocks()
  if not blocks then return nil end
  local best
  for _, b in ipairs(blocks) do
    if type(b.name) == "string" and b.name:find("ender", 1, true)
      and b.name:find("chest", 1, true) then
      local dist = math.abs(b.x) + math.abs(b.z)
      if not best or dist < best.dist then
        best = { x = b.x, y = b.y, z = b.z, dist = dist }
      end
    end
  end
  return best
end

local function calibrateHeading()
  local before = plotOffsetSet(scanBlocks())
  if next(before) == nil then return nil, "no plot to calibrate on" end
  for _ = 1, 4 do
    if not turtle.detect() and turtle.forward() then
      local after = plotOffsetSet(scanBlocks())
      turtle.back()
      local dir, score = bestStepDir(before, after)
      -- require a solid overlap so noise at the range edge can't pick a heading
      if dir and score and score >= 3 then return dir end
    end
    turtle.turnRight()
  end
  return nil, "couldn't read my facing - set me right beside the plot, not boxed in"
end

-- ----------------------------------------------------- scanner-less search
-- With NO Geo Scanner the turtle can still find the plot on foot: set it ON TOP
-- of the farm (one block above the crops) and it flies an expanding spiral at
-- that altitude, inspecting DOWN, until it sees the plot signature - all in a
-- turtle-LOCAL frame (drop = origin, the initial facing simply LABELLED "north";
-- no GPS, no heading calibration, because we never compare against world-aligned
-- scanner data). It returns to the drop point + initial facing. Be blunt about
-- the limits: it only sees the block directly below it, so the plot must sit at
-- the drop altitude minus one and within `radius` horizontally; a Geo Scanner
-- removes both constraints and finds the plot from anywhere nearby.

-- Burn any fuel the operator left in my inventory so I can move enough to search
-- and calibrate before the AE fuel path exists (the build later tops up from
-- coal in AE). No-op with unlimited fuel or no burnable items.
local function refuelFromInventory(target)
  if not turtle.getFuelLevel or turtle.getFuelLevel() == "unlimited" then return end
  for s = 1, 16 do
    if turtle.getFuelLevel() >= target then break end
    turtle.select(s)
    if turtle.refuel(0) then turtle.refuel() end
  end
end

-- expanding-ring (centre-out) offsets within Chebyshev `radius`, so the search
-- can stop one clear ring past the plot instead of flying the whole box
local function spiralCells(radius)
  local cells = { { 0, 0 } }
  for r = 1, radius do
    local x, z = -r, -r
    for _, step in ipairs({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }) do
      for _ = 1, 2 * r do
        cells[#cells + 1] = { x, z }
        x, z = x + step[1], z + step[2]
      end
    end
  end
  return cells
end

local function searchPlot(radius)
  radius = radius or 8
  -- dead-reckon in a LOCAL frame; the real facing is whatever it is, we just
  -- call it "north" and stay self-consistent (the build copies in the same frame)
  S = { pos = { x = 0, y = 0, z = 0 }, heading = "north" }
  local hits, found, maxR = {}, false, 0
  for _, c in ipairs(spiralCells(radius)) do
    local dx, dz = c[1], c[2]
    local cheb = math.max(math.abs(dx), math.abs(dz))
    if found and cheb > maxR + 1 then break end -- one clear ring past the plot
    if navTo(dx, 0, dz) then
      local has, info = turtle.inspectDown()
      if has and isPlotBlock(info.name) then
        hits[#hits + 1] = { x = dx, z = dz }
        found = true
        if cheb > maxR then maxR = cheb end
      end
    end
  end
  navTo(0, 0, 0)
  faceTo("north")
  if not found then return nil, "no plot found on foot within reach" end
  local minx, maxx, minz, maxz
  for _, h in ipairs(hits) do
    minx = math.min(minx or h.x, h.x); maxx = math.max(maxx or h.x, h.x)
    minz = math.min(minz or h.z, h.z); maxz = math.max(maxz or h.z, h.z)
  end
  -- inspectDown sees the CROP layer (one below the flight altitude); the soil
  -- layer is inferred one below it (a sulfur crop only grows on farmland), so
  -- the plot is 2 tall, exactly as capture infers it. crop layer = -1 local.
  return { rx = minx, ry = -2, rz = minz,
    w = maxx - minx + 1, h = 2, d = maxz - minz + 1, blocks = #hits }, "north"
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
-- Two strategies. With a Geo Scanner the turtle reads the WHOLE 3D structure in
-- one scan (every layer, including soil + crops UNDER an accelerator / cable /
-- chest canopy) - the only way to copy a real farm where the top surface is
-- infrastructure. Without a scanner it falls back to the top-down column probe
-- (sees only each column's top block + infers soil under a crop).

local function writeBlueprint(cells, w, h, d)
  local n = 0
  for _ in pairs(cells) do n = n + 1 end
  writeFile(BLUEPRINT, serializeBlueprint{ size = { w = w, h = h, d = d },
    cells = cells })
  print(("farm: captured %d cells (%dx%d, h=%d) -> %s")
    :format(n, w, d, h, BLUEPRINT))
  return true
end

-- Full-3D capture: hover above the plot CENTRE so one free scan (radius 8 reaches
-- +-8 = up to a 17-wide footprint) covers everything, then map each scanned
-- block offset to a plot cell (ix,dy,iz) and classify it. Sees every layer.
local function captureScan3D()
  local w, h, d = cfg.size.w, cfg.size.h, cfg.size.d
  local cx = cfg.origin.x + math.floor(w / 2)
  local cz = cfg.origin.z + math.floor(d / 2)
  -- The largest |offset| any in-range cell has from the scan centre (cx, scan_y,
  -- cz). A free scan only reaches +-8, so if the footprint pushes any column or
  -- the floor past that, a single radius-8 scan would silently drop those cells
  -- and write a blueprint with a plausible size header but a hole. Raising the
  -- radius is forbidden (a radius-16 scan is ~5274 fuel - the drain bug), so
  -- abort LOUDLY instead of capturing a truncated plot (fix #3).
  local need = math.max(
    math.floor(w / 2), w - 1 - math.floor(w / 2),
    math.floor(d / 2), d - 1 - math.floor(d / 2),
    cfg.scan_y - cfg.origin.y, (cfg.origin.y + h - 1) - cfg.scan_y)
  if need > SCAN_RADIUS then
    print(("farm: plot footprint (need radius %d) exceeds the free radius-%d "
      .. "scan; capture would drop the edges. Shrink the plot or re-place me so "
      .. "the whole footprint is within %d of the scan centre.")
      :format(need, SCAN_RADIUS, SCAN_RADIUS))
    return false
  end
  if not navTo(cx, cfg.scan_y, cz) then
    print("farm: capture couldn't reach the plot centre.")
    return false
  end
  local blocks, err = scanBlocks(8)
  if not blocks then
    print("farm: capture scan failed (" .. tostring(err) .. ").")
    return false
  end
  -- scanner offsets are relative to my cell (cx, scan_y, cz) in the build frame
  local cells = {}
  for _, b in ipairs(blocks) do
    local ix = cx + b.x - cfg.origin.x
    local dy = (cfg.scan_y + b.y) - cfg.origin.y
    local iz = cz + b.z - cfg.origin.z
    if ix >= 0 and ix < w and dy >= 0 and dy < h and iz >= 0 and iz < d then
      -- the Geo Scanner returns no blockstate (only name/x/y/z/tags), so pass
      -- nil explicitly rather than pretend b.state exists (it never does here)
      cells[key(ix, dy, iz)] = classify(b.name, nil)
    end
  end
  navTo(cfg.origin.x, cfg.scan_y, cfg.origin.z)
  return writeBlueprint(cells, w, h, d)
end

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

local function captureProbe()
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
  return writeBlueprint(cells, w, h, d)
end

local function capture()
  if findScanner() then return captureScan3D() end
  return captureProbe()
end

-- --------------------------------------------------------------- supply
-- The builder pulls/crafts every material from the cross-dim AE network
-- (FARM-RESEARCH Q2). ensureItem keeps a work slot stocked; restock() (filled
-- in with the ME-bridge wiring) gates on OBSERVED stock, never on the craft
-- job (AM-2). For the pure build/converge path the slots are pre-stocked, so
-- ensureItem's fast path returns without touching AE.

local bridge          -- wrapped ME Bridge peripheral, or nil
local broadcast       -- forward decl (telemetry; defined in orchestration)

-- The AP ME Bridge peripheral type has varied across builds (me_bridge /
-- meBridge / advancedperipherals:me_bridge), so an exact hasType("me_bridge")
-- match silently missed an attached bridge - the same camelCase trap the geo
-- scanner hit. Use the proven mesensor approach: match "bridge" as a substring
-- across ALL of a peripheral's types; then fall back to the ME-Bridge method
-- shape so a fully renamed type still can't hide it.
local function findBridge()
  if cfg and cfg.base and cfg.base.bridge and peripheral.isPresent(cfg.base.bridge) then
    return peripheral.wrap(cfg.base.bridge), cfg.base.bridge
  end
  for _, n in ipairs(peripheral.getNames()) do
    for _, ty in ipairs({ peripheral.getType(n) }) do
      if type(ty) == "string" and ty:lower():find("bridge", 1, true) then
        return peripheral.wrap(n), n
      end
    end
  end
  for _, n in ipairs(peripheral.getNames()) do
    local ok, m = pcall(peripheral.wrap, n)
    if ok and type(m) == "table" and type(m.getItem) == "function"
      and type(m.exportItem) == "function" then
      return m, n
    end
  end
  return nil
end

-- A turtle can only reach an adjacent ME Bridge BLOCK when it's facing it - the
-- bridge's readable side rotates with the turtle, so after I move/turn it may
-- not be reachable at all (the in-game "can't detect the bridge unless it's on
-- front" + "farm ae works, farm doesn't" symptom). Turn in place until findBridge
-- sees it; report the right-turns taken so the caller UNDOES them only AFTER it
-- has finished talking to the bridge (the handle is valid only while I face it).
-- Must be called while parked ADJACENT to the bridge.
-- Each turn updates S.heading + journals (like faceTo) WHEN a build state exists,
-- so a kill while faced at the bridge resumes square (C5): without this the raw
-- turn rotated the physical turtle while the journal kept the pre-turn heading,
-- and the resumed build dead-reckoned rotated. The wizard calls this before any
-- build state (S == nil) and tracks its own turns, so the journal is untouched
-- there.
local function faceBridge()
  for turns = 0, 3 do
    local b, n = findBridge()
    if b then return b, n, turns end
    turtle.turnRight()
    if S and S.heading then S.heading = RIGHTD[S.heading]; saveJournal() end
  end
  return nil, nil, 0 -- full circle, no net rotation
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

-- "Bridge ON the turtle" supply (suck == "self"): an export lands directly in
-- my inventory, in whatever slot was free. Consolidate every stack of `name`
-- into the work slot so the build's fixed-slot logic still holds. Doubles as the
-- recover-stranded step (a kill between export and gather leaves the items in
-- me, so gathering first means the next restock never double-pulls).
local function gatherToSlot(slot, name)
  for s = 1, 16 do
    if s ~= slot then
      local d = turtle.getItemDetail(s)
      if d and d.name == name then
        turtle.select(s); turtle.transferTo(slot)
      end
    end
  end
  turtle.select(slot)
end

-- Collect a just-exported (or stranded) stack into `slot`, by whichever handoff
-- the wizard calibrated: a chest cell we suck, or straight into our inventory.
local function collectExport(slot, name)
  if cfg.base.suck == "self" then gatherToSlot(slot, name) else collectStaging(slot) end
end

-- Restock `slot` to >= minCount of spec.name from AE: park, recover any stranded
-- export, craft if AE can't cover the request (gate on OBSERVED stock, AM-2),
-- export a batch to the staging cell, suck it, return to the build cell. All AE
-- actions are machine-sourced - no fake-player path (Q2).
local function restock(slot, spec, minCount, batch)
  if not cfg.base.park then return false end
  batch = batch or 64
  local saved, savedHeading = copyPos(S.pos), S.heading
  intent("restock " .. spec.name)
  if not navSafe(cfg.base.park.x, cfg.base.park.y, cfg.base.park.z) then
    -- a blocked travel-ceiling corridor: be symmetric with every other restock
    -- exit (don't leave the turtle mid-corridor facing an arbitrary way with an
    -- orphaned intent) - navSafe back, restore the heading, clear the intent.
    navSafe(saved.x, saved.y, saved.z); faceTo(savedHeading); clearIntent()
    return false
  end
  -- FACE the bridge before reading it. A turtle reaches an adjacent peripheral
  -- only on a side it faces; navigation left me facing some other way, so a handle
  -- wrapped elsewhere silently reads an empty grid (the "AE has nothing" bug).
  -- Prefer the calibrated facing (faceTo journals it -> kill-safe); else turn
  -- until I find it. Both branches journal the facing (faceBridge updates
  -- S.heading like faceTo), so the heading is restored by the journaling
  -- faceTo(savedHeading) below - no raw "undo turns" that would re-desync the
  -- journal from the physical turtle on a kill (C5).
  if cfg.base.bridge_facing then
    faceTo(cfg.base.bridge_facing)
    bridge = findBridge()
    if not bridge then bridge = faceBridge() end -- calibrated facing stale? turn to find it
  else
    bridge = faceBridge()
  end
  if not bridge then
    -- Parked but no ME Bridge in reach. With the home/park fixed this means I
    -- genuinely can't touch it (drifted off the dock, or it moved) - say so loudly
    -- instead of bubbling up a cryptic "no-<item>", which sent us chasing the AE.
    print("farm: I went back to my dock to restock but the ME Bridge isn't in reach")
    print("  - I may have drifted off the dock, or it moved. I won't fake it.")
    navSafe(saved.x, saved.y, saved.z); faceTo(savedHeading); clearIntent()
    return false
  end
  -- Resolve which item to actually pull. Prefer a STOCKED item over an autocraft:
  -- a craft needs a free ME Crafting CPU + ingredients and can STALL (isCraftable
  -- only means a pattern EXISTS, not that the job will finish - this was the
  -- in-game "no-hoe": diamond_hoe showed craftable but the job never delivered).
  -- spec.alt lets a generic need accept any matching variant (ANY *_hoe tills),
  -- so a stocked stone hoe beats crafting the exact diamond. Order: exact-if-
  -- stocked -> alt-if-stocked -> exact-if-craftable -> alt-if-craftable.
  local target = spec.name
  if spec.alt then
    local function stocked(nm)
      local it = bridge.getItem({ name = nm })
      return it and (it.count or 0) > 0
    end
    if not stocked(target) then
      local altStocked
      for _, e in ipairs(bridge.getItems() or {}) do
        if type(e.name) == "string" and e.name:find(spec.alt, 1, true)
          and (e.count or 0) > 0 then altStocked = e.name; break end
      end
      if altStocked then
        target = altStocked
      elseif bridge.isCraftable({ name = target }) ~= true
        and bridge.getCraftableItems then
        for _, e in ipairs(bridge.getCraftableItems() or {}) do
          if type(e.name) == "string" and e.name:find(spec.alt, 1, true) then
            target = e.name; break
          end
        end
      end
    end
  end
  turtle.select(slot)
  collectExport(slot, target)
  local function slotCount()
    local d = turtle.getItemDetail(slot)
    return (d and d.name == target) and turtle.getItemCount(slot) or 0
  end
  -- Resolve the stocked count + the export filter for `target`. A {name=} lookup
  -- finds normal items; an NBT-keyed block (a frequency-coded ender chest) is
  -- missed by name, so fall back to the full list and pull by FINGERPRINT (the
  -- operator re-keys the chest after). Returns count, exportFilter.
  local function resolveStock()
    local it = bridge.getItem({ name = target })
    if it and (it.count or 0) > 0 then return it.count, { name = target } end
    local items = bridge.getItems()
    if type(items) == "table" then
      for _, e in ipairs(items) do
        if e.name == target and (e.count or 0) > 0 then
          return e.count, { fingerprint = e.fingerprint or e.name }
        end
      end
    end
    return 0, { name = target }
  end
  if slotCount() < minCount then
    local count, filter = resolveStock()
    -- craft only if observed AE stock can't cover the request and a pattern
    -- exists; never re-issue on a job id (idempotent on observed stock)
    if count < minCount and bridge.isCraftable({ name = target }) then
      local job, cerr = bridge.craftItem({ name = target, count = batch })
      if not job then
        -- AP returns nil + reason if the craft can't even be scheduled
        print(("farm: AE refused to craft %s (%s)."):format(target, tostring(cerr)))
      else
        local deadline = os.clock() + cfg.craft_timeout
        while select(1, resolveStock()) < minCount and os.clock() < deadline do
          os.sleep(0.5)
        end
        if select(1, resolveStock()) < minCount then
          -- the pattern exists but no item arrived: a STALLED job (no free ME
          -- Crafting CPU, or an ingredient isn't itself auto-craftable). Name it
          -- - a bare "no-X" sent the operator hunting blind every round.
          print(("farm: asked AE to craft %s but none arrived in %ds - the pattern "
            .. "exists but the job didn't finish (free ME Crafting CPU + "
            .. "ingredients?). Stock one instead, or hand me one.")
            :format(target, cfg.craft_timeout))
        end
      end
      count, filter = resolveStock()
    end
    local want = math.min(batch, count)
    if want >= minCount then
      filter.count = want
      local n = bridge.exportItem(filter, cfg.base.export_side or cfg.base.suck)
      trace(("export %s x%d via %s -> %s"):format(target, want,
        tostring(cfg.base.export_side or cfg.base.suck), tostring(n)))
      if n and n > 0 then collectExport(slot, target) end
    end
  end
  local got = slotCount()
  trace(("restock %s (want>=%d) -> have %d"):format(target, minCount, got))
  -- faceTo(savedHeading) journals the heading restoration from wherever the
  -- face-the-bridge turns left me (both branches updated S.heading), so a kill
  -- anywhere in here leaves the journal heading == the physical turtle.
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

-- ANY hoe tills, so accept any *_hoe in the slot and pull any hoe the AE can give
-- (the operator's exact diamond hoe may have no encoded autocraft pattern even
-- if they can craft it by hand). spec.alt = "_hoe" lets restock substitute.
local function isHoe(name) return type(name) == "string" and name:find("_hoe", 1, true) ~= nil end

local function ensureHoe()
  turtle.select(cfg.slots.hoe)
  local d = turtle.getItemDetail(cfg.slots.hoe, true)
  local hoeSpec = { name = cfg.items.hoe, alt = "_hoe" }
  -- restock() prefers a STOCKED *_hoe over an autocraft (a craft can stall). If
  -- even that fails, say EXACTLY what to do - a hoe in the slot is the surest fix
  -- and the build is journaled, so re-running 'farm' resumes from here.
  local function pull()
    local ok = restock(cfg.slots.hoe, hoeSpec, 1, 1)
    if not ok then
      print(("farm: no hoe available. Drop ANY *_hoe in my slot %d and run "
        .. "'farm' to resume, or stock/auto-craft one in AE."):format(cfg.slots.hoe))
    end
    return ok
  end
  if d and isHoe(d.name) then
    -- restock before the hoe breaks mid-plot (Q1: ~one till-op per soil cell).
    -- A worn hoe still occupies the slot, so evacuate it first so a fresh one
    -- can be pulled in.
    if d.maxDamage and (d.maxDamage - (d.damage or 0)) <= 1 then
      turtle.select(cfg.slots.hoe); turtle.dropUp() -- discard the worn hoe
      return pull()
    end
    return true
  end
  return pull()
end

-- ----------------------------------------------------------- build cells
-- Stance: the turtle stands one block ABOVE the target cell and works it with
-- placeDown (FARM-RESEARCH §build geometry). Each step is CONVERGE-style: it
-- inspects the cell FIRST and acts only on the observed-block delta, so the
-- journal names WHICH cell and the world decides WHAT op. "Redo this cell" is
-- the universal recovery, and a kill-redo never double-fertilizes or re-tills
-- (P0-2). intent() writes the mutating op to disk before it runs (C5).

local bp              -- loaded blueprint
local skipWarned = {} -- block ids we've already warned we're skipping (dedup)

local function nameBelow()
  local h, i = turtle.inspectDown()
  return h and i.name or nil
end

local FERTILIZED_SOIL = "farmingforblockheads:fertilized_farmland_healthy"

-- Till the dirt directly BELOW the current stance (cx, Y0+1, cz) by tilling it
-- from the SIDE. Vanilla HoeItem only converts dirt->farmland when the block
-- directly above the dirt is air (HoeItem.onlyIfAirAbove), and a CC turtle's own
-- block is never removed during place() (TurtlePlaceCommand only repositions a
-- fake player) - so a placeDown from the stance ABOVE the dirt sees the turtle's
-- own cell and silently no-ops (the in-game "plot N: till" halt). Instead, step
-- into a clear horizontal neighbour, drop to the soil layer, face back toward the
-- dirt, and till it as the block IN FRONT (its block above is now air). Returns
-- to the stance and restores the heading on success. Kill-safe: every move
-- journals S.pos, and a resume re-runs doSoil (tilling existing farmland is a
-- no-op), so a kill mid-side-till converges.
local function tillBelowFromSide()
  local saved = S.heading
  for _, dir in ipairs({ "north", "south", "east", "west" }) do
    faceTo(dir)
    -- the stance-level neighbour and the soil-level neighbour must both be clear
    if not turtle.detect() and goFwd() then
      if not turtle.detectDown() and goDown() then
        faceTo(OPPD[dir]) -- face back toward the dirt cell (now in front)
        turtle.select(cfg.slots.hoe)
        intent("till"); turtle.place(); clearIntent()
        local has, info = turtle.inspect()
        local tilled = has and (info.name == "minecraft:farmland"
          or info.name == FERTILIZED_SOIL)
        -- return to the stance: rise back to the stance layer, then step back
        -- into the stance column (we already face OPPD[dir], i.e. toward it)
        goUp(); goFwd()
        faceTo(saved)
        if tilled then return true end
      else
        -- could not drop beside the dirt: back out of the neighbour and try next
        faceTo(OPPD[dir]); goFwd(); faceTo(saved)
      end
    end
  end
  faceTo(saved)
  return false
end

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
    -- Till from the SIDE: a placeDown from this stance (one block ABOVE the dirt)
    -- can never till because the turtle's own block is the non-air block above
    -- the dirt (HoeItem.onlyIfAirAbove). tillBelowFromSide steps into a clear
    -- neighbour, drops beside the dirt, and tills it as the block in front.
    tillBelowFromSide()
    cur = nameBelow()
    -- a broken/vetoed hoe or no clear side leaves the cell un-tilled: halt
    -- loudly rather than silently reporting an un-tilled cell as done (P0-2)
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
  -- Evacuate a stranded spent bucket (minecraft:bucket) from the water slot FIRST
  -- - before any converge guard - so a kill that struck after the water
  -- materialized but before the bottom-of-function evac never leaves the slot
  -- occupied by the wrong item (which would block the NEXT water cell's restock
  -- and halt 'no-water'). Idempotent across kills and the water-already-present
  -- converge path (fix #4).
  do
    local d = turtle.getItemDetail(cfg.slots.water)
    if d and d.name ~= cfg.items.water then
      turtle.select(cfg.slots.water); turtle.dropUp()
    end
  end
  local cur = nameBelow()
  if cur == "minecraft:water" then return true end -- already placed (converge)
  if cur then return true end
  -- A placeDown water bucket braces only against the cell DIRECTLY BELOW the
  -- target (vertical deploy; Q1-water), so guarantee a solid sub-floor there:
  -- descend into the water cell, place a dirt block beneath if the cell below
  -- is open, then return to the stance. This is what makes water on a STACKED
  -- plot autonomous (the cell below is the prior plot's air center).
  if not navTo(S.pos.x, S.pos.y - 1, S.pos.z) then return false, "water-nav" end
  -- The brace must be SOLID: a fluid below reads detectDown()==false and a
  -- BlockItem can't be placed into a liquid, so a stacked water-over-water cell
  -- needs the fluid cleared and a dirt brace laid (the cell below is the prior
  -- plot's water source). inspectDown names a fluid (detect can't), so probe it.
  local has, info = turtle.inspectDown()
  local solidBelow = has and info.name ~= "minecraft:water"
    and info.name ~= "minecraft:lava"
  if not solidBelow then
    if not ensureItem(cfg.slots.dirt, { name = cfg.items.dirt }, 1) then
      navTo(S.pos.x, S.pos.y + 1, S.pos.z)
      return false, "no-subfloor"
    end
    if has then turtle.digDown() end -- clear the fluid so dirt can deploy
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
  -- ensureItem already auto-crafts anything the ME has a pattern for. If it
  -- still can't get this block, it's infrastructure the turtle can't reproduce -
  -- an NBT-keyed ender chest (your external harvest output), a frequency-keyed
  -- cable, a harvester pylon. SKIP it (loudly) instead of killing the whole
  -- build: the soil + crops + water (what actually grows sulfur) still get laid,
  -- and you place/wire the harvest blocks yourself (per the Phase-1 design,
  -- harvest is external). A converge re-run re-checks, so adding a pattern later
  -- + re-running fills it in.
  if not ensureItem(cfg.slots.block, { name = id }, 1) then
    if not skipWarned[id] then            -- warn once per id, not once per cell
      print("farm: skipping " .. id .. " (not in AE / no craft pattern) - "
        .. "place these yourself.")
      skipWarned[id] = true
    end
    broadcast{ state = "BUILD", skipped = id }
    return true
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
  trace(("cell %d,%d,%d kind=%s id=%s tier=%s"):format(dx, dy, dz, cell.kind,
    tostring(cell.id), tostring(cell.tier)))
  local ok, why
  if cell.kind == "soil" then ok, why = doSoil(cell.tier)
  elseif cell.kind == "crop" then ok, why = doCrop(cell.id)
  elseif cell.kind == "water" then ok, why = doWater()
  elseif cell.kind == "block" then ok, why = doBlock(cell.id)
  else ok = true end
  trace(("  -> %s%s"):format(ok and "ok" or "FAIL", why and (" " .. why) or ""))
  return ok, why
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
      -- till from the side: a placeDown from above never tills (the turtle's own
      -- block is the non-air block above the dirt; HoeItem.onlyIfAirAbove)
      tillBelowFromSide(); cur = belowName()
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

-- The corner column's highest blueprint-occupied layer (dy in [0,h-1]). A plot
-- is "complete" only when the world has a block at THIS dy of that plot - every
-- blueprint cell (soil->farmland, crop, water, infra block) leaves something
-- detectDown sees, so the top occupied cell present means the plot was finished
-- to its top layer, not just touched at the corner. nil if the corner column is
-- entirely air in the blueprint (an L-shaped plot whose min corner is empty).
local function cornerTopDy()
  local top
  for dy = 0, bp.size.h - 1 do
    if bp.cells[key(0, dy, 0)] then top = dy end
  end
  return top
end

-- On a FRESH build (no journal), an operator re-run over an already-built or
-- extended stack must not descend into a plot buried under finished plots above
-- it (navSafe can't pass through them) and must not re-converge a finished plot
-- (whose soil-layer stance is its own occupied crop layer). Count the COMPLETE
-- plots from the bottom up: a plot counts only when its TOP blueprint cell is
-- actually present at the corner column - so a stray block or a half-built layer
-- left by a prior failed run is NOT mistaken for a finished plot (the in-game
-- bug: one stray dirt at the build corner skipped the real build). resume at the
-- first plot that is not complete. A partial build keeps its journal and resumes
-- via that instead, so a fresh build only ever sees empty or completed plots
-- below the resume point.
local function skipBuiltPlots()
  if not navSafe(cfg.build.x, cfg.travel_y, cfg.build.z) then return end
  -- descend onto the TOP of the stack (the corner column is the built blocks, so
  -- the turtle can only reach the topmost solid block, not probe buried layers)
  while not turtle.detectDown() and S.pos.y > cfg.build.y do
    if not goDown() then break end
  end
  if not turtle.detectDown() then return end -- nothing built: stay at plot 0
  local h = bp.size.h
  local topY = S.pos.y - 1                       -- Y of the highest solid block
  local plotOfTop = math.floor((topY - cfg.build.y) / h)
  local dyOfTop = topY - cfg.build.y - plotOfTop * h
  local topDy = cornerTopDy()
  -- The highest solid block tells how far the prior run got. A plot is COMPLETE
  -- only when that block reaches the plot's TOP blueprint layer (topDy): a stray
  -- block or a half-built top layer sits at a LOWER dy, so its plot is NOT
  -- counted and the resume re-builds it (converge skips what's already there).
  -- Without a known topDy (an all-air corner column) fall back to "any block in
  -- a plot's span counts that plot built" - the old, less strict heuristic.
  local built
  if topDy and dyOfTop < topDy then
    built = plotOfTop                       -- top plot is partial: rebuild it
  else
    built = plotOfTop + 1                   -- top plot reached its top layer
  end
  built = math.min(math.max(built, 0), cfg.plots)
  S.plot, S.dy = built, 0
  if built >= cfg.plots then
    print("farm: stack already complete - nothing to build.")
  elseif built > 0 then
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
  -- The park/drop must be off the build stack, or every restock strands on the
  -- now-occupied park and the build mislabels it "no-seed" (fix #1). Relocate it
  -- along the bridge axis; if no safe cell exists, fail LOUDLY rather than build
  -- a plot that can never restock.
  if not relocatePark() then
    S.err = "park-in-stack"; saveJournal()
    print("farm: park is inside the build column - move the turtle/bridge off "
      .. "the stack (the drop cell can't be a build cell).")
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

-- ----------------------------------------------------------- setup wizard
-- First run with no farm.conf: discover everything and write the config, so the
-- operator only ever places the turtle + an ME Bridge and runs the installer.
-- Frame: the turtle's drop point is the origin (0,0,0); the found plot and the
-- build column are expressed relative to it, so no coordinates are ever typed.

local DEFAULT_PLOTS = 8

local function ptStr(t) return ("{ x = %d, y = %d, z = %d }"):format(t.x, t.y, t.z) end

local function serializeConf(c)
  local o = { "return {" }
  o[#o + 1] = ("  start = %s, start_heading = %q,"):format(ptStr(c.start), c.start_heading)
  o[#o + 1] = ("  origin = %s, size = { w = %d, h = %d, d = %d },")
    :format(ptStr(c.origin), c.size.w, c.size.h, c.size.d)
  o[#o + 1] = ("  heading = %q, scan_y = %d,"):format(c.heading, c.scan_y)
  o[#o + 1] = ("  build = %s, plots = %d, travel_y = %d,")
    :format(ptStr(c.build), c.plots, c.travel_y)
  o[#o + 1] = "  base = {"
  if c.base.bridge then o[#o + 1] = ("    bridge = %q,"):format(c.base.bridge) end
  o[#o + 1] = ("    park = %s, suck = %q, export_side = %q,")
    :format(ptStr(c.base.park), c.base.suck, c.base.export_side or c.base.suck)
  if c.base.bridge_facing then
    o[#o + 1] = ("    bridge_facing = %q,"):format(c.base.bridge_facing)
  end
  o[#o + 1] = "  },"
  o[#o + 1] = ("  fleet = %q,"):format(c.fleet or "farm1")
  o[#o + 1] = "}"
  return table.concat(o, "\n") .. "\n"
end

-- Discover how the ME Bridge hands materials to the turtle, so the operator can
-- place the bridge on any side of a chest the turtle sits on/under (the common
-- "turtle on a chest, bridge next to it" layout) without configuring a thing.
-- A real exportItem(filter, side) pushes into the inventory on THAT side of the
-- bridge; the turtle then sucks from the cell adjacent to itself. We probe each
-- export side and the two vertical suck dirs (down/up - heading-independent, so
-- they stay correct when restock re-parks) until a single probe item makes the
-- full round trip from AE into a turtle slot. Returns { export_side, suck } or
-- nil. A handful of probe items may be stranded on non-working sides; we prefer
-- dirt (cheap, always needed) so that one-time cost is negligible.
local CAL_EXPORT_SIDES = { "up", "down", "north", "south", "east", "west" }
local CAL_SUCK_DIRS = { "down", "up" }
local CAL_SLOT = 15  -- the scratch slot (conf.slots.scratch default)

local function calibrateSupply(bridge0)
  -- The caller (wizard) has already turned me to FACE the bridge - a turtle can
  -- only read an adjacent peripheral on a side it faces, so this whole probe runs
  -- while facing it; the wizard turns me back afterward.
  if not bridge0 then return nil, "no ME Bridge to calibrate against" end
  -- A probe to push through the handoff so we can see which side feeds the
  -- turtle. Prefer something already in stock (dirt, else anything); if the AE
  -- keeps NO raw stock (everything autocrafted on demand), craft one dirt - the
  -- build needs dirt anyway, so it isn't wasted.
  local function stockOf(name)
    local it = bridge0.getItem({ name = name })
    return it and it.count or 0
  end
  local probe
  if stockOf("minecraft:dirt") > 0 then
    probe = "minecraft:dirt"
  else
    for _, it in ipairs(bridge0.getItems() or {}) do
      if (it.count or 0) > 0 then probe = it.name; break end
    end
  end
  if not probe and bridge0.isCraftable({ name = "minecraft:dirt" }) then
    bridge0.craftItem({ name = "minecraft:dirt", count = 1 })
    local deadline = os.clock() + 60
    while stockOf("minecraft:dirt") < 1 and os.clock() < deadline do os.sleep(0.5) end
    if stockOf("minecraft:dirt") > 0 then probe = "minecraft:dirt" end
  end
  if not probe then
    return nil, "AE has nothing stocked or craftable (dirt) to probe the handoff"
  end
  local function countOf(name)
    local n = 0
    for s = 1, 16 do
      local d = turtle.getItemDetail(s)
      if d and d.name == name then n = n + turtle.getItemCount(s) end
    end
    return n
  end
  for _, side in ipairs(CAL_EXPORT_SIDES) do
    local before = countOf(probe)
    local n = bridge0.exportItem({ name = probe, count = 1 }, side)
    if n and n > 0 then
      -- did it land directly in my own inventory? (bridge mounted ON me)
      if countOf(probe) > before then return { export_side = side, suck = "self" } end
      -- else maybe it landed in a chest directly above/below me I can suck
      for _, dir in ipairs(CAL_SUCK_DIRS) do
        turtle.select(CAL_SLOT)
        local ok = (dir == "up" and turtle.suckUp()) or turtle.suckDown()
        if ok then
          local got = turtle.getItemDetail(CAL_SLOT)
          if got and got.name == probe then
            return { export_side = side, suck = dir }
          end
        end
      end
      -- exported but unreachable: the inventory on this side isn't mine and
      -- isn't a chest above/below me. The probe is stranded; keep probing.
    end
  end
  return nil, "the bridge isn't feeding me - mount it touching me, "
    .. "or put a chest above/below me with the bridge touching the chest"
end

local function runWizard(plotCount)
  print("farm: first run - setting myself up.")
  refuelFromInventory(2000) -- burn any starting coal so I can move to look around
  -- Check the ME Bridge FIRST, before any wandering: a missing bridge should
  -- fail instantly, not after I step around calibrating my heading (which looked
  -- like the turtle "moving to find the bridge").
  local bridge0, bridgeName = findBridge()
  if not bridge0 then
    print("farm: no ME Bridge found - mount one touching me (or wire it), reboot.")
    return false
  end
  print("farm: ME Bridge found (" .. tostring(bridgeName) .. ").")
  local p, heading
  if findScanner() then
    print("farm: looking for your sulfur plot...")
    local why
    p, why = findPlot()
    if not p then
      print("farm: couldn't find a plot (" .. tostring(why) .. ").")
      printPlotDiagnostic()
      print("  Fix that, then reboot. ('farm find' re-runs just this check.)")
      return false
    end
    heading, why = calibrateHeading()
    if not heading then
      print("farm: couldn't work out my facing (" .. tostring(why) .. ").")
      return false
    end
  else
    -- no scanner: walk a bounded spiral and inspect down (Task #18)
    print("farm: no Geo Scanner - searching for the plot on foot...")
    local hp, herr = searchPlot()
    if not hp then
      print("farm: couldn't find a plot on foot (" .. tostring(herr) .. ").")
      print("  Set me ON TOP of the farm, or equip a Geo Scanner, then reboot.")
      return false
    end
    p, heading = hp, "north"
  end
  print(("farm: found a %dx%d plot (h=%d)."):format(p.w, p.d, p.h))
  print("farm: I'm facing " .. heading .. ".")
  -- I can only read the bridge while FACING it (a turtle reaches an adjacent
  -- peripheral only on a side it faces). Turn to face it, probe the handoff while
  -- facing it, record that facing (so restock re-faces it, kill-safe), turn back.
  local fb, _, fbTurns = faceBridge()
  local bridgeFacing = heading
  for _ = 1, fbTurns do bridgeFacing = RIGHTD[bridgeFacing] end
  local sup, serr
  if fb then
    print("farm: I read the ME Bridge when I face " .. bridgeFacing .. ".")
    sup, serr = calibrateSupply(fb)
  else
    serr = "couldn't get the bridge onto a side I can read"
  end
  for _ = 1, fbTurns do turtle.turnLeft() end -- back to my plot heading
  if sup then
    if sup.suck == "self" then
      print(("farm: supply calibrated - bridge on my %s feeds me directly.")
        :format(sup.export_side))
    else
      print(("farm: supply calibrated (export %s -> suck %s).")
        :format(sup.export_side, sup.suck))
    end
  else
    -- fall back to the classic chest-directly-below-me handoff; the self-test
    -- still proves the AE pull before any real plot, so a wrong guess aborts
    -- loudly rather than building blind
    print("farm: couldn't auto-calibrate the bridge handoff (" .. tostring(serr)
      .. "); assuming a chest directly below me.")
    sup = { export_side = "up", suck = "down" }
  end
  plotCount = plotCount or DEFAULT_PLOTS
  -- Align the stack over a ground-floor ender chest (the harvest anchor of each
  -- plot) so copies sit centred over it - not at the arbitrary bbox corner.
  local bx, bz = p.rx, p.rz
  local anchor = findEnderChest()
  if anchor then
    bx = anchor.x - math.floor(p.w / 2)
    bz = anchor.z - math.floor(p.d / 2)
    print("farm: aligning the stack centred over an ender chest.")
  end
  -- drop frame: turtle = (0,0,0); the plot + build column hang off it
  local gen = {
    start = { x = 0, y = 0, z = 0 }, start_heading = heading, heading = heading,
    origin = { x = p.rx, y = p.ry, z = p.rz },
    size = { w = p.w, h = p.h, d = p.d }, scan_y = p.ry + p.h + 1,
    build = { x = bx, y = p.ry + p.h, z = bz }, plots = plotCount,
    travel_y = p.ry + p.h + plotCount * p.h + 4,
    base = { bridge = bridgeName, park = { x = 0, y = 0, z = 0 },
      suck = sup.suck, export_side = sup.export_side, bridge_facing = bridgeFacing },
    fleet = "farm1",
  }
  writeFile(CONF_PATH, serializeConf(gen))
  cfg = loadConf() -- reload through the defaulter (items/cadence/etc.)
  -- The stack is centred over a ground-floor ender chest, so the drop column
  -- (0,0,0) can sit INSIDE the build footprint. Slide the park off the stack now
  -- and persist it, so the build never strands a restock on its own park (fix #1).
  if parkInFootprint(cfg.base.park) then
    if relocatePark() then
      gen.base.park = cfg.base.park
      writeFile(CONF_PATH, serializeConf(gen))
      print(("farm: park kept off the build stack at %d,%d,%d.")
        :format(gen.base.park.x, gen.base.park.y, gen.base.park.z))
    else
      print("farm: WARNING - couldn't keep the park off the build stack; move "
        .. "the turtle/bridge so the drop cell isn't a build cell.")
    end
  end
  print(("farm: configured. Stacking %d copies above your plot."):format(plotCount))
  print("farm: capturing your plot...")
  S = { pos = { x = 0, y = 0, z = 0 }, heading = heading, phase = "capture" }
  if not navTo(cfg.origin.x, cfg.scan_y, cfg.origin.z) then
    print("farm: couldn't reach the plot to scan it (something in the way).")
    return false
  end
  if not capture() then return false end
  -- Home to the dock for the build via navSafe (rise to the clear travel ceiling,
  -- move across, descend onto the dock column) - NOT navTo, whose vertical-first
  -- descent walks straight DOWN into the plot I just captured, jams, and leaves me
  -- stranded over the plot. boot() then assumes I'm at the dock (0,0,0) and the
  -- whole build dead-reckons from a frame that's OFFSET by however far I'm stuck -
  -- so every restock "returns to the bridge" at the wrong real cell and dies
  -- no-hoe. If even navSafe can't get home, ABORT (don't build from a bad frame).
  if not navSafe(cfg.start.x, cfg.start.y, cfg.start.z) then
    print("farm: scanned the plot but couldn't get back to my dock (path blocked).")
    print("  I won't build from a guessed position. Clear the route / set me beside")
    print("  the bridge, then re-run 'farm'.")
    return false
  end
  -- Leave me physically facing the heading boot() will assume. There is no
  -- journal yet (the wizard does not journal), so the fresh build dead-reckons
  -- from cfg.heading; capture's last move can leave me facing any direction, so
  -- square up now or the whole stack builds rotated.
  faceTo(cfg.start_heading or cfg.heading)
  return true
end

-- ---------------------------------------------------------------- main

local args = { ... }
local cmd = args[1]

-- `farm reset`: wipe my generated state (config / blueprint / journal) back to
-- first-run, for when a setup went wrong. `update` refreshes the program but
-- never touches these, so this is the clean slate. Leaves startup.lua alone.
if cmd == "reset" then
  for _, f in ipairs({ CONF_PATH, BLUEPRINT, JOURNAL_PATH, JOURNAL_PATH .. ".bak" }) do
    if fs.exists(f) then fs.delete(f) end
  end
  print("farm: reset - cleared config, blueprint, and journal.")
  print("  run 'farm' to set up from scratch.")
  return
end

-- Hold / inspect mode. The installer's startup.lua runs `farm` on EVERY boot, so
-- the turtle takes off before the operator can read `farm ae` / `farm capture`.
-- `farm hold` parks it at the shell; `farm go` builds; `farm release` clears the
-- hold. On a bare boot the turtle also offers a brief window to grab it with a
-- keypress - but only on a FRESH start, so a chunk-reload kill-resume (journal on
-- disk) keeps building unattended.
local HOLD_PATH = "farm.hold"
if cmd == "hold" then
  writeFile(HOLD_PATH, "held\n")
  print("farm: HELD - I won't auto-build on boot.")
  print("  inspect freely: 'farm ae', 'farm capture', 'farm find'.")
  print("  then 'farm go' to build, or 'farm release' to just clear the hold.")
  return
end
if cmd == "release" then
  if fs.exists(HOLD_PATH) then fs.delete(HOLD_PATH) end
  print("farm: hold cleared. Run 'farm' (or reboot) to build.")
  return
end
local explicitGo = (cmd == "go")
if explicitGo then
  if fs.exists(HOLD_PATH) then fs.delete(HOLD_PATH) end
  cmd = nil -- fall through to the normal auto-start (wizard / build) path
end
if cmd == nil and not explicitGo then
  if fs.exists(HOLD_PATH) then
    print("farm: HELD - not auto-building. 'farm go' to build, 'farm release' to clear.")
    return
  end
  if not fs.exists(JOURNAL_PATH) then
    print("farm: auto-building in 3s - press any key to HOLD (inspect first).")
    local timer = os.startTimer(3)
    while true do
      local ev, a = os.pullEvent()
      if ev == "timer" and a == timer then break end
      if ev == "key" or ev == "char" then
        writeFile(HOLD_PATH, "held\n")
        print("farm: HELD. Inspect freely; 'farm go' to build, 'farm release' to clear.")
        return
      end
    end
  end
end

-- `farm log`: the persistent debug log (everything the turtle printed, capped).
-- No arg shows its size + tail + how to share it; `on`/`off` toggle the verbose
-- step trace; `clear` wipes it. The display uses the raw print so that reading
-- the log doesn't append to it.
if cmd == "log" then
  local sub = args[2]
  if sub == "on" then
    writeFile(VERBOSE_FLAG, "on\n")
    print("farm: verbose logging ON - every move/build/AE step traces to " .. LOG_PATH .. ".")
    return
  elseif sub == "off" then
    if fs.exists(VERBOSE_FLAG) then fs.delete(VERBOSE_FLAG) end
    print("farm: verbose logging OFF (prints are still mirrored to " .. LOG_PATH .. ").")
    return
  elseif sub == "clear" then
    print("farm: log cleared.")
    fs.delete(LOG_PATH) -- wipes the line just mirrored too: a truly fresh log
    return
  end
  local size = (fs.exists(LOG_PATH) and fs.getSize) and fs.getSize(LOG_PATH) or 0
  _print(("farm log: %s  (%d bytes, verbose=%s)"):format(
    LOG_PATH, size, VERBOSE and "ON" or "off"))
  if fs.exists(LOG_PATH) then
    local f = fs.open(LOG_PATH, "r"); local all = f.readAll(); f.close()
    local lines = {}
    for ln in (all .. "\n"):gmatch("([^\n]*)\n") do
      if ln ~= "" then lines[#lines + 1] = ln end
    end
    _print("  --- last lines ---")
    for i = math.max(1, #lines - 12), #lines do _print("  " .. lines[i]) end
  end
  _print("  share it with me:  pastebin put " .. LOG_PATH)
  _print("  'farm log on|off' toggles the step trace; 'farm log clear' wipes it.")
  return
end

-- `farm find`: a no-config dry run of the autonomous plot-find, so the operator
-- can confirm the turtle sees their plot before committing to a build.
-- `farm ae`: prove the AE link. Reports the bridge connection/energy, how many
-- item types its grid exposes (0 = the bridge is NOT joined to your network),
-- whether dirt is there, and whether a real export actually reaches the turtle.
if cmd == "ae" then
  local b, bname = findBridge()
  if not b then
    print("farm: no ME Bridge found - mount one ON me (or wire it), reboot.")
    return
  end
  print("farm: bridge = " .. tostring(bname))
  local function try(m, ...)
    if type(b[m]) ~= "function" then return "(no " .. m .. ")" end
    local ok, r = pcall(b[m], ...)
    return ok and r or ("ERR:" .. tostring(r))
  end
  print("  connected=" .. tostring(try("isConnected"))
    .. " online=" .. tostring(try("isOnline")))
  print("  energy=" .. tostring(try("getStoredEnergy"))
    .. "/" .. tostring(try("getEnergyCapacity")))
  local items = try("getItems")
  if type(items) == "table" then
    print("  grid item types: " .. #items)
    for i = 1, math.min(6, #items) do
      print(("    %s x%s"):format(tostring(items[i] and items[i].name),
        tostring(items[i] and items[i].count)))
    end
  else
    print("  getItems -> " .. tostring(items))
  end
  local d = try("getItem", { name = "minecraft:dirt" })
  if type(d) == "table" then
    print(("  dirt: count=%s craftable=%s")
      :format(tostring(d.count), tostring(d.isCraftable)))
  else
    print("  dirt: " .. tostring(d) .. " (NOT in the grid)")
  end
  -- hoes: the build needs ANY hoe (stocked or AE-craftable). List what's there.
  local dh = try("getItem", { name = "minecraft:diamond_hoe" })
  print(("  diamond_hoe: %s"):format(type(dh) == "table"
    and ("count=" .. tostring(dh.count) .. " craftable=" .. tostring(dh.isCraftable))
    or "not in the grid"))
  local hoes = {}
  for _, e in ipairs(type(try("getItems")) == "table" and try("getItems") or {}) do
    if type(e.name) == "string" and e.name:find("_hoe", 1, true) then
      hoes[#hoes + 1] = e.name .. " x" .. tostring(e.count)
    end
  end
  for _, e in ipairs(type(try("getCraftableItems")) == "table"
    and try("getCraftableItems") or {}) do
    if type(e.name) == "string" and e.name:find("_hoe", 1, true) then
      hoes[#hoes + 1] = e.name .. " (craftable)"
    end
  end
  print("  hoes I could use: " .. (#hoes > 0 and table.concat(hoes, ", ") or "NONE"))
  -- proof-of-pull: export 1 dirt to each side; did it actually reach me?
  local function invCount()
    local n = 0
    for s = 1, 16 do n = n + turtle.getItemCount(s) end
    return n
  end
  local before, pulled = invCount(), false
  for _, side in ipairs(CAL_EXPORT_SIDES) do
    local n = try("exportItem", { name = "minecraft:dirt", count = 1 }, side)
    if type(n) == "number" and n > 0 then
      if invCount() > before then
        print("  PULL OK: export '" .. side .. "' landed dirt in me.")
        pulled = true; break
      end
      turtle.select(15)
      if turtle.suckDown() or turtle.suckUp() then
        print("  PULL OK: export '" .. side .. "' -> chest, sucked it.")
        pulled = true; break
      end
    end
  end
  if not pulled then
    print("  PULL FAILED: couldn't get dirt out of the bridge.")
    print("  grid item types 0 => the bridge isn't on your AE network")
    print("  (needs power + a channel + the cross-dim link). Fix that first.")
  end
  -- Craft probe: the dirt pull only proves exporting STOCKED items. A PATTERN
  -- existing (isCraftable=true) does NOT mean the job will FINISH - that needs a
  -- free ME Crafting CPU + ingredients. Actually run the hoe craft the build
  -- depends on, so a stalled autocraft (the in-game "no-hoe") is visible HERE in
  -- one shot, instead of only when the build halts.
  local hoeName = (cfg and cfg.items and cfg.items.hoe) or "minecraft:diamond_hoe"
  local hoeSlot = (cfg and cfg.slots and cfg.slots.hoe) or 2
  local h0 = type(b.getItem) == "function" and b.getItem({ name = hoeName }) or nil
  if type(h0) == "table" and (h0.count or 0) > 0 then
    print(("  craft probe: skipped - %s already stocked (count %s)."):format(
      hoeName, tostring(h0.count)))
  elseif type(h0) == "table" and h0.isCraftable then
    print("  craft probe: crafting " .. hoeName .. " (the build needs a hoe)...")
    local ok, job, cerr = pcall(b.craftItem, { name = hoeName, count = 1 })
    if not ok then
      print("  craft probe: craftItem ERRORED (" .. tostring(job) .. ").")
    elseif not job then
      print("  craft probe: AE refused the craft (" .. tostring(cerr) .. ").")
    else
      local deadline = os.clock() + 15
      while os.clock() < deadline do
        local it = b.getItem({ name = hoeName })
        if it and (it.count or 0) > 0 then break end
        os.sleep(0.5)
      end
      local it = b.getItem({ name = hoeName })
      if it and (it.count or 0) > 0 then
        print(("  craft probe: OK - AE crafted %s (count %s)."):format(
          hoeName, tostring(it.count)))
      else
        print("  craft probe: STALLED - pattern exists but nothing crafted in 15s.")
        print("  => no free ME Crafting CPU or a missing ingredient.")
        print(("     Stock a hoe, or drop one in my slot %d instead."):format(hoeSlot))
      end
    end
  else
    print(("  craft probe: %s is neither stocked nor craftable here."):format(hoeName))
  end
  return
end

if cmd == "find" then
  local radius = tonumber(args[2]) or SCAN_RADIUS
  local p, why = findPlot(radius)
  if p then
    print(("farm: found a %dx%d plot (h=%d) from %d signature blocks.")
      :format(p.w, p.d, p.h, p.blocks))
    print(("  min corner is x%+d y%+d z%+d relative to me.")
      :format(p.rx, p.ry, p.rz))
    return
  end
  print("farm: no plot found (" .. tostring(why) .. ").")
  printPlotDiagnostic(radius)
  return
end

-- First run with no config: discover everything and write farm.conf, then fall
-- through to the build. After this, a reboot has a config and resumes normally.
if not cfg and (cmd == nil or cmd == "setup") then
  if not runWizard(tonumber(args[2])) then return end
  cmd = nil
end

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
  print("usage: farm [setup|build|capture|selftest|ae|find|reset]")
  print("       farm hold | go | release   (park before it auto-builds)")
  print("       farm log [on|off|clear]    (debug log -> pastebin put farm.log)")
  return
end
