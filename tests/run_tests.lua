--[[
run_tests.lua - test suite for fluxdash against the CC:Tweaked harness.

Run from the project root:
  toolchain/lua-5.2.4/src/lua tests/run_tests.lua

Two groups:
  [v1] characterization tests against reference/fluxdash_v1.lua
       These pin the behavior the UI-chat script already has, and double
       as fidelity checks for the harness itself.
  [v2] contract tests against programs/fluxdash.lua
       These encode the improved behavior. They MUST fail while
       programs/fluxdash.lua is still a copy of v1 (TDD red), and pass
       once v2 is implemented (green).
]]

local CC = dofile("harness/cc_env.lua")

local V1 = "reference/fluxdash_v1.lua"
local V2 = "programs/fluxdash.lua"

local INT_MAX = 2147483647

-- ---------------------------------------------------------------- helpers

-- Standard rig: flux accessor charging at `charge` FE/s, optional bridge
-- and monitor. Mirrors the in-game setup from the UI chat instructions.
local function rig(opts)
  opts = opts or {}
  local env = CC.new{
    termW = opts.termW or 61, termH = opts.termH or 20,
    advanced = opts.advanced ~= false,
    strictColors = opts.strictColors,
  }
  env:addModem("back")
  if opts.accessor ~= false then
    env:addEnergyPeripheral("appflux:flux_accessor_0", {
      energy = opts.e0 or 1000000,
      capacity = opts.cap or 8000000,
      ratePerSec = opts.charge or 0,
    })
  end
  if opts.bridge then
    -- Real AP 0.7.62b API: type "me_bridge", energy methods in AE units
    env:addMeBridge("me_bridge_0", {
      stored = 1200000, max = 6400000, usage = 487.5, input = 512,
    })
  end
  if opts.monitor then
    env:addMonitor("monitor_5", { w = 39, h = 15 })
  end
  return env
end

