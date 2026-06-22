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

-- The operator's REAL rig: a fused w x d, h=3 sulfur plot whose TOP surface is an
-- accelerator/cable/ENDER-CHEST canopy over the crops, a water source at the
-- centre, and a ground-floor ender chest at the centre column (the harvest anchor
-- the stack centres over). dy0 = fertilized soil ring + centre water; dy1 = sulfur
-- crops (none over the water centre); dy2 = canopy (accelerators + a cable + an
-- ender chest). Crop age is non-zero so capture proves it drops age.
local function seedOperatorPlot(env, ox, oy, oz, w, d)
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
      -- top canopy (dy2): a cable spine down the centre row, an ender chest at the
      -- centre, accelerators everywhere else
      local top
      if dx == cx and dz == cz then
        top = "enderstorage:ender_chest"
      elseif dx == cx then
        top = "ae2:cable"
      else
        top = "mysticalagriculture:essence_farmland"
      end
      env:setBlock(ox + dx, oy + 2, oz + dz, { id = top })
    end
  end
  -- ground-floor ender chest anchor directly under the plot centre (one below the
  -- soil), so findEnderChest aligns the stack over it
  env:setBlock(ox + cx, oy - 1, oz + cz, { id = "enderstorage:ender_chest" })
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

-- fix #2(a) harness fidelity: vendor WorldUtil.isEmptyBlock = isAir || liquid,
-- and TurtleDetectCommand returns !isEmptyBlock - so a FLUID reads detect()==
-- FALSE (undetected), opposite a solid. inspect() only fails on isAir, so water
-- IS inspectable. The harness must match, or doWater's sub-floor brace test never
-- fires on a water-over-water stack.
T("harness: detectDown is FALSE for a fluid but inspectDown still names it", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 100, z = 0 },
    facing = "north", fuel = 100 } }
  env:setBlock(0, 99, 0, { id = "minecraft:water", state = { level = 0 } })
  env.files["prog.lua"] = [[
    local has, info = turtle.inspectDown()
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.detectDown()))
    out.writeLine(tostring(has) .. "/" .. tostring(info and info.name))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), "false\ntrue/minecraft:water\n",
    "fluid: detectDown false, inspectDown still names water")
end)

-- ----------------------------------------- 1. harness: turtle item-use mock
-- §Harness extensions (FARM-RESEARCH Q1): turtle.place dispatches an item's
-- useOn; the hoe tills dirt->farmland WITHOUT being consumed (durability only),
-- TurtlePlaceCommand.java:223 + vanilla HoeItem.useOn.

-- ROOT CAUSE (definitive, vendored): CC:Tweaked does NOT till via place()-with-hoe.
-- Tilling is a TOOL-UPGRADE op: equip the hoe on a turtle side, then dig()/digDown().
-- Proof: CC's own gametests Hoe_dirt (turtle.dig() -> FARMLAND) and Hoe_dirt_below
-- (turtle.digDown() -> FARMLAND) in Turtle_Test.kt:258-273; diamond_hoe is a
-- computercraft:tool upgrade (data/.../turtle_upgrade/diamond_hoe.json). The tilling
-- code is TurtleTool.dig -> useTool (TurtleTool.java:266-324): dig() calls
-- hasToolUsage(stack) (HOE_TILL/SHOVEL_FLATTEN, PlatformHelperImpl.java:206-208) and
-- runs stack.useOn BEFORE any break. useTool has the "one extra block below" rule
-- (TurtleTool.java:309-311): when digDown is called and the cell directly below is
-- empty (the turtle occupies it from above), the target drops one further, so
-- digDown tills the dirt UNDER the stance.
--
-- place()-with-hoe does NOT till: the hoe is not a BucketItem/BlockItem so it never
-- gets TurtlePlaceCommand's working useItem special-case; its useOn returns PASS and
-- the deploy falls through, never tilling. The harness models BOTH outcomes faithfully
-- so the tests agree with the game (the old harness modeled place()-hoe as a successful
-- till - a wrong mental model that hid the v52 in-game halt).
T("hoe: place()-with-hoe does NOT till - it is not CC's tilling verb", function()
  -- turtle at (1,63,0) facing west, dirt at (0,63,0) - same Y, air above dirt:
  -- the geometry the old (wrong) SIDE-till used. place() must NOT convert it.
  local env = CC.new{ turtle = { pos = { x = 1, y = 63, z = 0 },
    facing = "west", fuel = 100, inv = { [1] = nil } } }
  env.turtle.inv[1] = env:hoeItem{ durability = 100 }
  env:setBlock(0, 63, 0, { id = "minecraft:dirt" })   -- cell IN FRONT of turtle
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.place()))             -- NOT CC's till verb
    out.writeLine(tostring(turtle.placeDown()))         -- nor is placeDown
    local d = turtle.getItemDetail(1, true)
    out.writeLine("dmg=" .. tostring(d and d.damage))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:block(0, 63, 0).id, "minecraft:dirt", "place()-with-hoe does NOT till")
  eq(env:file("out"), "false\nfalse\ndmg=0\n", "place/placeDown both fail, no spend")
end)

T("hoe: equip + digDown tills the dirt BELOW the stance (one-extra-block rule)", function()
  -- The Hoe_dirt_below gametest geometry (turtle_test.hoe_dirt_below.snbt): turtle
  -- at y=65 with a ONE-BLOCK AIR GAP below it (y=64 empty) and the dirt at y=63.
  -- useTool's DOWN rule (TurtleTool.java:309-311): digDown targets the cell directly
  -- below (y=64); it's EMPTY, so the target drops one further to the dirt at y=63,
  -- which now has air above it (the gap) -> it tills to farmland.
  local env = CC.new{ turtle = { pos = { x = 0, y = 65, z = 0 },
    facing = "east", fuel = 100, inv = { [1] = nil } } }
  env.turtle.inv[2] = env:hoeItem{ durability = 100 }
  env:setBlock(0, 63, 0, { id = "minecraft:dirt" }) -- two below, air gap at y=64
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    turtle.select(2)
    out.writeLine("equip=" .. tostring(turtle.equipLeft()))  -- hoe -> left side tool
    out.writeLine("slotEmpty=" .. tostring(turtle.getItemCount(2) == 0))
    out.writeLine("dig=" .. tostring(turtle.digDown()))      -- CC's real till verb
    turtle.down()                                            -- drop into the gap
    local h, i = turtle.inspectDown()                        -- now the farmland is below
    out.writeLine("after=" .. tostring(h and i.name))
    turtle.up()
    turtle.select(2); turtle.equipLeft()                     -- swap hoe back
    out.writeLine("backInSlot=" .. tostring(turtle.getItemCount(2) == 1))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:block(0, 63, 0).id, "minecraft:farmland", "digDown tilled the dirt below the gap")
  eq(env:file("out"),
    "equip=true\nslotEmpty=true\ndig=true\nafter=minecraft:farmland\nbackInSlot=true\n",
    "equip moves hoe to side, digDown tills the dirt below the gap, equip swaps it back")
end)

T("hoe: equip + dig tills the dirt IN FRONT (side stance)", function()
  -- turtle at (1,63,0) facing west, dirt in front at (0,63,0), air above the dirt.
  -- With the hoe equipped, turtle.dig() tills the front block (the Hoe_dirt
  -- gametest, Turtle_Test.kt:258-261).
  local env = CC.new{ turtle = { pos = { x = 1, y = 63, z = 0 },
    facing = "west", fuel = 100, inv = { [1] = nil } } }
  env.turtle.inv[2] = env:hoeItem{ durability = 100 }
  env:setBlock(0, 63, 0, { id = "minecraft:dirt" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    turtle.select(2); turtle.equipLeft()
    out.writeLine("dig=" .. tostring(turtle.dig()))
    local h, i = turtle.inspect()
    out.writeLine("after=" .. tostring(h and i.name))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:block(0, 63, 0).id, "minecraft:farmland", "dig tilled the front dirt")
  eq(env:file("out"), "dig=true\nafter=minecraft:farmland\n", "equip+dig tills in front")
end)

T("hoe: equip + dig does NOT break a non-dirt block in front (PASS-through dig)", function()
  -- a HOE_TILL tool only TILLS tillables; on stone in front, dig falls through to
  -- the normal break (CC dig still works as a tool). We assert it does not magically
  -- "till" stone into farmland.
  local env = CC.new{ turtle = { pos = { x = 1, y = 63, z = 0 },
    facing = "west", fuel = 100, inv = { [1] = nil } } }
  env.turtle.inv[2] = env:hoeItem{ durability = 100 }
  env:setBlock(0, 63, 0, { id = "minecraft:stone" })
  env.files["prog.lua"] = [[
    turtle.select(2); turtle.equipLeft()
    local out = fs.open("out", "w")
    out.writeLine("dig=" .. tostring(turtle.dig()))
    local h, i = turtle.inspect()
    out.writeLine("after=" .. tostring(h and i.name or "air"))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  -- stone breaks normally (dig=true) and is removed, NOT tilled to farmland
  eq(env:block(0, 63, 0), nil, "stone broken by the equipped hoe, not tilled")
  eq(env:file("out"), "dig=true\nafter=air\n", "non-tillable just breaks")
end)

-- ALT-SOIL (hoe-free tier): MA prudentium_farmland is an InfusedFarmlandBlock(TWO)
-- extending vanilla FarmBlock (ModBlocks.java:72; InfusedFarmlandBlock.java:29) wrapped
-- in a BaseBlockItem (ModBlocks.java:136) and AE2-craftable via the farmland_till recipe
-- (the hoe is a crafting catalyst, NOT a turtle tool). Placing it uses the WORKING
-- BlockItem path - no hoe, no till. The harness models it as a plain placeable soil:
-- it places onto air like any block, satisfies the seed's farmland-below brace, and
-- needs NO air-above gate. This gives the operator a clean tiling-free alternative.
T("alt-soil: prudentium_farmland places like a block and a seed plants on it", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 100, inv = {} } }
  env.turtle.inv[1] = env:essenceFarmlandItem{ count = 8 }
  env.turtle.inv[2] = env:seedItem("mysticalagriculture:sulfur_crop", { count = 8 })
  -- place the alt-soil at (0,65,0) from the stance above it (a plain BlockItem place -
  -- no hoe, no air-above gate), then plant a seed onto it from (0,66,0)
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    turtle.down()                        -- to (0,65,0)? no - place from above
    turtle.up()
    turtle.select(1)
    out.writeLine("soil=" .. tostring(turtle.placeDown())) -- soil at (0,65,0)
    local h, i = turtle.inspectDown()
    out.writeLine("after=" .. tostring(h and i.name))
    turtle.up()                          -- to (0,67,0); seed targets (0,66,0)? no
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:block(0, 65, 0) and env:block(0, 65, 0).id,
    "mysticalagriculture:prudentium_farmland", "placed as a plain block, no hoe needed")
  eq(env:file("out"),
    "soil=true\nafter=mysticalagriculture:prudentium_farmland\n",
    "placeDown placed the alt-soil with no air-above gate")
  -- and a seed plants on it (isFarmland accepts the essence farmland brace)
  env:setBlock(5, 64, 0, { id = "mysticalagriculture:prudentium_farmland" })
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 1 })
  local ok = seed.onUse(env, 5, 65, 0, "down", seed)
  eq(ok, true, "seed plants on essence farmland (isFarmland accepts it)")
  eq(env:block(5, 65, 0) and env:block(5, 65, 0).id,
    "mysticalagriculture:sulfur_crop", "crop sits on the alt-soil")
