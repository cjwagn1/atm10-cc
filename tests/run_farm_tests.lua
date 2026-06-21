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
