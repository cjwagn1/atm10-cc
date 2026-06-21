--[[
run_farm_tests.lua - Sulfur-Farm Builder test suite (Phase 2).

Run from the project root:
  toolchain/lua-5.2.4/src/lua tests/run_farm_tests.lua

Covers docs/FARM-BUILD-DESIGN.md: harness item-use + ME-crafting extensions,
then programs/farm.lua driven test-by-test (capture, plan, build, restock,
self-test, kill-resume). Every mock behavior and verbatim string cites a claim
in docs/FARM-RESEARCH.md (Q1..Q6) or a vendored source line.

The 97 telemetry tests (run_tests.lua) and 60 sled tests (run_sled_tests.lua)
stay untouched; run all three.
]]

local CC = dofile("harness/cc_env.lua")

local tests, failures = {}, {}
local function T(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local current
local function fail(msg)
  error({ testfail = msg }, 2)
end

local function eq(got, want, label)
  if got ~= want then
    fail(("%s: expected %s, got %s")
      :format(label or "value", tostring(want), tostring(got)))
  end
end

local function expectContains(haystack, needle, label)
  if type(haystack) ~= "string" then
    fail(("%s: expected a string containing %q, got %s")
      :format(label or "output", needle, tostring(haystack)))
  end
  if not haystack:find(needle, 1, true) then
    fail(("%s: expected to find %q\n--- actual ---\n%s\n--------------")
      :format(label or "output", needle, haystack))
  end
end

local function expectNotContains(haystack, needle, label)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    fail(("%s: expected NOT to find %q\n--- actual ---\n%s\n--------------")
      :format(label or "output", needle, haystack))
  end
end

-- load a Lua-table file the program wrote (blueprint / conf) for assertions
local function loadTable(text, label)
  if type(text) ~= "string" then
    fail((label or "table") .. ": not written (got " .. tostring(text) .. ")")
  end
  local chunk = load(text, "=t", "t", {})
  if not chunk then fail((label or "table") .. ": not loadable") end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= "table" then
    fail((label or "table") .. ": did not return a table")
  end
  return t
end

local FARM = "programs/farm.lua"

-- The canonical 3x3 blueprint capture produces (asserted in the capture tests),
-- written directly so build tests are decoupled from a capture run.
local BP_3x3 = [[return {
  size = { w = 3, h = 2, d = 3 },
  cells = {
    ["0,0,0"] = { kind = "soil", tier = "fertilized" },
    ["0,0,1"] = { kind = "soil", tier = "fertilized" },
    ["0,0,2"] = { kind = "soil", tier = "fertilized" },
    ["0,1,0"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["0,1,1"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["0,1,2"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["1,0,0"] = { kind = "soil", tier = "fertilized" },
    ["1,0,1"] = { kind = "water" },
    ["1,0,2"] = { kind = "soil", tier = "fertilized" },
    ["1,1,0"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["1,1,2"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["2,0,0"] = { kind = "soil", tier = "fertilized" },
    ["2,0,1"] = { kind = "soil", tier = "fertilized" },
    ["2,0,2"] = { kind = "soil", tier = "fertilized" },
    ["2,1,0"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["2,1,1"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["2,1,2"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
  },
}
]]

-- A build rig: turtle parked in clear air above an empty build site, work slots
-- pre-stocked with behavior-carrying items (so the build runs without AE), the
-- blueprint on disk, and a conf pointing at the stack base. plots defaults 1.
local function buildRig(opts)
  opts = opts or {}
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = opts.fuel or 50000 } }
  env.files["farm.blueprint"] = opts.blueprint or BP_3x3
  env.files["farm.conf"] = ([[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 2, d = 3 },
    heading = "east", lateral = "south", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = %d, fleet = "farm1",
  }]]):format(opts.plots or 1)
  env.turtle.inv = {
    [1] = { id = "minecraft:dirt", count = 64 },
    [2] = env:hoeItem{ durability = 2000 },
    [3] = env:fertilizerItem{ count = 64 },
    [4] = env:seedItem("mysticalagriculture:sulfur_crop", { count = 64 }),
    [5] = env:waterBucketItem(),
  }
  return env
end

-- parse the farm journal the program wrote (flat key=value lines)
local function parseFarmJournal(text)
  if type(text) ~= "string" then return nil end
  local j = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then j[k] = v end
  end
  return j
end

-- a 3x3 plot of only plain soil (no crop/water/fertilize): the build needs only
-- dirt, isolating the AE dirt-supply path
local BP_PLAIN_SOIL = (function()
  local cells = {}
  for dx = 0, 2 do
    for dz = 0, 2 do
      cells[#cells + 1] = ("    [%q] = { kind = \"soil\", tier = \"plain\" },")
        :format(dx .. ",0," .. dz)
    end
  end
  return "return {\n  size = { w = 3, h = 1, d = 3 },\n  cells = {\n"
    .. table.concat(cells, "\n") .. "\n  },\n}\n"
end)()

-- count blocks of a given id in a y-layer of the build footprint
local function countLayer(env, y, id, w, d, ox, oz)
  local n = 0
  for dx = 0, (w or 3) - 1 do
    for dz = 0, (d or 3) - 1 do
      local b = env:block((ox or 0) + dx, y, (oz or 0) + dz)
      if b and b.id == id then n = n + 1 end
    end
  end
  return n
end

-- Build a w x d sulfur plot at (ox,oy,oz): fertilized-farmland ring with sulfur
-- crops above, a water source at the footprint center. Mirrors the canonical
-- proven plot the builder copies. Crop age is set non-zero to prove capture
-- ignores it.
local function seedRefPlot(env, ox, oy, oz, w, d)
  local cx, cz = math.floor(w / 2), math.floor(d / 2)
  for dx = 0, w - 1 do
    for dz = 0, d - 1 do
      if dx == cx and dz == cz then
        env:setBlock(ox + dx, oy, oz + dz, { id = "minecraft:water" })
      else
        env:setBlock(ox + dx, oy, oz + dz,
          { id = "farmingforblockheads:fertilized_farmland_healthy" })
        env:setBlock(ox + dx, oy + 1, oz + dz,
          { id = "mysticalagriculture:sulfur_crop", state = { age = 7 } })
      end
    end
  end
end

-- ------------------------------------ 0. harness: Geo Scanner mock (auto-find)
-- AP Geo Scanner scan(radius): blocks in a cube around the turtle, coords
-- RELATIVE to it. The turtle uses this to FIND the plot it was never told.

T("geo scanner: scan(radius) returns blocks relative to the turtle", function()
  local env = CC.new{ turtle = { pos = { x = 10, y = 64, z = 10 },
    facing = "north", fuel = 100 } }
  env:addGeoScanner("scanner")
  env:setBlock(12, 64, 10,
    { id = "farmingforblockheads:fertilized_farmland_healthy" }) -- +2 east
  env:setBlock(10, 63, 9, { id = "minecraft:stone" })            -- -1 y, -1 z
  env.files["prog.lua"] = [[
    local s = peripheral.find("geo_scanner")
    local out = fs.open("out", "w")
    local found = {}
    for _, b in ipairs(s.scan(4)) do
      found[b.name] = b.x .. "," .. b.y .. "," .. b.z
    end
    out.writeLine(tostring(found["farmingforblockheads:fertilized_farmland_healthy"]))
    out.writeLine(tostring(found["minecraft:stone"]))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), "2,0,0\n0,-1,-1\n", "relative block positions")
end)

-- ----------------------------------------- 1. harness: turtle item-use mock
-- §Harness extensions (FARM-RESEARCH Q1): turtle.place dispatches an item's
-- useOn; the hoe tills dirt->farmland WITHOUT being consumed (durability only),
-- TurtlePlaceCommand.java:223 + vanilla HoeItem.useOn.

T("hoe: placeDown tills dirt to farmland, not consumed, durability drops", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100,
    inv = { [1] = nil } } }
  env.turtle.inv[1] = env:hoeItem{ durability = 100 }
  env:setBlock(0, 63, 0, { id = "minecraft:dirt" })   -- cell below the turtle
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.placeDown()))         -- till dirt below
    local d = turtle.getItemDetail(1, true)
    out.writeLine((d and d.name or "nil") .. " x" .. tostring(d and d.count))
    out.writeLine("dmg=" .. tostring(d and d.damage))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:block(0, 63, 0).id, "minecraft:farmland", "dirt tilled to farmland")
  eq(env:file("out"),
    "true\nminecraft:diamond_hoe x1\ndmg=1\n", "hoe survives, durability used")
end)

-- FfB red fertilizer: farmland -> fertilized_healthy ONCE, shrinks 1; its only
-- guard is player==null (FertilizerItem.java:116). The load-bearing negative:
-- on an ALREADY-fertilized cell it must NOT re-apply and NOT waste an item
-- (P0-2 at the mock layer) — converge guards depend on this being faithful.

T("fertilizer: farmland -> fertilized healthy, shrinks 1", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env.turtle.inv[1] = env:fertilizerItem{ count = 3 }
  env:setBlock(0, 63, 0, { id = "minecraft:farmland" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.placeDown()))
    out.writeLine(tostring(turtle.getItemCount(1)))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:block(0, 63, 0).id,
    "farmingforblockheads:fertilized_farmland_healthy", "now fertilized")
  eq(env:file("out"), "true\n2\n", "succeeded, shrank by 1")
end)

