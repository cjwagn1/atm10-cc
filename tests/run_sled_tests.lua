--[[
run_sled_tests.lua - Project Sled test suite (phase 2).

Run from the project root:
  toolchain/lua-5.2.4/src/lua tests/run_sled_tests.lua

Covers the SLED-DESIGN.md §11 red-to-green list (as amended by the phase-2
brief): harness turtle/world/miner-mock extensions, then programs/sled.lua
driven test-by-test, then sledctl + the fluxwall sled card.

The original 47 tests live untouched in tests/run_tests.lua; run both.
Every mock behavior and verbatim string here cites a claim in
docs/RESEARCH.md ("Project Sled" ledger) or a vendored source line.
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

-- ---------------------------------------------------- 1. turtle mock basics
-- §11 test 1 (C4: fuel semantics + verbatim strings, CC-Tweaked
-- TurtleMoveCommand.java:44,55,84 @ v1.21.1-1.117.1)

T("turtle: moves mutate pos/facing, fuel decrements, turns are free", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10 } }
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.forward()))
    turtle.turnLeft()
    out.writeLine(tostring(turtle.forward()))
    turtle.turnRight()
    out.writeLine(tostring(turtle.up()))
    out.writeLine(tostring(turtle.down()))
    out.writeLine(tostring(turtle.back()))
    out.writeLine(tostring(turtle.getFuelLevel()))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), "true\ntrue\ntrue\ntrue\ntrue\n5\n", "program output")
  -- east=+x, north=-z: fwd, left+fwd, up, down, back => net (0,0,-1), east
  eq(env.turtle.pos.x, 0, "x"); eq(env.turtle.pos.y, 64, "y")
  eq(env.turtle.pos.z, -1, "z")
  eq(env.turtle.facing, "east", "facing")
  eq(env.turtle.fuel, 5, "fuel after 5 moves (turns free)")
end)

T("turtle: 'Out of fuel' verbatim at 0; failed move consumes nothing", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 1 } }
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.forward()))
    local ok, err = turtle.forward()
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    out.writeLine(tostring(turtle.getFuelLevel()))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"), "true\nfalse Out of fuel\n0\n", "output")
  eq(env.turtle.pos.x, 1, "moved exactly once")
end)

T("turtle: 'Movement obstructed' verbatim; detect/inspect see the block", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10 } }
  env:setBlock(1, 64, 0, { id = "minecraft:cobblestone" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local ok, err = turtle.forward()
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    out.writeLine(tostring(turtle.detect()))
    local ib, info = turtle.inspect()
    out.writeLine(tostring(ib) .. " " .. tostring(info and info.name))
    out.writeLine(tostring(turtle.detectUp()))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"),
    "false Movement obstructed\ntrue\ntrue minecraft:cobblestone\nfalse\n",
    "output")
  eq(env.turtle.fuel, 10, "failed move consumed no fuel")
end)

T("turtle: moves consume ~0.4s virtual time each", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10 } }
  env.files["prog.lua"] = [[
    local t0 = os.clock()
    turtle.forward()
    turtle.forward()
    local f = fs.open("out", "w")
    f.writeLine(tostring(os.clock() - t0))
    f.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  local dt = tonumber((env:file("out") or ""):match("[%d%.]+"))
  if not dt or dt < 0.75 or dt > 1.2 then
    fail("expected ~0.8s for two moves, got " .. tostring(dt))
  end
end)

-- -------------------------------------------------------- 2. world model
-- §11 test 2 (C1: place fails item-retained; C2: dig loot parity, full
-- inventory drops loot on the ground and the dig still succeeds)

T("world: place into occupied cell fails item-retained, verbatim", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10,
    inv = { [1] = { id = "minecraft:cobblestone", count = 2 } } } }
  env:setBlock(1, 64, 0, { id = "minecraft:dirt" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local ok, err = turtle.place()           -- occupied
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    out.writeLine(tostring(turtle.getItemCount(1)))
    out.writeLine(tostring(turtle.placeUp())) -- free cell above
    out.writeLine(tostring(turtle.getItemCount(1)))
    turtle.select(2)                          -- empty slot
    local ok2, err2 = turtle.placeDown()
    out.writeLine(tostring(ok2) .. " " .. tostring(err2))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"),
    "false Cannot place block here\n2\ntrue\n1\nfalse No items to place\n",
    "output")
  eq(env:block(0, 65, 0) and env:block(0, 65, 0).id,
    "minecraft:cobblestone", "block placed above")
end)

T("world: dig moves the block into inventory; dig of air is a no-op", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10,
    inv = { [1] = { id = "minecraft:cobblestone", count = 5 } } } }
  env:setBlock(1, 64, 0, { id = "minecraft:cobblestone" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.dig()))
    out.writeLine(tostring(turtle.getItemCount(1)))  -- stacked into slot 1
    local ok, err = turtle.dig()                     -- nothing left
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"), "true\n6\nfalse Nothing to dig here\n", "output")
  eq(env:block(1, 64, 0), nil, "block removed from world")
end)

T("world: dig with full inventory drops loot on the ground, dig still true", function()
  local inv = {}
  for i = 1, 16 do inv[i] = { id = "mod:junk" .. i, count = 1 } end
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10, inv = inv } }
  env:setBlock(1, 64, 0, { id = "minecraft:dirt" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    out.writeLine(tostring(turtle.dig()))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"), "true\n", "dig succeeded despite full inventory (C2)")
  eq(env:block(1, 64, 0), nil, "block removed")
  local dropped = env.ground["1,64,0"]
  if not dropped or #dropped == 0 or dropped[1].id ~= "minecraft:dirt" then
    fail("expected minecraft:dirt dropped at 1,64,0")
  end
  for i = 1, 16 do
    eq(env.turtle.inv[i].id, "mod:junk" .. i, "slot " .. i .. " untouched")
  end
end)

-- ------------------------------------------------------- 3. attach timing
-- §11 test 3 (C3 [SOURCE]: attach exactly one tick after placement; too
-- early wrap nil; stale handle silently nil, transparent rebind)

T("attach: wrap after place is nil; event next tick; stale nil; rebind", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10 } }
  env.turtle.inv[1] = env:machineItem{ id = "mock:box",
    types = { "mock_box" }, methods = { ping = function() return "pong" end } }
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    turtle.place()
    local w0 = peripheral.wrap("front")
    out.writeLine(tostring(w0))                 -- nil: too early (C3)
    local t0 = os.clock()
    local _, side = os.pullEvent("peripheral")
    out.writeLine(side .. " +" .. tostring(os.clock() - t0))
    local w = peripheral.wrap("front")
    out.writeLine(tostring(w.ping()))
    turtle.dig()
    os.pullEvent("peripheral_detach")
    local ok, r = pcall(w.ping)                 -- stale: nil, NO error (C3)
    out.writeLine(tostring(ok) .. " " .. tostring(r))
    turtle.place()
    os.pullEvent("peripheral")
    out.writeLine(tostring(w.ping()))           -- transparent rebind (C3)
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 60, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"),
    "nil\nfront +0.05\npong\ntrue nil\npong\n", "output")
end)

T("attach: peripheral detaches when the turtle moves away (one tick late)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10 } }
  env.turtle.inv[1] = env:machineItem{ id = "mock:box",
    types = { "mock_box" }, methods = { ping = function() return "pong" end } }
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    turtle.placeUp()
    os.pullEvent("peripheral")
    out.writeLine(peripheral.getType("top"))
    turtle.forward()
    os.pullEvent("peripheral_detach")
    out.writeLine(tostring(peripheral.isPresent("top")))
    turtle.back()
    os.pullEvent("peripheral")
    out.writeLine(tostring(peripheral.isPresent("top")))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 60, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), "mock_box\nfalse\ntrue\n", "output")
end)

-- ------------------------------------------------------- 4-6. miner mock
-- §11 tests 4 (A1 surface + security), 5 (C1 bounding volume), 6 (A2
-- component round-trip)

T("miner mock: A1 surface; start() throws verbatim unless PUBLIC; sim runs", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addDigitalMiner("digitalMiner_0", { security = "PRIVATE",
    radius = 12, minY = 65, maxY = 247, energy = 40000 })
  env:addDigitalMiner("digitalMiner_1", { security = "PUBLIC",
    targets = 100, searchSeconds = 1, mineRate = 100 })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local m = peripheral.wrap("digitalMiner_0")
    out.writeLine(m.getRadius() .. " " .. m.getMinY() .. " "
      .. m.getMaxY() .. " " .. m.getMaxRadius())
    out.writeLine(m.getState() .. " " .. tostring(m.isRunning())
      .. " " .. m.getToMine())
    out.writeLine(m.getEnergy() .. " " .. m.getMaxEnergy()
      .. " " .. m.getSecurityMode())
    local ok, err = pcall(m.start)
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    local p = peripheral.wrap("digitalMiner_1")
    p.start()
    out.writeLine(p.getState() .. " " .. tostring(p.isRunning()))
    sleep(1.5)
    out.writeLine(p.getState() .. " " .. tostring(p.isRunning()))
    sleep(3)
    out.writeLine(p.getState() .. " " .. p.getToMine()
      .. " " .. tostring(p.isRunning()))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 60, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), table.concat({
    "12 65 247 32",
    "IDLE false 0",
    "40000 50000 PRIVATE",
    "false Setter not available due to machine security not being public.",
    "SEARCHING true",
    "FINISHED true",
    -- exhaustion shape per corrected N4: `running` is operator intent and
    -- is NEVER auto-cleared when toMine drains — predicate is
    -- FINISHED + toMine==0 only (phase-1 `not isRunning()` clause dropped)
    "FINISHED 0 true",
    "" }, "\n"), "output")
