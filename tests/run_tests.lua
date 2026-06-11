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