T("fertilizer: refuses an already-fertilized cell, wastes nothing", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env.turtle.inv[1] = env:fertilizerItem{ count = 3 }
  env:setBlock(0, 63, 0,
    { id = "farmingforblockheads:fertilized_farmland_healthy" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local ok, err = turtle.placeDown()
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    out.writeLine(tostring(turtle.getItemCount(1)))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"), "false Cannot place item here\n3\n",
    "refused, no item consumed")
end)

-- MA sulfur seed: BlockItem placed on a farmland top face -> crop age 0,
-- shrinks 1 (MysticalSeedsItem.java:17; FertilizedFarmlandBlock canSustainPlant
-- unconditional). Negative: needs farmland directly below the target cell.

T("seed: plants sulfur crop (age 0) above farmland, shrinks 1", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 100 } }
  env.turtle.inv[1] = env:seedItem("mysticalagriculture:sulfur_crop", { count = 5 })
  env:setBlock(0, 64, 0, { id = "farmingforblockheads:fertilized_farmland_healthy" })
  -- turtle at y66, placeDown targets y65 (empty), farmland is y64 (below target)
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.placeDown()))
    out.writeLine(tostring(turtle.getItemCount(1)))
    local ib, info = turtle.inspectDown()
    out.writeLine(tostring(info and info.name) .. " age="
      .. tostring(info and info.state and info.state.age))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:block(0, 65, 0).id, "mysticalagriculture:sulfur_crop", "crop placed")
  eq(env:file("out"),
    "true\n4\nmysticalagriculture:sulfur_crop age=0\n", "planted, shrank")
end)

T("seed: refuses to plant with no farmland brace below", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 100 } }
  env.turtle.inv[1] = env:seedItem("mysticalagriculture:sulfur_crop", { count = 5 })
  -- y64 is plain stone, not farmland
  env:setBlock(0, 64, 0, { id = "minecraft:stone" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local ok, err = turtle.placeDown()
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    out.writeLine(tostring(turtle.getItemCount(1)))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"), "false Cannot place item here\n5\n", "no brace, refused")
end)

-- Water bucket: emits a source into an air cell that has a solid brace;
-- emptied bucket written back (TurtlePlaceCommand.java:230-232; Q1-water).
-- Negative: rejects pure air (canDeployOnBlock won't engage).

T("water bucket: fills a braced air cell, bucket emptied", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env.turtle.inv[1] = env:waterBucketItem()
  env:setBlock(0, 62, 0, { id = "minecraft:farmland" }) -- floor brace below target
  -- target = y63 (empty), brace below at y62
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.placeDown()))
    out.writeLine(tostring(turtle.getItemDetail(1) and turtle.getItemDetail(1).name))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:block(0, 63, 0).id, "minecraft:water", "water source placed")
  eq(env:file("out"), "true\nminecraft:bucket\n", "bucket emptied")
end)

T("water bucket: refuses pure air with no brace", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env.turtle.inv[1] = env:waterBucketItem()
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local ok, err = turtle.placeDown()
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    out.writeLine(tostring(turtle.getItemDetail(1).name))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"), "false Cannot place item here\nminecraft:water_bucket\n",
    "refused, still a full bucket")
end)

-- --------------------------------------- 2. harness: ME Bridge crafting (Q2)
-- AP 0.7.62b MEBridgePeripheral: getItem/getItems/isCraftable (sync),
-- craftItem (async -> fires ae_crafting, raises observed stock), exportItem
-- (-> count, two-return on error). All machine-sourced (no fake player).