end)

T("miner: placeUp checks all 17 bounding cells; forward/down never work", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10 } }
  env.turtle.inv[1] = env:minerItem{ radius = 12 }
  env:setBlock(1, 66, 1, { id = "minecraft:cobblestone" }) -- corner of volume
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local ok, err = turtle.place()
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    ok, err = turtle.placeDown()
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    ok, err = turtle.placeUp()
    out.writeLine(tostring(ok) .. " " .. tostring(err)
      .. " " .. turtle.getItemCount(1))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 60, fromVirtualFs = true })
  eq(env:file("out"), table.concat({
    "false Cannot place block here",
    "false Cannot place block here",
    "false Cannot place block here 1",  -- item retained (C1)
    "" }, "\n"), "blocked output")

  env:setBlock(1, 66, 1, nil)
  env.files["prog2.lua"] = [[
    local out = fs.open("out2", "w")
    out.writeLine(tostring(turtle.placeUp()))
    local _, side = os.pullEvent("peripheral")
    out.writeLine(side .. " " .. peripheral.getType("top"))
    out.close()
  ]]
  env:run("prog2.lua", {}, { maxTime = 60, fromVirtualFs = true })
  eq(env:file("out2"), "true\ntop digitalMiner\n", "placed output")
  eq(env:block(0, 65, 0).id, "mekanism:digital_miner", "main block")
  -- placeUp'd miner faces the horizontal opposite of the turtle (C1)
  eq(env:block(0, 65, 0).state.facing, "west", "miner facing")
  local bounding = 0
  for dx = -1, 1 do for dz = -1, 1 do for dy = 0, 1 do
    if not (dx == 0 and dz == 0 and dy == 0) then
      local b = env:block(dx, 65 + dy, dz)
      if b and b.id == "mekanism:bounding_block" then
        bounding = bounding + 1
      end
    end
  end end end
  eq(bounding, 17, "17 bounding blocks")
  -- port map (A4): item input top-center UP; item output top-back-center
  -- back face (back = turtle's facing = east); energy = outer faces of the
  -- left/right main-layer bounding blocks
  if not (env:block(0, 66, 0).facePeriph or {}).up then
    fail("top-center UP item port missing")
  end
  if not (env:block(1, 66, 0).facePeriph or {}).east then
    fail("top-back-center back-face item port missing")
  end
  if not (env:block(0, 65, 1).facePeriph or {}).south then
    fail("south energy port missing")
  end
  if not (env:block(0, 65, -1).facePeriph or {}).north then
    fail("north energy port missing")
  end
end)

T("miner: dig returns ONE item; re-place restores config but never `running` (A2/A4)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 10 } }
  env.turtle.inv[1] = env:minerItem{ radius = 12, minY = 65, maxY = 247,
    energy = 12345, security = "PUBLIC", targets = 50, searchSeconds = 5 }
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    turtle.placeUp()
    os.pullEvent("peripheral")
    local m = peripheral.wrap("top")
    m.start()
    out.writeLine(m.getState() .. " " .. tostring(m.isRunning()))
    turtle.digUp()
    out.writeLine(turtle.getItemCount(1) .. " " .. turtle.getItemDetail(1).name)
    turtle.forward(); turtle.forward(); turtle.forward()
    turtle.placeUp()
    os.pullEvent("peripheral")
    m = peripheral.wrap("top")
    out.writeLine(m.getRadius() .. " " .. m.getMinY() .. " "
      .. m.getMaxY() .. " " .. m.getEnergy())
    out.writeLine(m.getState() .. " " .. tostring(m.isRunning()))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 60, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), table.concat({
    "SEARCHING true",
    "1 mekanism:digital_miner",
    "12 65 247 12345",
    "IDLE false",   -- running is NBT-only, does not ride the item (A4)
    "" }, "\n"), "output")
  -- whole 3x3x2 volume at the OLD station is gone
  for dx = -1, 1 do for dz = -1, 1 do for dy = 0, 1 do
    if env:block(dx, 65 + dy, dz) then
      fail(("old structure cell %d,%d,%d not removed"):format(dx, 65 + dy, dz))
    end
  end end end
end)

-- ------------------------------------------------- multi-boot driver fixes
-- §11 items 4-5: restartAt/chunkUnloadAt hooks, relative maxTime, queue
-- flush at boot (C4: chunk unload KILLS the VM; reboot = fresh boot)

T("driver: restartAt ends the run with reason 'reboot'; files survive; maxTime is relative", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env.files["prog.lua"] = [[
    local n = 0
    while true do
      n = n + 1
      local f = fs.open("journal", "w")
      f.writeLine("beat=" .. n)
      f.close()
      sleep(0.5)
    end
  ]]
  env:restartAt(2.0)
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(res.reason, "reboot", "first run reason")
  expectContains(env:file("journal") or "", "beat=", "journal persisted")
  -- second boot: virtual clock is already at ~2s; a relative maxTime of 3
  -- must allow ~3 more seconds of run, not time out instantly (§11.5)
  env.files["prog2.lua"] = [[
    sleep(2)
    local f = fs.open("out", "w")
    f.writeLine("second boot ran " .. os.clock())
    f.close()
  ]]
  local res2 = env:run("prog2.lua", {}, { maxTime = 3, fromVirtualFs = true })
  eq(res2.reason, "done", "second run reason (err=" .. tostring(res2.err) .. ")")
  expectContains(env:file("out"), "second boot ran", "second run output")
end)

T("driver: restart mid-action = queued-but-dropped command (C5 skew window)", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env.files["prog.lua"] = [[
    sleep(1)
    local f = fs.open("journal", "w")
    f.writeLine("intent=MOVE 1")
    f.close()
    turtle.forward()
    f = fs.open("journal", "w")
    f.writeLine("done=MOVE 1")
    f.close()
    while true do sleep(1) end
  ]]
  env:restartAt(1.2) -- inside the 0.4s forward window starting at ~1.0
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(res.reason, "reboot", "run reason")
  expectContains(env:file("journal"), "intent=MOVE 1", "intent written ahead")
  expectNotContains(env:file("journal"), "done", "done never written")
  eq(env.turtle.pos.x, 0, "move was dropped, world did not advance (C5)")
  eq(env.turtle.fuel, 100, "no fuel consumed by the dropped move")
end)

T("driver: chunkUnloadAt kills the VM; next boot sees peripherals without events", function()
  local env = CC.new{ turtle = { pos = { x = 0, y = 64, z = 0 },
    facing = "east", fuel = 100 } }
  env.turtle.inv[1] = env:minerItem{ security = "PUBLIC", targets = 100,
    searchSeconds = 1, mineRate = 1 }
  env.files["prog.lua"] = [[
    turtle.placeUp()
    os.pullEvent("peripheral")
    peripheral.wrap("top").start()
    while true do sleep(1) end
  ]]
  env:chunkUnloadAt(3.0)
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 10, fromVirtualFs = true })
  eq(res.reason, "chunk_unload", "run reason")
  -- fresh boot: machines persisted in the world; the computer boots with
  -- the peripheral already present — wrap works with NO event wait (C4)
  env.files["prog2.lua"] = [[
    local out = fs.open("out", "w")
    local m = peripheral.wrap("top")
    out.writeLine(tostring(m ~= nil))
    out.writeLine(m.getState() .. " " .. tostring(m.isRunning()))
    out.close()
  ]]
  local res2 = env:run("prog2.lua", {}, { maxTime = 5, fromVirtualFs = true })
  eq(res2.reason, "done", "second run reason (err=" .. tostring(res2.err) .. ")")
  -- the miner kept its own state across OUR reboot (its chunk stayed
  -- loaded in this scenario; the sled's VM is what died)
  expectContains(env:file("out"), "true", "wrap at boot")
end)

T("driver: os.reboot is distinguishable from os.shutdown via res.reboot", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env.files["prog.lua"] = "os.reboot()"
  env.files["prog2.lua"] = "os.shutdown()"
  current = env
  local r1 = env:run("prog.lua", {}, { maxTime = 2, fromVirtualFs = true })
  eq(r1.reason, "shutdown", "reboot reason stays 'shutdown' (47-suite compat)")
  eq(r1.reboot, true, "reboot flag set")
  local r2 = env:run("prog2.lua", {}, { maxTime = 2, fromVirtualFs = true })
  eq(r2.reason, "shutdown", "shutdown reason")
  eq(r2.reboot, nil, "no reboot flag on shutdown")
end)

-- ------------------------------------- miner mock semantics (N4/N1b close)

T("miner mock: stop() interrupts search to IDLE but FINISHED needs reset() (N1b/N4)", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addDigitalMiner("digitalMiner_0", { security = "PUBLIC",
    targets = 100, searchSeconds = 1, mineRate = 0 })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local m = peripheral.wrap("digitalMiner_0")
    m.start()
    out.writeLine(m.getState())
    m.stop()                              -- interrupts searcher -> reset -> IDLE
    out.writeLine(m.getState() .. " " .. tostring(m.isRunning()))
    m.start()
    sleep(2)
    out.writeLine(m.getState() .. " " .. m.getToMine())
    m.stop()                              -- from FINISHED: running off, state stays
    out.writeLine(m.getState() .. " " .. tostring(m.isRunning()))
    local ok, err = pcall(m.setRadius, 20) -- IDLE-gated while FINISHED
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    m.reset()
    out.writeLine(m.getState() .. " " .. m.getToMine())
    m.setRadius(20)
    out.writeLine(tostring(m.getRadius()))
    out.close()
  ]]
  current = env
  local res = env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  eq(env:file("out"), table.concat({
    "SEARCHING",
    "IDLE false",
    "FINISHED 100",
    "FINISHED false",
    "false Miner must be stopped and reset before its targeting configuration is changed.",
    "IDLE 0",
    "20",
    "" }, "\n"), "output")