local tests, failures = {}, {}
local function T(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local current
local function fail(msg)
  error({ testfail = msg }, 2)
end

local function expectContains(haystack, needle, label)
  if not haystack:find(needle, 1, true) then
    fail(("%s: expected to find %q\n--- actual ---\n%s\n--------------")
      :format(label or "output", needle, haystack))
  end
end

local function expectNotContains(haystack, needle, label)
  if haystack:find(needle, 1, true) then
    fail(("%s: expected NOT to find %q\n--- actual ---\n%s\n--------------")
      :format(label or "output", needle, haystack))
  end
end

-- ------------------------------------------------------- v1: characterize

T("v1: dashboard shows stored energy and capacity", function()
  local env = rig{}
  current = env
  env:run(V1, {}, { maxTime = 2.5 })
  expectContains(env:termText(), "Stored:   1.00M FE", "terminal")
  expectContains(env:termText(), "Capacity: 8.00M FE", "terminal")
end)

T("v1: charging rig shows FE/t rate from clock deltas", function()
  local env = rig{ charge = 50000 } -- 50k FE/s = 2.5k FE/t
  current = env
  env:run(V1, {}, { maxTime = 3.5 })
  expectContains(env:termText(), "Rate:     +2.50k FE/t", "terminal")
end)

T("v1: warns when FE capability clamps at INT_MAX", function()
  local env = rig{ e0 = INT_MAX, cap = INT_MAX }
  current = env
  env:run(V1, {}, { maxTime = 2.5 })
  expectContains(env:termText(), "clamped at 2.147G", "terminal")
end)

T("v1: scan lists peripherals and their methods", function()
  local env = rig{ bridge = true }
  current = env
  env:run(V1, { "scan" }, { maxTime = 2 })
  expectContains(env:termText(), "appflux:flux_accessor_0", "terminal")
  expectContains(env:termText(), "getEnergy", "terminal")
  expectContains(env:termText(), "me_bridge_0", "terminal")
end)

T("v1: friendly message when nothing is attached", function()
  local env = rig{ accessor = false }
  current = env
  env:run(V1, {}, { maxTime = 2 })
  expectContains(env:termText(), "No FE peripheral or ME bridge found", "terminal")
end)

T("v1 FLAW: with a monitor attached, errors render only on the monitor", function()
  -- Characterizes the term.redirect ordering bug: a player staring at the
  -- computer terminal sees nothing; the message went to the wall monitor.
  local env = rig{ accessor = false, monitor = true }
  current = env
  env:run(V1, {}, { maxTime = 2 })
  expectContains(env:monitorText("monitor_5"), "No FE peripheral", "monitor")
  expectNotContains(env:termText(), "No FE peripheral", "terminal")
end)

T("v1 FLAW: bridge section header renders but stats stay blank", function()
  -- v1 calls getEnergyStorage/getMaxEnergyStorage, which don't exist on
  -- Advanced Peripherals 0.7.62b. The pcalls fail silently, so the AE
  -- section shows a header and nothing else.
  local env = rig{ accessor = false, bridge = true }
  current = env
  env:run(V1, {}, { maxTime = 2.5 })
  expectContains(env:termText(), "AE network", "terminal")
  expectNotContains(env:termText(), "Buffer:", "terminal")
end)

T("v1: monitor redirect leaves the terminal blank while dashboard runs", function()
  local env = rig{ monitor = true }
  current = env
  env:run(V1, {}, { maxTime = 2.5 })
  expectContains(env:monitorText("monitor_5"), "Stored:", "monitor")
  expectNotContains(env:termText(), "Stored:", "terminal")
end)

-- ------------------------------------------------------------ v2 contract

T("v2: renders to terminal AND monitor simultaneously", function()
  local env = rig{ monitor = true }
  current = env
  env:run(V2, {}, { maxTime = 2.5 })
  expectContains(env:termText(), "Stored:", "terminal")
  expectContains(env:monitorText("monitor_5"), "Stored:", "monitor")
end)

T("v2: no-peripheral guidance reaches the terminal even with a monitor", function()
  local env = rig{ accessor = false, monitor = true }
  current = env
  env:run(V2, {}, { maxTime = 2 })
  expectContains(env:termText(), "No energy peripheral", "terminal")
end)

T("v2: q key exits cleanly with a goodbye message", function()
  local env = rig{ charge = 50000 }
  current = env
  env:charAt(2.2, "q")
  local res = env:run(V2, {}, { maxTime = 6 })
  if res.reason ~= "done" then
    fail("expected clean exit, got " .. tostring(res.reason)
      .. " err=" .. tostring(res.err))
  end
  expectContains(env:termText(), "fluxdash stopped", "terminal")
end)

T("v2: survives source detach, says so, and recovers on reattach", function()
  local env = rig{ charge = 50000 }
  current = env
  env:detachAt(2.5, "appflux:flux_accessor_0")
  env:snapshotAt(4.5, "during")
  env:attachAt(5.0, "appflux:flux_accessor_0")
  local res = env:run(V2, {}, { maxTime = 7 })
  if res.reason == "error" then
    fail("crashed on detach: " .. tostring(res.err))
  end
  if not env.snapshots.during then fail("no snapshot captured") end
  expectContains(env.snapshots.during, "rescanning", "terminal (while detached)")
  expectContains(env:termText(), "Stored:", "terminal (after reattach)")
end)

T("v2: scan also writes fluxscan.txt for easy sharing", function()
  local env = rig{ bridge = true }
  current = env
  env:run(V2, { "scan" }, { maxTime = 2 })
  local f = env:file("fluxscan.txt")
  if not f then fail("fluxscan.txt was not written") end
  expectContains(f, "appflux:flux_accessor_0", "fluxscan.txt")
end)

T("v2: scan reports generic peripheral types (energy_storage)", function()
  local env = rig{}
  current = env
  env:run(V2, { "scan" }, { maxTime = 2 })
  expectContains(env:termText(), "energy_storage", "terminal")
end)

T("v2: runs safely on a non-color (standard) computer", function()
  local env = rig{ advanced = false, strictColors = true, charge = 50000 }
  current = env
  local res = env:run(V2, {}, { maxTime = 2.5 })
  if res.reason == "error" then
    fail("errored on non-color terminal: " .. tostring(res.err))
  end
  expectContains(env:termText(), "Stored:", "terminal")
end)

T("v2: keeps the INT_MAX clamp warning", function()
  local env = rig{ e0 = INT_MAX, cap = INT_MAX }
  current = env
  env:run(V2, {}, { maxTime = 2.5 })
  expectContains(env:termText(), "clamped", "terminal")
end)

T("v2: shows smoothed charge rate", function()
  local env = rig{ charge = 50000 }
  current = env
  env:run(V2, {}, { maxTime = 5.5 })
  expectContains(env:termText(), "+2.50k FE/t", "terminal")
end)

T("v2: explicit peripheral name argument overrides auto-detection", function()
  local env = rig{}
  env:addEnergyPeripheral("powah:energy_cell_3", {
    energy = 5000, capacity = 10000,
  })
  current = env
  env:run(V2, { "powah:energy_cell_3" }, { maxTime = 2.5 })
  expectContains(env:termText(), "powah:energy_cell_3", "terminal")
  expectContains(env:termText(), "5.00k", "terminal")
end)

T("v2: AE network stats via the real me_bridge methods", function()
  local env = rig{ bridge = true }
  current = env
  env:run(V2, {}, { maxTime = 2.5 })
  expectContains(env:termText(), "1.20M / 6.40M AE", "terminal")
  expectContains(env:termText(), "AE/t", "terminal")
end)

-- ------------------------------------------------- v3: block reader mode

T("v3: true totals via block reader replace the clamped reading", function()
  -- accessor pegged at INT_MAX, but a block reader on the drive sees the
  -- real 51.85G (Carter's actual number) in a 64k cell (68.72G capacity)
  local env = rig{ e0 = INT_MAX, cap = INT_MAX }
  env:addFluxDrive("block_reader_0", {
    cells = {
      { id = "ae2:item_storage_cell_64k", energy = nil }, -- decoy, no fe_energy
      { id = "appflux:fe_64k_cell", energy = 51847398108 },
    },
  })
  current = env
  env:run(V2, {}, { maxTime = 2.5 })
  expectContains(env:termText(), "51.85G FE", "terminal (true stored)")
  expectContains(env:termText(), "68.72G FE", "terminal (true capacity)")
  expectNotContains(env:termText(), "real network total is higher",
    "terminal (clamp banner suppressed in true mode)")
end)

T("v3: true rate computed from drive deltas while accessor is pegged", function()
  local env = rig{ e0 = INT_MAX, cap = INT_MAX }
  env:addFluxDrive("block_reader_0", {
    cells = { { id = "appflux:fe_64k_cell", energy = 51847398108 } },
    ratePerSec = 50000,
  })
  current = env
  env:run(V2, {}, { maxTime = 5.5 })
  expectContains(env:termText(), "+2.50k FE/t", "terminal")
end)

T("v3: sums cells across multiple readers/drives", function()
  local env = rig{ accessor = false }
  env:addFluxDrive("block_reader_0", {
    cells = { { id = "appflux:fe_64k_cell", energy = 10000000000 } },
  })
  env:addFluxDrive("block_reader_1", {
    cells = { { id = "appflux:fe_4k_cell", energy = 2000000000 } },
  })
  current = env
  env:run(V2, {}, { maxTime = 2.5 })
  expectContains(env:termText(), "12.00G FE", "terminal (summed stored)")
  expectContains(env:termText(), "73.01G FE", "terminal (summed capacity)")
end)

T("v3: reader with no flux data is ignored, accessor still works", function()
  local env = rig{}
  env:addFluxDrive("block_reader_0", {
    block = "minecraft:furnace",
    data = { BurnTime = 0, Items = {} },
  })
  current = env
  local res = env:run(V2, {}, { maxTime = 2.5 })
  if res.reason == "error" then
    fail("crashed on non-drive reader: " .. tostring(res.err))
  end
  expectContains(env:termText(), "1.00M FE", "terminal (accessor fallback)")
end)

-- ------------------------------------------------------------- fluxprobe

T("probe: sums appflux fe_energy values from a Block Reader dump", function()
  -- Mock an AP Block Reader facing an ME Drive holding two flux cells.
  -- The nested shape is a guess at AE2's save format on purpose - the
  -- probe must be shape-agnostic and find fe_energy keys at ANY depth.
  local env = CC.new{ termW = 61, termH = 20 }
  env:addPeripheral("block_reader_0", { "block_reader" }, {
    getBlockName = function() return "ae2:drive" end,
    getBlockData = function()
      return {
        inv = {
          items = {
            { Slot = 0, item = { id = "appflux:fe_4k_cell", count = 1,
                components = { ["appflux:fe_energy"] = 4294967296 } } },
            { Slot = 1, item = { id = "appflux:fe_64k_cell", count = 1,
                components = { ["appflux:fe_energy"] = 40705032704 } } },
          },
        },
        priority = 0,
      }
    end,
  })
  current = env
  local res = env:run("programs/fluxprobe.lua", {}, { maxTime = 3 })
  if res.reason == "error" or res.reason == "compile_error" then
    fail("probe crashed: " .. tostring(res.err))
  end
  expectContains(env:termText(), "45.00G", "terminal (true total)")
  expectContains(env:termText(), "fe_energy values found: 2", "terminal")
  local dump = env:file("fluxdump.txt")
  if not dump then fail("fluxdump.txt was not written") end
  expectContains(dump, "appflux:fe_energy", "fluxdump.txt")
end)

T("probe: helpful message when no fe_energy keys exist in the dump", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addPeripheral("block_reader_0", { "block_reader" }, {
    getBlockName = function() return "minecraft:furnace" end,
    getBlockData = function()
      return { BurnTime = 0, CookTime = 0, Items = {} }
    end,
  })
  current = env
  local res = env:run("programs/fluxprobe.lua", {}, { maxTime = 3 })
  if res.reason == "error" or res.reason == "compile_error" then
    fail("probe crashed: " .. tostring(res.err))
  end
  expectContains(env:termText(), "No appflux:fe_energy keys", "terminal")
end)

T("probe: guidance when no block reader is attached", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("back")
  current = env
  local res = env:run("programs/fluxprobe.lua", {}, { maxTime = 3 })
  if res.reason == "error" or res.reason == "compile_error" then
    fail("probe crashed: " .. tostring(res.err))
  end
  expectContains(env:termText(), "No Block Reader found", "terminal")
end)

-- ------------------------------------------- v4: rednet broadcast + wall

local WALL = "programs/fluxwall.lua"

T("v6: fluxdash broadcasts telemetry envelopes each refresh", function()
  local env = rig{} -- rig includes a modem on "back"
  env:addFluxDrive("block_reader_0", {
    cells = { { id = "appflux:fe_64k_cell", energy = 51847398108 } },
  })
  current = env
  env:run(V2, {}, { maxTime = 3.5 })
  if #env.rednetSent < 3 then
    fail("expected >=3 broadcasts, got " .. #env.rednetSent)
  end
  local last = env.rednetSent[#env.rednetSent]
  if last.protocol ~= "telemetry" then
    fail("expected protocol telemetry, got " .. tostring(last.protocol))
  end
  local m = last.message
  if type(m) ~= "table" or m.v ~= 1 or m.source ~= "flux"
    or type(m.data) ~= "table" then
    fail("bad envelope shape")
  end
  if m.data.trueE ~= 51847398108 then
    fail("envelope data.trueE = " .. tostring(m.data.trueE))
  end
end)

T("wall: renders big auto-scaled layout from rednet data", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 }) -- scale-aware
  -- legacy pre-mesh fluxdash packet still understood (envelope-wrapped)
  local d = { trueE = 2952790016, trueCap = 281474976710656,
    cells = 1, rate = 489420 }
  env:rednetAt(1.0, 7, { v = 1, source = "flux", data = d }, "telemetry")
  env:rednetAt(2.0, 7, { v = 1, source = "flux", data = d }, "telemetry")
  current = env
  env:run(WALL, {}, { maxTime = 3 })
  local m = env:monitorText("monitor_2")
  expectContains(m, "FLUX", "monitor (label)")
  expectContains(m, "2.95G", "monitor (stored)")
  expectContains(m, "281.47T", "monitor (capacity on headline)")
  expectContains(m, "+489.42k FE/t", "monitor (rate)")
  if env:monitorScale("monitor_2") ~= 1.5 then
    fail("expected auto-scale 1.5, got " .. tostring(env:monitorScale("monitor_2")))
  end
  expectContains(env:termText(), "2.95G", "terminal mirror")
end)

T("wall: shows NO SIGNAL when a source goes stale", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  -- legacy fluxdash envelope, then silence -> flux card goes stale
  env:rednetAt(1.0, 7, { v = 1, source = "flux", data = { trueE = 2952790016 } },
    "telemetry")
  current = env
  env:run(WALL, {}, { maxTime = 15 })
  expectContains(env:monitorText("monitor_2"), "NO SIGNAL", "monitor")
end)

T("wall: a flux sensor that can't read shows 'no reading', not '? FE' + stale trail", function()
  -- the AppFlux-blackout case: the dash computer loses its accessor/block
  -- reader and broadcasts flux with a nil energy value. The wall must not
  -- render "? FE" plus a frozen sparkline of pre-blackout history.
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  -- two healthy readings first (these populate the trend ring)
  env:rednetAt(1.0, 7, { v = 1, source = "flux", data = {
    trueE = 10000000000, trueCap = 68719476736, cells = 1, rate = -500 } },
    "telemetry")
  env:rednetAt(2.0, 7, { v = 1, source = "flux", data = {
    trueE = 9000000000, trueCap = 68719476736, cells = 1, rate = -500 } },
    "telemetry")
  -- then the sensor loses its source: alive (srcName present) but no energy
  env:rednetAt(3.0, 7, { v = 1, source = "flux", data = {
    srcName = "appflux:flux_accessor_0" } }, "telemetry")
  current = env
  env:run(WALL, {}, { maxTime = 4 })
  local m = env:monitorText("monitor_2")
  expectContains(m, "no reading", "degraded flux card states it plainly")
  expectNotContains(m, "? FE", "no question-mark energy headline")
end)

T("dash: an empty flux cell (0 FE, no fe_energy component) reads as 0, not 'no source'", function()
  -- AppFlux omits the appflux:fe_energy component when a cell is at 0 FE.
  -- The cell item is still there, so the dash must count it as a 0 reading
  -- instead of flickering to "(no energy peripheral)" every time the cell
  -- empties (the in-game flicker the user hit when the base ran dry).
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("back")
  env:addFluxDrive("block_reader_0", {
    cells = { { id = "appflux:fe_64k_cell", energy = nil } }, -- present, empty
  })
  current = env
  env:run("programs/fluxdash.lua", {}, { maxTime = 2.5 })
  expectContains(env:termText(), "block reader", "still names the reader source")
  expectNotContains(env:termText(), "no energy peripheral", "no false 'no source'")
  local last
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "telemetry" and type(s.message) == "table"
      and s.message.source == "flux" then
      last = s.message
    end
  end
  if not last then fail("no flux envelope broadcast") end
  if last.data.trueE ~= 0 then
    fail("empty cell should read trueE=0, got " .. tostring(last.data.trueE))
  end
  if last.data.cells ~= 1 then
    fail("the empty cell should still be counted, cells=" .. tostring(last.data.cells))
  end
end)

T("dash: a failed energy read broadcasts no stale value (nil, not the last good number)", function()
  -- accessor present but unreadable (chunk/AE down): getEnergy returns nil
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("back")
  local energy = 5000000000
  env:addPeripheral("appflux:flux_accessor_0", { "appflux:flux_accessor", "energy_storage" }, {
    getEnergy = function() return energy end,
    getEnergyCapacity = function() return 68719476736 end,
  })
  -- after t=2.5s the read starts failing
  env:scheduleAt(2.5, { fn = function() energy = nil end })
  current = env
  env:run("programs/fluxdash.lua", {}, { maxTime = 4 })
  -- find the last flux envelope broadcast
  local last
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "telemetry" and type(s.message) == "table"
      and s.message.source == "flux" then
      last = s.message
    end
  end
  if not last then fail("no flux envelope broadcast") end
  if last.data.e ~= nil then
    fail("broadcast a stale energy value after the read failed: e="
      .. tostring(last.data.e))
  end
end)

T("wall: q quits cleanly", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:charAt(2.2, "q")
  current = env
  local res = env:run(WALL, {}, { maxTime = 6 })
  if res.reason ~= "done" then
    fail("expected clean exit, got " .. tostring(res.reason))
  end
  expectContains(env:termText(), "fluxwall stopped", "terminal")
end)

T("wall: guidance when no modem attached", function()
  local env = CC.new{ termW = 51, termH = 19 }
  current = env
  env:run(WALL, {}, { maxTime = 2 })
  expectContains(env:termText(), "No modem", "terminal")
end)

-- -------------------------------------------------------- telemetry mesh

local function fluxEnvelope(e)
  return { v = 1, source = "flux", tick = 0, data = {
    trueE = e or 2952790016, trueCap = 281474976710656,
    cells = 1, rate = 489420,
  } }
end

local ME_ENVELOPE = { v = 1, source = "me", tick = 0, data = {
  usedBytes = 612000, totalBytes = 2100000, availBytes = 1488000,
  cpus = 4, cpusBusy = 1, aeUse = 96.4,
} }

T("mesh: wall renders flux page from a telemetry envelope", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  env:rednetAt(1.0, 7, fluxEnvelope(), "telemetry")
  env:rednetAt(2.0, 7, fluxEnvelope(), "telemetry")
  current = env
  env:run(WALL, {}, { maxTime = 3 })
  expectContains(env:monitorText("monitor_2"), "2.95G", "monitor")
  expectContains(env:monitorText("monitor_2"), "+489.42k FE/t", "monitor")
end)

T("mesh: wall shows ALL sources on one screen, no rotation", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  for t = 1, 12 do
    env:rednetAt(t, 7, fluxEnvelope(), "telemetry")
    env:rednetAt(t, 8, ME_ENVELOPE, "telemetry")
  end
  current = env
  env:run(WALL, {}, { maxTime = 13 })
  local m = env:monitorText("monitor_2")
  -- both sources visible in the SAME final frame
  expectContains(m, "FLUX", "monitor (flux card)")
  expectContains(m, "2.95G", "monitor (flux value)")
  expectContains(m, "ME", "monitor (me card)")
  expectContains(m, "612.00k", "monitor (me storage value)")
end)

T("mesh: both sources fit even on a small monitor", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 24, baseH = 10 }) -- scale 1 -> 24x10
  for t = 1, 4 do
    env:rednetAt(t, 7, fluxEnvelope(), "telemetry")
    env:rednetAt(t, 8, ME_ENVELOPE, "telemetry")
  end
  current = env
  env:run(WALL, {}, { maxTime = 5 })
  local m = env:monitorText("monitor_2")
  expectContains(m, "FLUX", "small monitor (flux headline)")
  expectContains(m, "ME", "small monitor (me headline)")
end)