end)

-- KILL SAFETY: the equip-to-till approach has a window where the hoe is mounted on
-- a turtle side (out of its slot). An in-game reboot KEEPS an equipped upgrade (it's
-- part of the turtle), so on resume the hoe slot looks empty but the hoe is on the
-- LEFT side. ensureHoe must RECOVER it (equipLeft swaps it back) instead of failing
-- "no hoe available". This harness preserves env.turtle.equipped across runs, exactly
-- like a real reboot, so the recovery path is testable.
T("hoe: equipped-on-side hoe survives a reboot and is recovered into the slot", function()
  -- a hoe sits on the LEFT side (a kill struck mid-till); the slot is empty
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100, inv = {} } }
  env.turtle.equipped = { left = env:hoeItem{ durability = 100 }, right = nil }
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine("before=" .. tostring(turtle.getItemCount(2)))  -- slot empty
    turtle.select(2)
    turtle.equipLeft()                                            -- recover the hoe
    local d = turtle.getItemDetail(2)
    out.writeLine("after=" .. tostring(d and d.name) .. " x" .. tostring(d and d.count))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), "before=0\nafter=minecraft:diamond_hoe x1\n",
    "equipLeft swaps the equipped hoe back into the slot")
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
  -- the copy lands one plot-height ABOVE the operator's plot PLUS the default
  -- clearance gap (3): captured top y75 -> base y76 + 3 = soil at y79
  eq(countLayer(env, 79, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 8, "copy soil ring built a clearance gap above the plot")
  eq(countLayer(env, 80, "mysticalagriculture:sulfur_crop", 3, 3, 3, 0), 8,
    "copy crops")
  eq(env:block(4, 79, 1) and env:block(4, 79, 1).id, "minecraft:water",
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
  -- (soil at base y76 + clearance 3 = y79)
  eq(countLayer(env, 79, "farmingforblockheads:fertilized_farmland_healthy",
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
  -- copy soil one plot-height above the original PLUS the default clearance gap
  -- (soil y64, h2 -> base y66 + clearance 3 = copy soil y69); footprint ox=1,oz=0
  -- mirrors the seeded plot at (1,64,0)
  eq(countLayer(env, 69, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 1, 0), 8, "copy soil ring built a clearance gap above the plot")
  eq(countLayer(env, 70, "mysticalagriculture:sulfur_crop", 3, 3, 1, 0), 8,
    "copy crops")
  eq(env:block(2, 69, 1) and env:block(2, 69, 1).id, "minecraft:water",
    "copy center water")
end)

-- A radius-16 scan costs ~5274 fuel (SphereOperation getCost); a radius-8 scan
-- is FREE. The wizard scans several times, so a costly radius drains the turtle
-- and every later scan fails ("found once, now never"). Default to the free 8;
-- a bigger radius needs an explicit arg.
T("find: default scan is the free radius 8 (a costly 16 needs an explicit arg)", function()
  local function plotAt11()
    -- enough fuel to AFFORD the real radius-16 cost (~5274, SphereOperation),
    -- now that the harness deducts it - the free radius 8 still can't reach 11.
    local env = CC.new{ turtle = { pos = { x = 0, y = 70, z = 0 },
      facing = "north", fuel = 10000 } }
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
  eq(countLayer(env, 79, "farmingforblockheads:fertilized_farmland_healthy",
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
  eq(countLayer(env, 79, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 8, "built by autocrafting everything from the ME")
end)

-- An AE PATTERN existing (isCraftable=true) does NOT mean the autocraft job can
-- finish - that needs a free ME Crafting CPU + ingredients. The in-game halt was
-- exactly this: diamond_hoe showed craftable, but the job stalled, so the build
-- said "no-hoe". A STOCKED hoe is a sure pull, so prefer it over any craft - and
-- ANY *_hoe tills, so a stocked stone hoe must beat crafting the exact diamond.
T("supply: a stocked hoe is pulled instead of crafting a stalling diamond one", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 74, 0, 3, 3)
  local dirt = { id = "minecraft:dirt", count = 256 }
  -- a stocked stone hoe AND a craftable diamond hoe whose job would HANG forever
  local stone = env:hoeItem{ id = "minecraft:stone_hoe", durability = 131 }
  stone.count = 4
  local diamond = env:hoeItem{ durability = 1561 }; diamond.count = 0
  diamond.isCraftable = true; diamond.craftStalls = true
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 0, craftSeconds = 1,
    items = { dirt, stone, diamond, fert, seed, water, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 200000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(diamond.count, 0, "never scheduled the stalling diamond-hoe craft")
  eq(countLayer(env, 79, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 8, "built using the stocked stone hoe")
end)

-- When the ONLY hoe is a craftable-but-stalling one (no free CPU) and none is
-- stocked, the build can't till. It must halt with an ACTIONABLE message (drop a
-- hoe in the slot / stock one) instead of a bare "no-hoe", and build nothing -
-- not silently leave a half-tilled cell.
T("supply: a stalling-only hoe halts with an actionable message, builds nothing", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "east", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 74, 0, 3, 3)
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }; hoe.count = 0
  hoe.isCraftable = true; hoe.craftStalls = true
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 0, craftSeconds = 1,
    items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  env:run(FARM, { "setup", "1" }, { maxTime = 300000 })
  local t = env:termText()
  expectContains(t, "no hoe", "halted on the hoe and said so")
  expectContains(t, "slot 2", "told the operator which slot to drop a hoe in")
  eq(countLayer(env, 79, "farmingforblockheads:fertilized_farmland_healthy",
    3, 3, 3, 0), 0, "built nothing without a hoe (no silent partial)")
end)

-- THE in-game bug: the wizard scans the plot from above, then homes to its dock
-- for the build. Homing straight DOWN (navTo) walks into the plot it just
-- captured, jams, and the build then dead-reckons from a frame OFFSET by however
-- far it's stuck - so every restock "goes back to the bridge" lands at the wrong
-- real cell and dies no-hoe. Here the bridge is a fixed BLOCK north of the dock
-- (readable ONLY when the turtle is physically docked facing it), so the offset
-- genuinely hides it - exactly like in-game. navSafe homing (over the top) fixes it.
T("setup wizard: homes back over the plot so restock can still reach the bridge", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "north", fuel = 90000 } }
  env:addGeoScanner("scanner")
  seedRefPlot(env, 3, 63, 0, 3, 3) -- one BELOW the dock + aside: the home descent crosses it
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  local water = env:waterBucketItem(); water.count = 16
  local coal = { id = "minecraft:coal_block", count = 64 }
  -- the bridge is a fixed BLOCK just NORTH of the dock: readable ONLY when the
  -- turtle is physically at the dock facing north. A frame offset hides it.
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "north",
    blockAt = { x = 0, y = 64, z = -1 }, stored = 1e6, max = 2e6, usage = 0,
    craftSeconds = 1, items = { dirt, hoe, fert, seed, water, coal } })
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 250000 })
  expectNotContains(env:termText(), "isn't in reach", "got back to the dock + reached the bridge")
  expectNotContains(env:termText(), "no-hoe", "restocked the hoe (frame not offset)")
  -- soil base y65 + default clearance 3 = y68
  eq(countLayer(env, 68, "farmingforblockheads:fertilized_farmland_healthy", 3, 3, 3, 0),
    8, "built the copy a clearance gap above the existing plot (frame stayed true)")
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
  eq(countLayer(env, 79, "farmingforblockheads:fertilized_farmland_healthy",
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
  eq(countLayer(env, 79, "farmingforblockheads:fertilized_farmland_healthy",
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
  -- centered over the chest at x4 -> build.x = 4 - floor(5/2) = 2 -> soil x2..6;
  -- soil layer at captured-top y74 + naive base 1 + default clearance 3 = y78
  eq(env:block(2, 78, 0) and env:block(2, 78, 0).id,
    "farmingforblockheads:fertilized_farmland_healthy",
    "aligned soil reaches the chest-centered x2")
  eq(env:block(7, 78, 0), nil, "NOT at the un-aligned bbox-corner x7")
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

-- The dirt PULL above only proves exporting STOCKED items. The build also needs
-- to CRAFT (the hoe is count=0, craftable). `farm ae` must actually run that
-- craft and report whether the AE can FINISH it - a stalled job (pattern exists,
-- no free CPU) is the exact in-game "no-hoe" cause and must be named, not hidden.
T("ae: the craft probe names a STALLED autocraft (pattern exists, nothing arrives)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }; hoe.count = 0
  hoe.isCraftable = true; hoe.craftStalls = true
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 5, items = { dirt, hoe } })
  current = env
  env:run(FARM, { "ae" }, { maxTime = 60 })
  local t = env:termText()
  expectContains(t, "craft probe", "ran a real craft probe, not just a stock pull")
  expectContains(t, "STALLED", "named the stalled craft (the in-game no-hoe cause)")
end)

T("ae: the craft probe confirms OK when the AE can finish the craft", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }; hoe.count = 0; hoe.isCraftable = true
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 5, craftSeconds = 1, items = { dirt, hoe } })
  current = env
  env:run(FARM, { "ae" }, { maxTime = 60 })
  expectContains(env:termText(), "craft probe: OK", "confirmed a working autocraft")
end)