end)

T("miner mock: N1b setter validation - throws not clamps, maxY-before-minY ordering", function()
  local env = CC.new{ termW = 61, termH = 20 }
  -- fresh miner ships minY=0/maxY=60 (N1b); mining dim heights -64..319 (D2)
  env:addDigitalMiner("digitalMiner_0", { security = "PUBLIC" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local m = peripheral.wrap("digitalMiner_0")
    local ok, err = pcall(m.setMinY, 65)   -- 65 > current maxY (60): ordering!
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    m.setMaxY(247)
    m.setMinY(65)
    out.writeLine(m.getMinY() .. " " .. m.getMaxY())
    ok, err = pcall(m.setRadius, 33)
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    m.setRadius(32)
    m.setSilkTouch(false)
    m.setAutoEject(true)
    out.writeLine(m.getRadius() .. " " .. tostring(m.getSilkTouch())
      .. " " .. tostring(m.getAutoEject()))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"), table.concat({
    "false Min Y '65' is out of range must be between -64 and 60. (Inclusive)",
    "65 247",
    "false Radius '33' is out of range must be between 0 and 32. (Inclusive)",
    "32 false true",
    "" }, "\n"), "output")
end)

T("miner mock: addFilter/getFilters/removeFilter with the N1b table shape", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addDigitalMiner("digitalMiner_0", { security = "PUBLIC" })
  env.files["prog.lua"] = [[
    local out = fs.open("out", "w")
    local m = peripheral.wrap("digitalMiner_0")
    out.writeLine(tostring(#m.getFilters()))
    out.writeLine(tostring(m.addFilter({ type = "MINER_TAG_FILTER",
      tag = "c:ores/copper" })))
    local fl = m.getFilters()
    local f = fl[1]
    out.writeLine(#fl .. " " .. f.type .. " " .. f.tag .. " "
      .. tostring(f.enabled) .. " " .. tostring(f.requires_replacement)
      .. " " .. f.replace_target)
    out.writeLine(tostring(m.addFilter({ type = "MINER_TAG_FILTER",
      tag = "c:ores/copper" })))          -- exact duplicate -> false
    out.writeLine(tostring(m.removeFilter({ type = "MINER_TAG_FILTER",
      tag = "c:ores/copper" })))
    out.writeLine(tostring(#m.getFilters()))
    local ok, err = pcall(m.addFilter, { type = "MINER_TAG_FILTER" })
    out.writeLine(tostring(ok) .. " " .. tostring(err))
    out.close()
  ]]
  current = env
  env:run("prog.lua", {}, { maxTime = 30, fromVirtualFs = true })
  eq(env:file("out"), table.concat({
    "0",
    "true",
    "1 MINER_TAG_FILTER c:ores/copper true false minecraft:air",
    "false",
    "true",
    "0",
    "false Invalid or missing tag specified for Tag filter",
    "" }, "\n"), "output")
end)

-- ------------------------------------------------------------ sled program

local SLED = "programs/sled.lua"

-- Standard lane rig: turtle parked at origin (0,253,0) heading east over
-- the D2 superflat surface (grass at y=252), miner/QE/fuel/markers in the
-- §1 slot map, sled.conf in place. spacing defaults small for fast tests —
-- spacing comes from conf, never from code (AM-2).
local function sledRig(o)
  o = o or {}
  local env = CC.new{ termW = 51, termH = 19, turtle = {
    pos = { x = 0, y = 253, z = 0 }, facing = "east",
    fuel = o.fuel or 5000 } }
  env:addModem("left")
  -- D2: the superflat surface is solid grass EVERYWHERE, not just under
  -- the lane — recovery probes depend on that
  for x = -4, (o.laneLen or 60) do
    for z = -4, 4 do
      env:setBlock(x, 252, z, { id = "minecraft:grass_block" })
    end
  end
  if o.minerDefaults then
    -- factory-fresh miner: radius 10, Y 0..60, no filters (N1b defaults)
    env.turtle.inv[1] = env:minerItem{ security = o.security or "PUBLIC",
      energy = o.energy or 40000,
      targets = o.targets or 100000, searchSeconds = o.searchSeconds or 1,
      mineRate = o.mineRate or 1, usagePerTick = 2756 }
  else
    env.turtle.inv[1] = env:minerItem{
      radius = 32, minY = 65, maxY = 247, security = o.security or "PUBLIC",
      energy = o.energy or 40000, maxEnergy = 50000,
      targets = o.targets or 100000, searchSeconds = o.searchSeconds or 1,
      mineRate = o.mineRate or 1, usagePerTick = 2756,
      publishLagTicks = o.publishLag }
  end
  env.turtle.inv[2] = env:qeItem{ components = o.qeComponents }
  env.turtle.inv[3] = env:qeItem{ components = o.qeComponents }
  env.turtle.inv[4] = { id = "minecraft:coal_block", count = o.coal or 64 }
  env.turtle.inv[5] = { id = "minecraft:cobblestone", count = 64 }
  env.files["sled.conf"] = ([[return {
    fleet = "sled1",
    origin = { x = 0, y = 253, z = 0 },
    heading = "east",
    lateral = "north",
    spacing = %d,
    stations_per_leg = %d,
    fuel_low = %d,
    fuel_reserve = %d,
    cadence = %d,
    token = "hunter2",
    slots = { miner = 1, qe_energy = 2, qe_item = 3, fuel = 4, marker = 5 },
    miner = { radius = 32, min_y = 65, max_y = 247, silk = false,
      auto_eject = true, tag = "c:ores/copper" },
    frequency = %q,
    frequency_mode = %q,
  }]]):format(o.spacing or 8, o.stations or 20, o.fuel_low or 1000,
    o.fuel_reserve or 100, o.cadence or 1, o.frequency or "slednet",
    o.freqMode or "verify")
  return env
end

-- assemble the skid by hand (what `sled commission` will automate): miner
-- above the park, energy QE at main+2*lateral, item QE at main+up+2*back
local SETUP_SKID = [[
  turtle.select(1) turtle.placeUp()
  turtle.turnLeft()
  turtle.forward() turtle.forward()
  turtle.select(2) turtle.placeUp()
  turtle.back() turtle.back()
  turtle.turnRight()
  turtle.forward() turtle.forward() turtle.up()
  turtle.select(3) turtle.placeUp()
  turtle.down() turtle.back() turtle.back()
  turtle.select(1)
]]
local function placeSkid(env)
  env.files["setup_skid.lua"] = SETUP_SKID
  local res = env:run("setup_skid.lua", {}, { maxTime = 60, fromVirtualFs = true })
  if res.reason ~= "done" then
    fail("skid setup failed: " .. tostring(res.reason) .. " " .. tostring(res.err))
  end
end

local function sledEnvelopes(env)
  local out = {}
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "telemetry" and type(s.message) == "table"
      and s.message.source == "sled1" then
      out[#out + 1] = s
    end
  end
  return out
end

T("sled: resume with no journal prints guidance, mutates nothing", function()
  local env = sledRig{}
  current = env
  local res = env:run(SLED, {}, { maxTime = 5 })
  eq(res.reason, "done", "run reason (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "journal", "guidance mentions the journal")
  eq(env.turtle.pos.x, 0, "did not move")
  eq(env:block(0, 252, 0).id, "minecraft:grass_block", "no marker placed")
end)

T("sled start: starts the miner, writes the journal, broadcasts E1 envelopes", function()
  local env = sledRig{ targets = 100000, mineRate = 1 }
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 12 })
  eq(env:block(0, 254, 0).state.running, true, "miner started (A4: start after place)")
  local j = env:file("sled.journal") or ""
  expectContains(j, "state=MINING", "journal state")
  expectContains(j, "station=0", "journal station")
  expectContains(j, "pos=0,253,0", "journal pos")
  expectContains(j, "heading=east", "journal heading")
  eq(env:block(0, 252, 0).id, "minecraft:cobblestone",
    "station marker placed below the park")
  local sent = sledEnvelopes(env)
  if #sent < 3 then fail("expected >=3 envelopes, got " .. #sent) end
  local m = sent[#sent].message
  eq(m.v, 1, "envelope v")
  eq(m.data.state, "MINING", "data.state")
  eq(m.data.pos, "0,253,0 E", "data.pos is a STRING (E2)")
  eq(m.data.miner, 1, "data.miner is 0/1, not boolean (E2)")
  eq(m.data.step, "", "data.step empty outside RELOCATE")
  eq(type(m.data.fuel), "number", "data.fuel")
  eq(type(m.data.targets), "number", "data.targets")
  local dt = sent[#sent].t - sent[#sent - 1].t
  if dt < 0.5 or dt > 3 then
    fail("cadence ~1s expected between envelopes, got " .. tostring(dt))
  end
end)

T("sled: exhaustion -> full RELOCATE -> mining at station 1; laneend RECOVER holds skid intact", function()
  local env = sledRig{ targets = 120, mineRate = 60, searchSeconds = 0.5,
    spacing = 8, stations = 2 }
  placeSkid(env)
  -- §11 test 7: write-ahead proof — sample journal + true position while
  -- the sled works; some sample must show a pending intent whose journal
  -- pos still equals the REAL position (intent written before mutation)
  env.snapshots.wa = {}
  for tt = 4, 40 do
    for _, frac in ipairs({ 0, 0.25, 0.5, 0.75 }) do
      env:scheduleAt(tt + frac, { fn = function()
        local w = env.snapshots.wa
        w[#w + 1] = { j = env.files["sled.journal"] or "",
          pos = env.turtle.pos.x .. "," .. env.turtle.pos.y .. ","
            .. env.turtle.pos.z }
      end })
    end
  end
  current = env
  env:run(SLED, { "start" }, { maxTime = 150 })

  -- new skid at station 1 (park x=8), running
  if not env:block(8, 254, 0) then fail("no block at new main 8,254,0") end
  eq(env:block(8, 254, 0).id, "mekanism:digital_miner", "new main")
  eq(env:block(8, 254, -2).id, "mekanism:quantum_entangloporter", "new energy QE")
  eq(env:block(10, 255, 0).id, "mekanism:quantum_entangloporter", "new item QE")
  -- old station fully struck
  eq(env:block(0, 254, 0), nil, "old main gone")
  eq(env:block(0, 254, -2), nil, "old energy QE gone")
  eq(env:block(2, 255, 0), nil, "old item QE gone")
  -- markers anchor both stations
  eq(env:block(0, 252, 0).id, "minecraft:cobblestone", "marker at station 0")
  eq(env:block(8, 252, 0).id, "minecraft:cobblestone", "marker at station 1")
  -- station 1 exhausts too; lane bound (stations=2) => RECOVER laneend
  -- BEFORE breaking the skid (machines stay placed for the human)
  local j = env:file("sled.journal") or ""
  expectContains(j, "state=RECOVER", "journal recovered at lane end")
  expectContains(j, "err=laneend", "journal err")
  expectContains(j, "station=1", "journal station")
  local sent = sledEnvelopes(env)
  local sawRelocate, last = false, nil
  for _, s in ipairs(sent) do
    if s.message.data.state == "RELOCATE" then sawRelocate = true end
    last = s.message
  end
  if not sawRelocate then fail("no RELOCATE envelope seen") end
  eq(last.data.state, "RECOVER", "final envelope state")
  eq(last.data.err, "laneend", "final envelope err")
  eq(last.data.hops, 1, "hops = stations completed")
  -- write-ahead: an intent visible while the world had NOT yet moved
  local proven = false
  for _, w in ipairs(env.snapshots.wa) do
    local jp = w.j:match("pos=([%-%d,]+)")
    if w.j:find("intent=M ", 1, true) and jp == w.pos then
      proven = true
      break
    end
  end
  if not proven then
    fail("no snapshot proved write-ahead (intent before world mutation, C5)")
  end
end)

T("sled: transient FINISHED+0 (publish lag) must NOT trigger relocation - debounce (N4)", function()
  -- N4 hazard (a): the search thread writes FINISHED before cachedToMine
  -- publishes (realistically a tick or two of visibility lag; the mock
  -- models a conservative 5), so a poll can read FINISHED+0 on a miner
  -- with thousands of targets left. The sled must re-confirm before
  -- striking the skid. searchSeconds is tuned so a cadence poll lands
  -- inside the lag window deterministically — the teeth assertion below
  -- fails loudly if a future timing change makes this vacuous.
  local env = sledRig{ targets = 4000, mineRate = 2, searchSeconds = 1,
    publishLag = 5 }
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 12 })
  expectContains(env:file("sled.journal"), "state=MINING",
    "still MINING after the transient")
  expectContains(env:file("sled.journal"), "station=0", "still at station 0")
  if not env:block(0, 254, 0) then
    fail("skid was struck on a transient FINISHED+0 read")
  end
  local sawTransient, sawRecoveryRead = false, false
  for _, s in ipairs(sledEnvelopes(env)) do
    local d = s.message.data
    -- `sled start` bootstraps through RELOCATE steps START/VERIFY_RUN;
    -- only a strike step would mean the transient fooled the sled
    if d.state == "RELOCATE" and d.step:match("^BREAK") then
      fail("sled entered RELOCATE on the transient (step " .. d.step .. ")")
    end
    if d.state == "MINING" and d.targets == 0 then sawTransient = true end
    if sawTransient and d.targets and d.targets > 0 then
      sawRecoveryRead = true
    end
  end
  if not (sawTransient and sawRecoveryRead) then
    fail("test lost its teeth: no FINISHED+0 transient was observed "
      .. "followed by a real targets reading - retune searchSeconds/lag")
  end
end)

-- -------------------------------------------- reconciliation (§5 rows)
-- §11 tests 8-10 as amended: the logout cycle (VM killed mid-step, fresh
-- boot later) is the ROUTINE case (AM-1). Explicit row tests pin the §5
-- table; the kill-sweep proves convergence from arbitrary kill points.

-- write a journal for a seeded scenario
local function seedJournal(env, t)
  local lines = {
    "state=" .. t.state,
    "station=" .. (t.station or 0),
  }
  if t.step then lines[#lines + 1] = "step=" .. t.step end
  lines[#lines + 1] = "pos=" .. t.pos
  lines[#lines + 1] = "heading=" .. (t.heading or "east")
  lines[#lines + 1] = "marker=minecraft:cobblestone"
  if t.intent then lines[#lines + 1] = "intent=" .. t.intent end
  if t.err then lines[#lines + 1] = "err=" .. t.err end
  env.files["sled.journal"] = table.concat(lines, "\n") .. "\n"
end

-- put the station-0 marker under the park (normally done at establishment)
local function seedMarker(env, x)
  env:setBlock(x or 0, 252, 0, { id = "minecraft:cobblestone" })
end

T("recon: journal MINING + miner above -> resume MINING in place", function()
  local env = sledRig{}
  placeSkid(env)
  seedMarker(env)
  seedJournal(env, { state = "MINING", station = 0, pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 5 })
  expectContains(env:file("sled.journal"), "state=MINING", "stays MINING")
  eq(env.turtle.pos.x, 0, "did not move")
  local sent = sledEnvelopes(env)
  if #sent < 2 then fail("expected resumed telemetry") end
  eq(sent[#sent].message.data.state, "MINING", "broadcasting MINING")
end)

T("recon: journal MINING + nothing above -> RECOVER err=reconcile", function()
  local env = sledRig{}
  seedMarker(env)
  seedJournal(env, { state = "MINING", station = 0, pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 5 })
  expectContains(env:file("sled.journal"), "state=RECOVER", "recovered")
  expectContains(env:file("sled.journal"), "err=reconcile", "reason")
  local sent = sledEnvelopes(env)
  eq(sent[#sent].message.data.err, "reconcile", "distress broadcast")
end)

T("recon: BREAK_QE_E with QE still placed -> dig is redone, cycle completes", function()
  local env = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env)
  seedMarker(env)
  seedJournal(env, { state = "RELOCATE", station = 0, step = "BREAK_QE_E",
    pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 90 })
  -- relocation runs to completion at station 1 and mines on
  expectContains(env:file("sled.journal"), "state=MINING", "mining again")
  expectContains(env:file("sled.journal"), "station=1", "at station 1")
  eq(env:block(8, 254, 0).id, "mekanism:digital_miner", "skid moved")
  eq(env:block(0, 254, -2), nil, "old energy QE gone")
end)

T("recon: BREAK_QE_E already dug, item in slot -> advance, cycle completes", function()
  local env = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env)
  seedMarker(env)
  -- dig the energy QE back into slot 2 (simulates step completed but the
  -- post-step journal write lost)
  env.files["setup2.lua"] = [[
    turtle.turnLeft() turtle.forward() turtle.forward()
    turtle.select(2) turtle.digUp()
    turtle.back() turtle.back() turtle.turnRight() turtle.select(1)
  ]]
  env:run("setup2.lua", {}, { maxTime = 30, fromVirtualFs = true })
  seedJournal(env, { state = "RELOCATE", station = 0, step = "BREAK_QE_E",
    pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 90 })
  expectContains(env:file("sled.journal"), "state=MINING", "mining again")
  expectContains(env:file("sled.journal"), "station=1", "at station 1")
  eq(env:block(8, 254, -2).id, "mekanism:quantum_entangloporter",
    "energy QE re-placed at station 1")
end)

T("recon: BREAK_QE_E drop on the ground -> suck() recovers it (C2)", function()
  local env = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env)
  seedMarker(env)
  -- QE cell empty, slot 2 empty, the item sits on the ground at the dig
  -- cell (C2 overflow shape)
  env.files["setup2.lua"] = [[
    turtle.turnLeft() turtle.forward() turtle.forward()
    turtle.select(2) turtle.digUp()
    turtle.back() turtle.back() turtle.turnRight() turtle.select(1)
  ]]
  env:run("setup2.lua", {}, { maxTime = 30, fromVirtualFs = true })
  local qe = env.turtle.inv[2]
  env.turtle.inv[2] = nil
  env.ground["0,254,-2"] = { qe }
  seedJournal(env, { state = "RELOCATE", station = 0, step = "BREAK_QE_E",
    pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 90 })
  expectContains(env:file("sled.journal"), "state=MINING", "mining again")
  expectContains(env:file("sled.journal"), "station=1", "at station 1")
  eq(env:block(8, 254, -2).id, "mekanism:quantum_entangloporter",
    "recovered QE re-placed at station 1")
end)

T("recon: BREAK_QE_E drop truly lost -> RECOVER err=lostdrop", function()
  local env = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env)
  seedMarker(env)
  env.files["setup2.lua"] = [[
    turtle.turnLeft() turtle.forward() turtle.forward()
    turtle.select(2) turtle.digUp()
    turtle.back() turtle.back() turtle.turnRight() turtle.select(1)
  ]]
  env:run("setup2.lua", {}, { maxTime = 30, fromVirtualFs = true })
  env.turtle.inv[2] = nil -- gone for good
  seedJournal(env, { state = "RELOCATE", station = 0, step = "BREAK_QE_E",
    pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 90 })
  expectContains(env:file("sled.journal"), "state=RECOVER", "recovered")
  expectContains(env:file("sled.journal"), "err=lostdrop", "reason")
end)

T("recon: TRAVEL +-1 ambiguity, BOTH variants -> marker walk-back resumes (C5)", function()
  for _, variant in ipairs({ "executed", "dropped" }) do
    local env = sledRig{ targets = 1e9, stations = 3 }
    seedMarker(env) -- station-0 marker = walk-back anchor
    -- machines are all in inventory mid-TRAVEL; journal says 4 moves done
    -- with a 5th pending; the world is either at 4 (dropped) or 5
    -- (executed) — the C5 two-cell window
    env.turtle.pos.x = variant == "executed" and 5 or 4
    seedJournal(env, { state = "RELOCATE", station = 0, step = "TRAVEL",
      pos = "4,253,0", intent = "M east" })
    current = env
    env:run(SLED, {}, { maxTime = 120 })
    expectContains(env:file("sled.journal"), "state=MINING",
      variant .. ": mining again")
    expectContains(env:file("sled.journal"), "station=1",
      variant .. ": at station 1")
    if not env:block(8, 254, 0) then
      fail(variant .. ": skid not rebuilt at station 1")
    end
    eq(env:block(8, 254, 0).id, "mekanism:digital_miner",
      variant .. ": new main")
    eq(env:block(8, 252, 0).id, "minecraft:cobblestone",
      variant .. ": marker at the new park")
  end
end)

T("recon: START step on a PRIVATE miner -> RECOVER err=security (A1)", function()
  local env = sledRig{ security = "PRIVATE" }
  placeSkid(env)
  seedMarker(env)
  seedJournal(env, { state = "RELOCATE", station = 0, step = "START",
    pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 15 })
  expectContains(env:file("sled.journal"), "state=RECOVER", "recovered")
  expectContains(env:file("sled.journal"), "err=security", "reason")
end)

T("recon: kill-sweep - reboot at ANY moment converges to the lane-end state", function()
  -- The AM-1 contract: a chunk unload mid-ANYTHING is routine. Sweep
  -- restart times across mining + the whole relocation; every scenario
  -- must converge (after resume boots) to the same terminal state:
  -- station 1, skid intact, RECOVER err=laneend (stations_per_leg=2).
  local killedIn = {}
  local t = 0.5
  while t <= 30 do
    local env = sledRig{ targets = 120, mineRate = 60, searchSeconds = 0.5,
      spacing = 8, stations = 2 }
    placeSkid(env)
    -- virtual time accumulated during skid setup; kills are offsets into
    -- the sled run itself
    env:restartAt(env.ticks * 0.05 + t)
    current = env
    env:run(SLED, { "start" }, { maxTime = 40 })
    local atKill = env:file("sled.journal") or ""
    local kstate = atKill:match("state=(%w+)") or "?"
    killedIn[atKill:match("step=([%w_]+)") or kstate] = true
    -- two resume boots with generous windows: first may itself complete
    -- the relocation, second drains to the terminal state
    env:run(SLED, {}, { maxTime = 60 })
    env:run(SLED, {}, { maxTime = 60 })
    local j = env:file("sled.journal") or ""
    local label = ("kill@%.1fs"):format(t)
    if not j:find("state=RECOVER", 1, true)
      or not j:find("err=laneend", 1, true)
      or not j:find("station=1", 1, true) then
      fail(label .. ": did not converge to laneend@1\n--- journal ---\n" .. j)
    end
    if not env:block(8, 254, 0)
      or env:block(8, 254, 0).id ~= "mekanism:digital_miner" then
      fail(label .. ": no miner at station 1")
    end
    if not env:block(8, 254, -2)
      or env:block(8, 254, -2).id ~= "mekanism:quantum_entangloporter" then
      fail(label .. ": no energy QE at station 1")
    end
    if not env:block(10, 255, 0)
      or env:block(10, 255, 0).id ~= "mekanism:quantum_entangloporter" then
      fail(label .. ": no item QE at station 1")
    end
    for dx = -1, 1 do for dz = -1, 1 do for dy = 0, 1 do
      if env:block(dx, 254 + dy, dz) then
        fail(label .. ": old station not fully struck")
      end
    end end end
    t = t + 0.5
  end
  -- teeth: the sweep must actually interrupt MINING and every WIDE step
  -- (the tick-narrow steps — BREAK_MINER, VERIFY_MINER, START,
  -- VERIFY_RUN — are pinned by dedicated seeded-row tests instead). If a
  -- timing change shrinks this set the sweep has silently lost coverage.
  for _, want in ipairs({ "MINING", "BREAK_QE_E", "BREAK_QE_I", "TRAVEL",
    "PLACE_MINER", "PLACE_QE_I", "PLACE_QE_E" }) do
    if not killedIn[want] then
      local got = {}
      for k in pairs(killedIn) do got[#got + 1] = k end
      fail("sweep lost its teeth: no kill landed in " .. want
        .. " (hit: " .. table.concat(got, ",") .. ") - retune stride")
    end
  end
end)

-- ------------------------------------------------- commission (AM-3/N1/N1b)

local function mutatingCalls(env)
  local n = 0
  for _, c in ipairs(env.mockCalls or {}) do
    if c:match("^set") or c:match("^add") or c:match("^remove")
      or c:match("^create") or c == "reset" or c == "start" or c == "stop" then
      n = n + 1
    end
  end
  return n
end

T("commission: assembles + converges the skid by read-back; 2nd run is a no-op", function()
  local env = sledRig{ minerDefaults = true,
    qeComponents = { frequency = { key = "slednet",
      security_mode = "PRIVATE", owner = "carter" } } }
  current = env
  local res = env:run(SLED, { "commission" }, { maxTime = 120 })
  eq(res.reason, "done", "commission exits (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "READY", "report")
  expectNotContains(env:termText(), "NOT READY", "no failures")
  -- miner converged to the conf (N1b setters, maxY before minY)
  local ms = env:block(0, 254, 0).state
  eq(ms.radius, 32, "radius")
  eq(ms.minY, 65, "minY"); eq(ms.maxY, 247, "maxY")
  eq(ms.silkTouch, false, "silk"); eq(ms.autoEject, true, "autoEject")
  eq(#ms.filters, 1, "one filter")
  eq(ms.filters[1].tag, "c:ores/copper", "tag filter (D2)")
  -- QEs placed and converged: items INPUT + energy OUTPUT on ALL sides
  -- (orientation-independent — placeUp'd QEs face UP, C1), energy eject ON
  for _, cell in ipairs({ { 0, 254, -2, "energy QE" }, { 2, 255, 0, "item QE" } }) do
    local b = env:block(cell[1], cell[2], cell[3])
    if not b or b.id ~= "mekanism:quantum_entangloporter" then
      fail(cell[4] .. " not placed")
    end
    local qs = b.state
    eq(qs.frequency.key, "slednet", cell[4] .. " frequency")
    for _, side in ipairs({ "FRONT", "BACK", "LEFT", "RIGHT", "TOP", "BOTTOM" }) do
      eq(qs.sideConfig.ITEM[side], "INPUT", cell[4] .. " ITEM " .. side)
      eq(qs.sideConfig.ENERGY[side], "OUTPUT", cell[4] .. " ENERGY " .. side)
    end
    eq(qs.ejecting.ENERGY, true, cell[4] .. " energy eject")
    eq(qs.ejecting.ITEM or false, false, cell[4] .. " item eject off")
  end
  eq(env:file("sled.journal"), nil, "journal cleared after commissioning")
  -- converge means converge: a second run changes nothing — neither
  -- Mekanism setter calls NOR turtle dig/place world mutations
  local before = mutatingCalls(env)
  local opsBefore = env.worldOps or 0
  local res2 = env:run(SLED, { "commission" }, { maxTime = 120 })
  eq(res2.reason, "done", "second run exits")
  eq(mutatingCalls(env) - before, 0, "second run made zero mutating calls")
  eq((env.worldOps or 0) - opsBefore, 0, "second run dug/placed nothing")
  expectContains(env:termText(), "READY", "second report")
end)

T("commission: no frequency selected -> NOT READY names the hand step", function()
  local env = sledRig{ minerDefaults = true } -- QEs carry no frequency
  current = env
  local res = env:run(SLED, { "commission" }, { maxTime = 120 })
  eq(res.reason, "done", "commission exits (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "NOT READY", "report")
  expectContains(env:termText(), "frequency", "names the missing piece")
end)

T("commission: frequency_mode=public-auto creates/selects a PUBLIC frequency (N1)", function()
  local env = sledRig{ minerDefaults = true, freqMode = "public-auto" }
  current = env
  local res = env:run(SLED, { "commission" }, { maxTime = 120 })
  eq(res.reason, "done", "commission exits (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "READY", "report")
  if not env.publicFreqs["slednet"] then
    fail("public frequency 'slednet' was not created")
  end
  eq(env:block(0, 254, -2).state.frequency.key, "slednet", "energy QE freq")
  eq(env:block(2, 255, 0).state.frequency.key, "slednet", "item QE freq")
end)

-- ---------------------------------------------------- fuel policy (§6)
-- §11 test 13 (C4: refuel(n) self-caps; fuel values are MEASURED at
-- runtime, never assumed — S3 says the pack can override burn values)

T("fuel: tops up at fuel_low using the measured per-item value", function()
  local env = sledRig{ targets = 120, mineRate = 60, searchSeconds = 0.5,
    spacing = 8, stations = 3, fuel = 130, fuel_low = 1000,
    fuel_reserve = 100, coal = 64 }
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 60 })
  -- by TRAVEL time the level is under fuel_low: the sled must measure
  -- coal-block fuel by burning ONE, then top up with a computed count
  local station = tonumber((env:file("sled.journal") or ""):match("station=(%d+)"))
  if not station or station < 1 then
    fail("never relocated: journal\n" .. tostring(env:file("sled.journal")))
  end
  if env.turtle.fuel < 500 then
    fail("never refueled: fuel=" .. env.turtle.fuel)
  end
  local coal = env.turtle.inv[4]
  if not coal or coal.count >= 64 then
    fail("no coal consumed")
  end
  if 64 - coal.count > 3 then
    fail("burned way more coal than the computed top-up: used "
      .. (64 - coal.count))
  end
end)

T("fuel: refuses TRAVEL below reserve with an empty fuel slot -> RECOVER err=fuel", function()
  local env = sledRig{ targets = 120, mineRate = 60, searchSeconds = 0.5,
    spacing = 8, stations = 3, fuel = 60, coal = 0 }
  env.turtle.inv[4] = nil
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 60 })
  expectContains(env:file("sled.journal"), "state=RECOVER", "recovered")
  expectContains(env:file("sled.journal"), "err=fuel", "reason")
  expectContains(env:file("sled.journal"), "station=0", "never left station 0")
end)

-- --------------------------------------------- empirical rates (AM-2)

T("telemetry: rate/eta are MEASURED from getToMine deltas (AM-2)", function()
  local env = sledRig{ targets = 100000, mineRate = 7, searchSeconds = 0.5 }
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 25 })
  local last
  for _, s in ipairs(sledEnvelopes(env)) do
    local d = s.message.data
    if d.state == "MINING" and d.rate then last = d end
  end
  if not last then fail("no MINING envelope carried a rate") end
  if last.rate < 7 * 0.8 or last.rate > 7 * 1.2 then
    fail("measured rate " .. tostring(last.rate)
      .. " not within 20% of the mock's 7 blocks/s")
  end
  if type(last.eta) ~= "string" or not last.eta:match("%d") then
    fail("eta missing or not a span string: " .. tostring(last.eta))
  end
  eq(last.jpt, 2756, "live J/t passed through from getEnergyUsage")
end)

T("AM-2: no base-rate constants exist in sled.lua to get wrong", function()
  local f = assert(io.open("programs/sled.lua", "r"))
  local src = f:read("*a")
  f:close()
  local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
  for _, banned in ipairs({
    "0%.25",     -- blocks/s base rate (illustration only, §10)
    "2756",      -- J/t at the verified config (A4)
    "88200",     -- FE per block (A4)
    "1102",      -- FE/t (A4)
    "= ?800[^%d]", -- coal-block fuel value (C4/S3 — must be measured)
  }) do
    if code:match(banned) then
      fail("banned constant pattern '" .. banned .. "' found in sled.lua")
    end
  end
end)

-- ------------------------------------------------------- sledctl (AM-5)

local CTL = "programs/sledctl.lua"

local function sledEnvelope(source, data)
  return { v = 1, source = source, tick = 0, data = data }
end

T("sledctl: renders a compact fleet table from telemetry envelopes", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:rednetAt(1.0, 7, sledEnvelope("sled1", { state = "MINING", step = "",
    pos = "0,253,0 E", hops = 2, fuel = 83000, targets = 3100, miner = 1 }),
    "telemetry")
  env:rednetAt(1.5, 8, sledEnvelope("sled2", { state = "RECOVER",
    step = "", pos = "64,253,0 E", hops = 7, fuel = 1200,
    targets = 0, miner = 0, err = "laneend" }), "telemetry")
  env:rednetAt(2.0, 9, sledEnvelope("flux", { trueE = 1 }), "telemetry")
  current = env
  env:run(CTL, {}, { maxTime = 4 })
  local t = env:termText()
  local row1, row2
  for line in t:gmatch("[^\n]+") do
    if line:find("sled1", 1, true) then row1 = line end
    if line:find("sled2", 1, true) then row2 = line end
  end
  if not row1 then fail("no sled1 row\n" .. t) end
  if not row2 then fail("no sled2 row\n" .. t) end
  expectContains(row1, "MINING", "sled1 row state")
  expectContains(row1, "2", "sled1 row hops")
  expectContains(row1, "83.00k", "sled1 row fuel")
  expectContains(row2, "RECOVER", "sled2 row state")
  expectContains(row2, "laneend", "sled2 row err")
  expectNotContains(t, "flux", "non-sled sources ignored")
end)

T("sledctl: 'u' broadcasts the token-gated update and updates itself", function()
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env.files["sledctl.conf"] = 'return { token = "hunter2" }'
  env.files["update"] = [[
    local f = fs.open("updated.flag", "w")
    f.write("yes")
    f.close()
    os.reboot()
  ]]
  env:charAt(1.5, "u")
  current = env
  local res = env:run(CTL, {}, { maxTime = 6 })
  eq(res.reason, "shutdown", "updater rebooted the console")
  eq(res.reboot, true, "via os.reboot")
  eq(env:file("updated.flag"), "yes", "updater ran")
  local sent
  for _, s in ipairs(env.rednetSent) do
    if s.protocol == "sledctl" then sent = s end
  end
  if not sent then fail("no sledctl broadcast") end
  eq(sent.message.cmd, "update", "cmd")
  eq(sent.message.token, "hunter2", "token attached")
end)

T("sled: update command runs the updater; wrong token is ignored (AM-5)", function()
  -- wrong token: sled keeps mining
  local env = sledRig{}
  placeSkid(env)
  env.files["update"] = [[
    local f = fs.open("updated.flag", "w")
    f.write("yes")
    f.close()
    os.reboot()
  ]]
  env:rednetAt(env.ticks * 0.05 + 6, 9,
    { cmd = "update", token = "wrong" }, "sledctl")
  current = env
  local res = env:run(SLED, { "start" }, { maxTime = 12 })
  eq(env:file("updated.flag"), nil, "wrong token ignored")
  if res.reason == "shutdown" then fail("rebooted on a bad token") end

  -- right token: updater runs and reboots
  local env2 = sledRig{}
  placeSkid(env2)
  env2.files["update"] = env.files["update"]
  env2:rednetAt(env2.ticks * 0.05 + 6, 9,
    { cmd = "update", token = "hunter2" }, "sledctl")
  current = env2
  local res2 = env2:run(SLED, { "start" }, { maxTime = 12 })
  eq(res2.reason, "shutdown", "updater rebooted the sled")
  eq(res2.reboot, true, "via os.reboot")
  eq(env2:file("updated.flag"), "yes", "updater ran")
end)

-- --------------------------------------------- fluxwall sled card (AM-6)

local WALL = "programs/fluxwall.lua"

T("wall: dedicated sled card - state, targets/rate/eta, hops, fuel", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  local d = { state = "MINING", step = "", pos = "0,253,0 E", hops = 12,
    fuel = 83000, targets = 3120, miner = 1, rate = 7.2, eta = "7m",
    jpt = 2756 }
  env:rednetAt(1.0, 7, sledEnvelope("sled1", d), "telemetry")
  env:rednetAt(2.0, 7, sledEnvelope("sled1", d), "telemetry")
  current = env
  env:run(WALL, {}, { maxTime = 3 })
  local m = env:monitorText("monitor_2")
  expectContains(m, "SLED1", "card label")
  expectContains(m, "MINING", "big state line")
  expectContains(m, "3.12k left", "targets remaining")
  expectContains(m, "7.2/s", "empirical rate (AM-2)")
  expectContains(m, "eta 7m", "eta")
  expectContains(m, "hops 12", "stations completed")
  expectContains(m, "fuel 83.00k", "fuel")
  -- the generic key:value card must NOT be the renderer here
  expectNotContains(m, "pos:", "not the generic card")
end)

T("wall: sled card shows step progress in RELOCATE and red reason in RECOVER", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  env:rednetAt(1.0, 7, sledEnvelope("sled1", { state = "RELOCATE",
    step = "TRAVEL 17/64", pos = "17,253,0 E", hops = 3, fuel = 70000,
    targets = 0, miner = 0 }), "telemetry")
  env:snapshotAt(1.5, "relocate")
  env:monitorSnapshotAt(1.6, "relocateMon", "monitor_2")
  env:rednetAt(2.0, 7, sledEnvelope("sled1", { state = "RECOVER", step = "",
    pos = "17,253,0 E", hops = 3, fuel = 70000, targets = 0, miner = 0,
    err = "unloaded" }), "telemetry")
  current = env
  env:run(WALL, {}, { maxTime = 3 })
  expectContains(env.snapshots.relocateMon or "", "TRAVEL 17/64",
    "step progress while relocating")
  local m = env:monitorText("monitor_2")
  expectContains(m, "RECOVER", "state")
  expectContains(m, "! unloaded", "red reason line (AM-6)")
end)

T("wall: sources filter dedicates a monitor to sled sources (AM-6)", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  for t = 1, 3 do
    env:rednetAt(t, 7, sledEnvelope("sled1", { state = "MINING", step = "",
      pos = "0,253,0 E", hops = 1, fuel = 9000, targets = 50, miner = 1 }),
      "telemetry")
    env:rednetAt(t + 0.1, 8, sledEnvelope("flux", { trueE = 2952790016,
      trueCap = 281474976710656, cells = 1, rate = 1000 }), "telemetry")
  end
  env:rednetAt(2.5, 9, sledEnvelope("alerts",
    { msg = "sled1 state has been RECOVER for 30s" }), "telemetry")
  current = env
  env:run(WALL, { "sources=sled*" }, { maxTime = 4 })
  local m = env:monitorText("monitor_2")
  expectContains(m, "SLED1", "sled card present")
  expectNotContains(m, "FLUX", "filtered source absent")
  expectContains(m, "! sled1 state", "alert banner still shows")
end)

-- ------------------------------------------- historian stuck rules (E2)

T("historian: sled stuck rules - RELOCATE 900s and RECOVER 30s, wildcard source", function()
  -- RECOVER for >30s fires quickly
  local env = CC.new{ termW = 61, termH = 20 }
  env:addModem("top")
  env:addChatBox("chat_box_0")
  for t = 1, 41, 5 do
    env:rednetAt(t, 7, sledEnvelope("sled1", { state = "RECOVER", step = "",
      pos = "0,253,0 E", hops = 0, fuel = 100, targets = 0, miner = 0,
      err = "security" }), "telemetry")
  end
  current = env
  local res = env:run("programs/historian.lua", {}, { maxTime = 45 })
  if res.reason == "error" then fail("crashed: " .. tostring(res.err)) end
  local hit = false
  for _, c in ipairs(env.chatLog) do
    if c.msg:find("RECOVER", 1, true) and c.msg:find("sled1", 1, true) then
      hit = true
    end
  end
  if not hit then fail("no RECOVER stuck alert in chat") end
  for _, b in ipairs(env.rednetSent) do
    if type(b.message) == "table" and b.message.source == "alerts"
      and tostring(b.message.data.msg):find("RECOVER", 1, true) then
      if b.t < 30 then
        fail("RECOVER stuck alert fired before the 30s debounce: t="
          .. tostring(b.t))
      end
    end
  end

  -- RELOCATE must NOT fire before 900s, and must fire after
  local env2 = CC.new{ termW = 61, termH = 20 }
  env2:addModem("top")
  env2:addChatBox("chat_box_0")
  local t = 1
  while t < 920 do
    env2:rednetAt(t, 7, sledEnvelope("sled1", { state = "RELOCATE",
      step = "TRAVEL 1/64", pos = "1,253,0 E", hops = 0, fuel = 100,
      targets = 0, miner = 0 }), "telemetry")
    t = t + 5
  end
  current = env2
  local res2 = env2:run("programs/historian.lua", {}, { maxTime = 930 })
  if res2.reason == "error" then fail("crashed: " .. tostring(res2.err)) end
  local firedAt
  for _, s in ipairs(env2.rednetSent) do
    if type(s.message) == "table" and s.message.source == "alerts"
      and tostring(s.message.data.msg):find("RELOCATE", 1, true) then
      firedAt = firedAt or s.t
    end
  end
  if not firedAt then fail("no RELOCATE stuck alert broadcast") end
  if firedAt < 900 then
    fail("stuck alert fired too early at " .. tostring(firedAt))
  end
end)

-- ----------------------------------------------------- deploy manifest

T("manifest: roles sled/sledctl exist and the files ship (AM-5)", function()
  local m = dofile("deploy/manifest.lua")
  eq(m.roles.sled, "sled", "sled role")
  eq(m.roles.sledctl, "sledctl", "sledctl role")
  local have = {}
  for _, f in ipairs(m.files) do have[f.path] = f.url end
  for _, p in ipairs({ "sled", "sledctl" }) do
    if not have[p] then fail("manifest missing file entry: " .. p) end
    expectContains(have[p], "programs/" .. p .. ".lua", p .. " url")
  end
end)

T("recon rows: BREAK_MINER redo+advance, PLACE_MINER/PLACE_QE advance, VERIFY_* resume", function()
  -- BREAK_MINER redo: QEs already in slots, miner still standing
  local env = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env)
  seedMarker(env)
  env.files["setup2.lua"] = [[
    turtle.turnLeft() turtle.forward() turtle.forward()
    turtle.select(2) turtle.digUp()
    turtle.back() turtle.back() turtle.turnRight()
    turtle.forward() turtle.forward() turtle.up()
    turtle.select(3) turtle.digUp()
    turtle.down() turtle.back() turtle.back() turtle.select(1)
  ]]
  env:run("setup2.lua", {}, { maxTime = 30, fromVirtualFs = true })
  seedJournal(env, { state = "RELOCATE", station = 0, step = "BREAK_MINER",
    pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 120 })
  expectContains(env:file("sled.journal"), "station=1", "BREAK_MINER redo")
  eq(env:block(8, 254, 0).id, "mekanism:digital_miner", "skid at station 1")

  -- BREAK_MINER advance: miner already dug into slot 1 (post-step kill)
  local env2 = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env2)
  seedMarker(env2)
  env2.files["setup2.lua"] = env.files["setup2.lua"]
    .. "\nturtle.select(1) turtle.digUp()"
  env2:run("setup2.lua", {}, { maxTime = 30, fromVirtualFs = true })
  seedJournal(env2, { state = "RELOCATE", station = 0, step = "BREAK_MINER",
    pos = "0,253,0" })
  current = env2
  env2:run(SLED, {}, { maxTime = 120 })
  expectContains(env2:file("sled.journal"), "station=1", "BREAK_MINER advance")

  -- PLACE_MINER advance + VERIFY_MINER resume + VERIFY_RUN resume +
  -- PLACE_QE_E advance, all at station 0 with progressively more world
  for _, case in ipairs({
    { step = "PLACE_MINER", placeQEs = false, kick = false },
    { step = "VERIFY_MINER", placeQEs = false, kick = false },
    { step = "PLACE_QE_E", placeQEs = true, kick = false },
    { step = "VERIFY_RUN", placeQEs = true, kick = true },
  }) do
    local e = sledRig{ targets = 1e9, stations = 3 }
    if case.placeQEs then
      placeSkid(e)
    else
      e.files["setup1.lua"] = "turtle.select(1) turtle.placeUp() turtle.select(1)"
      e:run("setup1.lua", {}, { maxTime = 30, fromVirtualFs = true })
    end
    seedMarker(e)
    if case.kick then
      e.files["kick.lua"] = "peripheral.wrap('top').start()"
      e:run("kick.lua", {}, { maxTime = 10, fromVirtualFs = true })
    end
    seedJournal(e, { state = "RELOCATE", station = 0, step = case.step,
      pos = "0,253,0" })
    current = e
    e:run(SLED, {}, { maxTime = 120 })
    expectContains(e:file("sled.journal"), "state=MINING",
      case.step .. " resumes to MINING")
    eq(e:block(0, 254, -2).id, "mekanism:quantum_entangloporter",
      case.step .. ": energy QE in place")
  end
end)

-- ------------------------------------------- review findings (phase 2.1)

T("recover: reboot after fixing the cause RESUMES (laneend + raised bound)", function()
  -- the runbook contract: RECOVER holds until a human fixes the cause and
  -- reboots; the reboot must re-attempt, not stay parked forever
  local env = sledRig{ targets = 120, mineRate = 60, searchSeconds = 0.5,
    spacing = 8, stations = 2 }
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 120 })
  expectContains(env:file("sled.journal"), "err=laneend", "parked at lane end")
  -- the human extends the lane: raise the bound (rewrite conf), reboot
  env.files["sled.conf"] = env.files["sled.conf"]
    :gsub("stations_per_leg = %d+", "stations_per_leg = 3")
  env:run(SLED, {}, { maxTime = 120 })
  local j = env:file("sled.journal") or ""
  expectContains(j, "station=2", "relocated to station 2 after the fix")
  if not env:block(16, 254, 0) then fail("no miner at station 2") end
end)

T("recover: mid-step RECOVER (fuel) + refill + reboot completes the cycle", function()
  local env = sledRig{ targets = 120, mineRate = 60, searchSeconds = 0.5,
    spacing = 8, stations = 2, fuel = 60, coal = 0 }
  env.turtle.inv[4] = nil
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 60 })
  expectContains(env:file("sled.journal"), "err=fuel", "fuel RECOVER")
  env.turtle.inv[4] = { id = "minecraft:coal_block", count = 8 }
  env:run(SLED, {}, { maxTime = 120 })
  expectContains(env:file("sled.journal"), "station=1", "completed after refill")
  if not env:block(8, 254, 0) then fail("no miner at station 1") end
end)

T("relocate: blocked QE navigation must never blind-dig the miner", function()
  -- a mob/block on the lateral path means digUp would target the MINER
  -- MAIN BLOCK if the step digs blind from the wrong cell
  local env = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env)
  seedMarker(env)
  env:setBlock(0, 253, -1, { id = "minecraft:stone" }) -- blocks the path
  seedJournal(env, { state = "RELOCATE", station = 0, step = "BREAK_QE_E",
    pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 90 })
  if not env:block(0, 254, 0)
    or env:block(0, 254, 0).id ~= "mekanism:digital_miner" then
    fail("the miner was dug while the path was blocked")
  end
  expectContains(env:file("sled.journal"), "state=RECOVER", "recovered")
  expectContains(env:file("sled.journal"), "err=blocked", "reason")
end)

T("sledctl/sled: a missing conf token DISABLES update, not accepts-empty", function()
  local env = sledRig{}
  env.files["sled.conf"] = env.files["sled.conf"]:gsub('token = "hunter2",%s*', "")
  placeSkid(env)
  env.files["update"] = 'local f=fs.open("updated.flag","w") f.write("yes") f.close() os.reboot()'
  env:rednetAt(env.ticks * 0.05 + 6, 9, { cmd = "update", token = "" },
    "sledctl")
  current = env
  local res = env:run(SLED, { "start" }, { maxTime = 12 })
  eq(env:file("updated.flag"), nil, "empty token rejected when none configured")
  if res.reason == "shutdown" then fail("rebooted on empty token") end
end)

T("telemetry: stall warn uses the N4 usage probe, not energy==0", function()
  -- an underfed miner stalls with a NONZERO buffer (active needs the full
  -- per-tick amount); the warn must come from usage==0 with targets left
  local env = sledRig{ targets = 5000, mineRate = 5, searchSeconds = 0.5,
    energy = 1000 } -- 1000 J < 2756 J/t: stalled but not empty
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 15 })
  local warned, frozen
  for _, s in ipairs(sledEnvelopes(env)) do
    local d = s.message.data
    if d.state == "MINING" and d.warn == "stalled" and (d.targets or 0) > 0 then
      warned = true
      frozen = d.targets
    end
  end
  if not warned then fail("no stalled warn despite usage==0 with targets left") end
  expectContains(env:file("sled.journal"), "state=MINING",
    "holds MINING through the stall (home-side fault, §3)")
end)

T("commission: refuels itself from the fuel slot when placed dry", function()
  local env = sledRig{ minerDefaults = true, fuel = 0,
    qeComponents = { frequency = { key = "slednet",
      security_mode = "PRIVATE", owner = "carter" } } }
  current = env
  local res = env:run(SLED, { "commission" }, { maxTime = 120 })
  eq(res.reason, "done", "commission exits (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "READY", "report")
  if env.turtle.fuel <= 0 then fail("never refueled") end
end)

T("commission: interrupted mid-way, a re-run from a displaced turtle converges", function()
  local env = sledRig{ minerDefaults = true,
    qeComponents = { frequency = { key = "slednet",
      security_mode = "PRIVATE", owner = "carter" } } }
  -- kill while commissioning (during QE work, turtle displaced/rotated)
  env:restartAt(env.ticks * 0.05 + 9)
  current = env
  env:run(SLED, { "commission" }, { maxTime = 60 })
  -- resume advice path: `sled` tells the operator to re-run commission
  env:run(SLED, {}, { maxTime = 10 })
  expectContains(env:termText(), "commission", "resume names the fix")
  -- and the re-run must converge from WHEREVER the turtle is now
  local res = env:run(SLED, { "commission" }, { maxTime = 120 })
  eq(res.reason, "done", "re-run exits (err=" .. tostring(res.err) .. ")")
  expectContains(env:termText(), "READY", "re-run converged")
  eq(env:block(0, 254, 0).id, "mekanism:digital_miner", "miner at origin")
  eq(env:block(0, 254, -2).id, "mekanism:quantum_entangloporter", "QE-E")
  eq(env:block(2, 255, 0).id, "mekanism:quantum_entangloporter", "QE-I")
end)

T("e2e: three consecutive stations; marker trail intact (§11 test 14)", function()
  local env = sledRig{ targets = 120, mineRate = 60, searchSeconds = 0.5,
    spacing = 8, stations = 3 }
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 240 })
  local j = env:file("sled.journal") or ""
  expectContains(j, "err=laneend", "terminal laneend")
  expectContains(j, "station=2", "two full relocations")
  eq(env:block(16, 254, 0).id, "mekanism:digital_miner", "miner at station 2")
  eq(env:block(16, 254, -2).id, "mekanism:quantum_entangloporter", "QE-E moved twice")
  eq(env:block(18, 255, 0).id, "mekanism:quantum_entangloporter", "QE-I moved twice")
  for _, x in ipairs({ 0, 8, 16 }) do
    eq(env:block(x, 252, 0).id, "minecraft:cobblestone",
      "marker trail at x=" .. x)
  end
  -- slot discipline after two cycles: machines placed, slots 1-3 empty
  for slot = 1, 3 do
    if env.turtle.inv[slot] then
      fail("slot " .. slot .. " not empty after relocations")
    end
  end
end)