T("me bridge: getItem returns stock view or nil; isCraftable reflects flag", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  local seeds = { id = "mysticalagriculture:sulfur_seeds", count = 320,
    isCraftable = true, displayName = "Sulfur Seeds" }
  env:addMeBridge("me", { stored = 1, max = 2, usage = 0, items = { seeds } })
  env.files["prog.lua"] = [[
    local b = peripheral.wrap("me")
    local out = fs.open("out", "w")
    local it = b.getItem({ name = "mysticalagriculture:sulfur_seeds" })
    out.writeLine(it.name .. " " .. tostring(it.count) .. " craftable="
      .. tostring(it.isCraftable))
    out.writeLine(tostring(b.getItem({ name = "minecraft:nonexistent" })))
    out.writeLine(tostring(b.isCraftable({ name = "mysticalagriculture:sulfur_seeds" })))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"),
    "mysticalagriculture:sulfur_seeds 320 craftable=true\nnil\ntrue\n", "views")
end)

T("me bridge: craftItem is async, raises observed stock + fires ae_crafting", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  local fert = { id = "farmingforblockheads:red_fertilizer", count = 0,
    isCraftable = true }
  env:addMeBridge("me", { stored = 1, max = 2, usage = 0, items = { fert },
    craftSeconds = 1 })
  env.files["prog.lua"] = [[
    local b = peripheral.wrap("me")
    local out = fs.open("out", "w")
    local spec = { name = "farmingforblockheads:red_fertilizer", count = 5 }
    out.writeLine("before=" .. tostring(b.getItem(spec).count))
    local job = b.craftItem(spec)
    out.writeLine("job=" .. tostring(job ~= nil))
    -- gate on OBSERVED stock, value-agnostic (AM-2): poll until it arrives
    local gotEvent = false
    local deadline = os.startTimer(10)
    while b.getItem(spec).count < 5 do
      local ev = { os.pullEvent() }
      if ev[1] == "ae_crafting" then gotEvent = true end
      if ev[1] == "timer" and ev[2] == deadline then break end
    end
    out.writeLine("after=" .. tostring(b.getItem(spec).count))
    out.writeLine("event=" .. tostring(gotEvent))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 20, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), "before=0\njob=true\nafter=5\nevent=true\n",
    "craft completed, stock rose, event fired")
end)

T("me bridge: exportItem drops a behavior-carrying stack the turtle sucks", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  -- stock seeds carry the seedItem onUse so a pulled stack still plants
  local seeds = env:seedItem("mysticalagriculture:sulfur_crop", { count = 64 })
  seeds.isCraftable = true
  env:addMeBridge("me", { stored = 1, max = 2, usage = 0, items = { seeds },
    exportCell = { x = 0, y = 63, z = 0 } }) -- turtle sucks DOWN from here
  env.files["prog.lua"] = [[
    local b = peripheral.wrap("me")
    local out = fs.open("out", "w")
    local n = b.exportItem({ name = "mysticalagriculture:sulfur_seeds", count = 8 }, "up")
    out.writeLine("exported=" .. tostring(n))
    out.writeLine("sucked=" .. tostring(turtle.suckDown()))
    out.writeLine("have=" .. tostring(turtle.getItemCount(1)))
    out.writeLine("name=" .. tostring(turtle.getItemDetail(1).name))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"),
    "exported=8\nsucked=true\nhave=8\nname=mysticalagriculture:sulfur_seeds\n",
    "export->ground->suck round trip")
end)

T("me bridge: exportItem two-returns (0, ERR) for an item not in stock", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env:addMeBridge("me", { stored = 1, max = 2, usage = 0, items = {},
    exportCell = { x = 0, y = 63, z = 0 } })
  env.files["prog.lua"] = [[
    local b = peripheral.wrap("me")
    local out = fs.open("out", "w")
    local n, err = b.exportItem({ name = "minecraft:coal_block", count = 4 }, "up")
    out.writeLine(tostring(n) .. " " .. tostring(err))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(env:file("out"), "0 ITEM_NOT_FOUND\n", "two-return error convention")
end)

-- A real ME Bridge exports to the inventory on the GIVEN side of the bridge;
-- a side with no inventory delivers nothing. o.deliver = { side, cell } models
-- a chest on exactly one side (e.g. the operator's "bridge next to a chest").
-- This is what supply calibration discovers (Task #17).
T("me bridge: exportItem honors the side - only the chest side delivers", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  local dirt = { id = "minecraft:dirt", count = 64 }
  env:addMeBridge("me", { stored = 1, max = 2, usage = 0, items = { dirt },
    deliver = { side = "north", cell = { x = 0, y = 65, z = 0 } } }) -- chest ABOVE
  env.files["prog.lua"] = [[
    local b = peripheral.wrap("me")
    local out = fs.open("out", "w")
    -- a side with no inventory: nothing delivered (real AP returns 0 + error)
    local n0, e0 = b.exportItem({ name = "minecraft:dirt", count = 4 }, "up")
    out.writeLine(tostring(n0) .. " " .. tostring(e0))
    -- the chest side delivers; the turtle sucks UP to collect it
    local n1 = b.exportItem({ name = "minecraft:dirt", count = 4 }, "north")
    out.writeLine(tostring(n1) .. " sucked=" .. tostring(turtle.suckUp()))
    out.writeLine("have=" .. tostring(turtle.getItemCount(1)))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"),
    "0 INVENTORY_NOT_FOUND\n4 sucked=true\nhave=4\n", "side-gated delivery")
end)

-- ------------------------------------ 2b. farm.lua: autonomous plot-find
-- The operator never tells the turtle where the plot is: with a Geo Scanner it
-- scans a radius, filters the plot signature, and reports the bounding box.

T("find: locates a sulfur plot it was never told about (Geo Scanner)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 70, z = 0 },
    facing = "north", fuel = 100 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 4, 64, 0, 3, 3) -- a 3x3 plot, NW corner 4 east + 6 below
  -- NO farm.conf at all - pure discovery
  current = env
  local res = env:run(FARM, { "find" }, { maxTime = 30 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "found a 3x3 plot", "located the plot by scanning")
end)

-- Real-world bug (operator report): the turtle HAD a Geo Scanner equipped but
-- farm printed "no Geo Scanner equipped". AP's GeoScannerPeripheral.
-- PERIPHERAL_TYPE is "geo_scanner" (underscore), NOT "geoScanner": peripheral
-- .find("geoScanner") never matches an equipped scanner. The harness now
-- registers the REAL type, so a stale camelCase find() must fail this.
T("find: detects an equipped scanner under AP's real type 'geo_scanner'", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 70, z = 0 },
    facing = "north", fuel = 100 } }
  env:addGeoScanner("scanner") -- registers "geo_scanner" (the real AP type)
  seedRefPlot(env, 4, 64, 0, 3, 3)
  current = env
  local res = env:run(FARM, { "find" }, { maxTime = 30 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "found a 3x3 plot",
    "scanner detected via the real geo_scanner type")
end)

-- Bulletproofing: even if a future build renames the type, an equipped upgrade
-- exposing scan() must still be found (so the operator never sees a false
-- "no Geo Scanner" again). Register under an unexpected type and require the
-- scan()-method fallback to discover it.
T("find: falls back to any peripheral exposing scan() (odd type string)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 70, z = 0 },
    facing = "north", fuel = 100 } }
  env:addGeoScanner("scanner", { type = "ap_future_scanner" })
  seedRefPlot(env, 4, 64, 0, 3, 3)
  current = env
  local res = env:run(FARM, { "find" }, { maxTime = 30 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "found a 3x3 plot",
    "scanner found by scan()-method fallback despite an odd type")
end)

T("setup wizard: no config at all -> finds, calibrates, scans, builds a copy", function()
  -- the turtle faces WEST (not the default) so a wrong heading calibration would
  -- mis-place the whole build; only correct discovery lands the copy right.
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "west", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 74, 0, 3, 3) -- the operator's plot: 3 east, 6 below (untold)
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 } -- a bare turtle pulls its hoe from AE
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    exportCell = { x = 0, y = 79, z = 0 },
    items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  -- NO farm.conf. Pass the copy count as an arg so the test isn't interactive.
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 40000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "found a 3x3 plot", "auto-found the plot")
  expectContains(env:termText(), "facing west", "calibrated its real heading")
  -- the copy lands one plot-height ABOVE the operator's plot: soil at y76
  eq(countLayer(env, 76, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 8, "copy soil ring built above the plot")
  eq(countLayer(env, 77, "mysticalagriculture:sulfur_crop", 3, 3, 3, 0), 8,
    "copy crops")
  eq(env:block(4, 76, 1) and env:block(4, 76, 1).id, "minecraft:water",
    "copy center water")
  eq(env:file("farm.conf") ~= nil, true, "wrote its own config for reboots")
end)

-- Task #17: the operator places the ME Bridge next to a chest and the turtle on
-- the chest - the bridge must export SIDEWAYS into the chest, not "up". The old
-- wizard hardcoded export_side="up"/suck="down", which silently delivers nothing
-- for that layout. The wizard now PROBES (export side x suck dir) and records the
-- pair that actually round-trips an item. Here the working handoff is a chest
-- ABOVE the turtle fed from the bridge's "south" side: NEITHER default axis is
-- right, so only probing both finds it.
T("setup wizard: auto-calibrates the bridge handoff (export side + suck dir)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 74, 0, 3, 3)
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    deliver = { side = "south", cell = { x = 0, y = 81, z = 0 } }, -- chest ABOVE park
    items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 60000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  local conf = loadTable(env:file("farm.conf"), "farm.conf")
  eq(conf.base.export_side, "south", "discovered the working export side")
  eq(conf.base.suck, "up", "discovered the working suck dir")
  -- and the build actually completes pulling through the calibrated handoff
  eq(countLayer(env, 76, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 8, "copy built via the calibrated supply path")
end)

T("find: reports nothing-found with no Geo Scanner and no plot", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 70, z = 0 },
    facing = "north", fuel = 100 } }
  current = env
  env:run(FARM, { "find" }, { maxTime = 10 })
  expectContains(env:termText(), "no plot found", "clear not-found message")
end)