-- `farm diag` is the operator's ground-truth capability self-test: a FAST check
-- (no ~6-minute plot scan) that exercises every real-world capability the build
-- depends on - AE stock pull, AE craft, place dirt, a TILL PROBE, fertilize, plant,
-- water - in a CLEAR test column it rises into, reports PASS/FAIL per capability,
-- then cleans up every block it placed so it never damages the operator's farm.
-- The TILL PROBE is the load-bearing one: it EMPIRICALLY tries every tilling method
-- on fresh dirt in clear air and reports which produced farmland, so the operator's
-- next run is DEFINITIVE about what tills in-game. The root cause (place()-with-hoe
-- does NOT till; CC tills via equip + dig/digDown - TurtleTool.java:265-324,
-- Turtle_Test.kt:258-273) is proven by the probe: place/placeDown FAIL, equip+dig
-- methods PASS.
T("diag: capability self-test reports every capability PASS and leaves no mess", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "north", fuel = 50000 } }
  -- a minimal conf so loadConf supplies the slot/item defaults diag pulls against
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 0, z = 0 }, size = { w = 1, h = 1, d = 1 },
    heading = "north", scan_y = 2,
    start = { x = 0, y = 64, z = 0 }, start_heading = "north",
    build = { x = 0, y = 0, z = 0 }, plots = 1, fleet = "farm1",
  }]]
  -- a full AE: dirt STOCKED, hoe CRAFTABLE (build needs to craft one), seed/fert/
  -- water stocked. The bridge is a fixed BLOCK just NORTH of the dock (blockAt):
  -- readable ONLY while the turtle is physically at the dock facing north - the
  -- moment diag RISES away, the bridge is unreachable (models the in-game frame).
  -- So any pull AFTER the rise must fail: diag has to stage every item WHILE
  -- DOCKED. This position-gated bridge reproduces the operator's in-game halt.
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }; hoe.count = 0; hoe.isCraftable = true
  local fert = env:fertilizerItem{ count = 64 }
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 64 })
  local water = env:waterBucketItem(); water.count = 16
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "north",
    blockAt = { x = 0, y = 64, z = -1 }, stored = 1e6, max = 2e6,
    usage = 5, craftSeconds = 1, items = { dirt, hoe, fert, seed, water } })
  -- a Geo Scanner with a block in reach so the timed diag SCAN line reports PASS
  env:addGeoScanner("scanner")
  env:setBlock(0, 63, 0, { id = "minecraft:dirt" }) -- one block for the scan to see
  current = env
  local res = env:run(FARM, { "diag" }, { maxTime = 4000 })
  eq(res.reason, "done", "diag ran (err=" .. tostring(res.err) .. ")")
  -- the full per-step narrative (PASS/FAIL per capability) is captured in the log;
  -- the CC terminal can't scroll, so the early step lines scroll off - the log is
  -- the operator's record (share with `pastebin put farm.log`)
  local log = env:file("farm.log") or ""
  -- every capability the build depends on reported PASS, in colon form per step
  expectContains(log, "SCAN: PASS", "the timed scan capability reported PASS")
  expectContains(log, "geo_scanner", "named the scanner peripheral type")
  expectContains(log, "captureScan3D", "named which capture path would run")
  expectContains(log, "AE STOCK PULL: PASS", "stock pull works")
  expectContains(log, "AE CRAFT: PASS", "ran the craft probe")
  expectContains(log, "PLACE DIRT: PASS", "placed dirt in clear air")
  -- TILL PROBE: empirically tries each method on fresh dirt; the place()-with-hoe
  -- methods FAIL (the root cause), the equip+dig methods PASS, each reported with the
  -- ret value, hoe slot count, and the after-id - the operator's definitive in-game proof
  expectContains(log, "TILL via side-place: FAIL", "place()-with-hoe from the side does NOT till")
  expectContains(log, "TILL via place-down: FAIL", "placeDown-with-hoe from above does NOT till")
  expectContains(log, "TILL via equip+digDown: PASS", "equip + digDown tills (CC's real verb)")
  expectContains(log, "TILL via equip+dig-side: PASS", "equip + dig from the side tills")
  -- each probe line carries the detail format: (hoe xN, ret=BOOL, after=ID)
  expectContains(log, "after=minecraft:farmland", "a working method reports farmland after")
  expectContains(log, "ret=", "each probe line reports the place/dig return value")
  expectContains(log, "TILL PROBE: PASS", "the rolled-up probe verdict is PASS (some method worked)")
  expectContains(log, "FERTILIZE: PASS", "fertilized the farmland")
  expectContains(log, "PLANT: PASS", "planted a sulfur seed")
  expectContains(log, "WATER: PASS", "placed a water source with a brace")
  expectContains(log, "CLEAN UP: PASS", "cleaned up every test block")
  -- the end-of-run summary block + one-line verdict survive on the terminal
  local t = env:termText()
  expectContains(t, "capability summary", "printed a summary block")
  expectContains(t, "all capabilities PASS", "a clear one-line verdict")
  -- CLEAN UP: every block diag placed is removed - the test column is clear air
  -- again (above the dock at y64), so it never damages the operator's farm
  for dy = 1, 6 do
    for dx = -1, 1 do
      for dz = -1, 1 do
        local b = env:block(dx, 64 + dy, dz)
        if b then
          fail(("diag left a block %s at %d,%d,%d - it must clean up")
            :format(b.id, dx, 64 + dy, dz))
        end
      end
    end
  end
end)

-- The diag SCAN line: a FAST, isolated check that the Geo Scanner is detected and
-- the scan is quick - separating the scanner (seconds) from the navigation (the
-- 6-minute up-and-down the operator saw). It runs early, while docked, alongside
-- the AE checks: report the scanner type (or NOT FOUND), the block count, the
-- elapsed seconds, and which capture path would run (captureScan3D with a scanner,
-- else the slow captureProbe). PASS iff a scanner is found and the scan returns
-- blocks.
T("diag: the SCAN line reports PASS, the block count, and the scanner type", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "north", fuel = 50000 } }
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 0, z = 0 }, size = { w = 1, h = 1, d = 1 },
    heading = "north", scan_y = 2,
    start = { x = 0, y = 64, z = 0 }, start_heading = "north",
    build = { x = 0, y = 0, z = 0 }, plots = 1, fleet = "farm1",
  }]]
  local dirt = { id = "minecraft:dirt", count = 256 }
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "north",
    blockAt = { x = 0, y = 64, z = -1 }, stored = 1e6, max = 2e6,
    usage = 5, items = { dirt } })
  env:addGeoScanner("scanner") -- registers the real "geo_scanner" type
  -- a couple of blocks for the scan to return (proves a non-zero count)
  env:setBlock(0, 63, 0, { id = "minecraft:dirt" })
  env:setBlock(1, 64, 0, { id = "minecraft:stone" })
  current = env
  local res = env:run(FARM, { "diag" }, { maxTime = 4000 })
  eq(res.reason, "done", "diag ran (err=" .. tostring(res.err) .. ")")
  local log = env:file("farm.log") or ""
  expectContains(log, "SCAN: PASS", "scanner found + scan returned blocks => PASS")
  expectContains(log, "geo_scanner", "reported the scanner peripheral type")
  expectContains(log, "captureScan3D", "named the capture path a scanner would take")
  -- the block count is reported (the scan saw the seeded blocks); the count must
  -- be a positive number in the SCAN narrative
  local scanLine
  for line in (log .. "\n"):gmatch("([^\n]*)\n") do
    if line:find("SCAN:", 1, true) then scanLine = line end
  end
  if not scanLine then fail("no SCAN line in the diag log") end
  local count = scanLine:match("(%d+) block")
  if not count or tonumber(count) < 1 then
    fail("SCAN line did not report a positive block count: " .. tostring(scanLine))
  end
end)

-- Without a scanner the SCAN line FAILs loudly (NOT FOUND) and names the SLOW
-- captureProbe path - so the operator sees exactly why capture would be slow.
T("diag: the SCAN line FAILs and names the probe path when no scanner is present", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "north", fuel = 50000 } }
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 0, z = 0 }, size = { w = 1, h = 1, d = 1 },
    heading = "north", scan_y = 2,
    start = { x = 0, y = 64, z = 0 }, start_heading = "north",
    build = { x = 0, y = 0, z = 0 }, plots = 1, fleet = "farm1",
  }]]
  local dirt = { id = "minecraft:dirt", count = 256 }
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "north",
    blockAt = { x = 0, y = 64, z = -1 }, stored = 1e6, max = 2e6,
    usage = 5, items = { dirt } })
  -- NO geo scanner attached
  current = env
  local res = env:run(FARM, { "diag" }, { maxTime = 4000 })
  eq(res.reason, "done", "diag ran (err=" .. tostring(res.err) .. ")")
  local log = env:file("farm.log") or ""
  expectContains(log, "SCAN: FAIL", "no scanner => SCAN FAIL")
  expectContains(log, "NOT FOUND", "reported the scanner is not found")
  expectContains(log, "captureProbe", "named the slow probe path the build would fall back to")
end)

-- SEED ROBUSTNESS (deliverable 4): mysticalagriculture:sulfur_seeds is correct (the
-- _crop->_seeds derivation is right), but the pack disables the crafting-table recipe
-- (seedCraftingRecipes=false) so AE can neither stock nor autocraft it from a pattern.
-- A bare "no sulfur_seeds from AE" is not actionable. The diag's AE PULL: seed line
-- must say EXACTLY what to do - stock/auto-craft via the Seed Infusion Altar - instead
-- of a bare fail.
T("diag: a missing sulfur seed reports an actionable 'stock seeds' message", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "north", fuel = 50000 } }
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 0, z = 0 }, size = { w = 1, h = 1, d = 1 },
    heading = "north", scan_y = 2,
    start = { x = 0, y = 64, z = 0 }, start_heading = "north",
    build = { x = 0, y = 0, z = 0 }, plots = 1, fleet = "farm1",
  }]]
  -- a full AE EXCEPT the sulfur seed (the operator's exact stock gap)
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 1561 }
  local fert = env:fertilizerItem{ count = 64 }
  local water = env:waterBucketItem(); water.count = 16
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "north",
    blockAt = { x = 0, y = 64, z = -1 }, stored = 1e6, max = 2e6,
    usage = 5, craftSeconds = 1, items = { dirt, hoe, fert, water } }) -- NO seed
  env:addGeoScanner("scanner")
  env:setBlock(0, 63, 0, { id = "minecraft:dirt" })
  current = env
  local res = env:run(FARM, { "diag" }, { maxTime = 4000 })
  eq(res.reason, "done", "diag ran (err=" .. tostring(res.err) .. ")")
  local log = env:file("farm.log") or ""
  expectContains(log, "AE PULL: seed: FAIL", "the seed pull FAILs (genuinely absent)")
  -- the actionable guidance, not a bare 'no <id> from AE'
  expectContains(log, "stock", "tells the operator to stock the seed")
  expectContains(log, "Seed Infusion Altar", "names where seeds come from (the pack disables crafting)")
  expectContains(log, "seedCraftingRecipes", "explains WHY AE can't autocraft it")
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

