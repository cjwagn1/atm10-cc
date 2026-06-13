--[[
sled.lua - self-relocating Digital Miner skid controller (Project Sled v1)

A turtle parked under a Mekanism Digital Miner mines copper in the ATM10
mining dimension; when the miner exhausts its targets the turtle breaks the
skid (miner + two Quantum Entangloporters), walks `spacing` blocks along a
straight lane, rebuilds it, and starts mining again. State is journaled
write-ahead to disk so a chunk unload / server restart at ANY moment (the
routine daily event: the computer is killed, not paused — claim C4) resumes
cleanly at next boot via observation-driven reconciliation (SLED-DESIGN §5).

Commands:
  sled              resume from the journal (what startup.lua runs)
  sled start        begin mining at the current park (skid must be placed)
  sled commission   place + converge-configure the skid, verify, report

Design + claims ledger: docs/SLED-DESIGN.md, docs/RESEARCH.md ("Project
Sled"). Every peripheral method called here is cited there (A1/N1/N1b).
No rate/duration constants appear in logic (executive amendment AM-2):
cadence/spacing/thresholds come from sled.conf, mining rate is measured
from getToMine() deltas, fuel-per-item is measured at refuel time.
]]

local CONF_PATH = "sled.conf"
local JOURNAL_PATH = "sled.journal"
local PROTOCOL = "telemetry"
local CTL_PROTOCOL = "sledctl"

local DIRV = {
  north = { x = 0, z = -1 }, south = { x = 0, z = 1 },
  east = { x = 1, z = 0 }, west = { x = -1, z = 0 },
}
local LEFTD = { north = "west", west = "south", south = "east", east = "north" }
local RIGHTD = { north = "east", east = "south", south = "west", west = "north" }
local OPPD = { north = "south", south = "north", east = "west", west = "east" }
local LETTER = { north = "N", south = "S", east = "E", west = "W" }

-- ------------------------------------------------------------------ config

local function loadConf()
  local f = fs.open(CONF_PATH, "r")
  if not f then return nil end
  local txt = f.readAll()
  f.close()
  local chunk = load(txt, "=sled.conf", "t", {})
  if not chunk then return nil end
  local ok, conf = pcall(chunk)
  if not ok or type(conf) ~= "table" then return nil end
  conf.slots = conf.slots or {}
  conf.slots.miner = conf.slots.miner or 1
  conf.slots.qe_energy = conf.slots.qe_energy or 2
  conf.slots.qe_item = conf.slots.qe_item or 3
  conf.slots.fuel = conf.slots.fuel or 4
  conf.slots.marker = conf.slots.marker or 5
  conf.slots.scratch = conf.slots.scratch or 8
  conf.cadence = conf.cadence or 5
  -- defaults follow the runbook's zero-server-change plan: radius 16 =
  -- 3x3 chunk footprint per station within FTB's default 25-chunk
  -- force-load budget (N3); spacing = 2*radius
  conf.spacing = conf.spacing or 32
  conf.stations_per_leg = conf.stations_per_leg or 20
  conf.fuel_low = conf.fuel_low or 1000
  conf.fuel_reserve = conf.fuel_reserve or 200
  -- commissioning targets (D2: copper band Y 65..247, tag covers stone +
  -- deepslate variants; silk OFF — silk costs x12 energy, A4)
  conf.miner = conf.miner or {}
  if conf.miner.radius == nil then conf.miner.radius = 16 end
  if conf.miner.min_y == nil then conf.miner.min_y = 65 end
  if conf.miner.max_y == nil then conf.miner.max_y = 247 end
  if conf.miner.silk == nil then conf.miner.silk = false end
  if conf.miner.auto_eject == nil then conf.miner.auto_eject = true end
  if conf.miner.tag == nil then conf.miner.tag = "c:ores/copper" end
  conf.frequency_mode = conf.frequency_mode or "verify"
  return conf
end

local function copyPos(p) return { x = p.x, y = p.y, z = p.z } end

local cfg = loadConf()

-- ----------------------------------------------------------------- journal

-- S is the live state, mirrored to disk on every change. Write-ahead rule:
-- `intent` is written BEFORE the action it names executes (C5), so a boot
-- that finds an intent knows the world is in one of exactly two states.
local S

local function writeJournalTo(path)
  local f = fs.open(path, "w")
  f.write("state=" .. S.state .. "\n")
  if S.mode then f.write("mode=" .. S.mode .. "\n") end
  f.write("station=" .. S.station .. "\n")
  if S.step then f.write("step=" .. S.step .. "\n") end
  f.write("pos=" .. S.pos.x .. "," .. S.pos.y .. "," .. S.pos.z .. "\n")
  f.write("heading=" .. S.heading .. "\n")
  if S.marker then f.write("marker=" .. S.marker .. "\n") end
  if S.intent then f.write("intent=" .. S.intent .. "\n") end
  if S.err then f.write("err=" .. S.err .. "\n") end
  f.close()
end

local function saveJournal() writeJournalTo(JOURNAL_PATH) end

-- A torn journal write (kill mid-save; C5 accepted risk) must not strand
-- the sled with "no journal": a backup is written at every STEP boundary,
-- and the recovery probes tolerate its one-step staleness by design.
local function saveBak() writeJournalTo(JOURNAL_PATH .. ".bak") end

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
  if not j.state or not j.pos then return nil end
  local x, y, z = j.pos:match("^(-?%d+),(-?%d+),(-?%d+)$")
  if not x then return nil end
  if j.state ~= "MINING" and j.state ~= "RELOCATE"
    and j.state ~= "RECOVER" then return nil end
  return {
    state = j.state, station = tonumber(j.station) or 0,
    step = j.step, heading = j.heading, marker = j.marker,
    intent = j.intent, err = j.err, mode = j.mode,
    pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) },
  }
