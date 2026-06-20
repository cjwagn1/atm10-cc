--[[
chemdemo.lua - drive the REAL mesensor + chemwall end-to-end against a mock ME
Bridge carrying all seven tracked Mekanism chemicals, so you can eyeball the
whole pipeline (read -> net rate -> publish -> render) without booting Minecraft.

  toolchain/lua-5.2.4/src/lua harness/chemdemo.lua

Each scenario:
  1. a mock ME Bridge holds the seven chemicals; each evolves at a chosen mB/s
     (positive = producing faster than consuming, negative = falling behind),
  2. the real programs/mesensor.lua (the AE-data computer) reads it and
     broadcasts the chemical balance as source "chem",
  3. the real programs/chemwall.lua renders those exact broadcasts on a wall.
Nothing is faked between the sensor and the wall - the wall shows the sensor's
own output.
]]

local CC = dofile("harness/cc_env.lua")

local MB = 1               -- amounts are already in mB
local BYTE = 1048576       -- one storage "byte" (for the cells line)

local function banner(s)
  print(("="):rep(66))
  print("  " .. s)
  print(("="):rep(66))
end

local function show(label, text)
  print("--- " .. label .. " " .. ("-"):rep(math.max(0, 50 - #label)))
  -- CC renders trend bytes 24/25/26 as up/down/right arrows in its font; a
  -- plain terminal can't, so map them to ^ v ~ just for this printout
  text = text:gsub("\24", "^"):gsub("\25", "v"):gsub("\26", "~")
  print(text)
  print("")
end

-- run the real sensor against a bridge snapshot; return its published packets
local function runSensor(chemicals, cells, secs)
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("back")
  env:addMeBridge("me_bridge_0", {
    stored = 1200000, max = 6400000, usage = 96.4, input = 130,
    totalChemicalStorage = cells.total, usedChemicalStorage = cells.used,
    chemicals = chemicals,
  })
  env:run("programs/mesensor.lua", {}, { maxTime = secs })
  local packets = {}
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "telemetry" and type(s.message) == "table"
      and s.message.source == "chem" then
      packets[#packets + 1] = s.message
    end
  end
  return env, packets
end

-- replay the sensor's own packets into the real wall on a given monitor
local function runWall(packets, mon)
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("wall", mon)
  local startIdx = math.max(1, #packets - 6)  -- last few -> sparkline history
  local t = 1
  for i = startIdx, #packets do
    env:rednetAt(t, 7, packets[i], "telemetry")
    t = t + 1
  end
  env:run("programs/chemwall.lua", {}, { maxTime = t + 1 })
  return env
end

-- pretty-print the final published packet (the contract the wall consumes)
local function showPacket(packets)
  local p = packets[#packets]
  if not p then print("  (no packet published)"); return end
  local d = p.data
  print(("  source=%q  cells=%s/%s B  %d chemicals:"):format(
    p.source, fmtN(d.usedBytes), fmtN(d.totalBytes), #d.chems))
  for _, c in ipairs(d.chems) do
    print(("    %-18s %12s mB   net %s%s mB/t"):format(
      c.label, fmtN(c.amount),
      (c.rate and c.rate >= 0) and "+" or "", c.rate and fmtN(c.rate) or "?"))
  end
  print("")
end

function fmtN(n)
  if type(n) ~= "number" then return "?" end
  local neg = n < 0; n = math.abs(n)
  local u = { "", "k", "M", "G", "T" }; local i = 1
  while n >= 1000 and i < #u do n = n / 1000; i = i + 1 end
  local s = i == 1 and ("%d"):format(math.floor(n + 0.5))
    or ("%.2f%s"):format(n, u[i])
  return neg and ("-" .. s) or s
end

-- ============================================================ scenario 1
-- A healthy mid-game base: most chemicals in surplus, two falling behind. This
-- is the everyday view - watch the signs and the colors.
banner("Scenario 1: a running base (mixed surplus / deficit, all seven)")

local healthy = {
  { name = "mekanism:oxygen",            displayName = "Oxygen",            count = 5000000 * MB, ratePerSec =  4000 }, -- +200/t
  { name = "mekanism:hydrogen",          displayName = "Hydrogen",          count = 3200000 * MB, ratePerSec =  1500 }, -- +75/t
  { name = "mekanism:chlorine",          displayName = "Chlorine",          count =  800000 * MB, ratePerSec = -1000 }, -- -50/t deficit
  { name = "mekanism:hydrogen_chloride", displayName = "Hydrogen Chloride", count = 1200000 * MB, ratePerSec =   100 }, -- +5/t ~balanced
  { name = "mekanism:sulfur_dioxide",    displayName = "Sulfur Dioxide",    count =  640000 * MB, ratePerSec =  -600 }, -- -30/t deficit
  { name = "mekanism:sulfur_trioxide",   displayName = "Sulfur Trioxide",   count =  250000 * MB, ratePerSec =   800 }, -- +40/t
  { name = "mekanism:sulfuric_acid",     displayName = "Sulfuric Acid",     count = 1500000 * MB, ratePerSec =  2000 }, -- +100/t
}
local s1env, s1 = runSensor(healthy, { total = 256 * BYTE, used = 64 * BYTE }, 12)
show("mesensor terminal (the AE computer - reads chemicals off the same bridge)",
  s1env:termText())
print("  published packet (what chemwall consumes):")
showPacket(s1)
local s1big = runWall(s1, { baseW = 82, baseH = 24 })   -- a 2-high wall
show("chemwall on a big wall (82x24 base -> auto-scaled)", s1big:monitorText("wall"))
local s1small = runWall(s1, { baseW = 50, baseH = 19 })  -- a smaller screen
show("chemwall on a smaller monitor (50x19 base)", s1small:monitorText("wall"))

-- ============================================================ scenario 2
-- The two faces of "rate ~ 0". Chlorine sits at ~0 mB - consumers are starving
-- it (BAD, a bottleneck: it shows LOW). Sulfuric Acid also reads ~0 rate, but
-- the cells are 98% full, so its makers are throttled by back-pressure (GOOD).
-- The pooled CELLS line + the LOW flag tell them apart.
banner("Scenario 2: the rate~0 ambiguity (starved bottleneck vs pegged-full)")

local pegged = {
  { name = "mekanism:oxygen",            displayName = "Oxygen",            count = 5000000 * MB, ratePerSec =  4000 },
  { name = "mekanism:hydrogen",          displayName = "Hydrogen",          count = 3200000 * MB, ratePerSec =  1500 },
  { name = "mekanism:chlorine",          displayName = "Chlorine",          count =     150 * MB, ratePerSec =     0 }, -- starved at ~0 -> LOW
  { name = "mekanism:hydrogen_chloride", displayName = "Hydrogen Chloride", count = 1200000 * MB, ratePerSec =   100 },
  { name = "mekanism:sulfur_dioxide",    displayName = "Sulfur Dioxide",    count =  640000 * MB, ratePerSec =  -600 },
  { name = "mekanism:sulfur_trioxide",   displayName = "Sulfur Trioxide",   count =  250000 * MB, ratePerSec =   800 },
  { name = "mekanism:sulfuric_acid",     displayName = "Sulfuric Acid",     count = 9000000 * MB, ratePerSec =     0 }, -- pegged full -> ~0
}
local s2env, s2 = runSensor(pegged, { total = 256 * BYTE, used = 251 * BYTE }, 12)  -- 98% full
print("  published packet:")
showPacket(s2)
local s2big = runWall(s2, { baseW = 82, baseH = 24 })
show("chemwall: chlorine LOW (add makers) vs acid pegged (cells 98% full)",
  s2big:monitorText("wall"))

-- ============================================================ scenario 3
-- "Watch it improve as I add generation." Same chlorine line, before and after
-- adding producers: the net rate climbs from deep red (-60/t) through zero to
-- green (+30/t). This is the whole point of the monitor.
banner("Scenario 3: chlorine recovering as you add producers (red -> green)")

local function chlorineAt(rate)
  return {
    { name = "mekanism:oxygen",            displayName = "Oxygen",            count = 5000000 * MB, ratePerSec = 4000 },
    { name = "mekanism:hydrogen",          displayName = "Hydrogen",          count = 3200000 * MB, ratePerSec = 1500 },
    { name = "mekanism:chlorine",          displayName = "Chlorine",          count = 1200000 * MB, ratePerSec = rate },
    { name = "mekanism:hydrogen_chloride", displayName = "Hydrogen Chloride", count = 1200000 * MB, ratePerSec =  100 },
    { name = "mekanism:sulfur_dioxide",    displayName = "Sulfur Dioxide",    count =  640000 * MB, ratePerSec =  900 },
    { name = "mekanism:sulfur_trioxide",   displayName = "Sulfur Trioxide",   count =  250000 * MB, ratePerSec =  800 },
    { name = "mekanism:sulfuric_acid",     displayName = "Sulfuric Acid",     count = 1500000 * MB, ratePerSec = 2000 },
  }
end

for _, step in ipairs({
  { label = "before (1 producer): chlorine deficit",  rate = -1200 },  -- -60/t
  { label = "after (added 2 more): chlorine surplus",  rate =   600 },  -- +30/t
}) do
  local _, pk = runSensor(chlorineAt(step.rate), { total = 256 * BYTE, used = 96 * BYTE }, 12)
  local wenv = runWall(pk, { baseW = 82, baseH = 24 })
  show("chemwall - " .. step.label, wenv:monitorText("wall"))
end

print(("="):rep(66))
print("  end of chemdemo - the wall renders the sensor's real output.")
print(("="):rep(66))