-- The installer's startup.lua runs `farm` on EVERY boot, so the turtle takes off
-- before the operator can read 'farm ae' / 'farm capture'. A hold flag parks it
-- at the shell; 'farm go' resumes. This is the operator's testing escape hatch.
T("hold: 'farm hold' parks the turtle so a bare 'farm' won't auto-build", function()
  local env = buildRig()
  current = env
  env:run(FARM, { "hold" }, { maxTime = 10 })
  eq(env:file("farm.hold") ~= nil, true, "hold flag written")
  env:run(FARM, {}, { maxTime = 4000 }) -- bare 'farm' = the boot auto-start
  expectContains(env:termText(), "HELD", "stayed held instead of building")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"), 0,
    "built nothing while held")
end)

T("hold: pressing a key during the boot window holds before the turtle moves", function()
  local env = buildRig()
  current = env
  env:keyAt(1, 57) -- tap a key 1s into the 3s auto-build window
  env:run(FARM, {}, { maxTime = 4000 })
  eq(env:file("farm.hold") ~= nil, true, "the keypress wrote the hold flag")
  expectContains(env:termText(), "HELD", "held on the keypress")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"), 0,
    "caught it before it built anything")
end)

T("hold: 'farm go' clears the hold and builds", function()
  local env = buildRig()
  current = env
  env:run(FARM, { "hold" }, { maxTime = 10 })
  local res = env:run(FARM, { "go" }, { maxTime = 4000 })
  eq(res.reason, "done", "go ran the build (err=" .. tostring(res.err) .. ")")
  eq(env:file("farm.hold"), nil, "go cleared the hold flag")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"), 8,
    "go built the plot")
end)

T("hold: a mid-build kill-resume skips the boot window (resumes unattended)", function()
  local env = buildRig()
  current = env
  -- an in-progress journal = a chunk-reload resume: must NOT wait for a keypress
  env.files["farm.journal"] = "phase=build\nplot=0\ndy=0\npos=0,120,0\nheading=east\n"
  env:run(FARM, {}, { maxTime = 4000 })
  expectNotContains(env:termText(), "press any key", "no hold window on a resume")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"), 8,
    "resumed and finished without waiting for a key")
end)

-- The CC terminal can't scroll and the output is long, so the operator can't get
-- it to me. Everything the turtle prints is mirrored to farm.log (share with
-- `pastebin put farm.log`); verbose mode also traces every real-world step so I
-- can debug + model the sim against what actually happened.
T("log: terminal output is mirrored to farm.log", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 5, items = { { id = "minecraft:dirt", count = 256 } } })
  current = env
  env:run(FARM, { "ae" }, { maxTime = 60 })
  local log = env:file("farm.log")
  eq(type(log) == "string", true, "farm.log written")
  expectContains(log or "", "PULL OK", "the on-screen narrative is captured in the log")
end)

T("log: 'farm log clear' wipes the log file", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 5, items = { { id = "minecraft:dirt", count = 256 } } })
  current = env
  env:run(FARM, { "ae" }, { maxTime = 60 })
  eq(type(env:file("farm.log")) == "string", true, "log exists before clear")
  env:run(FARM, { "log", "clear" }, { maxTime = 10 })
  eq(env:file("farm.log"), nil, "log cleared")
end)

T("log: step tracing is off by default, 'farm log on' enables it", function()
  local env = buildRig()
  current = env
  env:run(FARM, { "build" }, { maxTime = 4000 })
  expectNotContains(env:file("farm.log") or "", "[t]", "no step trace without verbose")
  env:run(FARM, { "log", "on" }, { maxTime = 10 })
  env.files["farm.log"] = nil -- fresh log for the verbose run
  env.turtle.pos = { x = 0, y = 120, z = 0 }; env.turtle.facing = "east"
  env:run(FARM, { "build" }, { maxTime = 4000 }) -- converge re-run; still moves
  expectContains(env:file("farm.log") or "", "[t]", "step trace present with verbose")
end)

T("log: 'farm log' reports the file and how to share it", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env:addMeBridge("me", { intoTurtle = "north", stored = 1e6, max = 2e6,
    usage = 5, items = { { id = "minecraft:dirt", count = 256 } } })
  current = env
  env:run(FARM, { "ae" }, { maxTime = 60 })
  env:run(FARM, { "log" }, { maxTime = 10 })
  expectContains(env:termText(), "pastebin put farm.log", "told the operator how to share it")
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

-- fix #3: a footprint that exceeds the free radius-8 scan must NOT be silently
-- truncated (outer columns / floor dropped behind a plausible size header). The
-- capture either covers the whole footprint or aborts LOUDLY - never writes a
-- blueprint with a hole the build then replicates across every stacked copy.
-- Raising the radius is forbidden (a radius-16 scan is ~5274 fuel, the drain bug)
-- - now that the harness deducts that cost, a "bump the radius" fix can't pass.
-- The no-silent-truncation invariant: a footprint past the free radius-8 either
-- captures in FULL (the radius is raised to the footprint, paying fuel) or fails
-- LOUDLY - it never writes a blueprint with a plausible size header but a hole.
-- Here too little fuel to pay for the radius-9 scan, so the scan fails loudly.
T("capture: a footprint wider than the free radius-8 scan is not silently truncated", function()
  -- start AT the dead-reckoning origin (cfg.start defaults to origin.x/scan_y/
  -- origin.z) so a successful capture scans from the true plot centre.
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 200 } } -- too little fuel to afford a costly r>8 scan
  env:addGeoScanner("scanner")
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 19, h = 1, d = 1 },
    heading = "east", scan_y = 66, fleet = "farm1",
  }]]
  for ix = 0, 18 do env:setBlock(ix, 64, 0, { id = "minecraft:farmland" }) end
  current = env
  env:run(FARM, { "capture" }, { maxTime = 600 })
  local bpText = env:file("farm.blueprint")
  if type(bpText) == "string" then
    local bp = loadTable(bpText, "blueprint")
    -- if a blueprint WAS written it must be complete: both edges present
    if not (bp.cells["0,0,0"] and bp.cells["18,0,0"]) then
      fail("blueprint silently truncated: far-edge column 18,0,0 missing")
    end
  else
    -- else it must have failed LOUDLY (over the 16 max, or the paid scan ran out
    -- of fuel) - never a silent truncation
    local t = env:termText()
    if not (t:find("exceeds", 1, true) or t:find("scan failed", 1, true)) then
      fail("no blueprint and no loud failure - capture must abort loudly, not silently")
    end
  end
end)

T("capture: a plot taller than the free radius-8 scan keeps its floor layer", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 73, z = 0 },
    facing = "east", fuel = 200 } } -- scan_y = origin.y + 9, floor is 9 below
  env:addGeoScanner("scanner")
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 1, h = 8, d = 1 },
    heading = "east", scan_y = 73, fleet = "farm1",
  }]]
  for dy = 0, 7 do
    env:setBlock(0, 64 + dy, 0,
      { id = dy == 0 and "minecraft:farmland" or "ae2:growth_accelerator" })
  end
  current = env
  env:run(FARM, { "capture" }, { maxTime = 600 })
  local bpText = env:file("farm.blueprint")
  if type(bpText) == "string" then
    local bp = loadTable(bpText, "blueprint")
    if not bp.cells["0,0,0"] then
      fail("blueprint silently dropped the floor layer (0,0,0)")
    end
  else
    local t = env:termText()
    if not (t:find("exceeds", 1, true) or t:find("scan failed", 1, true)) then
      fail("no blueprint and no loud failure - capture must abort loudly, not silently")
    end
  end
end)

-- captureScan3D covers the FULL 3D footprint. The scan radius is computed from
-- the footprint extents (cube reach per axis - the AP scanner traverses a cube,
-- ScanUtils.traverseBlocks ±radius, NOT a sphere) and capped at the 16-block max.
-- A footprint whose corners exceed the free radius 8 but fit within 16 is now
-- CAPTURED in full (the radius is raised to the need), not aborted - so no corner
-- cell is ever silently dropped. A footprint that exceeds 16 still aborts loudly.

-- A 21-wide plot needs radius 10 (max |offset| from the centre column = 10),
-- exceeding the free 8 but within 16. Under the OLD fixed radius-8 scan this
-- aborted ("exceeds"); now it captures every column including both far edges.
T("capture: a footprint past the free radius-8 but within 16 is captured in full", function()
  -- start AT the program's dead-reckoning origin (cfg.start defaults to origin.x,
  -- scan_y, origin.z) so navTo to the plot centre tracks the real turtle.
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 50000 } } -- ample fuel for the (paid) radius>8 scan
  env:addGeoScanner("scanner")
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 21, h = 1, d = 1 },
    heading = "east", scan_y = 66, fleet = "farm1",
  }]]
  for ix = 0, 20 do env:setBlock(ix, 64, 0, { id = "minecraft:farmland" }) end
  current = env
  local res = env:run(FARM, { "capture" }, { maxTime = 600 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "exceeds", "21 wide fits radius 16 - no abort")
  local bp = loadTable(env:file("farm.blueprint"), "blueprint")
  -- every column present, no hole - both far edges and the centre
  for ix = 0, 20 do
    if not bp.cells[ix .. ",0,0"] then
      fail("column " .. ix .. " dropped: capture left a hole within the 16-radius reach")
    end
  end
end)

-- The hardest case the task calls out: a far-BOTTOM corner of a tall, wide plot.
-- A 17x6x3 footprint scanned from its top-centre cell reaches a bottom corner at
-- per-axis offsets (8, scan_y-floor, 1). The capture must include EVERY one of the
-- 17*6*3 footprint cells - no corner silently dropped.
T("capture: every cell of a tall+wide footprint is captured (no dropped corner)", function()
  -- start AT the dead-reckoning origin (origin.x, scan_y, origin.z); the program
  -- navTo's from there to the plot centre (cx, scan_y, cz).
  local env = CC.new{ turtle = { pos = { x = 0, y = 74, z = 0 },
    facing = "east", fuel = 50000 } } -- hover high above a 17x6x3 plot
  env:addGeoScanner("scanner")
  -- origin (0,64,0); w17 d6 h3. scan_y (74) hovers 10 above the floor (y64), so the
  -- vertical reach to the floor (10) exceeds the free radius 8 - the radius must be
  -- raised to 10 to keep the floor corners, exercising the >8 (paid) scan path.
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 17, h = 3, d = 6 },
    heading = "east", scan_y = 74, fleet = "farm1",
  }]]
  for ix = 0, 16 do
    for iz = 0, 5 do
      for dy = 0, 2 do
        env:setBlock(ix, 64 + dy, iz,
          { id = dy == 0 and "minecraft:farmland" or "mysticalagriculture:essence_farmland" })
      end
    end
  end
  current = env
  local res = env:run(FARM, { "capture" }, { maxTime = 600 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "exceeds", "the footprint fits radius 16")
  local bp = loadTable(env:file("farm.blueprint"), "blueprint")
  local missing = 0
  for ix = 0, 16 do for iz = 0, 5 do for dy = 0, 2 do
    if not bp.cells[ix .. "," .. dy .. "," .. iz] then missing = missing + 1 end
  end end end
  eq(missing, 0, "all 17*6*3 footprint cells captured (no dropped corner)")
end)