end

local function readJournal()
  return parseJournal(JOURNAL_PATH)
    or parseJournal(JOURNAL_PATH .. ".bak")
end

-- -------------------------------------------------------------- geometry

local function stationPark(n)
  local v = DIRV[cfg.heading]
  return { x = cfg.origin.x + v.x * cfg.spacing * n, y = cfg.origin.y,
    z = cfg.origin.z + v.z * cfg.spacing * n }
end

-- ------------------------------------------------------------- movement

-- One journaled move in an absolute direction. The intent line goes to
-- disk BEFORE the turtle command (C5 write-ahead); position advances only
-- on success. Horizontal moves opposite the current heading use back() so
-- the heading never changes outside explicit turns.
local function jmove(absdir)
  S.intent = "M " .. absdir
  saveJournal()
  local ok, err
  if absdir == "up" then ok, err = turtle.up()
  elseif absdir == "down" then ok, err = turtle.down()
  elseif absdir == S.heading then ok, err = turtle.forward()
  elseif absdir == OPPD[S.heading] then ok, err = turtle.back()
  else
    S.intent = nil
    saveJournal()
    error("jmove: " .. absdir .. " is not reachable without a turn", 2)
  end
  if ok then
    if absdir == "up" then S.pos.y = S.pos.y + 1
    elseif absdir == "down" then S.pos.y = S.pos.y - 1
    else
      S.pos.x = S.pos.x + DIRV[absdir].x
      S.pos.z = S.pos.z + DIRV[absdir].z
    end
  end
  S.intent = nil
  saveJournal()
  return ok, err
end

local function fwd() return jmove(S.heading) end
local function bk() return jmove(OPPD[S.heading]) end

local function turnTo(dir)
  while S.heading ~= dir do
    if LEFTD[S.heading] == dir then
      turtle.turnLeft()
      S.heading = dir
    else
      turtle.turnRight()
      S.heading = RIGHTD[S.heading]
    end
    saveJournal()
  end
end

-- --------------------------------------------------------- peripherals

local function openModems()
  local opened = false
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType and peripheral.hasType(n, "modem") then
      if pcall(rednet.open, n) then opened = true end
    end
  end
  return opened
end

-- The capability cache refreshes exactly one tick after a world change
-- (C3) — a getType immediately after the turtle moves sees the OLD cell.
-- Where the question is "is there already a peripheral here", settle two
-- ticks first; the refresh is guaranteed, not racy.
local function settledType(side)
  sleep(0.1)
  return peripheral.getType(side)
end

-- Re-wrap on every use: stale handles silently return nil (C3); a nil
-- from any call means re-check, never trust a cached table.
local function minerOnTop()
  if peripheral.getType("top") ~= "digitalMiner" then return nil end
  return peripheral.wrap("top")
end

-- After a place: wait for the attach event with a timeout (C3: attach is
-- guaranteed exactly one tick after placement, so an event wait plus one
-- settled re-read is sufficient). Deliberately NO turn-rescan here: a
-- kill between the turns of a rescan pair would leave the heading
-- untracked with no anchor to recover it from — the manual turn-rescan
-- stays a human rescue tool only [design, phase-2 kill-sweep finding].
local function waitAttach(side, wantType)
  if peripheral.getType(side) == wantType then return true end
  local tm = os.startTimer(2)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "peripheral" and ev[2] == side then
      if peripheral.getType(side) == wantType then return true end
    elseif ev[1] == "timer" and ev[2] == tm then
      break
    end
  end
  return settledType(side) == wantType
end

-- ------------------------------------------------------------ telemetry

local lastTargets = 0