T("mesh: wall shows alert banner from the alerts source", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  env:rednetAt(1.0, 7, fluxEnvelope(), "telemetry")
  env:rednetAt(2.0, 9, { v = 1, source = "alerts", tick = 0,
    data = { msg = "flux energy dropped 45% in 5m" } }, "telemetry")
  env:rednetAt(3.0, 7, fluxEnvelope(), "telemetry")
  current = env
  env:run(WALL, {}, { maxTime = 4 })
  -- 24-char monitor clips the banner; the wide terminal shows it all
  expectContains(env:monitorText("monitor_2"), "! flux energy dropped",
    "monitor banner")
  expectContains(env:termText(), "dropped 45% in 5m", "terminal banner")
  expectContains(env:monitorText("monitor_2"), "FE", "monitor still shows flux")
end)

T("mesh: mesensor broadcasts ME storage envelopes", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("back")
  env:addMeBridge("me_bridge_0", {
    stored = 1200000, max = 6400000, usage = 96.4, input = 130,
    totalItemStorage = 2100000, usedItemStorage = 612000,
    cpus = {
      { name = "A", storage = 65536, coProcessors = 2, isBusy = true },
      { name = "B", storage = 65536, coProcessors = 0, isBusy = false },
    },
  })
  current = env
  env:run("programs/mesensor.lua", {}, { maxTime = 5.5 })
  if #env.rednetSent < 2 then
    fail("expected >=2 broadcasts, got " .. #env.rednetSent)
  end
  local m = env.rednetSent[#env.rednetSent].message
  if m.source ~= "me" then fail("source = " .. tostring(m.source)) end
  if m.data.usedBytes ~= 612000 then
    fail("usedBytes = " .. tostring(m.data.usedBytes))
  end
  if m.data.cpus ~= 2 or m.data.cpusBusy ~= 1 then
    fail(("cpus=%s busy=%s"):format(tostring(m.data.cpus),
      tostring(m.data.cpusBusy)))
  end
end)

-- -------------------------------------------------------------- historian

T("historian: persists telemetry rings to disk", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  for t = 1, 5 do
    env:rednetAt(t, 7, fluxEnvelope(), "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 12 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  local log = env:file("telemetry/flux.log")
  if not log then fail("telemetry/flux.log not written") end
  expectContains(log, "trueE", "flux.log")
end)

T("historian: fires drop alert to chat box and the mesh", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env:rednetAt(1.0, 7, fluxEnvelope(10000000000), "telemetry")
  env:rednetAt(3.0, 7, fluxEnvelope(5500000000), "telemetry") -- -45%
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 6 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  if #env.chatLog == 0 then fail("no chat message sent") end
  expectContains(env.chatLog[1].msg, "dropped 45%", "chat message")
  local alertSent = false
  for _, s in ipairs(env.rednetSent) do
    if type(s.message) == "table" and s.message.source == "alerts" then
      alertSent = true
    end
  end
  if not alertSent then fail("alert envelope not broadcast to the mesh") end
end)

T("historian: drop alert still broadcast without a chat box", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:rednetAt(1.0, 7, fluxEnvelope(10000000000), "telemetry")
  env:rednetAt(3.0, 7, fluxEnvelope(5500000000), "telemetry")
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 6 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  local alertSent = false
  for _, s in ipairs(env.rednetSent) do
    if type(s.message) == "table" and s.message.source == "alerts" then
      alertSent = true
    end
  end
  if not alertSent then fail("alert envelope not broadcast") end
end)

T("historian: flags a source that goes silent", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env:rednetAt(1.0, 7, fluxEnvelope(), "telemetry")
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 75 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  local found = false
  for _, c in ipairs(env.chatLog) do
    if c.msg:find("silent", 1, true) then found = true end
  end
  if not found then fail("no silence alert in chat log") end
end)

-- ----------------------------------------- v11: useful, recurring alerts

local function chatHas(env, needle)
  for _, c in ipairs(env.chatLog) do
    if c.msg:find(needle, 1, true) then return c.msg end
  end
  return nil
end

T("historian: stays quiet on a huge-capacity drive holding plenty (no false low-power)", function()
  -- the 0%-pathology rig: 550G stored in a 281T Applied Flux Drive is
  -- 0.0002% -- but it's a mountain of power and it's CHARGING. A pct-based
  -- "under 5%" rule would cry "flux power low" here forever, so that rule
  -- is gone; genuine drain is still covered by the runway 'empty in' rule.
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  for t = 1, 700, 30 do
    env:rednetAt(t, 7, { v = 1, source = "flux", tick = 0, data = {
      trueE = 550000000000, trueCap = 281474976710656, cells = 8,
      rate = 2490000 } }, "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 720 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  local cried = chatHas(env, "low")
  if cried then fail("false low-power alert fired: " .. cried) end
end)

T("historian: runway alert projects flux empty before it happens", function()
  -- a gradual drain (under the 40% drop threshold) must still warn that
  -- it's heading to empty soon, with lead time.
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  -- 10G draining ~0.1G/s: ~10% total drop (no drop alert), but empty in <2m
  for t = 1, 12 do
    env:rednetAt(t, 7, { v = 1, source = "flux", tick = 0, data = {
      trueE = 10000000000 - (t - 1) * 100000000,
      trueCap = 281474976710656, cells = 1, rate = -5000000 } }, "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 14 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  local msg = chatHas(env, "empty in")
  if not msg then fail("no runway 'empty in' alert fired") end
  expectNotContains(chatHas(env, "dropped") or "", "dropped",
    "a 10% drain must not trip the 40% drop rule")
end)

T("historian: ME storage filling warns before drives jam", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  -- drives held at 95% for >1 min
  for t = 1, 80, 5 do
    env:rednetAt(t, 8, { v = 1, source = "me", tick = 0, data = {
      usedBytes = 950000, totalBytes = 1000000, availBytes = 50000,
      cpus = 4, cpusBusy = 0, aeUse = 50 } }, "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 90 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  if not chatHas(env, "ME") or not chatHas(env, "full") then
    fail("no ME-full warning fired")
  end
end)

T("historian: ME-full runway projects when storage will fill", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  -- filling 100k bytes/s from 50% toward full: full in a few seconds
  for t = 1, 6 do
    env:rednetAt(t, 8, { v = 1, source = "me", tick = 0, data = {
      usedBytes = 400000 + (t - 1) * 100000, totalBytes = 1000000,
      cpus = 4, cpusBusy = 0 } }, "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 8 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  if not chatHas(env, "full in") then
    fail("no ME-full runway alert fired")
  end
end)

T("historian: no ME-full alarm while storage is only half full", function()
  -- ME drifting 30M->36M of 72M (~42%->50%): a craft/import bump, not a jam.
  -- The full-runway must stay quiet below its high-fill floor (the false
  -- 'me full in ~2m' that fired at 50%).
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  for t = 1, 130, 10 do
    env:rednetAt(t, 8, { v = 1, source = "me", tick = 0, data = {
      usedBytes = 30000000 + (t - 1) * 50000, totalBytes = 72000000,
      cpus = 2, cpusBusy = 1 } }, "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 140 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  local cried = chatHas(env, "full")
  if cried then fail("false ME-full alarm at ~50%: " .. cried) end
end)

T("historian: heartbeat posts a periodic 'base' digest proving it's alive", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  -- healthy base (no alerts): flux ~71%, ME ~30%, every 60s past one heartbeat
  for t = 1, 1840, 60 do
    env:rednetAt(t, 7, { v = 1, source = "flux", tick = 0, data = {
      trueE = 200000000000000, trueCap = 281474976710656, cells = 1, rate = 0 } },
      "telemetry")
    env:rednetAt(t + 1, 8, { v = 1, source = "me", tick = 0, data = {
      usedBytes = 300000, totalBytes = 1000000, cpus = 4, cpusBusy = 0 } },
      "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 1850 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  -- the chat box tags the digest with prefix "base"; the message itself no
  -- longer repeats "base:" (the [base] tag already says it)
  local hb
  for _, c in ipairs(env.chatLog) do
    if c.prefix == "base" and c.msg:find("flux", 1, true) then hb = c.msg end
  end
  if not hb then fail("no heartbeat digest in chat") end
  expectContains(hb, "flux", "heartbeat mentions flux")
end)

T("historian: heartbeat shows absolute flux + max capacity, not a dead 0%", function()
  -- the user's real rig: ~550G stored in a trillions-capacity Applied Flux
  -- Drive. trueE/trueCap rounds to 0%, which is information-free; the digest
  -- must instead show the absolute stored, the max capacity (the flex), and
  -- the rate -- and must NOT repeat the "base" label the chat box already
  -- tags via its [base] prefix.
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  for t = 1, 1840, 60 do
    env:rednetAt(t, 7, { v = 1, source = "flux", tick = 0, data = {
      trueE = 550000000000, trueCap = 281474976710656, cells = 8,
      rate = 2490000 } }, "telemetry")
    env:rednetAt(t + 1, 8, { v = 1, source = "me", tick = 0, data = {
      usedBytes = 500000, totalBytes = 1000000, cpus = 4, cpusBusy = 0 } },
      "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 1850 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  -- the digest is the only "base"-tagged line carrying BOTH sources; a
  -- "flux power low" alert (also prefix "base") carries only flux
  local hb
  for _, c in ipairs(env.chatLog) do
    if c.prefix == "base" and c.msg:find("flux", 1, true)
      and c.msg:find("ME", 1, true) then hb = c.msg end
  end
  if not hb then fail("no base heartbeat digest in chat") end
  expectContains(hb, "550G", "absolute stored, not a 0% ratio")
  expectContains(hb, "281.47T", "max capacity shown (the flex)")
  expectContains(hb, "+2.49M", "rate alongside the stored/capacity")
  expectContains(hb, "ME 50%", "ME ratio kept (it is meaningful)")
  expectNotContains(hb, "flux 0%", "the dead 0% flux ratio is gone")
  expectNotContains(hb, "base:", "no repeated 'base:' label")
end)

-- ----------------------------------------- base-wide update-all (v13)

local UPDATEALL = "programs/update-all.lua"
-- a stand-in for the real updater: prove it ran, then reboot like update.lua
local FAKE_UPDATER = [[
  local f = fs.open("updated.flag", "w")
  f.write("yes")
  f.close()
  os.reboot()
]]

T("update-all: broadcasts the token-gated update, tallies acks, then updates self", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env.files["update"] = FAKE_UPDATER
  -- a base computer answers the broadcast inside the ack window
  env:rednetAt(0.5, 7, { ack = true, label = "wall1" }, "basectl")
  current = env
  local res = env:run(UPDATEALL, {}, { maxTime = 6 })
  if res.reason ~= "shutdown" or not res.reboot then
    fail("expected self-update reboot, got " .. tostring(res.reason))
  end
  if env:file("updated.flag") ~= "yes" then fail("updater did not run on self") end
  local sent
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "basectl" and type(s.message) == "table"
      and s.message.cmd == "update" then sent = s end
  end
  if not sent then fail("no basectl update broadcast") end
  if sent.message.token ~= "flux" then
    fail("token = " .. tostring(sent.message.token))
  end
  expectContains(env:termText(), "wall1", "tallies the ack from wall1")
end)

T("fluxwall: a token-gated basectl update runs the updater (display joins the push)", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env.files["update"] = FAKE_UPDATER
  env:rednetAt(1.0, 9, { cmd = "update", token = "flux" }, "basectl")
  current = env
  local res = env:run(WALL, {}, { maxTime = 6 })
  if res.reason ~= "shutdown" or not res.reboot then
    fail("wall did not self-update on basectl cmd, got " .. tostring(res.reason))
  end
  if env:file("updated.flag") ~= "yes" then fail("updater did not run") end
end)

T("fluxdash: a token-gated basectl update runs the updater", function()
  local env = rig{ charge = 0 }
  env.files["update"] = FAKE_UPDATER
  env:rednetAt(1.0, 9, { cmd = "update", token = "flux" }, "basectl")
  current = env
  local res = env:run(V2, {}, { maxTime = 6 })
  if res.reason ~= "shutdown" or not res.reboot then
    fail("dash did not self-update, got " .. tostring(res.reason))
  end
  if env:file("updated.flag") ~= "yes" then fail("updater did not run") end
end)

T("mesensor: a token-gated basectl update runs the updater", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("back")
  env:addMeBridge("me_bridge_0", {
    stored = 1, max = 2, usage = 1, input = 1,
    totalItemStorage = 100, usedItemStorage = 10,
  })
  env.files["update"] = FAKE_UPDATER
  env:rednetAt(1.0, 9, { cmd = "update", token = "flux" }, "basectl")
  current = env
  local res = env:run("programs/mesensor.lua", {}, { maxTime = 6 })
  if res.reason ~= "shutdown" or not res.reboot then
    fail("mesensor did not self-update, got " .. tostring(res.reason))
  end
  if env:file("updated.flag") ~= "yes" then fail("updater did not run") end
end)

T("historian: a token-gated basectl update acks then updates; wrong token ignored", function()
  -- wrong token: historian keeps running (courtesy lock, like the sleds)
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env.files["update"] = FAKE_UPDATER
  env:rednetAt(1.0, 9, { cmd = "update", token = "nope" }, "basectl")
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 5 })
  if res.reason == "shutdown" then fail("rebooted on a bad token") end
  if env:file("updated.flag") ~= nil then fail("wrong token ran the updater") end

  -- right token: ack first (so a console can tally), then update + reboot
  local env2 = CC.new{ termW = 61, termH = 20 }
  env2:addModem("top")
  env2.files["update"] = FAKE_UPDATER
  env2:rednetAt(1.0, 9, { cmd = "update", token = "flux" }, "basectl")
  current = env2
  local res2 = env2:run("programs/historian.lua", {}, { maxTime = 6 })
  if res2.reason ~= "shutdown" or not res2.reboot then
    fail("historian did not self-update, got " .. tostring(res2.reason))
  end
  if env2:file("updated.flag") ~= "yes" then fail("updater did not run") end
  local acked
  for _, s in ipairs(env2.rednetSent) do
    if s.protocol == "basectl" and type(s.message) == "table"
      and s.message.ack then acked = true end
  end
  if not acked then fail("historian did not ack before updating") end
end)

T("historian: 'u' launches update-all to push to the whole base", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env.files["update-all"] = [[
    local f = fs.open("pushed.flag", "w")
    f.write("yes")
    f.close()
    os.reboot()
  ]]
  env:charAt(1.5, "u")
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 6 })
  if res.reason ~= "shutdown" or not res.reboot then
    fail("u did not launch update-all, got " .. tostring(res.reason))
  end
  if env:file("pushed.flag") ~= "yes" then fail("update-all did not run") end
end)

local PUSH_STUB = [[
  local f = fs.open("pushed.flag", "w")
  f.write("yes")
  f.close()
  os.reboot()
]]

T("historian: the owner typing 'update-all' in chat launches the base update", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env.files["update-all"] = PUSH_STUB
  env:chatAt(1.5, "cjwagn1", "update-all")  -- the owner types the trigger
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 6 })
  if res.reason ~= "shutdown" or not res.reboot then
    fail("chat trigger did not launch update-all, got " .. tostring(res.reason))
  end
  if env:file("pushed.flag") ~= "yes" then fail("update-all did not run") end
end)

T("historian: a non-owner's 'update-all' chat message is ignored", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env.files["update-all"] = PUSH_STUB
  env:chatAt(1.5, "RandoGriefer", "update-all")
  env:charAt(3.0, "q")  -- quit cleanly; the trigger should NOT have fired
  current = env
  env:run("programs/historian.lua", {}, { maxTime = 6 })
  if env:file("pushed.flag") ~= nil then
    fail("a non-owner triggered the base update")
  end
end)

T("historian: a post-update (update-all) boot acks each computer on its own chat line", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env.files[".fluxupdated"] = "16\n"   -- left by `update fromall`
  env.files[".fluxversion"] = "16\n"   -- the historian's own version (self-ack)
  -- another box answers the census ping
  env:rednetAt(0.8, 7, { version = "16", label = "wall1" }, "basectl")
  env:charAt(6.0, "q")
  current = env
  env:run("programs/historian.lua", {}, { maxTime = 9 })
  local ackWall, ackSelf
  for _, c in ipairs(env.chatLog) do
    if c.msg:lower():find("ack", 1, true) and c.msg:find("wall1 v16", 1, true) then
      ackWall = true
    end
    if c.msg:lower():find("ack", 1, true) and c.msg:find("v16", 1, true)
      and not c.msg:find("wall1", 1, true) then ackSelf = true end  -- historian
  end
  if not ackWall then fail("wall1 not acked on its own chat line") end
  if not ackSelf then fail("historian did not ack itself") end
  if env:file(".fluxupdated") ~= nil then fail("breadcrumb not cleared") end
end)

T("historian: a manual update (no breadcrumb) stays silent in chat", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  -- no .fluxupdated: this boot did NOT come from an update-all push
  env:charAt(2.0, "q")
  current = env
  env:run("programs/historian.lua", {}, { maxTime = 4 })
  for _, c in ipairs(env.chatLog) do
    if c.msg:find("back online", 1, true) or c.msg:find("base versions", 1, true) then
      fail("manual update announced in chat: " .. c.msg)
    end
  end
end)

T("fluxwall: replies to a version-census ping with its running version", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env.files[".fluxversion"] = "16\n"
  env:rednetAt(1.0, 9, { cmd = "version?", token = "flux" }, "basectl")
  env:charAt(3.0, "q")
  current = env
  env:run(WALL, {}, { maxTime = 6 })
  local reply
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "basectl" and type(s.message) == "table"
      and s.message.version ~= nil then reply = s.message end
  end
  if not reply then fail("no version reply broadcast") end
  if tostring(reply.version) ~= "16" then
    fail("version = " .. tostring(reply.version))
  end
end)

T("update-all chat (loud): announces the target version in chat", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env.files[".fluxdeploy"] = "historian\nhttps://example.test/manifest.lua\n"
  env:addHttp("https://example.test/manifest.lua",
    "return { version = 13, files = {} }")
  env.files["update"] = FAKE_UPDATER
  current = env
  env:run(UPDATEALL, { "chat" }, { maxTime = 7 })  -- "chat" = loud mode
  local sawVer
  for _, c in ipairs(env.chatLog) do
    if c.msg:find("v13", 1, true) then sawVer = c.msg end
  end
  if not sawVer then fail("target version not announced in chat") end
  -- per-computer acks come from the historian's post-reboot census, not here
end)

T("update-all (no arg / quiet): updates the base but posts nothing to chat", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env.files["update"] = FAKE_UPDATER
  env:rednetAt(0.5, 7, { ack = true, label = "wall1" }, "basectl")
  current = env
  env:run(UPDATEALL, {}, { maxTime = 7 })  -- quiet (e.g. from [u] / console)
  for _, c in ipairs(env.chatLog) do
    fail("quiet update-all posted to chat: " .. c.msg)
  end
end)

T("historian: a chat-typed 'update-all' is loud (narrates to chat)", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env.files["update"] = FAKE_UPDATER  -- update-all's self-update reboots out
  env:chatAt(1.0, "cjwagn1", "update-all")
  current = env
  env:run("programs/historian.lua", {}, { maxTime = 9 })
  local narrated
  for _, c in ipairs(env.chatLog) do
    if c.msg:lower():find("updating", 1, true) then narrated = true end
  end
  if not narrated then fail("chat-typed update-all did not narrate to chat") end
end)

T("historian: pressing [u] is quiet (updates base, no chat spam)", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  env.files["update"] = FAKE_UPDATER
  env:charAt(1.0, "u")
  env:rednetAt(1.4, 7, { ack = true, label = "wall1" }, "basectl")
  current = env
  env:run("programs/historian.lua", {}, { maxTime = 9 })
  for _, c in ipairs(env.chatLog) do
    fail("[u] posted to chat: " .. c.msg)
  end
end)

-- ------------------------------------------------------------------- eta

T("wall: shows time until empty while draining", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  -- 72M FE draining at 2k FE/t = 40k FE/s -> 1800s -> 30m
  local msg = { v = 1, trueE = 72000000, trueCap = 100000000,
    cells = 1, rate = -2000 }
  env:rednetAt(1.0, 7, msg, "fluxdash")
  env:rednetAt(2.0, 7, msg, "fluxdash")
  current = env
  env:run(WALL, {}, { maxTime = 3 })
  expectContains(env:monitorText("monitor_2"), "empty in 30m", "monitor")
end)

T("wall: shows time until full while charging", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  -- 72M FE of headroom at +2k FE/t -> 30m
  local msg = { v = 1, trueE = 28000000, trueCap = 100000000,
    cells = 1, rate = 2000 }
  env:rednetAt(1.0, 7, msg, "fluxdash")
  env:rednetAt(2.0, 7, msg, "fluxdash")
  current = env
  env:run(WALL, {}, { maxTime = 3 })
  expectContains(env:monitorText("monitor_2"), "full in 30m", "monitor")
end)

T("v5: fluxdash terminal shows ETA from true totals", function()
  -- 64k cell: 16.87G of headroom at 2.5k FE/t -> ~337,400s -> 3d 21h
  local env = rig{ accessor = false }
  env:addFluxDrive("block_reader_0", {
    cells = { { id = "appflux:fe_64k_cell", energy = 51847398108 } },
    ratePerSec = 50000,
  })
  current = env
  env:run(V2, {}, { maxTime = 5.5 })
  expectContains(env:termText(), "full in 3d 21h", "terminal")
end)

-- ------------------------------------------------------------ deployment

local MANIFEST_URL = "https://example.test/deploy/manifest.lua"
local function deployRig()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addHttp(MANIFEST_URL, [[return {
    version = 4,
    files = {
      { path = "fluxdash", url = "https://example.test/fluxdash.lua" },
      { path = "fluxwall", url = "https://example.test/fluxwall.lua" },
      { path = "fluxprobe", url = "https://example.test/fluxprobe.lua" },
      { path = "update", url = "https://example.test/update.lua" },
    },
    roles = { dash = "fluxdash", wall = "fluxwall",
      me = "mesensor", historian = "historian" },
  }]])
  env:addHttp("https://example.test/fluxdash.lua", "-- dash code")
  env:addHttp("https://example.test/fluxwall.lua", "-- wall code")
  env:addHttp("https://example.test/fluxprobe.lua", "-- probe code")
  env:addHttp("https://example.test/update.lua", "-- update code")
  return env
end

T("installer: sets up a wall computer with startup + update pointer", function()
  local env = deployRig()
  current = env
  local res = env:run("programs/installer.lua", { "wall", MANIFEST_URL },
    { maxTime = 3 })
  if res.reason == "error" or res.reason == "compile_error" then
    fail("installer crashed: " .. tostring(res.err))
  end
  if env:file("fluxwall") ~= "-- wall code" then
    fail("fluxwall not installed: " .. tostring(env:file("fluxwall")))
  end
  expectContains(env:file("startup.lua") or "", "fluxwall", "startup.lua")
  expectContains(env:file(".fluxdeploy") or "", MANIFEST_URL, ".fluxdeploy")
  expectContains(env:file(".fluxdeploy") or "", "wall", ".fluxdeploy role")
end)

T("installer: records .fluxversion so a fresh box reports its version", function()
  local env = deployRig()
  current = env
  env:run("programs/installer.lua", { "wall", MANIFEST_URL }, { maxTime = 3 })
  if (env:file(".fluxversion") or ""):gsub("%s+", "") ~= "4" then  -- deployRig = v4
    fail(".fluxversion = " .. tostring(env:file(".fluxversion")))
  end
end)

T("installer: accepts any role defined in the manifest (me)", function()
  local env = deployRig()
  current = env
  local res = env:run("programs/installer.lua", { "me", MANIFEST_URL },
    { maxTime = 3 })
  if res.reason == "error" or res.reason == "compile_error" then
    fail("installer crashed: " .. tostring(res.err))
  end
  expectContains(env:file("startup.lua") or "", "mesensor", "startup.lua")
  expectContains(env:file(".fluxdeploy") or "", "me", ".fluxdeploy role")
end)

T("installer: unknown role lists the roles the manifest offers", function()
  local env = deployRig()
  current = env
  env:run("programs/installer.lua", { "reactor", MANIFEST_URL },
    { maxTime = 3 })
  expectContains(env:termText(), "Roles:", "terminal")
  expectContains(env:termText(), "historian", "terminal (role list)")
  if env:file(".fluxdeploy") then
    fail(".fluxdeploy written despite unknown role")
  end
end)

T("update: re-downloads from the saved manifest and reboots", function()
  local env = deployRig()
  env.files[".fluxdeploy"] = "wall\n" .. MANIFEST_URL .. "\n"
  env.files["fluxwall"] = "-- old wall code"
  env:addHttp("https://example.test/fluxwall.lua", "-- wall code v2")
  current = env
  local res = env:run("programs/update.lua", {}, { maxTime = 5 })
  if res.reason ~= "shutdown" then
    fail("expected reboot (shutdown), got " .. tostring(res.reason)
      .. " err=" .. tostring(res.err))
  end
  if env:file("fluxwall") ~= "-- wall code v2" then
    fail("fluxwall not updated: " .. tostring(env:file("fluxwall")))
  end
end)

T("update: always records .fluxversion; only flags .fluxupdated for an update-all push", function()
  -- manual update: version recorded, but NO chat-announce breadcrumb
  local env = deployRig()
  env.files[".fluxdeploy"] = "wall\n" .. MANIFEST_URL .. "\n"
  env.files["fluxwall"] = "-- old wall code"
  current = env
  env:run("programs/update.lua", {}, { maxTime = 5 })  -- deployRig manifest = v4
  if (env:file(".fluxversion") or ""):gsub("%s+", "") ~= "4" then
    fail(".fluxversion = " .. tostring(env:file(".fluxversion")))
  end
  if env:file(".fluxupdated") ~= nil then
    fail("a manual update left a chat-announce breadcrumb")
  end

  -- update-all push (update fromall): both recorded
  local env2 = deployRig()
  env2.files[".fluxdeploy"] = "wall\n" .. MANIFEST_URL .. "\n"
  env2.files["fluxwall"] = "-- old wall code"
  current = env2
  env2:run("programs/update.lua", { "fromall" }, { maxTime = 5 })
  if (env2:file(".fluxupdated") or ""):gsub("%s+", "") ~= "4" then
    fail(".fluxupdated = " .. tostring(env2:file(".fluxupdated")))
  end
end)

-- ----------------------------------------- touch command console (v17)

local CONSOLE = "programs/console.lua"

T("console: draws the command buttons on the touch monitor", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_0", { w = 36, h = 18 })
  env:monitorSnapshotAt(1.0, "panel", "monitor_0")  -- capture before exit clears it
  env:charAt(2.0, "q")
  current = env
  local res = env:run(CONSOLE, {}, { maxTime = 4 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  local m = env.snapshots.panel or ""
  expectContains(m, "UPDATE ALL", "monitor")
  expectContains(m, "VERSIONS", "monitor")
  expectContains(m, "UPDATE SLEDS", "monitor")
end)

T("console: tapping UPDATE ALL broadcasts the base update", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_0", { w = 36, h = 18 })
  env:touchAt(1.5, "monitor_0", 10, 3)  -- inside the UPDATE ALL button
  current = env
  env:run(CONSOLE, {}, { maxTime = 5 })
  local sent
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "basectl" and type(s.message) == "table"
      and s.message.cmd == "update" then sent = s end
  end
  if not sent then fail("UPDATE ALL did not broadcast a base update") end
  if sent.message.token ~= "flux" then fail("token = " .. tostring(sent.message.token)) end
end)

T("console: UPDATE ALL shows each ack live on the panel", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_0", { w = 36, h = 18 })
  env:touchAt(1.5, "monitor_0", 10, 3)   -- UPDATE ALL
  env:rednetAt(1.8, 7, { ack = true, label = "wall1" }, "basectl")
  env:monitorSnapshotAt(3.0, "acks", "monitor_0")  -- during the ack window
  current = env
  env:run(CONSOLE, {}, { maxTime = 6 })
  expectContains(env.snapshots.acks or "", "ack wall1", "ack shown on the panel")
end)

T("console: tapping VERSIONS censuses and shows the roll-call on the monitor", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_0", { w = 36, h = 18 })
  env:touchAt(1.5, "monitor_0", 10, 7)   -- inside the VERSIONS button
  env:rednetAt(1.7, 7, { version = "16", label = "wall1" }, "basectl")
  env:monitorSnapshotAt(5.0, "roll", "monitor_0")  -- after the ~3s census, before exit
  env:charAt(6.0, "q")
  current = env
  env:run(CONSOLE, {}, { maxTime = 8 })
  local pings = 0
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "basectl" and type(s.message) == "table"
      and s.message.cmd == "version?" then pings = pings + 1 end
  end
  -- must re-ping (not a one-shot) so a busy box like the flux computer is
  -- caught instead of dropped
  if pings < 2 then fail("census did not re-ping (got " .. pings .. ")") end
  expectContains(env.snapshots.roll or "", "wall1", "roll-call on monitor")
end)

T("console: auto-updates when update-all is pushed from elsewhere", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_0", { w = 36, h = 18 })
  env.files["update"] = FAKE_UPDATER
  env:rednetAt(1.0, 9, { cmd = "update", token = "flux" }, "basectl")
  current = env
  local res = env:run(CONSOLE, {}, { maxTime = 5 })
  if res.reason ~= "shutdown" or not res.reboot then
    fail("console did not self-update on a base push, got " .. tostring(res.reason))
  end
  if env:file("updated.flag") ~= "yes" then fail("updater did not run") end
end)

T("console: tapping UPDATE SLEDS broadcasts a sled update when a token is set", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_0", { w = 36, h = 18 })
  env.files["sledctl.conf"] = 'return { token = "hunter2" }'
  env:touchAt(1.5, "monitor_0", 10, 12)  -- inside the UPDATE SLEDS button
  env:charAt(3.0, "q")
  current = env
  env:run(CONSOLE, {}, { maxTime = 5 })
  local sent
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "sledctl" and type(s.message) == "table"
      and s.message.cmd == "update" then sent = s end
  end
  if not sent then fail("UPDATE SLEDS did not broadcast on sledctl") end
  if sent.message.token ~= "hunter2" then fail("sled token = " .. tostring(sent.message.token)) end
end)

-- ----------------------------------------------------------------- runner

local passed = 0
for _, t in ipairs(tests) do
  current = nil
  local ok, err = pcall(t.fn)
  if ok then
    passed = passed + 1
    print(("PASS  %s"):format(t.name))
  else
    local msg = type(err) == "table" and err.testfail or tostring(err)
    failures[#failures + 1] = { name = t.name, msg = msg }
    print(("FAIL  %s"):format(t.name))
    print("      " .. msg:gsub("\n", "\n      "))
    if current and current.termText then
      print("      [terminal dump]")
      print("      " .. current:termText():gsub("\n", "\n      "))
    end
  end
end

print(("\n%d/%d passed, %d failed"):format(passed, #tests, #tests - passed))
os.exit(#failures == 0 and 0 or 1)