-- An OVERSIZE footprint (wider than the 16-block max reach) still aborts LOUDLY -
-- never writes a truncated blueprint. 35 wide needs radius 17 > 16.
T("capture: a footprint exceeding the 16-block max scan still aborts loudly", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 66, z = 0 },
    facing = "east", fuel = 50000 } }
  env:addGeoScanner("scanner")
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 35, h = 1, d = 1 },
    heading = "east", scan_y = 66, fleet = "farm1",
  }]]
  for ix = 0, 34 do env:setBlock(ix, 64, 0, { id = "minecraft:farmland" }) end
  current = env
  env:run(FARM, { "capture" }, { maxTime = 600 })
  eq(env:file("farm.blueprint"), nil, "no blueprint written for an oversize footprint")
  expectContains(env:termText(), "exceeds", "loud abort about exceeding the max scan")
end)

-- fix #6: the Geo Scanner returns only name/x/y/z/tags per block - NEVER a
-- blockstate (GeoScannerPeripheral.scan). So classify's axis-from-state branch is
-- DEAD on the 3D scan path: a vertical accelerator captured by the scanner has
-- axis==nil. The inspectDown PROBE path DOES carry state, so the same block there
-- recovers axis=='y'. This test pins that contract so a future author can't rely
-- on a scanner capture recovering axis (and a mock fabricating state in scan()
-- would diverge from vendor and be caught here).
T("capture: the Geo Scanner cannot recover a vertical axis (probe path can)", function()
  -- (a) 3D scan path: axis is NOT recoverable
  local e1 = CC.new{ turtle = { pos = { x = 0, y = 67, z = 0 },
    facing = "east", fuel = 5000 } }
  e1:addGeoScanner("scanner")
  e1.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 1, h = 3, d = 1 },
    heading = "east", scan_y = 67, fleet = "farm1",
  }]]
  e1:setBlock(0, 64, 0, { id = "farmingforblockheads:fertilized_farmland_healthy" })
  e1:setBlock(0, 65, 0, { id = "mysticalagriculture:sulfur_crop" })
  e1:setBlock(0, 66, 0,
    { id = "ae2:growth_accelerator", state = { axis = "y" } }) -- vertical canopy
  current = e1
  e1:run(FARM, { "capture" }, { maxTime = 600 })
  local bp1 = loadTable(e1:file("farm.blueprint"), "blueprint (scan)")
  eq(bp1.cells["0,2,0"].kind, "block", "scanner: canopy is a block")
  eq(bp1.cells["0,2,0"].axis, nil, "scanner: axis is NOT recoverable (no blockstate)")

  -- (b) probe path (no scanner): inspectDown carries state, so axis is recovered
  local e2 = CC.new{ turtle = { pos = { x = 0, y = 67, z = 0 },
    facing = "east", fuel = 5000 } }
  e2.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 1, h = 3, d = 1 },
    heading = "east", scan_y = 67, fleet = "farm1",
  }]]
  e2:setBlock(0, 64, 0, { id = "farmingforblockheads:fertilized_farmland_healthy" })
  e2:setBlock(0, 65, 0, { id = "mysticalagriculture:sulfur_crop" })
  e2:setBlock(0, 66, 0, { id = "ae2:growth_accelerator", state = { axis = "y" } })
  current = e2
  e2:run(FARM, { "capture" }, { maxTime = 600 })
  local bp2 = loadTable(e2:file("farm.blueprint"), "blueprint (probe)")
  eq(bp2.cells["0,2,0"].axis, "y", "probe: axis recovered from inspectDown state")
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

-- THE operator bug: a prior failed run left ONE stray dirt block at the build
-- corner column (cfg.build.x/z) at the plot-0 soil layer. A FRESH re-run (no
-- journal) must NOT mistake that single block for a COMPLETE plot 0 - the old
-- skipBuiltPlots probed only the corner column's top solid block, so a stray
-- block reads "1 plot already built" and the REAL plot 0 is never built. A plot
-- counts as built only if its top blueprint cell is actually present.
T("resume: one stray block at the build corner is NOT a complete plot", function()
  local env = buildRig{ plots = 1, blueprint = BP_3x3_NOWATER }
  -- a stray dirt at the build corner (0,100,0) from a prior failed run; the
  -- rest of plot 0 is empty (the failed run never got past the first cell)
  env:setBlock(0, 100, 0, { id = "minecraft:dirt" })
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 9000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "already complete",
    "a stray block must not read as a finished stack")
  -- plot 0 actually gets built: the stray corner dirt is tilled+fertilized like
  -- any cell, so all 9 soil cells end fertilized and all 9 crops are planted
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot0 soil built despite the stray block (the real plot was NOT skipped)")
  eq(countLayer(env, 101, "mysticalagriculture:sulfur_crop"), 9,
    "plot0 crops built (the real plot was NOT skipped)")
end)

-- The same mis-skip at a HIGHER plot: plot 0 is genuinely complete, but a stray
-- corner block sits at plot 1's soil layer (a prior fresh-run kill that lost its
-- journal). A fresh re-run must build plot 1, not skip it as "2 already built".
T("resume: a stray block above a finished plot doesn't skip the next plot", function()
  local env = buildRig{ plots = 2, blueprint = BP_3x3_NOWATER }
  current = env
  env:run(FARM, { "build" }, { maxTime = 9000 })   -- build BOTH plots
  -- now wipe plot 1 down to a single stray corner block to model a half-built
  -- plot 1 whose journal was lost; plot 0 stays complete below it
  for dx = 0, 2 do for dz = 0, 2 do
    env:setBlock(dx, 102, dz, nil); env:setBlock(dx, 103, dz, nil)
  end end
  env:setBlock(0, 102, 0, { id = "minecraft:dirt" }) -- lone stray at plot1 corner
  env.turtle.pos = { x = 0, y = 120, z = 0 }; env.turtle.facing = "east"
  local res = env:run(FARM, {}, { maxTime = 9000 }) -- fresh re-run (no journal)
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "1 plot(s) already built",
    "resumed at the partial plot 1, did not skip it as complete")
  -- plot 1 fully rebuilt: the stray corner dirt is tilled+fertilized like any
  -- cell, so all 9 soil cells end fertilized and all 9 crops are planted
  eq(countLayer(env, 102, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "plot1 soil rebuilt - not skipped as complete")
  eq(countLayer(env, 103, "mysticalagriculture:sulfur_crop"), 9,
    "plot1 crops built")
end)

-- A prior run finished a plot's SOIL layer but was killed before the crop layer
-- (a full lower layer, not a stray block). A fresh re-run must resume at that
-- plot and lay the missing crops - the top solid block sits at the soil dy,
-- BELOW the plot's top (crop) layer, so the plot is correctly counted incomplete.
T("resume: a plot built only through its lower layer resumes its top layer", function()
  local env = buildRig{ plots = 2, blueprint = BP_3x3_NOWATER }
  current = env
  env:run(FARM, { "build" }, { maxTime = 9000 })   -- build BOTH plots
  -- strip plot 1's crop (top) layer, leaving its full soil layer below
  for dx = 0, 2 do for dz = 0, 2 do env:setBlock(dx, 103, dz, nil) end end
  env.turtle.pos = { x = 0, y = 120, z = 0 }; env.turtle.facing = "east"
  local res = env:run(FARM, {}, { maxTime = 9000 }) -- fresh re-run (no journal)
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "1 plot(s) already built",
    "plot1 soil-only is NOT complete (top crop layer missing)")
  eq(countLayer(env, 103, "mysticalagriculture:sulfur_crop"), 9,
    "plot1 crop layer laid on resume")
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

-- ----------------------------------------------------- clearance / buried base
-- THE in-game halt (operator's farm.log): the operator's existing farm is, bottom
-- up, DIRT -> PLANT -> GROWTH ACCELERATOR -> ULTIMATE CABLE (4 layers), but the
-- capture is h=3 and MISSES the top cable layer. So the build base
-- Y0 = origin.y + size.h lands ON the (un-captured) cable level, and the turtle
-- places its first dirt block buried inside the existing canopy: ALL FOUR
-- horizontal neighbours - at both the soil layer and the stance layer above it -
-- are occupied by the canopy, so the v49 side-till can never drop beside the dirt
-- to till it from the side. tillBelowFromSide returns false and doSoil halts
-- "till". The side-till is CORRECT; it just has nowhere to stand.
--
-- The OLD harness hid this: the build tests seed the build column in OPEN AIR with
-- clear neighbours, so side-till passes there while it fails in-game. These tests
-- MODEL the canopy around the build base, so the no-clear-neighbour halt is
-- reproducible, and prove the clearance fix lifts the base into clear air.

-- Fill the four horizontal neighbours of the column (x,z) with canopy blocks at
-- BOTH the soil layer ySoil and the stance layer ySoil+1 - the two layers the
-- side-till needs clear to step into a neighbour and drop beside the dirt. This is
-- the operator's existing farm canopy (accelerators/cables) pressed against the
-- buried build column.
local function surroundColumnWithCanopy(env, x, ySoil, z)
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    env:setBlock(x + d[1], ySoil, z + d[2], { id = "mysticalagriculture:essence_farmland" })
    env:setBlock(x + d[1], ySoil + 1, z + d[2], { id = "ae2:cable" })
  end
end

-- A build rig whose conf build.y is derived from the wizard's formula
-- (origin.y + size.h + clearance), so a clearance of 0 buries the base on the
-- canopy level (modelled by surroundColumnWithCanopy) and the default 3 lifts it
-- into clear air. The reference plot's captured top is origin.y + size.h - 1; the
-- un-captured cable layer sits one above that, exactly where clearance=0 builds.
local function clearanceRig(clearance, blueprint)
  local oy, h = 64, 2
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 50000 } }
  env.files["farm.blueprint"] = blueprint or BP_3x3_NOWATER
  local buildY = oy + h + clearance
  env.files["farm.conf"] = ([[return {
    origin = { x = 0, y = %d, z = 0 }, size = { w = 3, h = %d, d = 3 },
    heading = "east", lateral = "south", scan_y = %d,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = %d, z = 0 }, clearance = %d, plots = 1, fleet = "farm1",
  }]]):format(oy, h, oy + h + 1, buildY, clearance)
  env.turtle.inv = {
    [1] = { id = "minecraft:dirt", count = 64 },
    [2] = env:hoeItem{ durability = 2000 },
    [3] = env:fertilizerItem{ count = 64 },
    [4] = env:seedItem("mysticalagriculture:sulfur_crop", { count = 64 }),
    [5] = env:waterBucketItem(),
  }
  -- model the existing farm canopy at its FIXED world level: the un-captured cable
  -- layer sits one above the captured plot top (origin.y + size.h = the buried
  -- base for clearance 0). The build base moves UP with clearance, away from this
  -- fixed canopy - so clearance 0 builds INTO it, the default clears it.
  surroundColumnWithCanopy(env, 0, oy + h, 0)
  return env, buildY