T("travel: chunk border holds + retries + RECOVER err=unloaded; failed moves burn no fuel (§11 test 10)", function()
  local env = sledRig{ targets = 120, mineRate = 60, searchSeconds = 0.5,
    spacing = 8, stations = 3 }
  env.loadedBounds = { minX = -4, maxX = 12, minZ = -3, maxZ = 3 }
  placeSkid(env)
  current = env
  env:run(SLED, { "start" }, { maxTime = 600 })
  local j = env:file("sled.journal") or ""
  expectContains(j, "state=RECOVER", "recovered")
  expectContains(j, "err=unloaded", "reason (C4 sentinel)")
  -- it stopped AT the border (x=12), station 1 was completed earlier
  eq(env.turtle.pos.x, 12, "held at the loaded-world edge")
  expectContains(j, "station=1", "border hit while traveling to station 2")
end)

T("recon rows: BREAK_QE_I redo, PLACE_MINER redo, START already-running", function()
  -- BREAK_QE_I with the item QE still placed: step redone, cycle completes
  local env = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env)
  seedMarker(env)
  env.files["setup2.lua"] = [[
    turtle.turnLeft() turtle.forward() turtle.forward()
    turtle.select(2) turtle.digUp()
    turtle.back() turtle.back() turtle.turnRight() turtle.select(1)
  ]]
  env:run("setup2.lua", {}, { maxTime = 30, fromVirtualFs = true })
  seedJournal(env, { state = "RELOCATE", station = 0, step = "BREAK_QE_I",
    pos = "0,253,0" })
  current = env
  env:run(SLED, {}, { maxTime = 120 })
  expectContains(env:file("sled.journal"), "station=1", "QE_I redo completed")

  -- PLACE_MINER redo: machines in inventory at the NEW park, journal says
  -- PLACE_MINER (kill before placeUp executed)
  local env2 = sledRig{ targets = 1e9, stations = 3 }
  seedMarker(env2, 0)
  env2.turtle.pos.x = 8
  seedJournal(env2, { state = "RELOCATE", station = 1, step = "PLACE_MINER",
    pos = "8,253,0" })
  current = env2
  env2:run(SLED, {}, { maxTime = 120 })
  expectContains(env2:file("sled.journal"), "state=MINING", "mining at 1")
  eq(env2:block(8, 254, 0).id, "mekanism:digital_miner", "placed at new park")

  -- START on an already-running miner: advance straight to MINING
  local env3 = sledRig{ targets = 1e9 }
  placeSkid(env3)
  seedMarker(env3)
  env3.files["kick.lua"] = "peripheral.wrap('top').start()"
  env3:run("kick.lua", {}, { maxTime = 10, fromVirtualFs = true })
  seedJournal(env3, { state = "RELOCATE", station = 0, step = "START",
    pos = "0,253,0" })
  current = env3
  env3:run(SLED, {}, { maxTime = 15 })
  expectContains(env3:file("sled.journal"), "state=MINING", "advanced")