-- The plot signature must be mod-agnostic: the operator's farm uses whatever
-- farmland/crop/accelerator blocks their pack provides, not the exact ids in the
-- canonical study. Match by substring so a different soil tier or crop mod still
-- registers (the old exact-id match silently saw "no plot").
T("find: matches a plot by generic farmland/crop signature (any mod)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 70, z = 0 },
    facing = "north", fuel = 5000 } }
  env:addGeoScanner("scanner")
  for dx = 0, 2 do
    for dz = 0, 2 do
      env:setBlock(3 + dx, 64, dz, { id = "farmersdelight:rich_farmland" })
      env:setBlock(3 + dx, 65, dz, { id = "croptopia:tomato_crop" })
    end
  end
  current = env
  env:run(FARM, { "find" }, { maxTime = 30 })
  expectContains(env:termText(), "found a 3x3 plot",
    "matched by generic farmland/crop signature, not hardcoded ids")
end)

-- When nothing matches, the turtle must report WHAT it saw + the scanner's reach,
-- so the operator can see whether the farm is out of range or uses other blocks
-- (instead of a dead-end "no plot"). Answers "what is it even looking for?".
T("find: no match -> reports the blocks it saw and the 16-block reach", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 70, z = 0 },
    facing = "north", fuel = 5000 } }
  env:addGeoScanner("scanner")
  for dx = -2, 2 do
    for dz = -2, 2 do env:setBlock(dx, 69, dz, { id = "minecraft:grass_block" }) end
  end
  current = env
  env:run(FARM, { "find" }, { maxTime = 30 })
  local t = env:termText()
  expectContains(t, "minecraft:grass_block", "reported what it actually saw")
  expectContains(t, "16 blocks", "explained the scanner's 16-block reach")
end)

-- Task #18: NO Geo Scanner at all. Set the turtle on top of the farm (one block
-- above the crops) and it finds the plot by flying a bounded spiral, inspecting
-- down, in a turtle-local frame - then builds a copy directly above. The floor
-- is truly just an advanced turtle (a scanner only makes the find robust at any
-- nearby position).
T("setup wizard (no scanner): finds the plot on foot and builds a copy", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 90000 } }
  -- NO geo scanner. Plot crops at y65 (one below the drop), close enough to spiral
  seedRefPlot(env, 1, 64, 0, 3, 3)
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    exportCell = { x = 0, y = 65, z = 0 }, -- chest directly below the drop (suck down)
    items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 120000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "found a 3x3 plot", "found the plot on foot")
  expectContains(env:termText(), "no Geo Scanner", "told the operator it searched on foot")
  -- copy soil one plot-height above the original (soil y64, h2 -> copy soil y66);
  -- footprint ox=1,oz=0 mirrors the seeded plot at (1,64,0)
  eq(countLayer(env, 66, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 1, 0), 8, "copy soil ring built above the plot")
  eq(countLayer(env, 67, "mysticalagriculture:sulfur_crop", 3, 3, 1, 0), 8,
    "copy crops")
  eq(env:block(2, 66, 1) and env:block(2, 66, 1).id, "minecraft:water",
    "copy center water")
end)

-- A radius-16 scan costs ~5274 fuel (SphereOperation getCost); a radius-8 scan
-- is FREE. The wizard scans several times, so a costly radius drains the turtle
-- and every later scan fails ("found once, now never"). Default to the free 8;
-- a bigger radius needs an explicit arg.
T("find: default scan is the free radius 8 (a costly 16 needs an explicit arg)", function()
  local function plotAt11()
    local env = CC.new{ turtle = { pos = { x = 0, y = 70, z = 0 },
      facing = "north", fuel = 5000 } }
    env:addGeoScanner("scanner")
    for dx = 0, 2 do
      for dz = 0, 2 do
        env:setBlock(11 + dx, 64, dz, { id = "minecraft:farmland" })
      end
    end
    return env
  end
  local e1 = plotAt11(); current = e1
  e1:run(FARM, { "find" }, { maxTime = 30 })
  expectContains(e1:termText(), "no plot found",
    "the free radius-8 default doesn't reach 11 blocks")
  local e2 = plotAt11(); current = e2
  e2:run(FARM, { "find", "16" }, { maxTime = 30 })
  expectContains(e2:termText(), "found a 3x3 plot", "an explicit radius 16 reaches it")
end)

-- A turtle can only call a peripheral that's touching it; a chest can't be
-- face-adjacent to both the turtle and an adjacent bridge. So the simplest setup
-- is the ME Bridge ON the turtle, exporting straight into its inventory
-- (getHandlerFromDirection returns the adjacent turtle's handler - source-
-- verified). The wizard detects this (suck="self") and gathers pulls into the
-- work slot. No chest, no suck cell.
T("setup wizard: a bridge ON the turtle exports straight into it (no chest)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 74, 0, 3, 3)
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    intoTurtle = "north", -- bridge on my north face; export pushes into my inventory
    items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 60000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  local conf = loadTable(env:file("farm.conf"), "farm.conf")
  eq(conf.base.suck, "self", "detected the direct-into-turtle handoff")
  eq(conf.base.export_side, "north", "recorded the export side that feeds me")
  eq(countLayer(env, 76, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 8, "copy built pulling straight into the turtle")
end)

-- An autocraft-heavy AE may keep NO raw stock (everything crafted on demand), so
-- the handoff calibration has nothing stocked to push through. It must craft a
-- probe (dirt, which the build needs anyway) instead of giving up and assuming a
-- chest. Operator's base is exactly this - "autocraft anything it needs".
T("setup wizard: calibrates the handoff when AE keeps no stock (crafts a probe)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 74, 0, 3, 3)
  -- everything is craftable but NOTHING is stocked (count 0): an autocraft base
  local dirt = { id = "minecraft:dirt", count = 0, isCraftable = true }
  local hoe = env:hoeItem{ durability = 1561 }; hoe.count = 0; hoe.isCraftable = true
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 0 })
  seed.isCraftable = true
  local water = env:waterBucketItem(); water.count = 0; water.isCraftable = true
  local coal = { id = "minecraft:coal_block", count = 0, isCraftable = true }
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 0, craftSeconds = 1, items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 80000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  local conf = loadTable(env:file("farm.conf"), "farm.conf")
  eq(conf.base.suck, "self", "calibrated by crafting a probe, not assuming a chest")
  eq(countLayer(env, 76, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 8, "built by autocrafting everything from the ME")
end)

-- Heading calibration steps one block and reads the plot offset shift. At the
-- scan-range edge the bbox MIN can "stick" on the boundary (the leaving block is
-- replaced by its neighbour), so the old bbox-delta read 0 and failed. The
-- cross-correlation of the two scans reads the true step direction regardless.
T("setup wizard: reads heading even when a step pushes the plot to the range edge", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, -8, 74, 0, 3, 3) -- plot 8 west: the edge of the free radius-8 scan
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    intoTurtle = "north", items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 60000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "facing east", "read the true heading despite the edge step")
  eq(countLayer(env, 76, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, -8, 0), 8, "copy built at the correct (un-rotated) location")
end)