end

-- RED-proves the bug: with clearance 0 the build base lands on the canopy level
-- and the side-till has no clear neighbour to drop beside the dirt -> halts "till".
T("clearance: build base buried in the canopy halts the till (no clear side)", function()
  local env = clearanceRig(0)
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 9000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "halted", "the buried build halts loudly")
  expectContains(env:termText(), "till", "it halts on the side-till (no clear neighbour)")
  -- and it built NO soil layer (the very first cell could not be tilled)
  eq(countLayer(env, 64 + 2, "farmingforblockheads:fertilized_farmland_healthy"),
    0, "no soil fertilized - the build never got past the first buried cell")
end)

-- GREEN: with the default clearance the wizard's formula lifts the base ABOVE the
-- canopy into clear air, so the same canopy does not block the side-till and the
-- soil layer builds.
T("clearance: the default gap lifts the base into clear air and the soil builds", function()
  local env, buildY = clearanceRig(3)
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 9000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "halted", "the clear-air build does not halt")
  eq(countLayer(env, buildY, "farmingforblockheads:fertilized_farmland_healthy"),
    9, "all 9 soil cells fertilized in clear air above the canopy")
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

-- fix #2(b): a water cell whose brace position is occupied by a FLUID (a prior
-- plot's water that flowed under it, or leftover flowing water). With the harness
-- fluid-detect fix, that cell reads not-solid (detectDown()==false) - exactly as
-- the real turtle sees it - so doWater must CLEAR the fluid and lay a solid dirt
-- sub-floor before placing: a placeDown water braces only against the cell
-- directly below, and a bucket can't deploy against a liquid (vendor
-- canDeployOnBlock: isEmptyBlock(pos) is true for a liquid). Without the brace
-- the place fails and the plot reports a dry centre ("needs hand-seeding"). The
-- OLD air-only guard `if not detectDown()` plus the masking harness both treated
-- the fluid as solid and skipped the brace.
T("supply: water over a fluid brace cell clears it and lays a sub-floor (no dry cell)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] =
    "return {\n  size = { w = 1, h = 1, d = 1 },\n  cells = {\n"
    .. "    [\"0,0,0\"] = { kind = \"water\" },\n  },\n}\n"
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 1, h = 1, d = 1 },
    heading = "east", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      suck = "self", export_side = "north", bridge_facing = "south" },
  }]]
  -- the brace cell directly below the water target is a FLUID, not air or solid
  env:setBlock(0, 99, 0, { id = "minecraft:water", state = { level = 1 } })
  local dirt = { id = "minecraft:dirt", count = 256 }
  local water = env:waterBucketItem(); water.count = 16; water.isCraftable = false
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "south",
    stored = 1e6, max = 2e6, usage = 0, items = { dirt, water } })
  env.turtle.inv = {}
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 16000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "needs hand-seeding", "no dry centre")
  eq(env:block(0, 99, 0).id, "minecraft:dirt", "fluid brace cell cleared to dirt")
  eq(env:block(0, 100, 0).id, "minecraft:water", "water source placed over the brace")
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

-- fix #5: if navSafe to the park fails (a blocked travel-ceiling corridor), the
-- early `return false` must be SYMMETRIC with every other restock exit - navSafe
-- back to the build cell, restore the saved heading, and clear the write-ahead
-- intent. Otherwise the turtle is left parked mid-corridor facing an arbitrary
-- direction with an orphaned `intent=restock ...` in the journal.
T("supply: a blocked restock-park path restores heading + clears intent", function()
  local env = supplyRig()
  -- obstruct the travel-ceiling corridor between the build column (z=0) and the
  -- park (z=-2) at travel_y, so the FIRST restock's navSafe to the park fails
  env:setBlock(0, 116, -1, { id = "minecraft:stone" })
  current = env
  env:run(FARM, { "build" }, { maxTime = 12000 })
  -- the restock could not reach the park, so the build halts - but the journal
  -- must carry no orphaned intent and the turtle must be back on its build heading
  local j = parseFarmJournal(env:file("farm.journal"))
  if j then eq(j.intent, nil, "no orphaned restock intent left in the journal") end
  eq(env.turtle.facing, "east", "heading restored to the build heading (not the corridor)")
end)

-- ----------------------------------- navSafe travel ceiling (the speed fix)
-- navSafe rises to a clear ceiling, crosses horizontally, then descends - so the
-- corridor never crashes through the partially-built stack. The OLD ceiling was
-- the UNCONDITIONAL cfg.travel_y, sized for the FULLY-built stack (build.y +
-- plots*size.h + clearance). On an EARLY plot almost nothing is up there yet, so
-- every restock wasted a tall climb to travel_y. The fix: climb only as high as
-- what is ACTUALLY built - builtCeil = build.y + (S.plot+1)*size.h + clearance -
-- which still clears the existing farm (below build.y) and the finished plots
-- (below builtCeil), and is always <= travel_y, so it never climbs HIGHER than
-- today. These tests pin both: it still clears the built structure on a horizontal
-- move (the build completes), and it does NOT over-climb to travel_y on plot 0.

-- A low, tall (many-plot) stack so travel_y sits well above the early-plot
-- builtCeil, with the turtle parked LOW (so a stray-high maxY can only come from
-- an over-climb, never from the start pose). Empty work slots force a restock on
-- plot 0; the bridge stocks everything. ceilBlock (optional) drops a block in the
-- build column between builtCeil and travel_y: it would obstruct the OLD over-
-- climb (navSafe false -> build fails) but is above the NEW builtCeil, so the fix
-- sails under it. Returns env + the two ceilings for the assertions.
local function navCeilRig(opts)
  opts = opts or {}
  -- Build ONE plot (so the measured maxY reflects plot 0 only - later plots have
  -- a HIGHER, legitimate builtCeil), but size travel_y as if for an 8-plot stack
  -- (the real conf sizes travel_y for the planned full stack). The fix must keep
  -- plot 0 well below that full-stack travel_y.
  local buildY, plots, h, clr = 100, 1, 2, 3
  local travelY = buildY + 8 * h + 4 -- 120: the full (8-plot) stack ceiling (>> builtCeil)
  local builtCeil = buildY + (0 + 1) * h + clr -- plot 0 in progress: 105
  -- park LOW and OFF the stack (z=-2), at the build base height; the turtle starts
  -- AT the park so its initial maxY is buildY, well below builtCeil.
  local env = CC.new{ turtle = { pos = { x = 0, y = buildY, z = -2 },
    facing = "east", fuel = 200000 } }
  env.files["farm.blueprint"] = opts.blueprint or BP_3x3
  env.files["farm.conf"] = ([[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 2, d = 3 },
    heading = "east", lateral = "south", scan_y = 66,
    start = { x = 0, y = %d, z = -2 }, start_heading = "east",
    build = { x = 0, y = %d, z = 0 }, plots = %d, fleet = "farm1",
    travel_y = %d, clearance = %d,
    base = { bridge = "me", park = { x = 0, y = %d, z = -2 },
      staging = { x = 0, y = %d, z = -2 }, suck = "down", export_side = "up" },
  }]]):format(buildY, buildY, plots, travelY, clr, buildY, buildY - 1)
  local dirt = { id = "minecraft:dirt", count = 256, isCraftable = false }
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  seed.isCraftable = false
  local water = env:waterBucketItem(); water.count = 16; water.isCraftable = false
  env:addMeBridge("me", { stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    exportCell = { x = 0, y = buildY - 1, z = -2 },
    items = { dirt, fert, seed, water } })
  env.turtle.inv = { [2] = env:hoeItem{ durability = 2000 } } -- only a hoe; work slots empty -> restock on plot 0
  if opts.ceilBlock then
    -- a ceiling block in the build column ABOVE builtCeil but BELOW travel_y: only
    -- the old over-climb (to travel_y) hits it.
    env:setBlock(0, opts.ceilBlock, 0, { id = "minecraft:stone" })
  end
  if opts.resume then
    -- a journal-resume (phase=build) so the one-time fresh-build top probe
    -- (skipBuiltPlots, which legitimately rises to travel_y once over an EXISTING
    -- stack) is skipped - isolating the PER-RESTOCK ceiling we are measuring.
    env.files["farm.journal"] =
      ("phase=build\nplot=0\ndy=0\npos=0,%d,-2\nheading=east\n"):format(buildY)
  end
  return env, builtCeil, travelY
end

-- The fix must NOT regress correctness: navSafe still clears the built structure
-- on a horizontal move, so an early-plot build with restocks runs to completion.
T("navSafe: an early-plot restock still clears the built stack (build completes)", function()
  local env = navCeilRig()
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 30000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  -- plot 0 fully built (8 fertilized ring cells) - the restock corridor worked
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"), 8,
    "plot 0 soil ring built (restock cleared the structure)")
end)