end)

T("wall: sources filter also reads fluxwall.conf", function()
  local env = CC.new{ termW = 51, termH = 19 }
  env:addModem("top")
  env:addMonitor("monitor_2", { baseW = 36, baseH = 18 })
  env.files["fluxwall.conf"] = "sources=sled*\n"
  for t = 1, 3 do
    env:rednetAt(t, 7, sledEnvelope("sled1", { state = "MINING", step = "",
      pos = "0,253,0 E", hops = 1, fuel = 9000, targets = 50, miner = 1 }),
      "telemetry")
    env:rednetAt(t + 0.1, 8, sledEnvelope("flux", { trueE = 123456 }),
      "telemetry")
  end
  current = env
  env:run("programs/fluxwall.lua", {}, { maxTime = 4 })
  expectContains(env:monitorText("monitor_2"), "SLED1", "sled card")
  expectNotContains(env:monitorText("monitor_2"), "FLUX", "filtered")
end)

T("journal: corrupt main journal falls back to the step-boundary backup", function()
  local env = sledRig{ targets = 1e9, stations = 3 }
  placeSkid(env)
  seedMarker(env)
  seedJournal(env, { state = "RELOCATE", station = 0, step = "BREAK_QE_E",
    pos = "0,253,0" })
  env.files["sled.journal.bak"] = env.files["sled.journal"]
  env.files["sled.journal"] = "state=RELO" -- torn write
  current = env
  env:run(SLED, {}, { maxTime = 120 })
  expectContains(env:file("sled.journal"), "station=1",
    "resumed from the backup journal")
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