-- AP's ME Bridge type string has varied (me_bridge / meBridge /
-- advancedperipherals:me_bridge); an exact hasType("me_bridge") silently missed
-- it - the same camelCase trap as the geo scanner. Match "bridge" as a substring
-- across all of a peripheral's types (the proven mesensor approach).
T("setup wizard: detects an ME Bridge whose type is camelCase 'meBridge'", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 74, 0, 3, 3)
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { type = "meBridge", intoTurtle = "north",
    stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 60000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "ME Bridge found", "found the camelCase-typed bridge")
  eq(countLayer(env, 76, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 8, "built after detecting the bridge")
end)

-- A missing bridge must fail BEFORE the turtle wanders off to calibrate its
-- heading (the operator saw it step forward, then fail on the bridge, then step
-- back - confusing). Check the bridge first, move nothing.
T("setup wizard: a missing ME Bridge fails without the turtle moving", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 74, 0, 3, 3)
  -- NO ME bridge at all
  current = env
  env:run(FARM, { "setup", "1" }, { maxTime = 30000 })
  expectContains(env:termText(), "no ME Bridge", "reported the missing bridge")
  eq(env.turtle.pos.x, 0, "did not move x"); eq(env.turtle.pos.z, 0, "did not move z")
  eq(env.turtle.pos.y, 80, "did not move y")
end)

-- The stack must line up with the ground-floor plot grid: center each copy over
-- a ground-floor ender chest (the harvest anchor), not at the arbitrary bbox
-- corner. Here the signature bbox center (x5) is OFF the ender chest (x4), so an
-- aligned build shifts the stack to center on the chest.
T("setup wizard: centers the stack over a ground-floor ender chest", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  for dx = 0, 4 do
    for dz = 0, 2 do
      env:setBlock(3 + dx, 74, dz,
        { id = "farmingforblockheads:fertilized_farmland_healthy" })
    end
  end
  env:setBlock(4, 73, 1, { id = "enderstorage:ender_chest" }) -- below, off bbox center
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 0, craftSeconds = 1, items = { dirt, hoe, fert, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 80000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "aligning the stack", "aligned to the ender chest")
  -- centered over the chest at x4 -> build.x = 4 - floor(5/2) = 2 -> soil x2..6
  eq(env:block(2, 75, 0) and env:block(2, 75, 0).id,
    "farmingforblockheads:fertilized_farmland_healthy",
    "aligned soil reaches the chest-centered x2")
  eq(env:block(7, 75, 0), nil, "NOT at the un-aligned bbox-corner x7")
end)

T("reset: wipes config, blueprint, and journal back to first-run state", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env.files["farm.conf"] = "return { origin = { x = 0, y = 0, z = 0 } }"
  env.files["farm.blueprint"] = "return { size = { w = 1, h = 1, d = 1 }, cells = {} }"
  env.files["farm.journal"] = "phase=build\npos=0,0,0\nheading=east\n"
  env.files["farm.journal.bak"] = "phase=build\npos=0,0,0\nheading=east\n"
  current = env
  env:run(FARM, { "reset" }, { maxTime = 10 })
  eq(env:file("farm.conf"), nil, "config deleted")
  eq(env:file("farm.blueprint"), nil, "blueprint deleted")
  eq(env:file("farm.journal"), nil, "journal deleted")
  eq(env:file("farm.journal.bak"), nil, "journal backup deleted")
end)

-- `farm ae` is a diagnostic: it reports what the bridge's AE grid actually
-- exposes and PROVES a real pull (or shows the grid is empty = the bridge isn't
-- joined to the network). The operator needs to SEE the AE works.
T("ae: diagnostic reports the grid and proves a real pull", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  local dirt = { id = "minecraft:dirt", count = 256 }
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 5, items = { dirt } })
  current = env
  env:run(FARM, { "ae" }, { maxTime = 30 })
  local t = env:termText()
  expectContains(t, "grid item types: 1", "reported the grid contents")
  expectContains(t, "dirt: count=256", "found dirt in the grid")
  expectContains(t, "PULL OK", "proved a real pull from AE")
end)

T("ae: an empty/disconnected bridge shows 0 item types and PULL FAILED", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env:addMeBridge("me", { stored = 0, max = 2e6, usage = 0, items = {} })
  current = env
  env:run(FARM, { "ae" }, { maxTime = 30 })
  local t = env:termText()
  expectContains(t, "grid item types: 0", "empty grid reported")
  expectContains(t, "PULL FAILED", "couldn't pull from an empty grid")
end)

-- ------------------------------------------- 3. farm.lua: capture (Q3)
-- Inspect-traversal of a reference plot -> normalized blueprint. Fertilized
-- farmland becomes a soil recipe (build = dirt + till + fertilize), never a
-- placeable block (FARM-RESEARCH Q3/§4). Crop age is dropped (plant fresh).

T("capture: scans a 3x3 plot into a normalized blueprint", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 5000 } }
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 2, d = 3 },
    heading = "east", lateral = "south", scan_y = 66, fleet = "farm1",
  }]]
  seedRefPlot(env, 0, 64, 0, 3, 3)
  current = env
  local res = env:run(FARM, { "capture" }, { maxTime = 600 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  local bp = loadTable(env:file("farm.blueprint"), "blueprint")
  eq(bp.size.w, 3, "w"); eq(bp.size.d, 3, "d")
  -- ring cell: crop recorded, soil INFERRED below it (fertilized)
  eq(bp.cells["0,1,0"].kind, "crop", "ring crop recorded")
  eq(bp.cells["0,1,0"].id, "mysticalagriculture:sulfur_crop", "crop id kept")
  eq(bp.cells["0,1,0"].age, nil, "crop age dropped (plant fresh)")
  eq(bp.cells["0,0,0"].kind, "soil", "soil under crop")
  eq(bp.cells["0,0,0"].tier, "fertilized", "fertilized => recipe")
  -- center: water at soil level, air (omitted) above
  eq(bp.cells["1,0,1"].kind, "water", "center water recorded")
  eq(bp.cells["1,1,1"], nil, "center crop level is air (omitted)")
end)

-- With a Geo Scanner the capture reads the WHOLE 3D structure, so soil + crops
-- UNDER an accelerator/cable/chest canopy are recorded - not just the top block.
-- This is the fix for a real farm whose top surface is all infrastructure (a
-- top-down probe captured only the canopy and the build then placed nothing).
T("capture: 3D scan records layers under a top canopy (not just the top)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 68, z = 0 },
    facing = "east", fuel = 5000 } }
  env:addGeoScanner("scanner")
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 1, h = 3, d = 1 },
    heading = "east", scan_y = 68, fleet = "farm1",
  }]]
  env:setBlock(0, 64, 0, { id = "farmingforblockheads:fertilized_farmland_healthy" })
  env:setBlock(0, 65, 0, { id = "mysticalagriculture:sulfur_crop" })
  env:setBlock(0, 66, 0, { id = "ae2:growth_accelerator" }) -- the canopy on top
  current = env
  local res = env:run(FARM, { "capture" }, { maxTime = 600 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  local bp = loadTable(env:file("farm.blueprint"), "blueprint")
  eq(bp.cells["0,0,0"].kind, "soil", "soil captured under the canopy")
  eq(bp.cells["0,1,0"].kind, "crop", "crop captured under the canopy")
  eq(bp.cells["0,2,0"].kind, "block", "the canopy block itself captured")
  eq(bp.cells["0,2,0"].id, "ae2:growth_accelerator", "canopy id kept")
end)

T("capture: re-running is idempotent (same blueprint)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 9000 } }
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 2, d = 3 },
    heading = "east", lateral = "south", scan_y = 66, fleet = "farm1",
  }]]
  seedRefPlot(env, 0, 64, 0, 3, 3)
  current = env
  env:run(FARM, { "capture" }, { maxTime = 600 })
  local first = env:file("farm.blueprint")
  -- turtle is back; re-place it at the scan origin and re-capture
  env.turtle.pos = { x = 0, y = 66, z = 0 }; env.turtle.facing = "east"
  env:run(FARM, { "capture" }, { maxTime = 600 })
  eq(env:file("farm.blueprint"), first, "second capture identical")