-- The speed fix proper: on plot 0 the turtle must rise only to builtCeil, NEVER to
-- travel_y. With the turtle parked LOW, maxY can only exceed builtCeil via an
-- over-climb - so assert maxY == builtCeil and is strictly below travel_y.
T("navSafe: an early-plot restock climbs to builtCeil, not the full-stack travel_y", function()
  local env, builtCeil, travelY = navCeilRig{ resume = true }
  current = env
  local res = env:run(FARM, {}, { maxTime = 30000 }) -- bare resume (uses the journal)
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  if travelY <= builtCeil then fail("rig misconfigured: travel_y must exceed builtCeil") end
  if env.turtle.maxY > builtCeil then
    fail(("over-climbed: maxY=%d exceeds builtCeil=%d (travel_y=%d) - navSafe still "
      .. "rises to the full-stack ceiling on plot 0"):format(
      env.turtle.maxY, builtCeil, travelY))
  end
  eq(env.turtle.maxY, builtCeil, "rose exactly to the built ceiling on plot 0")
end)

-- The complement, proving the assertion above has teeth: a block parked BETWEEN
-- builtCeil and travel_y obstructs the OLD over-climb (it would rise into it and
-- navSafe would fail), but the fixed climb sails UNDER it, so the build still
-- completes. (Under the old code this block would halt the build.)
T("navSafe: a ceiling block above builtCeil but below travel_y no longer blocks the build", function()
  local env, builtCeil, travelY = navCeilRig{ ceilBlock = 115, resume = true }
  current = env
  if not (115 > builtCeil and 115 < travelY) then
    fail("rig misconfigured: the ceiling block must sit between builtCeil and travel_y")
  end
  local res = env:run(FARM, {}, { maxTime = 30000 }) -- bare resume (uses the journal)
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(countLayer(env, 100, "farmingforblockheads:fertilized_farmland_healthy"), 8,
    "plot 0 built - the fixed climb passes under the high ceiling block")
  if env.turtle.maxY >= 115 then
    fail(("climbed into the ceiling-block layer: maxY=%d >= 115"):format(env.turtle.maxY))
  end
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

-- fix #4: a kill striking AFTER a water source materialized but BEFORE the spent
-- bucket was evacuated leaves a minecraft:bucket stranded in the water work slot.
-- On the NEXT water cell, restock can't merge a fresh water_bucket into a slot
-- holding a different item, so it reads 0 and halts 'no-water'. doWater must
-- evacuate a non-water item from the slot at the TOP of the function (idempotent
-- across kills), before ensureItem, so the stranded empty never strands a pull.
T("kill-resume: a stranded spent bucket in the water slot never halts 'no-water'", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
    facing = "east", fuel = 80000 } }
  env.files["farm.blueprint"] =
    "return {\n  size = { w = 1, h = 1, d = 1 },\n  cells = {\n"
    .. "    [\"0,0,0\"] = { kind = \"water\" },\n  },\n}\n"
  env.files["farm.conf"] = [[return {
    origin = { x = 0, y = 64, z = 0 }, size = { w = 1, h = 1, d = 1 },
    heading = "east", scan_y = 66,
    start = { x = 0, y = 120, z = 0 }, start_heading = "east",
    build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
    base = { bridge = "me", park = { x = 0, y = 116, z = -2 },
      suck = "self", export_side = "north", bridge_facing = "south" },
  }]]
  env:setBlock(0, 99, 0, { id = "minecraft:stone" }) -- solid sub-floor
  local water = env:waterBucketItem(); water.count = 16; water.isCraftable = false
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "south",
    stored = 1e6, max = 2e6, usage = 0, items = { water } })
  -- the stranded empty bucket sits in the water work slot (slots.water default 5)
  env.turtle.inv = { [5] = { id = "minecraft:bucket", count = 1 } }
  env.files["farm.journal"] =
    "phase=build\nplot=0\ndy=0\npos=0,120,0\nheading=east\nselftest=done\n"
  current = env
  local res = env:run(FARM, {}, { maxTime = 9000 }) -- no-arg = resume
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "no-water", "did not strand on the empty bucket")
  eq(env:block(0, 100, 0).id, "minecraft:water", "water source placed")
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

-- THE faceBridge kill window: with NO calibrated bridge_facing in conf, restock
-- falls back to faceBridge(), which turns toward the bridge with RAW turtle.
-- turnRight() - turns that do NOT update S.heading or journal. A kill while
-- parked-and-faced-at-the-bridge then leaves the physical turtle rotated
-- (facing the bridge) while the journal still records the pre-turn heading. On
-- resume the build dead-reckons with the WRONG facing -> every move goes the
-- wrong way and the whole stack lands rotated/displaced. faceBridge's turns
-- must be journaled (like faceTo) so a kill mid-face resumes square.
T("kill-resume: a kill while faced at the bridge (no bridge_facing) resumes square", function()
  -- bridge ON the turtle, readable ONLY facing south, suck="self"; conf OMITS
  -- bridge_facing so restock takes the raw-turn faceBridge() fallback. Plain
  -- soil needs only dirt, isolating the supply turn.
  local function mkEnv()
    local env = CC.new{ turtle = { pos = { x = 0, y = 120, z = 0 },
      facing = "east", fuel = 80000 } }
    env.files["farm.blueprint"] = BP_PLAIN_SOIL
    env.files["farm.conf"] = [[return {
      origin = { x = 0, y = 64, z = 0 }, size = { w = 3, h = 1, d = 3 },
      heading = "east", scan_y = 66,
      start = { x = 0, y = 120, z = 0 }, start_heading = "east",
      build = { x = 0, y = 100, z = 0 }, plots = 1, fleet = "farm1", travel_y = 116,
      base = { bridge = "me", park = { x = 0, y = 116, z = 0 },
        suck = "self", export_side = "north" },
    }]]
    local dirt = { id = "minecraft:dirt", count = 256 }
    env:addMeBridge("me", { intoTurtle = "north", whenFacing = "south",
      stored = 1e6, max = 2e6, usage = 0, items = { dirt } })
    env.turtle.inv = { [2] = env:hoeItem{ durability = 2000 } }
    return env
  end
  -- t=27 lands the kill while parked at the park (y116) having just raw-turned
  -- east->south to read the bridge: journal heading must still == physical
  local env = mkEnv()
  env:restartAt(27)
  current = env
  env:run(FARM, { "build" }, { maxTime = 4000 })
  local j = parseFarmJournal(env:file("farm.journal") or env:file("farm.journal.bak"))
  if j and j.heading then
    eq(j.heading, env.turtle.facing,
      "journal heading must match physical facing after a kill mid-faceBridge")
  end
  env:run(FARM, {}, { maxTime = 8000 })   -- resume
  -- the plot must build at its INTENDED footprint (0..2), not rotated/displaced
  eq(countLayer(env, 100, "minecraft:farmland", 3, 3, 0, 0), 9,
    "all 9 soil tilled at the intended footprint after a mid-face kill resume")
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
  -- the ctl ack only happens in serveIdle (post-build), so the messages must
  -- land AFTER the build completes; the side-till build is ~90 sim-sec long, so
  -- deliver at 100/102 (the build phase consumes-and-drops rednet, it does not
  -- buffer for serveIdle) and terminate the idle loop after.
  env:rednetAt(100, 9, { token = "flux", cmd = "update" }, "basectl")
  env:rednetAt(102, 9, { token = "wrong", cmd = "update" }, "basectl") -- ignored
  env:terminateAt(200)
  current = env
  env:run(FARM, { "build" }, { maxTime = 400 })
  local acks = 0
  for _, m in ipairs(env.rednetSent) do
    if m.protocol == "basectl" and type(m.message) == "table" and m.message.ack then
      acks = acks + 1
    end
  end
  eq(acks, 1, "exactly one ack (valid token only)")
end)

-- ------------------------------------ fix #1: park must never be a build cell
-- The operator's rig: bridge ON the turtle (suck=self), the stack centred over a
-- ground-floor ender chest, so the park column (0,0,0) lands INSIDE the build
-- footprint. Plot 0 places a block AT the park cell; every later restock then
-- rises to travel_y, moves over, and tries to descend onto the now-occupied park
-- -> goDown "Movement obstructed" -> restock false -> the build mislabels the
-- strand "no-seed" with the soil ring laid and zero crops. The park/drop must be
-- relocated off the stack so the build completes.