-- Empirical mining rate (AM-2): blocks/second measured from getToMine()
-- deltas over real (tick-clock) time. No base-rate constant exists here —
-- speed upgrades on the miner simply show up as a bigger measured rate.
local rateSamples = {}
local function noteSample(toMine)
  local s = rateSamples
  s[#s + 1] = { t = os.clock(), v = toMine }
  if #s > 12 then table.remove(s, 1) end
end
local function measuredRate()
  local s = rateSamples
  if #s < 2 then return nil end
  local a, b = s[1], s[#s]
  if b.t <= a.t or b.v > a.v then return nil end -- re-scan grew the count
  return (a.v - b.v) / (b.t - a.t)
end

local function fmtSpan(sec)
  if sec ~= sec or sec < 0 or sec >= 999 * 86400 then return nil end
  if sec < 60 then return ("%ds"):format(math.floor(sec)) end
  if sec < 3600 then return ("%dm"):format(math.floor(sec / 60)) end
  if sec < 48 * 3600 then
    return ("%dh %dm"):format(math.floor(sec / 3600),
      math.floor(sec % 3600 / 60))
  end
  return ("%dd %dh"):format(math.floor(sec / 86400),
    math.floor(sec % 86400 / 3600))
end

local function broadcast(extra)
  extra = extra or {}
  local data = {
    state = S.state,
    step = extra.step or S.step or "",
    pos = S.pos.x .. "," .. S.pos.y .. "," .. S.pos.z
      .. " " .. (LETTER[S.heading] or "?"),
    hops = S.station,
    fuel = turtle.getFuelLevel(),
    targets = extra.targets or lastTargets,
    miner = extra.miner or 0,
    err = S.err,
    warn = extra.warn,
    rate = extra.rate,
    eta = extra.eta,
    jpt = extra.jpt,
  }
  pcall(rednet.broadcast,
    { v = 1, source = cfg.fleet, tick = os.clock(), data = data }, PROTOCOL)
end

-- ----------------------------------------------------- control channel

local function runUpdater()
  -- file transfer stays wget-from-GitHub: the standard updater re-fetches
  -- the manifest and reboots (AM-5); rednet only carries the command
  if shell and shell.run then
    broadcast{ step = "updating" }
    shell.run("update")
  end
end

local function handleCtl(_, msg)
  if type(msg) ~= "table" then return end
  -- courtesy lock, not cryptography (AM-5). No configured token means the
  -- remote channel is DISABLED — never "accepts the empty token".
  if not cfg.token or msg.token ~= cfg.token then return end
  if msg.cmd == "update" then runUpdater() end
end

-- Sleep `secs` while staying responsive to sledctl commands. The timer is
-- re-armed from a deadline after every command, so a long handleCtl (a
-- failed update fetch eats events inside http.get) cannot wedge the loop.
local function waitCadence(secs)
  local deadline = os.clock() + secs
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then return end
    local tm = os.startTimer(remaining)
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == tm then
      return
    elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL then
      handleCtl(ev[2], ev[3])
    end
  end
end

-- ----------------------------------------------------------- inventory

local function markerName()
  if S.marker then return S.marker end
  local d = turtle.getItemDetail(cfg.slots.marker)
  return d and d.name or nil
end

-- Establish the station anchor: a marker block in the ground directly
-- below the park. Placed at station ESTABLISHMENT (not just before
-- TRAVEL) so every later step of the cycle can re-localize on it
-- [design, phase-2 amendment to §6].
local function ensureMarker()
  local d = turtle.getItemDetail(cfg.slots.marker)
  if not d then return end
  S.marker = d.name
  local has, info = turtle.inspectDown()
  if has and info.name == S.marker then
    saveJournal()
    return
  end
  if has then
    turtle.select(cfg.slots.scratch) -- surface block goes to the scratch slot
    turtle.digDown()
  end
  turtle.select(cfg.slots.marker)
  turtle.placeDown()
  saveJournal()
end

-- Refuel to `target` measuring fuel-per-item empirically (S3: the pack can
-- override burn values; AM-2: no constants in logic).
local function refuelTo(target)
  turtle.select(cfg.slots.fuel)
  local level = turtle.getFuelLevel()
  if level >= target then return true end
  if turtle.getItemCount(cfg.slots.fuel) == 0 then return false end
  if not turtle.refuel(1) then return false end
  local per = turtle.getFuelLevel() - level
  if per <= 0 then return false end
  local need = math.ceil((target - turtle.getFuelLevel()) / per)
  if need > 0 then
    turtle.refuel(math.min(need, turtle.getItemCount(cfg.slots.fuel)))
  end
  return turtle.getFuelLevel() >= target
end

-- ------------------------------------------------------ RELOCATE steps
-- Step bodies are CONVERGE-style: each observes the world and does only
-- what is missing, so "redo step from the start" is the universal
-- reconciliation action after a mid-step reboot (§5 rows become guards).
-- Each returns true, or nil + a RECOVER reason from the §9 catalog.

local function recoverDrop(slot, suckDir)
  if turtle.getItemCount(slot) > 0 then return true end
  for _ = 1, 3 do
    if suckDir == "up" then turtle.suckUp() else turtle.suck() end
    if turtle.getItemCount(slot) > 0 then return true end
    sleep(1)
  end
  return false
end

-- Bounded, undoing navigation [phase 2.1]: each move is retried, and on
-- persistent failure the completed moves are reversed so the turtle is
-- back where it started before reporting RECOVER "blocked" — a blocked
-- path must never lead to acting on the wrong cell (the cell straight
-- above the park is the miner MAIN BLOCK).
local function tryMoves(moves)
  local done = {}
  for _, mv in ipairs(moves) do
    local ok
    for _ = 1, 3 do
      ok = mv[1]()
      if ok then break end
      sleep(1)
    end
    if not ok then
      for i = #done, 1, -1 do done[i][2]() end
      return false
    end
    done[#done + 1] = mv
  end
  return true
end

local MOVE_OUT = { fwd, bk }
local MOVE_BACKHOME = { bk, fwd }
local MOVE_UP = { function() return jmove("up") end,
  function() return jmove("down") end }
local MOVE_DOWN = { function() return jmove("down") end,
  function() return jmove("up") end }

local function qeNavOut(which)
  if which == "E" then
    turnTo(cfg.lateral)
    if not tryMoves({ MOVE_OUT, MOVE_OUT }) then
      turnTo(cfg.heading)
      return false
    end
  else
    if not tryMoves({ MOVE_OUT, MOVE_OUT, MOVE_UP }) then return false end
  end
  return true
end

-- best effort: a failed homeward leg is healed by relocalize at next boot
local function qeNavHome(which)
  if which == "E" then
    tryMoves({ MOVE_BACKHOME, MOVE_BACKHOME })
    turnTo(cfg.heading)
  else
    tryMoves({ MOVE_DOWN, MOVE_BACKHOME, MOVE_BACKHOME })
  end
end

local function stepBreakQE(which)
  local slot = which == "E" and cfg.slots.qe_energy or cfg.slots.qe_item
  if not qeNavOut(which) then return nil, "blocked" end
  turtle.select(slot)
  local ok, reason = true, nil
  local has, info = turtle.inspectUp()
  if has and info.name == "mekanism:quantum_entangloporter" then
    turtle.digUp()
  elseif has then
    ok, reason = nil, "reconcile" -- unexpected block: never dig blind
  end
  if ok and not recoverDrop(slot, "up") then ok, reason = nil, "lostdrop" end
  qeNavHome(which)
  return ok, reason
end

local function stepBreakMiner()
  turtle.select(cfg.slots.miner)
  local has, info = turtle.inspectUp()
  if has and info.name == "mekanism:digital_miner" then
    local ok = turtle.digUp()
    if not ok then return nil, "protected" end
  elseif has then
    return nil, "reconcile" -- unexpected block above the park [2.1]
  end
  if not recoverDrop(cfg.slots.miner, "up") then return nil, "lostdrop" end
  return true
end

local function stepTravel()
  local park = stationPark(S.station + 1)
  -- moves cost exactly 1 fuel each and turns are free (C4)
  local remaining = math.abs(park.x - S.pos.x) + math.abs(park.z - S.pos.z)
  -- fuel policy (§6): top up when below fuel_low OR below what this hop
  -- actually needs; never start a hop without distance + reserve
  local need = math.max(cfg.fuel_low, remaining + cfg.fuel_reserve)
  if turtle.getFuelLevel() < need then
    refuelTo(need)
  end
  if turtle.getFuelLevel() < remaining + cfg.fuel_reserve then
    return nil, "fuel"
  end
  local total = cfg.spacing
  while S.pos.x ~= park.x or S.pos.z ~= park.z do
    local ok, err = fwd()
    if ok then
      local done = total - (math.abs(park.x - S.pos.x) + math.abs(park.z - S.pos.z))
      broadcast{ step = ("TRAVEL %d/%d"):format(done, total) }
    elseif err == "Cannot leave loaded world" then
      -- chunk-border sentinel (C4): hold and retry, the chunk may tick
      -- back in; bounded, then hand it to the human
      local okRetry = false
      for _ = 1, 10 do
        sleep(30)
        if fwd() then okRetry = true break end
      end
      if not okRetry then return nil, "unloaded" end
    elseif err == "Movement obstructed" then
      -- lane cells are never machine cells (§1 geometry): dig and go on
      turtle.select(cfg.slots.scratch)
      turtle.dig()
    elseif err == "Out of fuel" then
      return nil, "fuel"
    else
      return nil, "travel"
    end
  end
  -- the station increment is journaled by the DRIVER together with the
  -- advance to PLACE_MINER (one write), so no kill can leave
  -- step=TRAVEL with the incremented station on disk [phase 2.1]
  return true, nil, "arrived"
end

local function stepPlaceMiner()
  ensureMarker()
  if settledType("top") == "digitalMiner" then return true end
  turtle.select(cfg.slots.miner)
  if turtle.detectUp() then return nil, "placeblocked" end
  if turtle.getItemCount(cfg.slots.miner) == 0 then return nil, "lostdrop" end
  local ok
  for _ = 1, 5 do
    ok = turtle.placeUp()
    if ok then break end
    sleep(1)
  end
  if not ok then return nil, "placeblocked" end
  return true
end

local function stepVerifyMiner()
  if waitAttach("top", "digitalMiner") then return true end
  return nil, "wraptimeout"
end

local function stepPlaceQE(which)
  local slot = which == "E" and cfg.slots.qe_energy or cfg.slots.qe_item
  local ok, reason = true, nil
  if not qeNavOut(which) then return nil, "blocked" end
  if settledType("top") ~= "quantumEntangloporter" then
    turtle.select(slot)
    if turtle.detectUp() then
      ok, reason = nil, "placeblocked"
    elseif turtle.getItemCount(slot) == 0 then
      ok, reason = nil, "lostdrop"
    else
      local placed
      for _ = 1, 5 do
        placed = turtle.placeUp()
        if placed then break end
        sleep(1)
      end
      if placed then
        if not waitAttach("top", "quantumEntangloporter") then
          ok, reason = nil, "wraptimeout"
        end
      else
        ok, reason = nil, "placeblocked"
      end
    end
  end
  qeNavHome(which)
  return ok, reason
end

local function stepStart()
  -- idempotent at every station: PLACE_MINER establishes the marker on
  -- relocation; this covers station 0 (`sled start` boots straight into
  -- this step) and costs one inspectDown when already present
  ensureMarker()
  settledType("top")
  local m = minerOnTop()
  if not m then return nil, "wraptimeout" end
  local running, toMine = m.isRunning(), m.getToMine()
  if running or (toMine or 0) > 0 then return true end
  local ok, err = pcall(m.start)
  if not ok then
    if tostring(err):find("security not being public", 1, true) then
      return nil, "security"
    end
    return nil, "startfail"
  end
  return true
end

local function stepVerifyRun()
  for _ = 1, 10 do
    local m = minerOnTop()
    if m then
      local st = m.getState()
      if m.isRunning() or (m.getToMine() or 0) > 0
        or (st and st ~= "IDLE") then
        return true
      end
    end
    sleep(1)
  end
  return nil, "startfail"
end

-- Step order [design, amended phase 2]: PLACE_QE_I runs BEFORE PLACE_QE_E
-- so that during both lateral steps (the only steps containing turns) the
-- item QE stands at park+2*heading — giving boot recovery an absolute
-- directional fingerprint (see probeParkAndHeading).
local STEPS = {
  { "BREAK_QE_E", function() return stepBreakQE("E") end },
  { "BREAK_QE_I", function() return stepBreakQE("I") end },
  { "BREAK_MINER", stepBreakMiner },
  { "TRAVEL", stepTravel },
  { "PLACE_MINER", stepPlaceMiner },
  { "VERIFY_MINER", stepVerifyMiner },
  { "PLACE_QE_I", function() return stepPlaceQE("I") end },
  { "PLACE_QE_E", function() return stepPlaceQE("E") end },
  { "START", stepStart },
  { "VERIFY_RUN", stepVerifyRun },
}

-- ------------------------------------------------- boot re-localization
-- After a kill the journal narrows position to two cells along the last
-- intent (C5) and heading may be skewed if the kill hit a turn. Rather
-- than trusting arithmetic, re-anchor on observations: the station marker
-- below the park (placed at establishment) fixes position; the miner main
-- block's FACING blockstate above the park fixes heading (C1 + C6 — a
-- placeUp'd miner faces the horizontal opposite of the placement heading).
-- Both searches are position-agnostic and bounded, so a second kill
-- mid-recovery just restarts them.

local function normalizeHeight()
  -- lane and QE paths sit at lane level (ground/marker below) or at most
  -- one cell above it (the QE-I dig position): descend until something is
  -- below us
  for _ = 1, 3 do
    if turtle.inspectDown() then return end
    if not jmove("down") then return end
  end
end

local function walkBackToMarker(maxSteps)
  local mk = markerName()
  if not mk then return nil, "reconcile" end
  normalizeHeight()
  for _ = 0, maxSteps do
    local has, info = turtle.inspectDown()
    if has and info.name == mk then
      local p = stationPark(S.station)
      S.pos = { x = p.x, y = p.y, z = p.z }
      saveJournal()
      return true
    end
    if not bk() then
      local moved = false
      for _ = 1, 3 do
        sleep(1)
        if bk() then moved = true break end
      end
      if not moved then return nil, "reconcile" end
    end
  end
  return nil, "reconcile"
end

-- Full re-anchor for the two steps that contain turns (BREAK/PLACE_QE_E):
-- position from the station marker + the miner main block directly above
-- the park; ACTUAL facing from the QE fingerprint — a block 2 cells out
-- at park-level+1 is the energy QE (that direction = cfg.lateral), a
-- block 2 out at park-level+2 is the item QE (that direction =
-- cfg.heading; guaranteed present in both QE_E steps by the step order).
-- The probe is facing-agnostic: it only uses relative moves and resolves
-- the absolute direction it happens to be pointing at.
local function probeParkAndHeading()
  local mk = markerName()
  if not mk then return nil, "reconcile" end
  normalizeHeight()
  local function atPark()
    local has, info = turtle.inspectDown()
    if not (has and info.name == mk) then return false end
    local hasUp, up = turtle.inspectUp()
    return hasUp and up.name == "mekanism:digital_miner"
  end
  if not atPark() then
    local found = false
    for _ = 1, 4 do
      local went = 0
      for _ = 1, 2 do
        if not fwd() then break end
        went = went + 1
        if atPark() then found = true break end
      end
      if found then break end
      for _ = 1, went do bk() end
      turtle.turnRight() -- relative search; bookkeeping fixed below
    end
    if not found then return nil, "reconcile" end
  end
  local p = stationPark(S.station)
  S.pos = { x = p.x, y = p.y, z = p.z }
  for _ = 1, 4 do
    local went = 0
    local s1, s2 = false, false
    for _ = 1, 2 do
      if not turtle.forward() then break end
      went = went + 1
    end
    if went == 2 then
      s1 = turtle.detectUp()           -- park-level+1: energy QE column
      if not s1 and turtle.up() then
        s2 = turtle.detectUp()         -- park-level+2: item QE column
        turtle.down()
      end
    end
    for _ = 1, went do turtle.back() end
    if s1 or s2 then
      -- we are physically facing that column right now
      S.heading = s1 and cfg.lateral or cfg.heading
      saveJournal()
      turnTo(cfg.heading)
      return true
    end
    turtle.turnRight()
  end
  return nil, "reconcile"
end

local function relocalize()
  if not S.step then return true end
  if S.step == "TRAVEL" then return walkBackToMarker(cfg.spacing + 2) end
  if S.step == "BREAK_QE_E" or S.step == "PLACE_QE_E" then
    return probeParkAndHeading()
  end
  if S.step == "BREAK_QE_I" or S.step == "PLACE_QE_I" then
    -- displaced along the lane and/or one cell up, but never turned:
    -- height-normalize and walk back to the station marker (§5/§6)
    return walkBackToMarker(4)
  end
  -- BREAK_MINER / PLACE_MINER / VERIFY_MINER / START / VERIFY_RUN never
  -- move the turtle and contain no turns — the journal holds
  return true
end

-- ----------------------------------------------------------- commission
-- Turtle-led commissioning, maximized (AM-3): place whatever is missing,
-- converge every CC-settable knob to sled.conf, and READ EVERYTHING BACK
-- (N1b setters throw rather than clamp, so a successful set always reads
-- back exact). Anything not programmatically reachable is reported as a
-- hand step. Idempotent: a second run makes zero mutating calls.

local function convergeVal(get, want, set, label, problems)
  local ok, cur = pcall(get)
  if ok and cur == want then return end
  local sok, serr = pcall(set, want)
  ok, cur = pcall(get)
  if not (ok and cur == want) then
    problems[#problems + 1] = ("%s: want %s, read back %s%s"):format(
      label, tostring(want), tostring(cur),
      sok and "" or (" (" .. tostring(serr) .. ")"))
  end
end

local function commissionMiner(problems)
  S.step = "PLACE_MINER"
  saveJournal()
  local ok, reason = stepPlaceMiner()
  if ok then ok, reason = stepVerifyMiner() end
  if not ok then
    problems[#problems + 1] = "miner placement: " .. tostring(reason)
    return
  end
  local m = minerOnTop()
  if not m then
    problems[#problems + 1] = "miner: wrap failed"
    return
  end
  -- targeting setters are IDLE-gated; stop() at FINISHED does NOT unlock
  -- them — only reset() does (N1b). reset() is security-gated (A1):
  -- report instead of crashing on a PRIVATE miner.
  local stOk, st = pcall(m.getState)
  if stOk and st ~= "IDLE" then
    local rok, rerr = pcall(m.reset)
    if not rok then
      problems[#problems + 1] = "miner reset: " .. tostring(rerr)
      return
    end
  end
  local mc = cfg.miner
  convergeVal(m.getRadius, mc.radius, m.setRadius, "radius", problems)
  -- ordering: setMinY validates against the CURRENT maxY, and a fresh
  -- miner ships maxY=60 — set maxY first (N1b)
  convergeVal(m.getMaxY, mc.max_y, m.setMaxY, "maxY", problems)
  convergeVal(m.getMinY, mc.min_y, m.setMinY, "minY", problems)
  convergeVal(m.getSilkTouch, mc.silk, m.setSilkTouch, "silkTouch", problems)
  convergeVal(m.getAutoEject, mc.auto_eject, m.setAutoEject, "autoEject",
    problems)
  convergeVal(m.getAutoPull, false, m.setAutoPull, "autoPull", problems)
  -- exactly one enabled tag filter covering the conf tag (N1b shape, D2 tag)
  local fl = m.getFilters()
  local good = #fl == 1 and fl[1].type == "MINER_TAG_FILTER"
    and fl[1].tag == mc.tag and fl[1].enabled
  if not good then
    for _, f in ipairs(fl) do pcall(m.removeFilter, f) end
    local aok, aerr = pcall(m.addFilter,
      { type = "MINER_TAG_FILTER", tag = mc.tag })
    fl = m.getFilters()
    good = #fl == 1 and fl[1].tag == mc.tag
    if not good then
      problems[#problems + 1] = "filter: converge failed ("
        .. tostring(aok and "readback mismatch" or aerr) .. ")"
    end
  end
end

-- navigate to directly below a QE cell, run fn, come home to the park
local function qeVisit(which, fn)
  if not qeNavOut(which) then return false end
  fn()
  qeNavHome(which)
  return true
end

local function convergeQEConfig(which, problems)
  local label = which == "E" and "energy QE" or "item QE"
  if settledType("top") ~= "quantumEntangloporter" then
    problems[#problems + 1] = label .. ": wrap failed"
    return
  end
  local q = peripheral.wrap("top")
  -- frequency: verify, or (public-auto) select/create on the PUBLIC
  -- manager — computers cannot create/select PRIVATE frequencies (N1), so
  -- a PRIVATE frequency is a one-time hand selection that then rides the
  -- item forever (B1)
  if cfg.frequency then
    local function freqKey()
      local ok, f = pcall(q.getFrequency)
      return ok and type(f) == "table" and f.key or nil
    end
    if freqKey() ~= cfg.frequency then
      pcall(q.setFrequency, cfg.frequency)
    end
    if freqKey() ~= cfg.frequency and cfg.frequency_mode == "public-auto" then
      pcall(q.createFrequency, cfg.frequency)
    end
    if freqKey() ~= cfg.frequency then
      problems[#problems + 1] = label .. ": frequency '" .. cfg.frequency
        .. "' not selected. Hand step: select it in the GUI (computers"
        .. " can only manage PUBLIC frequencies - N1)"
    end
  end
  -- side config: identical on both QEs and on EVERY side — placeUp'd QEs
  -- face UP (C1) and RelativeSide is facing-relative (B2), so converging
  -- all six sides makes orientation irrelevant and the two QE items
  -- interchangeable [design]: items INPUT (receives the miner's eject),
  -- energy OUTPUT with eject ON (pushes into the miner's energy port; the
  -- miner never pulls, A4)
  for _, side in ipairs({ "FRONT", "LEFT", "RIGHT", "BACK", "TOP", "BOTTOM" }) do
    convergeVal(function() return q.getMode("ITEM", side) end, "INPUT",
      function(v) q.setMode("ITEM", side, v) end,
      label .. " ITEM " .. side, problems)
    convergeVal(function() return q.getMode("ENERGY", side) end, "OUTPUT",
      function(v) q.setMode("ENERGY", side, v) end,
      label .. " ENERGY " .. side, problems)
  end
  convergeVal(function() return q.isEjecting("ENERGY") end, true,
    function(v) q.setEjecting("ENERGY", v) end,
    label .. " energy eject", problems)
  convergeVal(function() return q.isEjecting("ITEM") end, false,
    function(v) q.setEjecting("ITEM", v) end,
    label .. " item eject", problems)
end

local function commission()
  local problems = {}
  -- a dry turtle cannot move: top up from the fuel slot first (measured
  -- per-item, AM-2) [phase 2.1]
  if turtle.getFuelLevel() < cfg.fuel_reserve then
    refuelTo(math.max(cfg.fuel_low, cfg.fuel_reserve))
  end
  -- interrupted commissioning: re-anchor from wherever the kill left the
  -- turtle (the relocalize probes), then converge from scratch — every
  -- commission action is idempotent [phase 2.1]
  local prior = readJournal()
  local startPos, startHeading = copyPos(cfg.origin), cfg.heading
  if prior and prior.mode == "commission" and prior.pos then
    S = prior
    if relocalize() then
      startPos, startHeading = copyPos(S.pos), S.heading
    end
  end
  S = { state = "RELOCATE", station = 0, step = "PLACE_MINER",
    mode = "commission", pos = startPos, heading = startHeading }
  saveJournal()
  saveBak()
  commissionMiner(problems)
  for _, which in ipairs({ "I", "E" }) do
    S.step = which == "I" and "PLACE_QE_I" or "PLACE_QE_E"
    saveJournal()
    saveBak()
    local ok, reason = stepPlaceQE(which)
    if not ok then
      problems[#problems + 1] = (which == "I" and "item" or "energy")
        .. " QE placement: " .. tostring(reason)
    elseif not qeVisit(which, function() convergeQEConfig(which, problems) end) then
      problems[#problems + 1] = (which == "I" and "item" or "energy")
        .. " QE: navigation blocked"
    end
  end
  fs.delete(JOURNAL_PATH)
  fs.delete(JOURNAL_PATH .. ".bak")
  if #problems == 0 then
    print("sled commission: READY")
    print("Run 'sled start' to begin mining.")
  else
    print("sled commission: NOT READY")
    for _, p in ipairs(problems) do print("  - " .. p) end
  end
end

-- ------------------------------------------------------------- states

local function stateMining()
  S.state, S.step, S.err = "MINING", nil, nil
  saveJournal()
  saveBak()
  rateSamples = {}
  local nilPolls = 0
  while true do
    local m = minerOnTop()
    local st, toMine, running, energy, usage, sec
    if m then
      st = m.getState()
      toMine = m.getToMine()
      running = m.isRunning()
      energy = m.getEnergy()
      usage = m.getEnergyUsage()
      sec = m.getSecurityMode()
    end
    if st == nil then
      nilPolls = nilPolls + 1
      if nilPolls >= 3 then return "RECOVER", "minerlost" end
    else
      nilPolls = 0
      if sec and sec ~= "PUBLIC" then return "RECOVER", "security" end
      lastTargets = toMine or 0
      noteSample(lastTargets)
      local rate = measuredRate()
      local eta = (rate and rate > 0)
        and fmtSpan(lastTargets / rate) or nil
      broadcast{
        targets = lastTargets,
        miner = running and 1 or 0,
        -- stall probe (N4): getEnergyUsage() flips to 0 the tick the
        -- machine gate fails (starvation/redstone/overflow) while targets
        -- remain — a home-side fault: warn and hold (§3). energy==0 never
        -- fires in practice (the buffer idles nonzero below the per-tick
        -- cost, A4/N4).
        warn = (usage == 0 and running and (toMine or 0) > 0)
          and "stalled" or nil,
        rate = rate, eta = eta, jpt = usage,
      }
      -- Exhaustion predicate, corrected per N4: FINISHED + getToMine()==0
      -- ONLY (`running` is operator intent, never auto-cleared). The
      -- search thread writes FINISHED before cachedToMine publishes, so a
      -- single read can transiently show FINISHED+0 on a miner with work
      -- left (N4 hazard a) — confirm with two re-reads before striking.
      if st == "FINISHED" and toMine == 0 then
        local confirmed = true
        for _ = 1, 2 do
          sleep(0.3)
          local m2 = minerOnTop()
          if not m2 or m2.getState() ~= "FINISHED"
            or (m2.getToMine() or 0) > 0 then
            confirmed = false
            break
          end
        end
        if confirmed then
          if S.station + 1 >= cfg.stations_per_leg then
            -- lane bound: stop BEFORE striking the skid so the machines
            -- stay placed for the human to extend the lane [design]
            return "RECOVER", "laneend"
          end
          return "RELOCATE"
        end
      end
    end
    waitCadence(cfg.cadence)
  end
end

local function stateRelocate(fromStep)
  S.state, S.err = "RELOCATE", nil
  local idx = 1
  if fromStep then
    for i, s in ipairs(STEPS) do
      if s[1] == fromStep then idx = i end
    end
  end
  for k = idx, #STEPS do
    S.step = STEPS[k][1]
    saveJournal()
    saveBak()
    broadcast{}
    local ok, reason, extra = STEPS[k][2]()
    if not ok then return "RECOVER", reason end
    if extra == "arrived" then
      -- TRAVEL completed: the station increment lands on disk together
      -- with the advance to PLACE_MINER (next loop write) — no journal
      -- can ever say step=TRAVEL with the incremented station [2.1]
      S.station = S.station + 1
    end
  end
  S.step = nil
  return "MINING"
end

local function stateRecover(reason)
  S.state, S.err = "RECOVER", reason or "manual"
  -- S.step is KEPT: a reboot in RECOVER means a human fixed the cause,
  -- and boot() re-attempts the failed step [phase 2.1 / runbook contract]
  saveJournal()
  saveBak()
  -- deliberately inert (§3): hold position, broadcast distress, wait for
  -- a human — but keep listening so `sledctl` can still push an update
  while true do
    broadcast{}
    waitCadence(cfg.cadence)
  end
end

-- --------------------------------------------------------------- boot

local function mainLoop(entry, reason, fromStep)
  while true do
    if entry == "MINING" then
      entry, reason = stateMining()
    elseif entry == "RELOCATE" then
      entry, reason = stateRelocate(fromStep)
      fromStep = nil
    else
      stateRecover(reason) -- never returns
    end
  end
end

-- Boot reconciliation (§5): the journal names the step; observations pick
-- the action. Steps are converge-style, so "redo current step" is safe
-- wherever the reboot landed.
local function boot()
  local j = readJournal()
  if not j then
    print("sled: no journal found - nothing to resume.")
    print("  sled commission   set up the skid here")
    print("  sled start        begin mining at this park")
    return nil
  end
  S = j
  if S.mode == "commission" then
    -- commissioning is fully idempotent — just run it again rather than
    -- resuming a half-converged setup blind [design]
    print("sled: commissioning was interrupted.")
    print("Run 'sled commission' again - it converges idempotently.")
    return nil
  end
  if S.state == "MINING" then
    if peripheral.getType("top") == "digitalMiner" then
      return "MINING"
    end
    return "RECOVER", "reconcile" -- machines gone/unloaded mid-mine (§5)
  end
  if S.state == "RECOVER" then
    -- a reboot in RECOVER is the human saying "I fixed it": clear the
    -- error and re-attempt; the machinery re-fails harmlessly back into
    -- RECOVER if not [phase 2.1]
    S.err = nil
    if S.step then
      local rok, why = relocalize()
      if not rok then return "RECOVER", why or "reconcile" end
      S.state = "RELOCATE"
      return "RELOCATE", nil, S.step
    end
    if peripheral.getType("top") == "digitalMiner" then
      return "MINING"
    end
    return "RECOVER", "reconcile"
  end
  -- RELOCATE mid-step: re-anchor position/heading, then redo the step
  -- from its start — step bodies are converge-style, so redo is safe (§5)
  local ok, reason = relocalize()
  if not ok then return "RECOVER", reason or "reconcile" end
  return "RELOCATE", nil, S.step
end

-- ---------------------------------------------------------------- main

local args = { ... }
local cmd = args[1]

if not openModems() then
  print("sled: no modem - telemetry disabled, continuing blind.")
end

local function confError()
  if not cfg then
    return "no sled.conf - write one first (see SLED-RUNBOOK)."
  end
  if type(cfg.origin) ~= "table" or type(cfg.origin.x) ~= "number"
    or type(cfg.origin.y) ~= "number" or type(cfg.origin.z) ~= "number" then
    return "sled.conf: origin must be { x=, y=, z= } numbers."
  end
  if not DIRV[cfg.heading] then
    return "sled.conf: heading must be north/south/east/west."
  end
  if not DIRV[cfg.lateral] then
    return "sled.conf: lateral must be north/south/east/west."
  end
  if cfg.lateral == cfg.heading or cfg.lateral == OPPD[cfg.heading] then
    return "sled.conf: lateral must be perpendicular to heading."
  end
  if type(cfg.fleet) ~= "string" then
    return "sled.conf: fleet must be a string (the telemetry source name)."
  end
  return nil
end

local entry, reason, fromStep

local confErr = confError()
if confErr then
  print("sled: " .. confErr)
  return
end

if cmd == "commission" then
  commission()
  return
elseif cmd == "start" then
  if peripheral.getType("top") ~= "digitalMiner" then
    print("sled: no miner above this park.")
    print("Park the turtle under the miner main block, or run")
    print("'sled commission' to build the skid first.")
    return
  end
  -- journal exists from the FIRST instant so a kill at any point of the
  -- start flow resumes through the normal machinery (kill-sweep finding)
  S = { state = "RELOCATE", station = 0, step = "START",
    pos = copyPos(cfg.origin), heading = cfg.heading }
  saveJournal()
  saveBak()
  entry, reason, fromStep = "RELOCATE", nil, "START"
elseif cmd == nil then
  entry, reason, fromStep = boot()
  if not entry then return end
else
  print("sled: unknown command '" .. tostring(cmd) .. "'")
  print("usage: sled [start|commission]")
  return
end

local ok, err = pcall(mainLoop, entry, reason, fromStep)
if not ok and tostring(err):find("Terminated", 1, true) then
  print("sled stopped.")
else
  error(err, 0)
end