end)

-- ------------------------------------------ 4. farm.lua: single-plot build
-- Layer-by-layer bottom-up, observe-then-act per cell (P0-2). Soil ring +
-- center water at Y0, sulfur crops at Y0+1.

T("build: single plot from empty world matches the blueprint", function()
  local env = buildRig()
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 4000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  -- soil layer Y0=100: 8 fertilized ring cells + 1 water center
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    8, "8 fertilized soil cells")
  eq(env:block(1, 100, 1).id, "minecraft:water", "center water")
  -- crop layer Y0+1=101: 8 sulfur crops (center is air above water)
  eq(countLayer(env, 101, "mysticalagriculture:sulfur_crop"), 8, "8 crops")
  eq(env:block(1, 101, 1), nil, "center crop level stays air")
  -- journal cleared on completion
  eq(env:file("farm.journal"), nil, "journal deleted after success")
end)

T("build: re-running over a finished plot is a converge no-op (idempotent)", function()
  local env = buildRig()
  current = env
  env:run(FARM, { "build" }, { maxTime = 4000 })
  -- snapshot fertilizer count; a second build must not re-fertilize / re-plant
  env.turtle.pos = { x = 0, y = 120, z = 0 }; env.turtle.facing = "east"
  local fertBefore = env.turtle.inv[3] and env.turtle.inv[3].count
  local seedBefore = env.turtle.inv[4] and env.turtle.inv[4].count
  env:run(FARM, { "build" }, { maxTime = 4000 })
  eq(env.turtle.inv[3] and env.turtle.inv[3].count, fertBefore,
    "no fertilizer consumed on re-run")
  eq(env.turtle.inv[4] and env.turtle.inv[4].count, seedBefore,
    "no seed consumed on re-run")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    8, "still 8 fertilized")
end)

-- a water-free 3x3 (all 9 cells soil+crop) so stacking can be tested without an
-- AE bucket refill between plots (refill is exercised in the supply tests)
local BP_3x3_NOWATER = (function()
  local cells = {}
  for dx = 0, 2 do
    for dz = 0, 2 do
      cells[#cells + 1] = ("    [%q] = { kind = \"soil\", tier = \"fertilized\" },")
        :format(dx .. ",0," .. dz)
      cells[#cells + 1] = ("    [%q] = { kind = \"crop\", id = \"mysticalagriculture:sulfur_crop\" },")
        :format(dx .. ",1," .. dz)
    end
  end
  return "return {\n  size = { w = 3, h = 2, d = 3 },\n  cells = {\n"
    .. table.concat(cells, "\n") .. "\n  },\n}\n"
end)()

T("build: re-running over a finished 2-plot stack does not self-obstruct", function()
  local env = buildRig{ plots = 2, blueprint = BP_3x3_NOWATER }
  current = env
  env:run(FARM, { "build" }, { maxTime = 9000 })       -- build the stack
  -- operator re-runs (journal was deleted on completion): must skip to the top
  -- plot and re-converge, not try to descend into the buried plot 0
  env.turtle.pos = { x = 0, y = 120, z = 0 }; env.turtle.facing = "east"
  local fertBefore = env.turtle.inv[3] and env.turtle.inv[3].count
  local res = env:run(FARM, { "build" }, { maxTime = 9000 })
  eq(res.reason, "done", "re-run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "halted", "re-run did not self-obstruct")
  eq(countLayer(env, 102, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot1 still intact after re-run")
  eq(env.turtle.inv[3] and env.turtle.inv[3].count, fertBefore,
    "no materials consumed on the converge re-run")
end)

T("build: raising plots and re-running extends the stack", function()
  local env = buildRig{ plots = 1, blueprint = BP_3x3_NOWATER }
  current = env
  env:run(FARM, { "build" }, { maxTime = 9000 })          -- build 1 plot
  -- operator raises plots and re-runs; the build extends from plot 1 upward
  env.files["farm.conf"] = env.files["farm.conf"]:gsub("plots = 1", "plots = 2")
  env.turtle.pos = { x = 0, y = 120, z = 0 }; env.turtle.facing = "east"
  local res = env:run(FARM, { "build" }, { maxTime = 9000 })
  eq(res.reason, "done", "extend reason (err=" .. tostring(res.err) .. ")")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot0 intact")
  eq(countLayer(env, 102, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot1 added by the extend re-run")
end)

T("build: stacks 2 plots, plot N+1 base = plot N base + height", function()
  local env = buildRig{ plots = 2, blueprint = BP_3x3_NOWATER }
  current = env
  env:run(FARM, { "build" }, { maxTime = 9000 })
  -- plot 0 at Y0=100 (no-water blueprint: all 9 cells soil+crop)
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot0 soil")
  eq(countLayer(env, 101, "mysticalagriculture:sulfur_crop"), 9, "plot0 crops")
  -- plot 1 at Y0=102 (= 100 + height 2)
  eq(countLayer(env, 102, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot1 soil at base+height")
  eq(countLayer(env, 103, "mysticalagriculture:sulfur_crop"), 9, "plot1 crops")
end)

-- A captured farm includes infrastructure blocks the turtle can't reproduce: an
-- NBT-keyed ender chest (the external harvest output), keyed cables, etc. The AE
-- has no pattern for those, so the build must SKIP them (warn) and finish the
-- sulfur-growing part, not halt the whole stack.
local BP_WITH_INFRA = [[return {
  size = { w = 2, h = 1, d = 1 },
  cells = {
    ["0,0,0"] = { kind = "soil", tier = "plain" },
    ["1,0,0"] = { kind = "block", id = "enderstorage:ender_chest" },
  },
}
]]

-- The operator's ender chest IS in AE, but frequency-keyed (NBT), so a plain
-- {name=} lookup misses it. The build must pull it by fingerprint and place it
-- (the operator re-keys it after) - "replicate everything".
T("build: pulls an NBT-keyed block (frequency ender chest) by fingerprint", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] = [[return {
    size = { w = 2, h = 1, d = 1 },
    cells = {
      ["0,0,0"] = { kind = "soil", tier = "plain" },
      ["1,0,0"] = { kind = "block", id = "enderstorage:ender_chest" },
    },
  }
  ]]
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 2, h = 1, d = 1 },
    heading = "east", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      staging = { x = 0, y = 115, z = -2 }, suck = "down", export_side = "up" },
  }]]
  local dirt = { id = "minecraft:dirt", count = 256 }
  -- in AE but ONLY matchable by fingerprint (frequency NBT), not by name
  local chest = { id = "enderstorage:ender_chest", count = 8,
    fingerprint = "ender_chest:white/white/white", nbtKeyed = true }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0,
    exportCell = { x = 0, y = 115, z = -2 }, items = { dirt, chest } })
  env.turtle.inv = { [2] = env:hoeItem{ durability = 2000 } }
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 8000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "skipping", "did not skip - pulled it by fingerprint")
  eq(env:block(1, 100, 0) and env:block(1, 100, 0).id, "enderstorage:ender_chest",
    "the frequency ender chest was placed")
end)