-- 3x3 h=2: soil ring (8 fertilized) + center water at dy0 (1,0,1); crops at dy1
-- (none above the water center). Local cell (1,0,1) is the centre.
local BP_RING_WATER = [[return {
  size = { w = 3, h = 2, d = 3 },
  cells = {
    ["0,0,0"] = { kind = "soil", tier = "fertilized" },
    ["0,0,1"] = { kind = "soil", tier = "fertilized" },
    ["0,0,2"] = { kind = "soil", tier = "fertilized" },
    ["1,0,0"] = { kind = "soil", tier = "fertilized" },
    ["1,0,1"] = { kind = "water" },
    ["1,0,2"] = { kind = "soil", tier = "fertilized" },
    ["2,0,0"] = { kind = "soil", tier = "fertilized" },
    ["2,0,1"] = { kind = "soil", tier = "fertilized" },
    ["2,0,2"] = { kind = "soil", tier = "fertilized" },
    ["0,1,0"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["0,1,1"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["0,1,2"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["1,1,0"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["1,1,2"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["2,1,0"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["2,1,1"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
    ["2,1,2"] = { kind = "crop", id = "mysticalagriculture:sulfur_crop" },
  },
}
]]

T("supply: park inside the build footprint never strands the build as no-seed", function()
  -- build cell (1,0,1) world = (-1+1, 0+0, -1+1) = (0,0,0) == park. The stray
  -- block plot 0 places at the centre would block a park descent.
  local env = CC.new{ turtle = { pos = { x = 0, y = 0, z = 0 },
    facing = "north", fuel = 90000 } }
  env.files["farm.blueprint"] = BP_RING_WATER
  env.files["farm.conf"] = [[return {
    origin = { x = -1, y = -2, z = -1 }, size = { w = 3, h = 2, d = 3 },
    heading = "north", scan_y = 1,
    start = { x = 0, y = 0, z = 0 }, start_heading = "north",
    build = { x = -1, y = 0, z = -1 }, plots = 1, fleet = "farm1", travel_y = 8,
    base = { bridge = "me", park = { x = 0, y = 0, z = 0 },
      suck = "self", export_side = "north", bridge_facing = "north" },
  }]]
  local dirt = { id = "minecraft:dirt", count = 256 }
  local hoe = env:hoeItem{ durability = 2000 }; hoe.count = 0; hoe.isCraftable = true
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 256 })
  seed.isCraftable = false
  local water = env:waterBucketItem(); water.count = 16; water.isCraftable = false
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "north",
    stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    items = { dirt, hoe, fert, seed, water } })
  env.turtle.inv = {}
  current = env
  local res = env:run(FARM, { "build" }, { maxTime = 60000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectNotContains(env:termText(), "halted", "build did not halt")
  expectNotContains(env:termText(), "no-seed", "did not mislabel as no-seed")
  eq(countLayer(env, 1, "mysticalagriculture:sulfur_crop", 3, 3, -1, -1), 8,
    "all 8 crops laid (park was relocated off the stack)")
end)

T("setup: wizard keeps the park off the build stack (ender-centred, on-turtle bridge)", function()
  -- turtle dropped roughly over the plot, on-turtle bridge readable facing north,
  -- an ender chest at the plot centre so the stack centres over it -> the drop
  -- column would otherwise be a build cell. The wizard must relocate the park.
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "north", fuel = 90000 } }
  -- a 3x3 plot just below the turtle, with an ender chest at its centre column
  seedRefPlot(env, -1, 77, -1, 3, 3)
  env:setBlock(0, 76, 0, { id = "enderstorage:ender_chest" }) -- ground-floor anchor
  env:addGeoScanner("scanner")
  local dirt = { id = "minecraft:dirt", count = 2554 }
  local hoe = env:hoeItem{ durability = 2000 }; hoe.count = 0; hoe.isCraftable = true
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 0 })
  seed.isCraftable = true
  local water = env:waterBucketItem(); water.count = 16; water.isCraftable = false
  local ender = { id = "enderstorage:ender_chest", count = 4, nbtKeyed = true,
    fingerprint = "ender#wWw" }
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "north",
    stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    items = { dirt, hoe, fert, seed, water, ender } })
  env.turtle.inv = {}
  current = env
  local res = env:run(FARM, { "setup", "1" }, { maxTime = 120000 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  local conf = loadTable(env:file("farm.conf"), "farm.conf")
  local b, sz, pk = conf.build, conf.size, conf.base.park
  local horiz = pk.x >= b.x and pk.x < b.x + sz.w and pk.z >= b.z and pk.z < b.z + sz.d
  local vert = pk.y >= b.y and pk.y < b.y + conf.plots * sz.h
  if horiz and vert then
    fail(("park %d,%d,%d is INSIDE the build footprint"):format(pk.x, pk.y, pk.z))
  end
  expectNotContains(env:termText(), "no-seed", "build completed, not stranded")
end)

-- ===================================================================== e2e
-- One comprehensive end-to-end drive of the operator's REAL rig, exercising
-- every load-bearing fix together: a facing-gated on-turtle bridge (whenFacing/
-- intoTurtle), an autocraft-heavy AE (hoe/fert/seed craftable, dirt stocked, a
-- fingerprint-keyed ender chest), a 17x6 h=3 canopy plot captured without
-- truncation (fix #3, exactly the radius-8 boundary), ender-centred 2-plot
-- stacking with the park kept off the stack (fix #1), water bracing on the stack
-- (fix #2), and a stray-block resume that must NOT mis-skip the real plot.
T("e2e: operator scenario - on-turtle bridge, autocraft AE, canopy plot, ender-centred 2-plot stack, resume after a partial build", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 80, z = 0 },
    facing = "north", fuel = 200000 } } -- facing north: on-turtle bridge readable
  -- the operator's fused 17x6 h=3 plot just below + south of the turtle (so the
  -- turtle's own drop column sits off the build footprint and stays navigable
  -- across the resume), with a canopy and a ground-floor ender-chest anchor at
  -- its centre column
  seedOperatorPlot(env, -8, 76, 1, 17, 6)
  env:addGeoScanner("scanner") -- free radius-8 path (17 wide is the boundary)
  -- the facing-gated, into-turtle bridge: autocraft hoe/fert/seed, dirt STOCKED,
  -- a fingerprint-keyed ender chest pulled by fingerprint, canopy blocks present
  local dirt = { id = "minecraft:dirt", count = 2554 }
  local hoe = env:hoeItem{ durability = 2000 }; hoe.count = 0; hoe.isCraftable = true
  local fert = env:fertilizerItem{ count = 0 }; fert.isCraftable = true
  local seed = env:seedItem("mysticalagriculture:sulfur_crop", { count = 0 })
  seed.isCraftable = true
  local water = env:waterBucketItem(); water.count = 64; water.isCraftable = false
  local coal = { id = "minecraft:coal_block", count = 64 }
  local accel = { id = "mysticalagriculture:essence_farmland", count = 999 }
  local cable = { id = "ae2:cable", count = 999 }
  local ender = { id = "enderstorage:ender_chest", count = 9, nbtKeyed = true,
    fingerprint = "ender#wWw" }
  env:addMeBridge("me", { intoTurtle = "north", whenFacing = "north",
    stored = 1e6, max = 2e6, usage = 0, craftSeconds = 1,
    items = { dirt, hoe, fert, seed, water, coal, accel, cable, ender } })
  env.turtle.inv = {}
  current = env

  -- ----- PHASE 1: setup + build -----
  local res1 = env:run(FARM, { "setup", "2" }, { maxTime = 400000 })
  eq(res1.reason, "done", "setup/build reason (err=" .. tostring(res1.err) .. ")")
  expectNotContains(env:termText(), "halted", "build did not halt")
  expectNotContains(env:termText(), "no-seed", "no seed strand")
  expectNotContains(env:termText(), "no-water", "no water strand")
  expectNotContains(env:termText(), "needs hand-seeding", "no dry centre")
  expectNotContains(env:termText(), "exceeds", "capture not truncated (17 fits r8)")

  local conf = loadTable(env:file("farm.conf"), "farm.conf")
  eq(conf.base.suck, "self", "bridge on the turtle")
  eq(conf.base.export_side, "north", "export side")
  eq(conf.base.bridge_facing, "north", "bridge facing")
  eq(conf.plots, 2, "two stacked plots")
  -- fix #1: the park / drop must be OFF the build footprint so restocks never
  -- strand on their own park (the relocation logic itself is pinned by the two
  -- dedicated fix-#1 tests; here we assert the end-to-end invariant holds)
  local b, sz, pk = conf.build, conf.size, conf.base.park
  local horiz = pk.x >= b.x and pk.x < b.x + sz.w and pk.z >= b.z and pk.z < b.z + sz.d
  local vert = pk.y >= b.y and pk.y < b.y + conf.plots * sz.h
  if horiz and vert then
    fail(("park %d,%d,%d is INSIDE the build footprint"):format(pk.x, pk.y, pk.z))
  end
  -- fix #3: blueprint integrity - outer-ring columns AND the floor layer present
  local bp = loadTable(env:file("farm.blueprint"), "farm.blueprint")
  eq(sz.w, 17, "captured full width"); eq(sz.d, 6, "captured full depth")
  eq(sz.h, 3, "captured full height")
  if not bp.cells["0,0,0"] then fail("blueprint floor corner 0,0,0 missing") end
  if not bp.cells["16,0,5"] then fail("blueprint far-edge floor 16,0,5 missing") end
  if not bp.cells["0,2,0"] then fail("blueprint canopy corner 0,2,0 missing") end

  -- physical build frame: turtle started at world (0,80,0); build is dead-reckoned
  -- relative to start (0,0,0), so physical = world-start + relative.
  local px0 = 0 + b.x          -- -8
  local pz0 = 0 + b.z          -- -3
  local py0 = 80 + b.y         -- plot0 base (soil) world Y
  local H = sz.h
  for plot = 0, 1 do
    local soilY = py0 + plot * H
    local cropY = soilY + 1
    local canopyY = soilY + 2
    eq(countLayer(env, soilY, "farmingforblockheads:fertilized_farmland_healthy",
      17, 6, px0, pz0), 17 * 6 - 1, "plot " .. plot .. " fertilized soil ring")
    eq(countLayer(env, cropY, "mysticalagriculture:sulfur_crop",
      17, 6, px0, pz0), 17 * 6 - 1, "plot " .. plot .. " crop layer")
    -- centre water (a source) in BOTH copies
    eq(env:block(px0 + 8, soilY, pz0 + 3).id, "minecraft:water",
      "plot " .. plot .. " centre water source")
    -- the bulk canopy accelerators are pulled+placed in BOTH copies (the ender
    -- chest + cable are NBT/frequency-keyed harvest infrastructure the builder
    -- skips by design - "place these yourself" - so they are not asserted placed)
    if countLayer(env, canopyY, "mysticalagriculture:essence_farmland",
      17, 6, px0, pz0) < 80 then
      fail("plot " .. plot .. " canopy accelerators missing")
    end
  end
  -- the keyed harvest infrastructure was skipped LOUDLY (design: external harvest)
  expectContains(env:termText(), "skipping enderstorage:ender_chest",
    "the fingerprint-keyed ender chest is skipped loudly, not silently")

  -- ----- PHASE 2: resume after a PARTIAL build (must NOT mis-skip) -----
  -- fresh-run state: drop the journal so skipBuiltPlots runs; keep conf+blueprint
  env.files["farm.journal"] = nil
  env.files["farm.journal.bak"] = nil
  -- wipe everything plot 1 (the top copy) placed EXCEPT one stray block at its
  -- corner-column soil layer (dy0). Plot 0 stays genuinely complete.
  local p1soilY = py0 + 1 * H
  for dx = 0, 16 do
    for dz = 0, 5 do
      for dyy = 0, 2 do
        if not (dx == 0 and dz == 0 and dyy == 0) then
          env.world[(px0 + dx) .. "," .. (p1soilY + dyy) .. "," .. (pz0 + dz)] = nil
        end
      end
    end
  end
  -- ensure the stray block IS present at plot1 corner dy0
  env:setBlock(px0, p1soilY, pz0, { id = "minecraft:dirt" })
  -- re-stock the AE for the rebuild (counts were drawn down)
  fert.count = 0; seed.count = 0
  env.turtle.pos = { x = 0, y = 80, z = 0 }; env.turtle.facing = "north"
  env.turtle.inv = {}

  local res2 = env:run(FARM, {}, { maxTime = 400000 }) -- bare resume
  eq(res2.reason, "done", "resume reason (err=" .. tostring(res2.err) .. ")")
  expectContains(env:termText(), "1 plot(s) already built",
    "plot 0 counted as built")
  expectNotContains(env:termText(), "stack already complete",
    "the stray block at plot1 dy0 did NOT count plot1 as built")
  -- the real plot 1 was rebuilt, not skipped
  eq(countLayer(env, p1soilY + 1, "mysticalagriculture:sulfur_crop",
    17, 6, px0, pz0), 17 * 6 - 1, "plot 1 crop layer fully laid on resume")
  eq(env:block(px0 + 8, p1soilY, pz0 + 3).id, "minecraft:water",
    "plot 1 centre water rebuilt")
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