T("build: an un-obtainable infrastructure block is skipped, not a fatal halt", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] = BP_WITH_INFRA
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 2, h = 1, d = 1 },
    heading = "east", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      staging = { x = 0, y = 115, z = -2 }, suck = "down", export_side = "up" },
  }]]
  local dirt = { id = "minecraft:dirt", count = 256 } -- AE has dirt, NOT the chest
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0,
    exportCell = { x = 0, y = 115, z = -2 }, items = { dirt } })
  env.turtle.inv = { [2] = env:hoeItem{ durability = 2000 } }
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 8000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "halted", "did not halt on the un-obtainable block")
  expectContains(env:termText(), "skipping enderstorage:ender_chest", "warned about the skip")
  eq(env:block(0, 100, 0) and env:block(0, 100, 0).id, "minecraft:farmland",
    "the soil (sulfur-growing part) still got built")
  eq(env:file("farm.journal"), nil, "build completed despite the skip")
end)

-- ----------------------------------------- 5. farm.lua: supply / restock (Q2)
-- The build pulls and crafts every material from AE. Empty work slots + a
-- stocked ME bridge -> a full plot. Fertilizer is crafted on demand (gate on
-- observed stock). All exports land on the staging cell the turtle sucks.

-- a build rig whose work slots are EMPTY (only a hoe) and an ME bridge supplies
-- dirt/seed/water/coal and CRAFTS fertilizer. Park above the stack, staging
-- one below the park (suck down).
local function supplyRig(opts)
  opts = opts or {}
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] = opts.blueprint or BP_3x3
  env.files["farm.conf"] = ([[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 2, d = 3 },
    heading = "east", lateral = "south", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = %d, fleet = "farm1",
    travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      staging = { x = 0, y = 115, z = -2 }, suck = "down", export_side = "up" },
  }]]):format(opts.plots or 1)
  local dirt = { id = "minecraft:dirt", count = 256, isCraftable = false }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  seed.isCraftable = false
  local water = env:waterBucketItem(); water.count = 16; water.isCraftable = false
  local coal = { id = "minecraft:coal_block", count = 64, isCraftable = false }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    exportCell = { x = 0, y = 115, z = -2 },
    items = { dirt, fert, seed, water, coal } })
  env.turtle.inv = { [2] = env:hoeItem{ durability = 2000 } } -- only a hoe
  env._fert = fert -- expose for assertions
  return env
end

T("supply: build pulls dirt/seed/water and CRAFTS fertilizer from AE", function()
  local env = supplyRig()
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 12000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    8, "8 fertilized soil pulled+crafted")
  eq(env:block(1, 100, 1).id, "minecraft:water", "center water pulled")
  eq(countLayer(env, 101, "mysticalagriculture:sulfur_crop"), 8, "8 crops planted")
end)

T("supply: stacks TWO water-bearing plots (emptied bucket is evacuated)", function()
  -- regression for the emptied-bucket slot-strand: plot 0 empties the bucket,
  -- and plot 1's center water must still pull a fresh full bucket + lay its own
  -- sub-floor (the cell below it is plot 0's air crop-center)
  local env = supplyRig{ plots = 2 }
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 16000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:block(1, 100, 1).id, "minecraft:water", "plot0 center water")
  eq(env:block(1, 102, 1).id, "minecraft:water", "plot1 center water (refilled)")
  -- each water cell got a solid sub-floor directly beneath it
  if not env:block(1, 99, 1) then fail("plot0 water has no sub-floor") end
  if not env:block(1, 101, 1) then fail("plot1 water has no sub-floor") end
end)

-- THE in-game bug: a turtle reaches the ME Bridge only while FACING it (an
-- adjacent block, not a network peripheral), and navigation leaves it facing
-- elsewhere -> it reads an empty grid and reports "AE has nothing", even though
-- `farm ae` (which never turns) pulls fine. The build must turn to face the
-- bridge (cfg.base.bridge_facing) before every pull. whenFacing models the
-- constraint the harness never did.
T("supply: pulls from a bridge it can only read while FACING it", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] = BP_PLAIN_SOIL
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 1, d = 3 },
    heading = "east", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      suck = "self", export_side = "north", bridge_facing = "south" },
  }]]
  local dirt = { id = "minecraft:dirt", count = 256 }
  -- the turtle can ONLY read this bridge while facing south
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "south",
    stored = 1e6, max = 2e6, usage = 0, items = { dirt } })
  env.turtle.inv = { [2] = env:hoeItem{ durability = 2000 } }
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 10000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(countLayer(env, 100, "minecraft:farmland"), 9,
    "tilled all 9 - it turned to face the bridge before each pull")
end)

-- ANY hoe tills, so the builder must not insist on a diamond hoe specifically -
-- the operator's exact diamond hoe may have no encoded AE autocraft pattern even
-- though they can craft it by hand. If another hoe is stocked or craftable, use
-- it. (operator hit "no-hoe" with a diamond hoe they said was craftable.)
T("supply: uses any craftable hoe when the configured one has no AE pattern", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] = BP_PLAIN_SOIL
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 1, d = 3 },
    heading = "east", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      staging = { x = 0, y = 115, z = -2 }, suck = "down", export_side = "up" },
  }]]
  local dirt = { id = "minecraft:dirt", count = 256 }
  -- the default diamond hoe is NOT in the grid; a netherite hoe IS craftable
  local nhoe = env:hoeItem{ id = "minecraft:netherite_hoe", durability = 2031 }
  nhoe.count = 0; nhoe.isCraftable = true
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    exportCell = { x = 0, y = 115, z = -2 }, items = { dirt, nhoe } })
  env.turtle.inv = {} -- no hoe to start - it must pull one from AE
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 12000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(countLayer(env, 100, "minecraft:farmland"), 9,
    "tilled all 9 with a substitute hoe (no diamond-hoe pattern needed)")
end)

T("supply: a worn hoe is swapped for a fresh one (no silent un-tilled cells)", function()
  -- only dirt+hoe needed (plain soil). Start with a near-broken hoe (1 use
  -- left, 9 cells to till) and stock a fresh hoe in AE. Without the swap the
  -- hoe breaks and later cells stay un-tilled while the build reports done.
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] = BP_PLAIN_SOIL
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 1, d = 3 },
    heading = "east", lateral = "south", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      staging = { x = 0, y = 115, z = -2 }, suck = "down", export_side = "up" },
  }]]
  local dirt = { id = "minecraft:dirt", count = 256 }
  local freshHoe = env:hoeItem{ durability = 1561 }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0,
    exportCell = { x = 0, y = 115, z = -2 }, items = { dirt, freshHoe } })
  env.turtle.inv = { [2] = env:hoeItem{ durability = 1561, damage = 1559 } }
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 12000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(countLayer(env, 100, "minecraft:farmland"), 9, "all 9 cells tilled")
end)

T("supply: a craft was actually issued for the out-of-stock fertilizer", function()
  local env = supplyRig()
  current = env
  env:run(FARM, { "build" }, { maxTime = 12000 })
  -- fertilizer started at 0 and is craftable; after the build the AE stock must
  -- have been crafted up then drawn down by the 8 ring applications
  -- (net: a craft happened, else the soil would be plain farmland)
  eq(countLayer(env, 100, "minecraft:farmland"), 0, "no plain farmland left")
end)

-- -------------------------------------------- 6. farm.lua: self-test gate
-- Before any real plot: prove ME-pull, craft, and the till/fertilize/plant/
-- water chain on a scratch column. Pass => build; fail => build NOTHING.

local function selftestRig(opts)
  opts = opts or {}
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 120000 } }
  env.files["farm.blueprint"] = BP_3x3
  env.files["farm.conf"] = ([[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 2, d = 3 },
    heading = "east", lateral = "south", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 126,
    base = { bridge = "me", park = { x = 0, y = 126, z = -2 },
      staging = { x = 0, y = 125, z = -2 }, suck = "down", export_side = "up",
      scratch = { x = 6, y = 118, z = 0 },
      test_item = %q, craft_probe = "farmingforblockheads:red_fertilizer" },
  }]]):format(opts.test_item or "minecraft:dirt")
  env:setBlock(6, 118, 0, { id = "minecraft:stone" }) -- scratch soil-column floor
  env:setBlock(7, 118, 0, { id = "minecraft:stone" }) -- scratch water-column floor
  local dirt = { id = "minecraft:dirt", count = 256 }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    exportCell = { x = 0, y = 125, z = -2 },
    items = { dirt, fert, seed, water, coal } })
  env.turtle.inv = { [2] = env:hoeItem{ durability = 2000 } }
  return env
end

T("self-test: passes the scratch chain, then builds the plot", function()
  local env = selftestRig()
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 30000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "self-test passed", "self-test ran + passed")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    8, "plot built after passing self-test")
end)

T("self-test: the 'farm selftest' command runs the check and builds no plot", function()
  local env = selftestRig()
  current = env
  local res = env:run(FARM, { "selftest" }, { maxTime = 12000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "self-test passed", "the command ran the self-test")
  expectNotContains(env:termText(), "unknown command", "selftest is a real command")
  eq(env:block(0, 100, 0), nil, "build site untouched by a standalone self-test")
end)

T("self-test: a broken ME pull aborts and builds NOTHING", function()
  local env = selftestRig{ test_item = "minecraft:unobtainium_probe" }
  current = env
  env:run(FARM, { "build" }, { maxTime = 30000 })
  expectContains(env:termText(), "SELF-TEST FAILED", "aborted loudly")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    0, "no plot cells touched on self-test failure")
  eq(env:block(0, 100, 0), nil, "build site untouched")
end)

-- ----------------------------------------- 7. farm.lua: kill-resume (C4/C5)
-- A chunk unload / server restart kills the computer at ANY instant. Write-
-- ahead journaling + observe-then-act converge must resume cleanly with no
-- double-spend. The harness restartAt() abandons the run mid-command exactly
-- like the C5 queued-but-dropped window.

T("kill-resume: mid-build kills resume to a correct plot, no double-spend", function()
  for _, t in ipairs({ 6, 12, 18, 25, 33 }) do  -- all < 38.4s (mid-build)
    local env = buildRig{ blueprint = BP_3x3_NOWATER }
    env:restartAt(t)
    current = env
    env:run(FARM, { "build" }, { maxTime = 4000 })  -- run 1: killed at t
    -- write-ahead invariant: the journaled pose never gets ahead of the
    -- physical turtle (pos is saved AFTER a move succeeds; a killed move left
    -- both at the un-moved cell) - so resume navigates from the real position
    local j = parseFarmJournal(env:file("farm.journal"))
    if j and j.pos then
      eq(j.pos, ("%d,%d,%d"):format(env.turtle.pos.x, env.turtle.pos.y,
        env.turtle.pos.z), "kill@" .. t .. ": journal pos == physical pos")
    end
    env:run(FARM, {}, { maxTime = 9000 })  -- run 2: resume (no-arg)
    eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
      9, "kill@" .. t .. ": 9 fertilized after resume")
    eq(countLayer(env, 101, "mysticalagriculture:sulfur_crop"), 9,
      "kill@" .. t .. ": 9 crops after resume")
    eq(env.turtle.inv[3] and env.turtle.inv[3].count or 0, 64 - 9,
      "kill@" .. t .. ": exactly 9 fertilizer used (no double-fertilize)")
    eq(env.turtle.inv[4] and env.turtle.inv[4].count or 0, 64 - 9,
      "kill@" .. t .. ": exactly 9 seeds used (no double-plant)")
  end
end)

T("kill-resume: recovers a stranded AE export instead of double-pulling", function()
  -- only dirt is needed (plain soil). Strand 64 dirt on the staging cell (as if
  -- a kill struck between export and suck) and DRAIN AE dirt to 0, so the build
  -- can only finish by collecting the stranded stack - never by re-exporting.
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] = BP_PLAIN_SOIL
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 1, d = 3 },
    heading = "east", lateral = "south", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      staging = { x = 0, y = 115, z = -2 }, suck = "down", export_side = "up" },
  }]]
  local dirt = { id = "minecraft:dirt", count = 0 }  -- AE empty
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0,
    exportCell = { x = 0, y = 115, z = -2 }, items = { dirt } })
  env.turtle.inv = { [2] = env:hoeItem{ durability = 2000 } }
  env.ground["0,115,-2"] = { { id = "minecraft:dirt", count = 64 } } -- stranded
  -- resume scenario: a kill struck between export and suck during the build;
  -- the journal says build in progress + self-test already done (so it is not
  -- re-run and does not collect the stranded stack first)
  env.files["farm.journal"] =
    "phase=build\nplot=0\ndy=0\npos=0,120,0\nheading=east\nselftest=done\n"
  current = env
  local res = env:run(FARM, {}, { maxTime = 9000 })  -- no-arg = resume
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(countLayer(env, 100, "minecraft:farmland"), 9,
    "plot finished from the recovered stranded dirt (AE was empty)")
  eq(dirt.count, 0, "AE dirt never re-exported (no double-pull)")
end)

T("kill-resume: a kill mid-second-plot resumes both plots in the stack", function()
  local env = buildRig{ plots = 2, blueprint = BP_3x3_NOWATER }
  env:restartAt(55)  -- ~mid second plot (first plot ~38s)
  current = env
  env:run(FARM, { "build" }, { maxTime = 6000 })   -- killed mid plot 2
  env:run(FARM, {}, { maxTime = 12000 })           -- resume
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot0 intact")
  eq(countLayer(env, 102, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot1 completed after resume")
  eq(countLayer(env, 103, "mysticalagriculture:sulfur_crop"), 9, "plot1 crops")
end)

-- --------------------------------------- 8. farm.lua: mesh orchestration
-- Telemetry (source = fleet) on protocol "telemetry"; token-gated "update" on
-- the shared "basectl" channel, reusing the base mesh conventions.

T("orchestration: broadcasts farm telemetry during the build", function()
  local env = buildRig{ blueprint = BP_3x3_NOWATER }
  env:addModem("left")
  env:terminateAt(120)  -- stop the post-build idle loop
  current = env
  env:run(FARM, { "build" }, { maxTime = 200 })
  local found = false
  for _, m in ipairs(env.rednetSent) do
    if m.protocol == "telemetry" and type(m.message) == "table"
      and m.message.source == "farm1" then found = true end
  end
  if not found then fail("no farm telemetry broadcast on protocol 'telemetry'") end
end)

T("orchestration: a token-gated basectl 'update' is acked", function()
  local env = buildRig{ blueprint = BP_3x3_NOWATER }
  env:addModem("left")
  env.files["update.lua"] = "print('updated')" -- stand-in for the real updater
  env:rednetAt(70, 9, { token = "flux", cmd = "update" }, "basectl")
  env:rednetAt(72, 9, { token = "wrong", cmd = "update" }, "basectl") -- ignored
  env:terminateAt(120)
  current = env
  env:run(FARM, { "build" }, { maxTime = 200 })
  local acks = 0
  for _, m in ipairs(env.rednetSent) do
    if m.protocol == "basectl" and type(m.message) == "table" and m.message.ack then
      acks = acks + 1
    end
  end
  eq(acks, 1, "exactly one ack (valid token only)")
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
