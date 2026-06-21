--[[
cc_env.lua - headless CC:Tweaked emulator harness (Lua 5.2)

Runs CC programs in a sandbox that mirrors how CC:Tweaked actually executes
them: the program is a coroutine; os.pullEventRaw is coroutine.yield; the
host resumes it with events, honouring the yield filter exactly like the
Java ComputerThread does (non-matching events are DISCARDED, "terminate"
always passes). Time is virtual and tracked in integer game ticks (1 tick =
0.05s) so runs are deterministic and instant.

write/print/sleep/os.pullEvent are adapted from CC:Tweaked's bios.lua
(MPL-2.0, vendored at vendor/CC-Tweaked) so word-wrapping and event
semantics match in-game behaviour.

Usage:
  local CC = dofile("harness/cc_env.lua")
  local env = CC.new{ termW = 51, termH = 19, advanced = true }
  env:addEnergyPeripheral("appflux:flux_accessor_0",
    { energy = 1e6, capacity = 8e6, ratePerSec = 50000 })
  env:addMonitor("monitor_5", { w = 39, h = 15 })
  env:charAt(2.2, "q")                  -- inject a keypress at t=2.2s
  local res = env:run("programs/fluxdash.lua", {}, { maxTime = 6 })
  print(env:termText(), env:monitorText("monitor_5"), res.reason)
]]

local TICK = 0.05
local INT_MAX = 2147483647

local unpack = table.unpack

-- ------------------------------------------------------------- world geometry

-- Minecraft horizontal convention: north=-z, south=+z, east=+x, west=-x
local FACES = {
  north = { x = 0, z = -1 }, south = { x = 0, z = 1 },
  east = { x = 1, z = 0 }, west = { x = -1, z = 0 },
}
local LEFT = { north = "west", west = "south", south = "east", east = "north" }
local RIGHT = { north = "east", east = "south", south = "west", west = "north" }
local OPP = { north = "south", south = "north", east = "west", west = "east",
  up = "down", down = "up" }
local DIRS6 = { "up", "down", "north", "south", "east", "west" }

local function keyOf(x, y, z) return x .. "," .. y .. "," .. z end

-- ------------------------------------------------------------------ colors

local COLOR_NAMES = {
  white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16,
  lime = 32, pink = 64, gray = 128, lightGray = 256, cyan = 512,
  purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384,
  black = 32768,
}

local GRAYSCALE = { [1] = true, [128] = true, [256] = true, [32768] = true }

local function makeColorsTable()
  local c = {}
  for k, v in pairs(COLOR_NAMES) do c[k] = v end
  c.grey, c.lightGrey = c.gray, c.lightGray
  return c
end

local BLIT_HEX = "0123456789abcdef"
local function colorToBlit(color)
  local n = math.floor(math.log(color) / math.log(2) + 0.5)
  return BLIT_HEX:sub(n + 1, n + 1)
end

local function validColor(c)
  if type(c) ~= "number" then return false end
  for i = 0, 15 do if c == 2 ^ i then return true end end
  return false
end

-- ------------------------------------------------------------ term buffers

-- A virtual screen. Returns the buffer record plus a table of CC term API
-- closures (so it can be wrapped as a monitor peripheral or used as the
-- native terminal). Cell colors are tracked in blit format for assertions.
-- buf.resize(w, h) re-blanks the grid (used by scale-aware monitors).
local function newScreen(w, h, isColor, strictColors, label)
  local buf = {
    w = w, h = h, x = 1, y = 1,
    fg = COLOR_NAMES.white, bg = COLOR_NAMES.black,
    blink = false, label = label or "screen",
    text = {}, fgmap = {}, bgmap = {},
  }
  local blank, blankColors
  function buf.resize(nw, nh)
    buf.w, buf.h = nw, nh
    blank = (" "):rep(nw)
    blankColors = function(c) return colorToBlit(c):rep(nw) end
    buf.text, buf.fgmap, buf.bgmap = {}, {}, {}
    for i = 1, nh do
      buf.text[i] = blank
      buf.fgmap[i] = blankColors(buf.fg)
      buf.bgmap[i] = blankColors(buf.bg)
    end
  end
  buf.resize(w, h)

  local function setColor(which, c)
    if not validColor(c) then
      error("bad argument (color expected)", 3)
    end
    if strictColors and not isColor and not GRAYSCALE[c] then
      error("Colour not supported", 3)
    end
    buf[which] = c
  end

  local function put(line, x, str, fgs, bgs)
    if line < 1 or line > buf.h or #str == 0 then return end
    local from = math.max(1, x)
    local to = math.min(buf.w, x + #str - 1)
    if to < from then return end
    local s, e = from - x + 1, to - x + 1
    buf.text[line] = buf.text[line]:sub(1, from - 1)
      .. str:sub(s, e) .. buf.text[line]:sub(to + 1)
    buf.fgmap[line] = buf.fgmap[line]:sub(1, from - 1)
      .. fgs:sub(s, e) .. buf.fgmap[line]:sub(to + 1)
    buf.bgmap[line] = buf.bgmap[line]:sub(1, from - 1)
      .. bgs:sub(s, e) .. buf.bgmap[line]:sub(to + 1)
  end

  local t = {}
  function t.write(text)
    if type(text) == "number" then text = tostring(text) end
    if type(text) ~= "string" then
      error("bad argument #1 (string expected, got " .. type(text) .. ")", 2)
    end
    text = text:gsub("[\r\n\t]", " ")
    put(buf.y, buf.x, text,
      colorToBlit(buf.fg):rep(#text), colorToBlit(buf.bg):rep(#text))
    buf.x = buf.x + #text
  end
  function t.blit(text, fgs, bgs)
    if #text ~= #fgs or #text ~= #bgs then
      error("Arguments must be the same length", 2)
    end
    put(buf.y, buf.x, text, fgs, bgs)
    buf.x = buf.x + #text
  end
  function t.clear()
    for i = 1, buf.h do
      buf.text[i] = blank
      buf.fgmap[i] = blankColors(buf.fg)
      buf.bgmap[i] = blankColors(buf.bg)
    end
  end
  function t.clearLine()
    if buf.y >= 1 and buf.y <= buf.h then
      buf.text[buf.y] = blank
      buf.fgmap[buf.y] = blankColors(buf.fg)
      buf.bgmap[buf.y] = blankColors(buf.bg)
    end
  end
  function t.getCursorPos() return buf.x, buf.y end
  function t.setCursorPos(x, y)
    buf.x, buf.y = math.floor(x), math.floor(y)
  end
  function t.setCursorBlink(b) buf.blink = b end
  function t.getCursorBlink() return buf.blink end
  function t.getSize() return buf.w, buf.h end
  function t.scroll(n)
    n = math.floor(n)
    local text, fgmap, bgmap = {}, {}, {}
    for i = 1, buf.h do
      local src = i + n
      if src >= 1 and src <= buf.h then
        text[i], fgmap[i], bgmap[i] = buf.text[src], buf.fgmap[src], buf.bgmap[src]
      else
        text[i], fgmap[i], bgmap[i] =
          blank, blankColors(buf.fg), blankColors(buf.bg)
      end
    end
    buf.text, buf.fgmap, buf.bgmap = text, fgmap, bgmap
  end
  function t.isColor() return isColor end
  function t.setTextColor(c) setColor("fg", c) end
  function t.getTextColor() return buf.fg end
  function t.setBackgroundColor(c) setColor("bg", c) end
  function t.getBackgroundColor() return buf.bg end
  -- British aliases, same functions (CC exposes both spellings)
  t.isColour, t.setTextColour, t.getTextColour = t.isColor, t.setTextColor, t.getTextColor
  t.setBackgroundColour, t.getBackgroundColour = t.setBackgroundColor, t.getBackgroundColor

  return buf, t
end

local function screenText(buf)
  local lines, last = {}, 0
  for i = 1, buf.h do
    lines[i] = buf.text[i]:gsub("%s+$", "")
    if #lines[i] > 0 then last = i end
  end
  return table.concat(lines, "\n", 1, math.max(last, 1))
end

-- ----------------------------------------------------------------- env

local Env = {}
Env.__index = Env

local M = {}

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Env)
  self.ticks = 0
  self.queue = {}            -- FIFO of pending event tuples
  self.timers = {}           -- id -> fire tick
  self.nextTimer = 1
  self.scheduled = {}        -- {atTick, seq, ev=|fn=}
  self.seq = 0
  self.periph = {}           -- name -> entry
  self.periphOrder = {}
  self.files = {}            -- path -> contents (in-memory fs)
  self.snapshots = {}
  self.rednetSent = {}       -- log of rednet.broadcast/send calls
  self.rednetOpen = {}       -- side -> true
  self.httpFiles = {}        -- url -> body served by the http mock
  self.chatLog = {}          -- messages sent through a chat_box
  self.publicFreqs = {}      -- PUBLIC inventory-frequency manager (B1/N1)
  self.mockCalls = {}        -- log of Mekanism-mock method calls
  self.advanced = opts.advanced ~= false
  self.strictColors = opts.strictColors or false
  -- exact string confirmed in-game on Carter's ATM10 v7.0 server
  self.host = opts.host or "ComputerCraft 1.117.1 (Minecraft 1.21.1)"
  local buf, t = newScreen(opts.termW or 51, opts.termH or 19,
    self.advanced, self.strictColors, "terminal")
  self.termBuf, self.termApi = buf, t
  self.monitors = {}         -- name -> buf (for assertions)

  -- voxel world + turtle (Project Sled harness extension; SLED-DESIGN §11)
  self.world = {}            -- "x,y,z" -> block table { id = ..., ... }
  self.ground = {}           -- "x,y,z" -> list of dropped item stacks
  if opts.turtle then
    local o = opts.turtle
    self.turtle = {
      pos = { x = o.pos.x, y = o.pos.y, z = o.pos.z },
      facing = o.facing or "north",
      fuel = o.fuel or 0,
      -- advanced turtle default: limit 100,000 (C4, pack
      -- computercraft-server.toml:200-210)
      limit = o.limit or 100000,
      inv = o.inv or {},     -- slot -> { id, count, components }
      sel = 1,
    }
    self.loadedBounds = opts.loadedBounds -- {minX,maxX,minZ,maxZ} or nil
    self.sideAttach = {}     -- side name -> peripheral entry (or nil)
  end
  return self
end

function Env:setBlock(x, y, z, block)
  self.world[keyOf(x, y, z)] = block
end

function Env:block(x, y, z)
  return self.world[keyOf(x, y, z)]
end

-- --------------------------------------------- side-attached peripherals

local function mkPeriphEntry(name, types, methods)
  local typeSet = {}
  for _, ty in ipairs(types) do typeSet[ty] = true end
  return { name = name, types = types, typeSet = typeSet,
    methods = methods, attached = true }
end

-- Which peripheral entry (if any) a turtle side currently touches. A block
-- exposes its peripheral per absolute face via block.facePeriph — the
-- miner mock uses this for its port geometry (A4); plain machine blocks
-- expose all six faces.
local SIDE_NAMES = { "top", "bottom", "front", "back", "left", "right" }

function Env:computeSidePeriph(side)
  local t = self.turtle
  if not t then return nil end
  local p, dx, dy, dz, face = t.pos, 0, 0, 0, nil
  if side == "top" then dy, face = 1, "down"
  elseif side == "bottom" then dy, face = -1, "up"
  else
    local dir
    if side == "front" then dir = t.facing
    elseif side == "back" then dir = OPP[t.facing]
    elseif side == "left" then dir = LEFT[t.facing]
    elseif side == "right" then dir = RIGHT[t.facing] end
    dx, dz, face = FACES[dir].x, FACES[dir].z, OPP[dir]
  end
  local b = self.world[keyOf(p.x + dx, p.y + dy, p.z + dz)]
  return b and b.facePeriph and b.facePeriph[face] or nil
end

-- Re-resolve all six sides. Capability-cache refresh happens at the START
-- of the NEXT tick after a world change (C3 [SOURCE]) — so the deferred
-- flavor schedules the diff one tick out and a wrap immediately after
-- place/dig/move sees the OLD state. A turn runs updateInputsImmediately
-- (synchronous full rescan, C3) — immediate=true.
function Env:rescanSides(immediate)
  if not self.turtle then return end
  local env = self
  local function apply()
    for _, side in ipairs(SIDE_NAMES) do
      local want = env:computeSidePeriph(side)
      local have = env.sideAttach[side]
      if want ~= have then
        if have then env:push("peripheral_detach", side) end
        env.sideAttach[side] = want
        if want then env:push("peripheral", side) end
      end
    end
  end
  if immediate then
    apply()
  else
    self.seq = self.seq + 1
    self.scheduled[#self.scheduled + 1] =
      { atTick = self.ticks + 1, seq = self.seq, fn = apply }
  end
end

-- Generic single-block machine item: placing it builds a block exposing a
-- peripheral on every face, tile state initialized from the item's
-- components (A2 applyImplicitComponents); digging returns a fresh item
-- carrying the tile state back as components (A2 copy_components loot).
-- o.makeMethods(state, env) builds the method table over the tile state.
function Env:machineItem(o)
  local env = self
  local function makeBlock(stack, x, y, z, placeDir)
    local state = {}
    for k, v in pairs(stack.components or {}) do state[k] = v end
    local methods = o.makeMethods and o.makeMethods(state, env) or o.methods
    local entry = mkPeriphEntry(o.id, o.types, methods)
    local faceP = {}
    for _, f in ipairs(DIRS6) do faceP[f] = entry end
    env.world[keyOf(x, y, z)] = {
      id = o.id, state = state, facePeriph = faceP,
      onDig = function()
        env.world[keyOf(x, y, z)] = nil
        local comps = {}
        for k, v in pairs(state) do comps[k] = v end
        return { id = o.id, count = 1, components = comps,
          makeBlock = makeBlock }
      end,
    }
    return true
  end
  return { id = o.id, count = 1, components = o.components or {},
    makeBlock = makeBlock }
end

-- ----------------------------------------------------- scheduling helpers

local function toTicks(seconds)
  return math.floor(seconds / TICK + 0.5)
end

function Env:push(...)
  self.queue[#self.queue + 1] = table.pack(...)
end

function Env:scheduleAt(seconds, item)
  self.seq = self.seq + 1
  item.atTick = toTicks(seconds)
  item.seq = self.seq
  self.scheduled[#self.scheduled + 1] = item
end

function Env:charAt(seconds, ch)
  self:scheduleAt(seconds, { ev = { "char", ch } })
end

function Env:keyAt(seconds, code)
  self:scheduleAt(seconds, { ev = { "key", code, false } })
end

-- AP Chat Box "chat" event: a player typed in game. Params mirror Advanced
-- Peripherals: event, username, message, uuid, isHidden.
function Env:chatAt(seconds, username, message)
  self:scheduleAt(seconds, { ev = {
    "chat", username, message,
    "00000000-0000-0000-0000-000000000000", false } })
end

-- Advanced Monitor "monitor_touch" event: a player right-clicked the screen.
-- Params mirror CC: event, monitor name, x, y (character cells).
function Env:touchAt(seconds, name, x, y)
  self:scheduleAt(seconds, { ev = { "monitor_touch", name, x, y } })
end

function Env:terminateAt(seconds)
  self:scheduleAt(seconds, { ev = { "terminate" } })
end

function Env:detachAt(seconds, name)
  self:scheduleAt(seconds, { fn = function()
    local e = self.periph[name]
    if e then e.attached = false end
    self:push("peripheral_detach", name)
  end })
end

function Env:attachAt(seconds, name)
  self:scheduleAt(seconds, { fn = function()
    local e = self.periph[name]
    if e then e.attached = true end
    self:push("peripheral", name)
  end })
end

-- Force-end the run as if the server restarted / the chunk reloaded: the
-- Lua VM dies mid-whatever-it-was-doing (C4). An action in flight at that
-- moment never mutates the world — the C5 queued-but-dropped window.
function Env:restartAt(seconds)
  self:scheduleAt(seconds, { fn = function()
    self.abort = "reboot"
  end })
end

-- Same, flavored as a chunk unload: peripherals die with the computer.
function Env:chunkUnloadAt(seconds)
  self:scheduleAt(seconds, { fn = function()
    if self.sideAttach then
      for side in pairs(self.sideAttach) do self.sideAttach[side] = nil end
    end
    self.abort = "chunk_unload"
  end })
end

function Env:snapshotAt(seconds, key)
  self:scheduleAt(seconds, { fn = function()
    self.snapshots[key] = self:termText()
  end })
end

function Env:monitorSnapshotAt(seconds, key, name)
  self:scheduleAt(seconds, { fn = function()
    self.snapshots[key] = self:monitorText(name)
  end })
end

-- Deliver an incoming rednet message at t (the bios rednet daemon turns
-- modem traffic into "rednet_message" events; programs listen for those).
function Env:rednetAt(seconds, senderId, message, protocol)
  self:scheduleAt(seconds, { ev =
    { "rednet_message", senderId, message, protocol } })
end

function Env:addHttp(url, body)
  self.httpFiles[url] = body
end

-- ------------------------------------------------------------ peripherals

function Env:addPeripheral(name, types, methods)
  local typeSet = {}
  for _, ty in ipairs(types) do typeSet[ty] = true end
  local entry = {
    name = name, types = types, typeSet = typeSet,
    methods = methods, attached = true,
  }
  self.periph[name] = entry
  self.periphOrder[#self.periphOrder + 1] = name
  return entry
end

-- Generic FE peripheral, like a modded block seen through CC's generic
-- peripheral system. Energy evolves with virtual time; values are clamped
-- to Java int range exactly like the Forge Energy capability is.
function Env:addEnergyPeripheral(name, o)
  local ty = name:gsub("_%d+$", "")
  local env = self
  local function energyAt()
    local t = env.ticks * TICK
    local e = o.energy + (o.ratePerSec or 0) * t
    e = math.max(0, math.min(e, o.capacity))
    return math.floor(math.min(e, INT_MAX))
  end
  return self:addPeripheral(name, { ty, "energy_storage" }, {
    getEnergy = energyAt,
    getEnergyCapacity = function()
      return math.floor(math.min(o.capacity, INT_MAX))
    end,
  })
end

-- Advanced Peripherals 0.7.62b ME Bridge (verified against
-- vendor/AdvancedPeripherals .../MEBridgePeripheral.java): type "me_bridge",
-- energy methods return AE units (1 AE = 2 FE), usage/input are
-- per-tick rolling averages from AE2's energy service.
-- Put a stack into the turtle's inventory (first matching/empty slot), as when
-- an ME Bridge adjacent to the turtle exports straight into it. Mirrors the
-- turtle's own giveItem consolidation.
function Env:giveToTurtle(stack)
  local t = self.turtle
  if not t or not t.inv then return false end
  for i = 1, 16 do
    local s = t.inv[i]
    if s and s.id == stack.id then s.count = s.count + stack.count; return true end
  end
  for i = 1, 16 do
    if not t.inv[i] then t.inv[i] = stack; return true end
  end
  return false
end

function Env:addMeBridge(name, o)
  local env = self
  -- Applied Mekanistics chemicals on the ME network. Shape verified against
  -- vendor/AdvancedPeripherals AEApi.listChemicals -> LuaConverter
  -- .chemicalStackToObject: each entry is { name="mekanism:oxygen",
  -- count=<mB long>, displayName="Oxygen", ... }. The amount field is `count`,
  -- a 64-bit long (NOT the 32-bit-clamped FE capability), so millions of mB
  -- pass through intact. o.chemicals = { {name=, displayName=, count=,
  -- ratePerSec=}, ... }; a chemical's ratePerSec (mB/s, may be negative for net
  -- consumption) evolves its count over virtual time so a sensor can measure a
  -- net rate of change. Counts clamp at >= 0 like a real buffer.
  local function chemicalsNow()
    local out = {}
    for _, c in ipairs(o.chemicals or {}) do
      local amt = c.count or 0
      if c.ratePerSec then amt = amt + c.ratePerSec * env.ticks * TICK end
      amt = math.floor(amt + 0.5)
      -- AE2 purges zero-quantity keys, so a depleted chemical is ABSENT from
      -- getChemicals(), not present with count 0 - mirror that here
      if amt > 0 then
        local copy = {}
        for k, v in pairs(c) do copy[k] = v end
        copy.ratePerSec = nil  -- not part of the AP return shape
        copy.count = amt
        out[#out + 1] = copy
      end
    end
    return out
  end
  -- Crafting / export surface (AP MEBridgePeripheral, FARM-RESEARCH Q2).
  -- o.items = list of stock STACKS { id, count, isCraftable, displayName,
  -- onUse?/makeBlock?/cropId?/... }; a stack may carry the same behavior hooks
  -- as a turtle inventory item, so a stack exported then sucked still tills /
  -- fertilizes / plants. getItem returns a name/count/isCraftable view;
  -- craftItem is ASYNC (schedules a stock bump after o.craftSeconds, then fires
  -- "ae_crafting"); exportItem moves stock to env.ground at o.exportCell so
  -- turtle.suck() collects it. All machine-sourced (no fake-player path).
  local items = o.items or {}
  -- A stack with nbtKeyed=true models a frequency/NBT-coded item (e.g. an
  -- EnderStorage ender chest White/White/White): a plain {name=} lookup MISSES
  -- it (AE keys it by fingerprint), so it is found only by {fingerprint=}. The
  -- builder must fall back to getItems()+fingerprint to pull such a block.
  local function findItem(filter)
    local byName, byFp
    if type(filter) == "table" then byName, byFp = filter.name, filter.fingerprint
    else byName = filter end
    for _, s in ipairs(items) do
      if byFp and (s.fingerprint or s.id) == byFp then return s end
      if byName and s.id == byName and not s.nbtKeyed then return s end
    end
    return nil
  end
  local function itemView(s)
    return { name = s.id, count = s.count or 0,
      displayName = s.displayName or s.id,
      isCraftable = s.isCraftable or false,
      fingerprint = s.fingerprint or s.id }
  end
  local craftJobSeq = 0

  -- o.type overrides the registered peripheral type so a test can reproduce the
  -- real-world variance (me_bridge / meBridge / advancedperipherals:me_bridge)
  -- that an exact hasType() match silently missed.
  return self:addPeripheral(name, { o.type or "me_bridge" }, {
    getStoredEnergy = function() return o.stored end,
    getEnergyCapacity = function() return o.max end,
    getEnergyUsage = function() return o.usage end,
    getAverageEnergyInput = function() return o.input or 0 end,
    isConnected = function() return true end,
    isOnline = function() return true end,
    getTotalItemStorage = function() return o.totalItemStorage or 0 end,
    getUsedItemStorage = function() return o.usedItemStorage or 0 end,
    getAvailableItemStorage = function()
      return (o.totalItemStorage or 0) - (o.usedItemStorage or 0)
    end,
    -- shape per AP AEApi.parseCraftingCPU: {storage, coProcessors, isBusy, name}
    getCraftingCPUs = function() return o.cpus or {} end,
    getItem = function(filter)
      local s = findItem(filter)
      return s and itemView(s) or nil
    end,
    getItems = function()
      local out = {}
      for _, s in ipairs(items) do out[#out + 1] = itemView(s) end
      return out
    end,
    isCraftable = function(filter)
      if type(filter) ~= "table" and type(filter) ~= "string" then
        return false, "EMPTY_FILTER"
      end
      local s = findItem(filter)
      return s ~= nil and s.isCraftable == true
    end,
    -- async (NOT mainThread): returns a job stub immediately; the requested
    -- count materializes into stock after o.craftSeconds, then ae_crafting
    -- fires. The count bump is scheduled FIRST so a poll woken by the event
    -- already observes the raised stock (the builder gates on observed stock,
    -- never on the job object — AM-2).
    craftItem = function(filter)
      local s = findItem(filter)
      if not s or not s.isCraftable then return nil, "NOT_CRAFTABLE" end
      local need = (type(filter) == "table" and filter.count) or 1
      craftJobSeq = craftJobSeq + 1
      local jobId = craftJobSeq
      local at = env.ticks * TICK + (o.craftSeconds or 1)
      env:scheduleAt(at, { fn = function() s.count = (s.count or 0) + need end })
      env:scheduleAt(at, { ev = { "ae_crafting", false, jobId, "JOB_DONE" } })
      return { getId = function() return jobId end,
        isDone = function() return (s.count or 0) >= need end }
    end,
    -- exportItem(filter, side) -> count moved, or 0, "ERROR" (two-return). The
    -- exported stack lands on env.ground at o.exportCell (the staging chest the
    -- turtle sucks from), carrying its behavior hooks so a pulled stack still
    -- places correctly.
    exportItem = function(filter, side)
      local s = findItem(filter)
      if not s or (s.count or 0) <= 0 then return 0, "ITEM_NOT_FOUND" end
      local want = (type(filter) == "table" and filter.count) or 64
      -- Bridge ON the turtle: exporting toward the turtle (side == o.intoTurtle)
      -- pushes straight into its inventory (getHandlerFromDirection returns the
      -- adjacent turtle's IItemHandler - source-verified). Any other side finds
      -- no inventory.
      if o.intoTurtle then
        if side ~= o.intoTurtle then return 0, "INVENTORY_NOT_FOUND" end
        local n = math.min(want, s.count)
        local stack = { id = s.id, count = n, components = s.components,
          onUse = s.onUse, makeBlock = s.makeBlock, cropId = s.cropId,
          displayName = s.displayName, damage = s.damage, maxDamage = s.maxDamage }
        if not env:giveToTurtle(stack) then return 0, "INVENTORY_FULL" end
        s.count = s.count - n
        return n
      end
      -- Side-aware delivery. o.deliver = { side, cell } models a chest on
      -- exactly ONE side of the bridge (the operator's "bridge next to a
      -- chest"): exporting to any other side finds no inventory, like the real
      -- AP method. With no o.deliver, o.exportCell delivers on any side (the
      -- back-compatible single-staging-cell tests).
      local c
      if o.deliver then
        if side ~= o.deliver.side then return 0, "INVENTORY_NOT_FOUND" end
        c = o.deliver.cell
      else
        if not o.exportCell then return 0, "INVENTORY_NOT_FOUND" end
        c = o.exportCell
      end
      local n = math.min(want, s.count)
      s.count = s.count - n
      local key = keyOf(c.x, c.y, c.z)
      local g = env.ground[key] or {}
      g[#g + 1] = { id = s.id, count = n, components = s.components,
        onUse = s.onUse, makeBlock = s.makeBlock, cropId = s.cropId,
        displayName = s.displayName, damage = s.damage, maxDamage = s.maxDamage }
      env.ground[key] = g
      return n
    end,
    -- list-all-chemicals; fresh deep copy each call (AE returns a snapshot).
    -- o.chemicalsBroken simulates a transient read failure / Applied Mekanistics
    -- not loaded: the real method then returns nil + an error string.
    getChemicals = function()
      if o.chemicalsBroken then return nil, "ADDON_NOT_LOADED" end
      return chemicalsNow()
    end,
    getChemical = function(filter)
      local want = type(filter) == "table"
        and (filter.name or filter.fingerprint) or filter
      for _, c in ipairs(chemicalsNow()) do
        if c.name == want then return c end
      end
      return nil
    end,
    -- pooled chemical-cell storage in BYTES (AEApi.getTotalChemicalStorage
    -- sums cell.getBytes()), not mB - mirrors item storage
    getTotalChemicalStorage = function() return o.totalChemicalStorage or 0 end,
    getUsedChemicalStorage = function() return o.usedChemicalStorage or 0 end,
    getAvailableChemicalStorage = function()
      return (o.totalChemicalStorage or 0) - (o.usedChemicalStorage or 0)
    end,
  })
end

-- AP Geo Scanner (type "geoScanner"): scan(radius) returns every block in a
-- cube of half-extent `radius` around the turtle, coords RELATIVE to it (the
-- shape the turtle uses to FIND a plot it was never told the location of). Air
-- is omitted, like the real scanner. Reads the live voxel world.
function Env:addGeoScanner(name, o)
  o = o or {}
  local env = self
  -- The real AP type is "geo_scanner" (GeoScannerPeripheral.PERIPHERAL_TYPE);
  -- o.type lets a test register a different/odd string to prove findScanner's
  -- scan()-method fallback still discovers an equipped upgrade.
  return self:addPeripheral(name, { o.type or "geo_scanner" }, {
    scan = function(radius)
      if type(radius) ~= "number" then radius = 8 end
      if radius > (o.maxRadius or 16) then
        return nil, "Radius exceeds the maximum of " .. (o.maxRadius or 16)
      end
      local t = env.turtle
      if not t then return nil, "No turtle" end
      local out = {}
      for k, b in pairs(env.world) do
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        local dx, dy, dz = x - t.pos.x, y - t.pos.y, z - t.pos.z
        if math.abs(dx) <= radius and math.abs(dy) <= radius
          and math.abs(dz) <= radius then
          out[#out + 1] = { name = b.id, x = dx, y = dy, z = dz,
            tags = b.tags or {} }
        end
      end
      return out
    end,
    cost = function(radius) return (radius or 8) end,
    getScanCooldown = function() return 0 end,
  })
end

-- AP Chat Box (type "chat_box"); messages land in env.chatLog
function Env:addChatBox(name)
  local env = self
  return self:addPeripheral(name, { "chat_box" }, {
    sendMessage = function(msg, prefix)
      env.chatLog[#env.chatLog + 1] = { msg = msg, prefix = prefix }
      return true
    end,
    sendMessageToPlayer = function(msg, player, prefix)
      env.chatLog[#env.chatLog + 1] =
        { msg = msg, player = player, prefix = prefix }
      return true
    end,
  })
end

-- ----------------------------------------------- Mekanism Digital Miner mock

-- Verbatim from TileEntityMekanism.validateSecurityIsPublic (A1,
-- vendor/Mekanism .../tile/base/TileEntityMekanism.java:1647-1651)
local SECURITY_ERR =
  "Setter not available due to machine security not being public."

-- Verbatim from TileEntityDigitalMiner.validateCanChangeConfiguration (N1b)
local IDLE_ERR =
  "Miner must be stopped and reset before its targeting configuration is changed."

-- Every Mekanism CC call dispatches to the main thread and costs >=1
-- server tick (A1, CCMethodCaller.java:29-33). Calls are logged so tests
-- can assert converge/no-op behavior.
local function wrapMekMethods(env, M)
  local wrapped = {}
  for name, fn in pairs(M) do
    wrapped[name] = function(...)
      env.ticks = env.ticks + 1
      env.mockCalls[#env.mockCalls + 1] = name
      return fn(...)
    end
  end
  return wrapped
end

-- Method surface per claims A1 + N1b; run-model semantics per N4:
-- the searcher enum (IDLE/SEARCHING/FINISHED; PAUSED is dead code in
-- 10.7.19.85) advances on search completion only, `running` is operator
-- intent and is NEVER auto-cleared on exhaustion, stop() during SEARCHING
-- interrupts to IDLE while stop() at FINISHED leaves FINISHED (setters
-- stay locked until reset()), and toMine publishes a configurable number
-- of ticks AFTER state flips to FINISHED (the N4 transient hazard the
-- sled must debounce). Mining drains toMine at a CONFIGURABLE mock rate —
-- sled logic must measure it, never assume it (AM-2).
local function minerMethods(state, env)
  -- The miner is ACTIVE — draining energy and mining — only when running,
  -- search FINISHED+published, targets remain, and the FULL per-tick cost
  -- is available (A4/N4: the tick gate calls setActive(false) otherwise;
  -- an underfed miner stalls with a NONZERO buffer). Progress accrues
  -- through an active-ticks accumulator so stalls and stop()/start()
  -- freeze it exactly.
  local function isActive()
    return state.running == true and state.status == "FINISHED"
      and env.ticks >= (state.publishTick or 0)
      and (state.toMine or 0) > 0
      and (state.energy or 0) >= (state.usagePerTick or 0)
  end

  local function sync()
    if state.status == "SEARCHING" and env.ticks >= (state.searchDoneTick or 0) then
      state.status = "FINISHED"
      state.publishTick = state.searchDoneTick + (state.publishLagTicks or 1)
      state.lastSyncTick = state.publishTick
      state.minedTicks = 0
    end
    if state.status == "FINISHED" then
      local last = state.lastSyncTick or env.ticks
      if env.ticks > last then
        if state.running and env.ticks >= (state.publishTick or 0)
          and (state.energy or 0) >= (state.usagePerTick or 0) then
          state.minedTicks = (state.minedTicks or 0) + (env.ticks - last)
        end
        state.lastSyncTick = env.ticks
      end
      if env.ticks < (state.publishTick or 0) then
        state.toMine = 0 -- the N4 publish-lag transient window
      else
        local mined = math.floor((state.minedTicks or 0) * TICK
          * (state.mineRate or 0))
        state.toMine = math.max(0, (state.targets or 0) - mined)
      end
    end
  end

  local function guardPublic()
    if state.security ~= "PUBLIC" then error(SECURITY_ERR, 0) end
  end
  local function guardIdle()
    guardPublic()
    sync()
    if state.status ~= "IDLE" then error(IDLE_ERR, 0) end
  end

  local M = {}
  function M.getState() sync(); return state.status end
  function M.isRunning() sync(); return state.running end
  function M.getToMine() sync(); return state.toMine end
  function M.start()
    guardPublic()
    sync()
    if state.running and state.status ~= "IDLE" then return end
    state.running = true
    if state.status == "IDLE" then
      -- every start from IDLE triggers a full volume re-scan (A4)
      state.status = "SEARCHING"
      state.searchDoneTick = env.ticks + toTicks(state.searchSeconds or 1)
      state.toMine = 0
    end
    -- from FINISHED: the active-ticks accumulator simply resumes
  end
  function M.stop()
    guardPublic()
    sync()
    if state.status == "SEARCHING" then
      -- stop() mid-search interrupts the searcher and resets to IDLE (N1b)
      state.status, state.toMine = "IDLE", 0
    end
    -- at FINISHED: state STAYS FINISHED, setters stay locked (N1b); the
    -- accumulator freezes because running is false
    state.running = false
  end
  function M.reset()
    guardPublic()
    state.status, state.running, state.toMine = "IDLE", false, 0
  end

  function M.getRadius() return state.radius end
  function M.getMaxRadius() return 32 end -- pack general.toml:126 (A4/N1b)
  function M.getMinY() return state.minY end
  function M.getMaxY() return state.maxY end
  function M.getSilkTouch() return state.silkTouch end
  function M.getAutoEject() return state.autoEject end
  function M.getAutoPull() return state.autoPull end
  function M.getEnergy() return state.energy end          -- Joules (A1)
  function M.getMaxEnergy() return state.maxEnergy end
  function M.getEnergyUsage()
    -- the purpose-built stall probe (N4): `getActive() ? energyPerTick :
    -- 0`. NOT active during SEARCHING (the tick gate requires FINISHED
    -- with targets left), and an underfed buffer (below the full per-tick
    -- cost) stalls the machine with usage 0 (A4/N4).
    sync()
    return isActive() and (state.usagePerTick or 0) or 0
  end
  function M.getSecurityMode() return state.security end

  -- N1b setters: validation THROWS rather than clamps, so a successful
  -- set always reads back exactly (converge-by-readback works)
  function M.setRadius(r)
    guardIdle()
    if r < 0 or r > 32 then
      error(("Radius '%d' is out of range must be between 0 and %d. (Inclusive)")
        :format(r, 32), 0)
    end
    state.radius = r
  end
  function M.setMinY(y)
    guardIdle()
    if y < state.minBuild or y > state.maxY then
      error(("Min Y '%d' is out of range must be between %d and %d. (Inclusive)")
        :format(y, state.minBuild, state.maxY), 0)
    end
    state.minY = y
  end
  function M.setMaxY(y)
    guardIdle()
    if y < state.minY or y > state.maxBuild - 1 then
      error(("Max Y '%d' is out of range must be between %d and %d. (Inclusive)")
        :format(y, state.minY, state.maxBuild - 1), 0)
    end
    state.maxY = y
  end
  function M.setSilkTouch(b) guardPublic(); state.silkTouch = b end
  function M.setAutoEject(b) guardPublic(); state.autoEject = b end
  function M.setAutoPull(b) guardPublic(); state.autoPull = b end

  -- Filters (N1b): the mock supports the one shape the sled ships —
  -- MINER_TAG_FILTER. Normalization (lowercased tag, defaulted keys)
  -- mirrors SpecialConverters; duplicates are rejected like the
  -- LinkedHashSet path.
  local function normFilter(t)
    if type(t) ~= "table" or type(t.type) ~= "string" then
      error("Missing 'type' element", 0)
    end
    if t.type:upper() ~= "MINER_TAG_FILTER" then
      error("Unknown 'type' value", 0)
    end
    if type(t.tag) ~= "string" or #t.tag == 0 then
      error("Invalid or missing tag specified for Tag filter", 0)
    end
    return {
      type = "MINER_TAG_FILTER", tag = t.tag:lower(),
      enabled = t.enabled == nil and true or t.enabled,
      requires_replacement = t.requires_replacement or false,
      replace_target = t.replace_target or "minecraft:air",
    }
  end
  local function sameFilter(a, b)
    return a.type == b.type and a.tag == b.tag and a.enabled == b.enabled
      and a.requires_replacement == b.requires_replacement
      and a.replace_target == b.replace_target
  end
  function M.addFilter(t)
    guardIdle()
    local f = normFilter(t)
    for _, x in ipairs(state.filters) do
      if sameFilter(x, f) then return false end
    end
    state.filters[#state.filters + 1] = f
    return true
  end
  function M.removeFilter(t)
    guardIdle()
    local f = normFilter(t)
    for i, x in ipairs(state.filters) do
      if sameFilter(x, f) then
        table.remove(state.filters, i)
        return true
      end
    end
    return false
  end
  function M.getFilters()
    local out = {}
    for i, x in ipairs(state.filters) do
      out[i] = { type = x.type, tag = x.tag, enabled = x.enabled,
        requires_replacement = x.requires_replacement,
        replace_target = x.replace_target }
    end
    return out
  end

  return wrapMekMethods(env, M)
end

local function minerDefaults(o)
  o = o or {}
  return {
    radius = o.radius or 10, minY = o.minY or 0, maxY = o.maxY or 60,
    silkTouch = o.silkTouch or false, autoEject = o.autoEject or false,
    autoPull = o.autoPull or false, filters = o.filters or {},
    energy = o.energy or 0, maxEnergy = o.maxEnergy or 50000, -- 50 kJ (A4)
    security = o.security or "PUBLIC", upgrades = o.upgrades or {},
    targets = o.targets or 0, searchSeconds = o.searchSeconds or 1,
    mineRate = o.mineRate or 0, usagePerTick = o.usagePerTick or 0,
    -- D2 mining-dim build heights; N1b setter validation bounds
    minBuild = o.minBuild or -64, maxBuild = o.maxBuild or 320,
    publishLagTicks = o.publishLagTicks or 1,
  }
end

-- Named flavor: a miner already attached (wired/adjacent), no world model.
function Env:addDigitalMiner(name, o)
  local state = minerDefaults(o)
  state.status, state.running, state.toMine = "IDLE", false, 0
  return self:addPeripheral(name, { "digitalMiner" },
    minerMethods(state, self))
end

-- Item flavor: places as the 3x3x2 multiblock, digs back to one item.
function Env:minerItem(o)
  local env = self
  local function makeBlock(stack, x, y, z, placeDir)
    if placeDir ~= "up" then
      -- C1 [FALSE]: every deploy branch except placeUp leaves the turtle
      -- inside the bounding volume — placement can never succeed
      return false, "Cannot place block here"
    end
    -- all 17 bounding cells must be free too (C1; main is bottom-center
    -- of the 3x3x2 volume; the main cell itself was checked by place())
    for dx = -1, 1 do for dz = -1, 1 do for dy = 0, 1 do
      if not (dx == 0 and dz == 0 and dy == 0)
        and env.world[keyOf(x + dx, y + dy, z + dz)] then
        return false, "Cannot place block here"
      end
    end end end

    local state = {}
    for k, v in pairs(stack.components or {}) do state[k] = v end
    -- `running` is NBT-only — never rides the item; fresh placement is
    -- IDLE and stopped, the sled must call start() (A4 skeptic)
    state.status, state.running, state.toMine = "IDLE", false, 0
    state.facing = OPP[env.turtle.facing] -- horizontal opposite (C1)
    local entry = mkPeriphEntry("digitalMiner", { "digitalMiner" },
      minerMethods(state, env))

    local function breakAll()
      -- breaking main or any bounding block removes the whole structure
      -- with a single item drop carrying the config back (A2)
      for dx = -1, 1 do for dz = -1, 1 do for dy = 0, 1 do
        env.world[keyOf(x + dx, y + dy, z + dz)] = nil
      end end end
      local comps = {}
      for k, v in pairs(state) do comps[k] = v end
      comps.status, comps.running, comps.toMine = nil, nil, nil
      comps.facing, comps.searchDoneTick, comps.mineFromTick = nil, nil, nil
      return { id = "mekanism:digital_miner", count = 1,
        components = comps, makeBlock = makeBlock }
    end

    -- main block: peripheral reachable through its DOWN face only (A1/A4)
    env.world[keyOf(x, y, z)] = { id = "mekanism:digital_miner",
      state = state, facePeriph = { down = entry }, onDig = breakAll }
    for dx = -1, 1 do for dz = -1, 1 do for dy = 0, 1 do
      if not (dx == 0 and dz == 0 and dy == 0) then
        env.world[keyOf(x + dx, y + dy, z + dz)] =
          { id = "mekanism:bounding_block", onDig = breakAll }
      end
    end end end
    -- ports (A4 :1147-1183): energy = outer faces of the left/right
    -- main-layer bounding blocks; item input = top-center UP face; item
    -- output = top-back-center back face. Eject target (not a port the
    -- turtle wraps) = main +up +2*back.
    local B = OPP[state.facing]
    local L, R = LEFT[state.facing], RIGHT[state.facing]
    env.world[keyOf(x + FACES[L].x, y, z + FACES[L].z)].facePeriph = { [L] = entry }
    env.world[keyOf(x + FACES[R].x, y, z + FACES[R].z)].facePeriph = { [R] = entry }
    env.world[keyOf(x, y + 1, z)].facePeriph = { up = entry }
    env.world[keyOf(x + FACES[B].x, y + 1, z + FACES[B].z)].facePeriph =
      { [B] = entry }
    return true
  end
  return { id = "mekanism:digital_miner", count = 1,
    components = minerDefaults(o), makeBlock = makeBlock }
end

-- Quantum Entangloporter surface per claim N1 (the subset the sled and
-- commissioning use; claim N1 in docs/RESEARCH.md documents the full
-- 50-method surface in summary form).
-- Frequencies are GLOBAL state (B1): env.publicFreqs is the PUBLIC
-- inventory-frequency manager and computers can only create/select/list
-- PUBLIC frequencies (N1); a PRIVATE frequency rides the item components
-- but is not reachable from Lua.
local QE_TYPES = { "ITEM", "FLUID", "CHEMICAL", "ENERGY", "HEAT" }
local QE_SIDES = { "FRONT", "LEFT", "RIGHT", "BACK", "TOP", "BOTTOM" }

local function qeMethods(state, env)
  state.sideConfig = state.sideConfig or {}
  state.ejecting = state.ejecting or {}
  for _, ty in ipairs(QE_TYPES) do
    state.sideConfig[ty] = state.sideConfig[ty] or {}
    -- per-tab auto-eject defaults OFF (B2, ConfigInfo.java:38-43)
    if state.ejecting[ty] == nil then state.ejecting[ty] = false end
  end

  local function guardPublic()
    if (state.security or "PUBLIC") ~= "PUBLIC" then error(SECURITY_ERR, 0) end
  end
  -- enum args pass as case-insensitive strings matched against the Java
  -- enum name() (N1). Rejection goes through CC:Tweaked, not Mekanism:
  -- CCComputerHelper.getEnum delegates to IArguments.getEnum ->
  -- LuaValues.checkEnum, "bad argument #"+(index+1)+" (unknown option "
  -- +value+")" (vendor/CC-Tweaked .../core/lua/LuaValues.java:161-166;
  -- Mekanism CCComputerHelper.java:21-27, CCMethodCaller.java:52-56
  -- rethrows the original LuaException) — N1 phase-2.1 addendum.
  local function normIn(v, list, idx)
    local up = tostring(v):upper()
    for _, t in ipairs(list) do if t == up then return t end end
    error(("bad argument #%d (unknown option %s)"):format(idx or 1,
      tostring(v)), 0)
  end
  local function freqCopy(f)
    return { key = f.key, security_mode = f.security_mode, owner = f.owner }
  end

  local M = {}
  function M.getFrequency()
    if not state.frequency then
      error("No frequency is currently selected.", 0) -- N1 verbatim
    end
    return freqCopy(state.frequency)
  end
  function M.getFrequencies()
    local out = {}
    for name, f in pairs(env.publicFreqs) do
      out[#out + 1] = { key = name, security_mode = "PUBLIC", owner = f.owner }
    end
    return out
  end
  function M.setFrequency(name)
    guardPublic()
    local f = env.publicFreqs[name]
    if not f then
      error(("No public inventory frequency with name '%s' found.")
        :format(name), 0) -- N1 verbatim
    end
    state.frequency = { key = name, security_mode = "PUBLIC", owner = f.owner }
  end
  function M.createFrequency(name)
    guardPublic()
    if env.publicFreqs[name] then
      error(("Unable to create public inventory frequency with name '%s' as one already exists.")
        :format(name), 0) -- N1 verbatim
    end
    local owner = state.owner or "owner"
    env.publicFreqs[name] = { owner = owner }
    state.frequency = { key = name, security_mode = "PUBLIC", owner = owner }
  end

  function M.getConfigurableTypes()
    local out = {}
    for i, t in ipairs(QE_TYPES) do out[i] = t end
    return out
  end
  function M.getSupportedModes(ty)
    ty = normIn(ty, QE_TYPES)
    -- HEAT supports {NONE, INPUT_OUTPUT} only (N1 skeptic correction)
    if ty == "HEAT" then return { "NONE", "INPUT_OUTPUT" } end
    return { "NONE", "INPUT", "OUTPUT", "INPUT_OUTPUT" }
  end
  function M.getMode(ty, side)
    return state.sideConfig[normIn(ty, QE_TYPES)][normIn(side, QE_SIDES)]
      or "NONE"
  end
  function M.setMode(ty, side, mode)
    guardPublic()
    ty, side = normIn(ty, QE_TYPES), normIn(side, QE_SIDES)
    mode = normIn(mode, M.getSupportedModes(ty))
    state.sideConfig[ty][side] = mode
  end
  function M.canEject(ty)
    -- the heat tab is not ejectable on the real QE (fidelity review)
    return normIn(ty, QE_TYPES) ~= "HEAT"
  end
  function M.isEjecting(ty)
    return state.ejecting[normIn(ty, QE_TYPES)] == true
  end
  function M.setEjecting(ty, b)
    guardPublic()
    ty = normIn(ty, QE_TYPES)
    if ty == "HEAT" then return end
    state.ejecting[ty] = b == true
  end

  function M.getEnergy() return state.energy or 0 end
  function M.getMaxEnergy() return state.maxEnergy or 0 end
  function M.getEnergyFilledPercentage()
    -- with NO frequency the container list is empty and Mekanism's
    -- divideToLevel(0, 0) returns 1.0, not 0 (N1 skeptic correction)
    if not state.frequency or (state.maxEnergy or 0) == 0 then return 1.0 end
    return (state.energy or 0) / state.maxEnergy
  end
  function M.getSecurityMode() return state.security or "PUBLIC" end
  function M.getOwnerName() return state.owner or "owner" end
  function M.getOwnerUUID()
    return state.ownerUUID or "00000000-0000-0000-0000-000000000000"
  end

  return wrapMekMethods(env, M)
end

function Env:qeItem(o)
  o = o or {}
  local comps = o.components or {}
  if comps.security == nil then comps.security = "PUBLIC" end
  return self:machineItem{
    id = "mekanism:quantum_entangloporter",
    types = { "quantumEntangloporter" },
    makeMethods = qeMethods,
    components = comps,
  }
end

-- ------------------------------------------- farm build item-use mocks (Q1)
-- Inventory stacks that carry an onUse(env, x,y,z, dir, stack) hook;
-- turtle.place() dispatches it (buildTurtleApi place()). Each re-derives the
-- real game's gate against env.world and returns ok, err, consumed. Verified
-- turtle-visible behavior from vendored CC/FfB/MA source (FARM-RESEARCH Q1,
-- Q1-water): success returns true; a precondition miss returns false +
-- "Cannot place item here", stack retained. The blocks they leave are the
-- exact registry ids the scan distinguishes (FARM-RESEARCH Q3 table).

local PLACE_FAIL = "Cannot place item here"
local FARMLAND = "minecraft:farmland"
local FERTILIZED = "farmingforblockheads:fertilized_farmland_healthy"

local function isFarmland(id) return id == FARMLAND or id == FERTILIZED end

-- a brace face for fluid placement / planting: any non-fluid block
local function isSolid(b) return b ~= nil and b.id ~= "minecraft:water"
  and b.id ~= "minecraft:lava" end

-- The hoe tills dirt/grass/path into farmland; it is NOT consumed, only loses
-- durability (TurtlePlaceCommand.java:223 -> vanilla HoeItem.useOn). The stack
-- carries damage/maxDamage so getItemDetail(slot, true) exposes durability.
local TILLABLE = { ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true,
  ["minecraft:dirt_path"] = true, ["minecraft:coarse_dirt"] = true,
  ["minecraft:rooted_dirt"] = true }

function Env:hoeItem(o)
  o = o or {}
  local env = self
  return {
    id = o.id or "minecraft:diamond_hoe", count = 1,
    displayName = o.displayName or "Diamond Hoe",
    damage = o.damage or 0, maxDamage = o.durability or 1561, -- diamond default
    onUse = function(_, x, y, z, _dir, s)
      local b = env.world[keyOf(x, y, z)]
      if not (b and TILLABLE[b.id]) then return false, PLACE_FAIL end
      if (s.damage or 0) >= s.maxDamage then return false, PLACE_FAIL end -- broken
      env.world[keyOf(x, y, z)] = { id = FARMLAND, state = { moisture = 0 } }
      s.damage = (s.damage or 0) + 1
      return true, nil, 0 -- not consumed
    end,
  }
end

-- FfB red fertilizer: applies the HEALTHY trait to plain farmland once and
-- shrinks 1 (FertilizerItem.java:114-132; RED = HEALTHY :28). Its only guard
-- is player==null, which a fake player passes. The load-bearing negative for
-- the builder's converge guards: it refuses an already-fertilized cell and
-- consumes nothing (so a kill-redo never double-spends a fertilizer).
function Env:fertilizerItem(o)
  o = o or {}
  local env = self
  return {
    id = o.id or "farmingforblockheads:red_fertilizer", count = o.count or 1,
    displayName = o.displayName or "Red Fertilizer (Healthy)",
    onUse = function(_, x, y, z, _dir, _s)
      local b = env.world[keyOf(x, y, z)]
      if not (b and b.id == FARMLAND) then return false, PLACE_FAIL end
      env.world[keyOf(x, y, z)] = { id = FERTILIZED, state = { moisture = 0 } }
      return true, nil, 1
    end,
  }
end

-- MA seed: a BlockItem; plants on a farmland top face -> crop age 0, shrinks 1
-- (MysticalSeedsItem.java:17 ItemNameBlockItem; FertilizedFarmlandBlock
-- canSustainPlant unconditional :38). The crop occupies the target air cell
-- and needs farmland in the cell directly below it.
function Env:seedItem(cropId, o)
  o = o or {}
  local env = self
  return {
    id = o.id or (cropId:gsub("_crop$", "_seeds")), count = o.count or 1,
    displayName = o.displayName, cropId = cropId,
    onUse = function(_, x, y, z, _dir, _s)
      if env.world[keyOf(x, y, z)] then return false, PLACE_FAIL end -- not empty
      local below = env.world[keyOf(x, y - 1, z)]
      if not (below and isFarmland(below.id)) then return false, PLACE_FAIL end
      env.world[keyOf(x, y, z)] = { id = cropId, state = { age = 0 } }
      return true, nil, 1
    end,
  }
end

-- Water bucket: the explicit BucketItem branch (TurtlePlaceCommand.java:230-232)
-- emits a source into the target air cell, which must have a solid brace face
-- (Q1-water: canDeployOnBlock won't engage on pure air). The emptied bucket is
-- written back to the slot (transformed in place, not consumed).
function Env:waterBucketItem(o)
  o = o or {}
  local env = self
  return {
    id = o.id or "minecraft:water_bucket", count = 1,
    displayName = o.displayName or "Water Bucket",
    onUse = function(_, x, y, z, dir, s)
      if env.world[keyOf(x, y, z)] then return false, PLACE_FAIL end -- not empty
      -- The deploy braces against the block the bucket aims THROUGH, not any
      -- neighbor: a placeDown is a Y-axis direction, so it can only brace
      -- against the cell DIRECTLY BELOW the target (TurtlePlaceCommand gates
      -- the horizontal "deploy on the block in front" path on a non-Y axis).
      -- placeUp braces above; a horizontal place braces below (water needs a
      -- floor either way). Modeling this faithfully is what forces the builder
      -- to lay a sub-floor under each stacked-plot water cell (Q1-water).
      local by = (dir == "up") and (y + 1) or (y - 1)
      if not isSolid(env.world[keyOf(x, by, z)]) then return false, PLACE_FAIL end
      env.world[keyOf(x, y, z)] = { id = "minecraft:water", state = { level = 0 } }
      s.id = "minecraft:bucket"          -- emptied bucket written back
      s.displayName = "Bucket"
      return true, nil, 0
    end,
  }
end

-- Monitor mock, two flavors:
--   { w=, h= }          fixed size, setTextScale is a no-op (legacy tests)
--   { baseW=, baseH= }  scale-aware: size at textScale 1; like real CC,
--                       halving the scale doubles the character grid
function Env:addMonitor(name, o)
  local isColor = o.advanced ~= false
  local scale = 1
  local buf, t
  if o.baseW then
    buf, t = newScreen(o.baseW, o.baseH, isColor, self.strictColors, name)
    t.setTextScale = function(s)
      if type(s) ~= "number" or s < 0.5 or s > 5 or (s * 2) % 1 ~= 0 then
        error("Expected number in range 0.5-5", 2)
      end
      scale = s
      buf.resize(
        math.floor(o.baseW / s + 0.5),
        math.floor(o.baseH / s + 0.5))
    end
  else
    buf, t = newScreen(o.w or 39, o.h or 15, isColor, self.strictColors, name)
    t.setTextScale = function(s) scale = s end
  end
  t.getTextScale = function() return scale end
  buf.getScale = function() return scale end
  self.monitors[name] = buf
  return self:addPeripheral(name, { "monitor" }, t)
end

function Env:monitorScale(name)
  local buf = self.monitors[name]
  return buf and buf.getScale()
end

-- AP Block Reader facing a drive of AppFlux cells. NBT shape matches the
-- in-game dump from Carter's server (extendedae:ex_drive, items keyed
-- "item0".."itemN", cell energy in component "appflux:fe_energy").
-- o.cells = { {id="appflux:fe_64k_cell", energy=N}, ... };
-- o.ratePerSec charges the first cell over virtual time.
function Env:addFluxDrive(name, o)
  local env = self
  return self:addPeripheral(name, { "block_reader" }, {
    getBlockName = function() return o.block or "extendedae:ex_drive" end,
    getBlockData = function()
      if o.data then return o.data end
      local inv = {}
      for i, cell in ipairs(o.cells) do
        local item = { id = cell.id, count = 1, components = {} }
        if type(cell.energy) == "number" then
          local e = cell.energy
          if i == 1 and o.ratePerSec then
            e = e + o.ratePerSec * env.ticks * TICK
          end
          item.components["appflux:fe_energy"] = math.floor(e)
        end
        inv["item" .. (i - 1)] = item
      end
      return { inv = inv, priority = 0 }
    end,
  })
end

function Env:addModem(name)
  return self:addPeripheral(name, { "modem", "peripheral_hub" }, {
    isWireless = function() return false end,
    getNamesRemote = function() return {} end,
    isPresentRemote = function() return false end,
  })
end

function Env:file(path) return self.files[path] end
function Env:termText() return screenText(self.termBuf) end
function Env:monitorText(name)
  local buf = self.monitors[name]
  return buf and screenText(buf) or nil
end

-- -------------------------------------------------------------- turtle mock

-- The `turtle` global (a global, not a peripheral — SLED-DESIGN §11).
-- Move-command check order mirrors TurtleMoveCommand.execute @ CC:T
-- v1.21.1-1.117.1: canEnter incl. "Cannot leave loaded world" (:84) ->
-- obstruction "Movement obstructed" (:44,:51) -> fuel "Out of fuel" (:55)
-- -> teleport -> consumeFuel(1). Turns never consume fuel (C4,
-- TurtleTurnCommand.java:20-31). Every world-touching command takes one
-- 0.4s turtle action, implemented on the same virtual-timer machinery as
-- the rest of the harness so scenario hooks (restartAt / chunkUnloadAt)
-- can fire mid-action — i.e. BEFORE the world mutates, exactly the
-- queued-but-dropped command window C5 reconciliation exists for.
local function buildTurtleApi(env, osT)
  local T = {}
  local t = env.turtle

  local function takeTime()
    local id = osT.startTimer(0.4)
    while true do
      local ev, a = coroutine.yield("timer")
      if ev == "timer" and a == id then return end
    end
  end

  -- dir: "front" | "back" | "up" | "down" (front/back relative to facing)
  local function targetCell(dir)
    local p = t.pos
    if dir == "up" then return p.x, p.y + 1, p.z end
    if dir == "down" then return p.x, p.y - 1, p.z end
    local f = FACES[t.facing]
    local s = dir == "back" and -1 or 1
    return p.x + f.x * s, p.y, p.z + f.z * s
  end

  local function move(dir)
    takeTime()
    local x, y, z = targetCell(dir)
    if env.loadedBounds then
      local b = env.loadedBounds
      if x < b.minX or x > b.maxX or z < b.minZ or z > b.maxZ then
        return false, "Cannot leave loaded world"
      end
    end
    if env.world[keyOf(x, y, z)] then
      return false, "Movement obstructed"
    end
    if t.fuel < 1 then return false, "Out of fuel" end
    t.pos.x, t.pos.y, t.pos.z = x, y, z
    t.fuel = t.fuel - 1
    env:rescanSides(false)
    return true
  end

  function T.forward() return move("front") end
  function T.back() return move("back") end
  function T.up() return move("up") end
  function T.down() return move("down") end

  function T.turnLeft()
    takeTime()
    t.facing = LEFT[t.facing]
    env:rescanSides(true)
    return true
  end
  function T.turnRight()
    takeTime()
    t.facing = RIGHT[t.facing]
    env:rescanSides(true)
    return true
  end

  local function detect(dir)
    local x, y, z = targetCell(dir)
    return env.world[keyOf(x, y, z)] ~= nil
  end
  function T.detect() return detect("front") end
  function T.detectUp() return detect("up") end
  function T.detectDown() return detect("down") end

  local function inspect(dir)
    local x, y, z = targetCell(dir)
    local b = env.world[keyOf(x, y, z)]
    if not b then return false, "No block to inspect" end
    return true, { name = b.id, state = b.state or {}, tags = b.tags or {} }
  end
  function T.inspect() return inspect("front") end
  function T.inspectUp() return inspect("up") end
  function T.inspectDown() return inspect("down") end

  -- Insert a stack CC-style: selected slot first, then ascending; merge
  -- only on same id AND same components table (CC merges via
  -- ItemStack.isSameItemSameComponents, InventoryUtil.java:130-134 — so
  -- two differently-configured machines never stack, B1).
  local function sameStack(a, b)
    if a.id ~= b.id then return false end
    if a.components or b.components then
      return a.components == b.components
    end
    return true
  end
  local function giveItem(stack)
    local order = { t.sel }
    for i = 1, 16 do if i ~= t.sel then order[#order + 1] = i end end
    for _, i in ipairs(order) do
      local s = t.inv[i]
      if s and sameStack(s, stack) and s.count + stack.count <= 64 then
        s.count = s.count + stack.count
        return true
      end
    end
    for _, i in ipairs(order) do
      if not t.inv[i] then
        t.inv[i] = stack
        return true
      end
    end
    return false
  end

  -- Drops land at the broken cell; C2: a full inventory does NOT fail the
  -- dig — overflow drops on the ground and the command still succeeds.
  local function dropAt(key, stack)
    local g = env.ground[key] or {}
    g[#g + 1] = stack
    env.ground[key] = g
  end

  local function place(dir)
    takeTime()
    local stack = t.inv[t.sel]
    -- "No items to place": TurtlePlaceCommand.java:52
    if not stack or stack.count < 1 then return false, "No items to place" end
    local x, y, z = targetCell(dir)
    -- Use-on-block items (hoe/fertilizer/seed/water bucket) dispatch their own
    -- useOn semantics (FARM-RESEARCH Q1; TurtlePlaceCommand.java:223,230-232):
    -- they may target an OCCUPIED cell (till/fertilize transform in place) or
    -- require specific bracing (seed needs farmland below; bucket a solid
    -- brace), so they run BEFORE the "Cannot place block here" check. The item
    -- fully owns its precondition, world mutation, and consumption, returning
    -- ok, err, consumed (items to remove from the stack; 0 = not consumed,
    -- e.g. the hoe loses durability only). On a precondition miss it returns
    -- false + the stack is retained, mirroring the makeBlock contract.
    if stack.onUse then
      local ok, err, consumed = stack.onUse(env, x, y, z, dir, stack)
      if not ok then return false, err end
      consumed = consumed or 0
      if consumed > 0 then
        stack.count = stack.count - consumed
        if stack.count <= 0 then t.inv[t.sel] = nil end
      end
      env.worldOps = (env.worldOps or 0) + 1
      env:rescanSides(false)
      return true
    end
    -- "Cannot place block here": TurtlePlaceCommand.java:73
    if env.world[keyOf(x, y, z)] then return false, "Cannot place block here" end
    if stack.makeBlock then
      -- machine items place through their own hook (bounding-volume and
      -- facing rules live there); on false the item is retained (C1)
      local ok, err = stack.makeBlock(stack, x, y, z, dir)
      if not ok then return false, err end
    else
      env.world[keyOf(x, y, z)] = { id = stack.id, components = stack.components }
    end
    stack.count = stack.count - 1
    if stack.count == 0 then t.inv[t.sel] = nil end
    env.worldOps = (env.worldOps or 0) + 1
    env:rescanSides(false)
    return true
  end
  function T.place() return place("front") end
  function T.placeUp() return place("up") end
  function T.placeDown() return place("down") end

  local function dig(dir)
    takeTime()
    local x, y, z = targetCell(dir)
    local key = keyOf(x, y, z)
    local b = env.world[key]
    -- "Nothing to dig here": TurtleTool.java:280
    if not b then return false, "Nothing to dig here" end
    local stack
    if b.onDig then
      stack = b.onDig(env, x, y, z)
    else
      env.world[key] = nil
      stack = { id = b.id, count = 1, components = b.components }
    end
    if stack and not giveItem(stack) then dropAt(key, stack) end
    env.worldOps = (env.worldOps or 0) + 1
    env:rescanSides(false)
    return true
  end
  function T.dig() return dig("front") end
  function T.digUp() return dig("up") end
  function T.digDown() return dig("down") end

  local function suck(dir)
    takeTime()
    local x, y, z = targetCell(dir)
    local key = keyOf(x, y, z)
    local g = env.ground[key]
    -- "No items to take": TurtleSuckCommand.java:55,68
    if not g or #g == 0 then return false, "No items to take" end
    local stack = g[1]
    if not giveItem(stack) then return false, "No space for items" end
    table.remove(g, 1)
    if #g == 0 then env.ground[key] = nil end
    return true
  end
  function T.suck() return suck("front") end
  function T.suckUp() return suck("up") end
  function T.suckDown() return suck("down") end

  -- drop the selected slot's items onto the ground at the target cell (with no
  -- adjacent inventory the real turtle drops into the world, TurtleDropCommand)
  local function drop(dir, n)
    takeTime()
    local s = t.inv[t.sel]
    if not s or s.count < 1 then return false, "No items to drop" end
    local x, y, z = targetCell(dir)
    local cnt = math.min(n or s.count, s.count)
    dropAt(keyOf(x, y, z),
      { id = s.id, count = cnt, components = s.components, onUse = s.onUse,
        makeBlock = s.makeBlock, cropId = s.cropId, displayName = s.displayName })
    s.count = s.count - cnt
    if s.count <= 0 then t.inv[t.sel] = nil end
    return true
  end
  function T.drop(n) return drop("front", n) end
  function T.dropUp(n) return drop("up", n) end
  function T.dropDown(n) return drop("down", n) end

  -- fuel = burnTime/20 (C4, FurnaceRefuelHandler.java:36-38); values below
  -- are the S3-verified pack numbers; override per-env via env.fuelValues
  local FUEL_VALUES = {
    ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80,
    ["minecraft:coal_block"] = 800, ["minecraft:blaze_rod"] = 120,
    ["minecraft:lava_bucket"] = 1000,
  }
  function T.refuel(n)
    takeTime()
    local s = t.inv[t.sel]
    -- "No items to combust" / "Items not combustible":
    -- TurtleRefuelCommand.java:24,27
    if not s then return false, "No items to combust" end
    local per = (env.fuelValues and env.fuelValues[s.id]) or FUEL_VALUES[s.id]
    if not per then return false, "Items not combustible" end
    if n == 0 then return true end
    local take = math.min(n or 64, s.count)
    -- refuel(n) self-caps at the limit (C4, FurnaceRefuelHandler.java:
    -- 21-23); the last item's overfill is clamped and wasted
    -- (TurtleBrain.java:365-366)
    local used = 0
    while used < take and t.fuel < t.limit do
      t.fuel = math.min(t.limit, t.fuel + per)
      used = used + 1
    end
    s.count = s.count - used
    if s.count == 0 then t.inv[t.sel] = nil end
    return true
  end

  function T.getFuelLevel() return t.fuel end
  function T.getFuelLimit() return t.limit end

  function T.select(n)
    if type(n) ~= "number" or n < 1 or n > 16 then
      error("bad argument #1 (slot out of range)", 2)
    end
    t.sel = math.floor(n)
    return true
  end
  function T.getSelectedSlot() return t.sel end
  function T.getItemCount(slot)
    local s = t.inv[slot or t.sel]
    return s and s.count or 0
  end
  -- getItemDetail(slot) -> { name, count }; getItemDetail(slot, true) adds the
  -- detailed fields CC exposes, including tool durability (damage/maxDamage/
  -- durability), the signal the farm builder uses to restock the hoe before it
  -- breaks mid-plot.
  function T.getItemDetail(slot, detailed)
    local s = t.inv[slot or t.sel]
    if not s then return nil end
    local d = { name = s.id, count = s.count }
    if detailed then
      d.displayName = s.displayName or s.id
      d.tags = s.tags or {}
      if s.maxDamage then
        d.damage = s.damage or 0
        d.maxDamage = s.maxDamage
        d.durability = (s.maxDamage - (s.damage or 0)) / s.maxDamage
      end
    end
    return d
  end

  -- transferTo(slot[, count]): move up to count from the selected slot into slot,
  -- stacking onto a same-id stack (TurtleInventory). Used by the farm builder to
  -- gather an AE export that landed in some free slot into its work slot.
  function T.transferTo(slot, count)
    if type(slot) ~= "number" or slot < 1 or slot > 16 then
      error("bad argument #1 (slot out of range)", 2)
    end
    local src = t.inv[t.sel]
    if not src or src.count < 1 then return false end
    if slot == t.sel then return true end
    local n = math.min(count or src.count, src.count)
    local dst = t.inv[slot]
    if dst then
      if dst.id ~= src.id then return false end -- can't stack different items
      dst.count = dst.count + n
    else
      t.inv[slot] = { id = src.id, count = n, components = src.components,
        onUse = src.onUse, makeBlock = src.makeBlock, cropId = src.cropId,
        displayName = src.displayName, damage = src.damage, maxDamage = src.maxDamage }
    end
    src.count = src.count - n
    if src.count <= 0 then t.inv[t.sel] = nil end
    return true
  end

  return T
end

-- --------------------------------------------------------- sandbox builder

local function buildPeripheralApi(env)
  local P = {}

  local SIDES = { top = true, bottom = true, front = true,
    back = true, left = true, right = true }

  local function sideEntry(name)
    if env.sideAttach and SIDES[name] then return env.sideAttach[name] end
    return nil
  end

  local function entryFor(name)
    local e = env.periph[name]
    if e and e.attached then return e end
    return sideEntry(name)
  end

  function P.getNames()
    local out = {}
    for _, name in ipairs(env.periphOrder) do
      if env.periph[name].attached then out[#out + 1] = name end
    end
    if env.sideAttach then
      for _, side in ipairs(SIDE_NAMES) do
        if env.sideAttach[side] then out[#out + 1] = side end
      end
    end
    return out
  end

  function P.isPresent(name) return entryFor(name) ~= nil end

  function P.getType(p)
    if type(p) == "table" then
      local mt = getmetatable(p)
      if not mt or mt.__name ~= "peripheral" then
        error("bad argument #1 (table is not a peripheral)", 2)
      end
      return unpack(mt.types)
    end
    local e = entryFor(p)
    if not e then return nil end
    return unpack(e.types)
  end

  function P.hasType(p, ty)
    if type(p) == "table" then
      local mt = getmetatable(p)
      return mt and mt.typeSet and mt.typeSet[ty] ~= nil or nil
    end
    local e = entryFor(p)
    if not e then return nil end
    return e.typeSet[ty] == true
  end

  function P.getMethods(name)
    local e = entryFor(name)
    if not e then return nil end
    local out = {}
    for m in pairs(e.methods) do out[#out + 1] = m end
    table.sort(out)
    return out
  end

  function P.call(name, method, ...)
    local e = entryFor(name)
    if not e then
      error("No peripheral attached with name " .. tostring(name), 2)
    end
    local fn = e.methods[method]
    if not fn then
      error("No such method " .. tostring(method), 2)
    end
    return fn(...)
  end

  function P.wrap(name)
    local e = env.periph[name]
    if (not e or not e.attached) and sideEntry(name) then
      -- Side-attached (turtle) peripheral: closures resolve the CURRENT
      -- attachment at call time, so a stale handle silently returns nil
      -- from every method (never errors) and transparently rebinds after
      -- a re-place — C3 [SOURCE], peripheral.lua:255-268,284-287.
      e = sideEntry(name)
      local wrapped = {}
      for m in pairs(e.methods) do
        wrapped[m] = function(...)
          local cur = sideEntry(name)
          if not cur then return nil end
          local fn = cur.methods[m]
          if not fn then return nil end
          return fn(...)
        end
      end
      local types = {}
      for i, ty in ipairs(e.types) do types[i] = ty end
      for ty in pairs(e.typeSet) do types[ty] = true end
      return setmetatable(wrapped,
        { __name = "peripheral", name = name, type = e.types[1],
          types = types, typeSet = e.typeSet })
    end
    if not e or not e.attached then return nil end
    local wrapped = {}
    for m in pairs(e.methods) do
      wrapped[m] = function(...) return P.call(name, m, ...) end
    end
    -- CC tags wrapped peripherals with this metatable shape
    -- (see rom/apis/peripheral.lua)
    local types = {}
    for i, ty in ipairs(e.types) do types[i] = ty end
    for ty in pairs(e.typeSet) do types[ty] = true end
    return setmetatable(wrapped,
      { __name = "peripheral", name = name, type = e.types[1],
        types = types, typeSet = e.typeSet })
  end

  function P.find(ty, filter)
    local found = {}
    for _, name in ipairs(env.periphOrder) do
      local e = env.periph[name]
      if e.attached and e.typeSet[ty] then
        local w = P.wrap(name)
        if not filter or filter(name, w) then found[#found + 1] = w end
      end
    end
    return unpack(found)
  end

  return P
end

local function buildFsApi(env)
  local FS = {}
  function FS.exists(path) return env.files[path] ~= nil end
  function FS.open(path, mode)
    if mode == "r" then
      local data = env.files[path]
      if not data then return nil, "No such file" end
      local pos = 1
      return {
        readAll = function() local d = data:sub(pos); pos = #data + 1; return d end,
        readLine = function()
          if pos > #data then return nil end
          local nl = data:find("\n", pos, true)
          local line
          if nl then line = data:sub(pos, nl - 1); pos = nl + 1
          else line = data:sub(pos); pos = #data + 1 end
          return line
        end,
        close = function() end,
      }
    elseif mode == "w" or mode == "a" then
      local parts = { mode == "a" and env.files[path] or nil }
      return {
        write = function(s) parts[#parts + 1] = tostring(s) end,
        writeLine = function(s) parts[#parts + 1] = tostring(s) .. "\n" end,
        flush = function() env.files[path] = table.concat(parts) end,
        close = function() env.files[path] = table.concat(parts) end,
      }
    end
    return nil, "Unsupported mode"
  end
  function FS.delete(path) env.files[path] = nil end
  function FS.combine(a, b)
    return (a .. "/" .. b):gsub("//+", "/"):gsub("^/", "")
  end
  return FS
end

local function buildSandbox(env)
  local G = {}
  G._G = G
  G._HOST = env.host
  G._CC_DEFAULT_SETTINGS = ""

  -- plain Lua stdlib (shared with host; CC programs see the same)
  for _, k in ipairs{
    "assert", "error", "ipairs", "next", "pairs", "pcall", "select",
    "setmetatable", "getmetatable", "rawget", "rawset", "rawequal",
    "rawlen", "tonumber", "tostring", "type", "xpcall",
  } do G[k] = _G[k] end
  G.string, G.math, G.table, G.coroutine = string, math, table, coroutine
  G.unpack = table.unpack
  -- like CC, load() defaults the chunk's environment to the sandbox
  G.load = function(chunk, name, mode, genv)
    return load(chunk, name, mode, genv or G)
  end

  G.colors = makeColorsTable()
  G.colours = G.colors
  G.peripheral = buildPeripheralApi(env)
  G.fs = buildFsApi(env)

  -- ------------------------------------------------------------- term
  local current = env.termApi
  local native = env.termApi
  local term = {}
  local TERM_METHODS = {
    "write", "blit", "clear", "clearLine", "getCursorPos", "setCursorPos",
    "setCursorBlink", "getCursorBlink", "getSize", "scroll",
    "isColor", "isColour", "setTextColor", "setTextColour",
    "getTextColor", "getTextColour", "setBackgroundColor",
    "setBackgroundColour", "getBackgroundColor", "getBackgroundColour",
  }
  for _, m in ipairs(TERM_METHODS) do
    term[m] = function(...) return current[m](...) end
  end
  function term.redirect(target)
    if type(target) ~= "table" then
      error("bad argument #1 (table expected)", 2)
    end
    local old = current
    current = target
    return old
  end
  function term.current() return current end
  function term.native() return native end
  G.term = term

  -- --------------------------------------------------------------- os
  local osT = {}
  function osT.version() return "CraftOS 1.9" end
  function osT.getComputerID() return 0 end
  function osT.getComputerLabel() return "fluxtest" end
  function osT.clock() return env.ticks * TICK end
  function osT.time() return 12.0 end
  function osT.day() return 1 end
  function osT.epoch(spec)
    return 1765432100000 + env.ticks * TICK * 1000
  end
  function osT.startTimer(t)
    if type(t) ~= "number" then
      error("bad argument #1 (number expected)", 2)
    end
    local id = env.nextTimer
    env.nextTimer = env.nextTimer + 1
    env.timers[id] = env.ticks + math.max(1, math.floor(t / TICK + 0.5))
    return id
  end
  function osT.cancelTimer(id) env.timers[id] = nil end
  function osT.queueEvent(name, ...)
    if type(name) ~= "string" then
      error("bad argument #1 (string expected)", 2)
    end
    env:push(name, ...)
  end
  -- bios.lua faithful (vendor/CC-Tweaked .../bios.lua:37-56)
  function osT.pullEventRaw(filter) return coroutine.yield(filter) end
  function osT.pullEvent(filter)
    local eventData = table.pack(osT.pullEventRaw(filter))
    if eventData[1] == "terminate" then
      error("Terminated", 0)
    end
    return unpack(eventData, 1, eventData.n)
  end
  -- reboot and shutdown both end the run with reason "shutdown" (the
  -- pre-sled suite pins that); res.reboot distinguishes them (§11.4)
  function osT.shutdown() error("__shutdown__", 0) end
  function osT.reboot() error("__reboot__", 0) end
  G.os = osT

  function G.sleep(t)
    local timer = osT.startTimer(t or 0)
    repeat
      local _, param = osT.pullEvent("timer")
    until param == timer
  end
  osT.sleep = G.sleep

  if env.turtle then
    G.turtle = buildTurtleApi(env, osT)
  end

  -- ------------------------------------------------------------ rednet
  -- Outbound traffic is logged to env.rednetSent for assertions; inbound
  -- arrives as scenario-scripted "rednet_message" events, exactly the
  -- shape the real bios rednet daemon produces.
  local rednet = {}
  local function anyOpen() return next(env.rednetOpen) ~= nil end
  function rednet.open(side)
    if not G.peripheral.hasType(side, "modem") then
      error("bad argument #1 (no such modem: " .. tostring(side) .. ")", 2)
    end
    env.rednetOpen[side] = true
  end
  function rednet.close(side)
    if side then env.rednetOpen[side] = nil
    else env.rednetOpen = {} end
  end
  function rednet.isOpen(side)
    if side then return env.rednetOpen[side] == true end
    return anyOpen()
  end
  function rednet.broadcast(message, protocol)
    if not anyOpen() then return false end
    env.rednetSent[#env.rednetSent + 1] = {
      kind = "broadcast", message = message,
      protocol = protocol, t = env.ticks * TICK,
    }
    return true
  end
  function rednet.send(id, message, protocol)
    if not anyOpen() then return false end
    env.rednetSent[#env.rednetSent + 1] = {
      kind = "send", to = id, message = message,
      protocol = protocol, t = env.ticks * TICK,
    }
    return true
  end
  function rednet.receive(protocol, timeout)
    local timer = timeout and osT.startTimer(timeout)
    while true do
      local ev = table.pack(osT.pullEvent())
      if ev[1] == "rednet_message" then
        if protocol == nil or ev[4] == protocol then
          return ev[2], ev[3], ev[4]
        end
      elseif ev[1] == "timer" and ev[2] == timer then
        return nil
      end
    end
  end
  G.rednet = rednet

  -- -------------------------------------------------------------- http
  G.http = {
    get = function(url)
      -- the mock ignores query strings (cache-busters etc), like a server
      -- that serves the same content regardless of params
      url = url:gsub("%?.*$", "")
      local body = env.httpFiles[url]
      if not body then
        return nil, "Could not connect (mock has no " .. tostring(url) .. ")"
      end
      return {
        readAll = function() return body end,
        getResponseCode = function() return 200 end,
        close = function() end,
      }
    end,
  }

  -- ------------------------------------------------------------- shell
  -- Minimal shell for programs that chain into others (sled/sledctl run
  -- the standard updater). Resolves the virtual fs first, then
  -- programs/<name>.lua on disk. Reboot/shutdown sentinels propagate.
  G.shell = {
    run = function(name, ...)
      local fwd = { ... }
      local src = env.files[name] or env.files[name .. ".lua"]
      if not src then
        local f = io.open("programs/" .. name .. ".lua", "r")
        if f then
          src = f:read("*a")
          f:close()
        end
      end
      if not src then return false end
      local chunk, err = load(src, "@" .. name, "t", G)
      if not chunk then error(err, 0) end
      chunk(table.unpack(fwd))
      return true
    end,
  }

  -- bios.lua faithful write/print (vendor/CC-Tweaked .../bios.lua:58-145)
  function G.write(sText)
    local w, h = term.getSize()
    local x, y = term.getCursorPos()
    local nLinesPrinted = 0
    local function newLine()
      if y + 1 <= h then
        term.setCursorPos(1, y + 1)
      else
        term.setCursorPos(1, h)
        term.scroll(1)
      end
      x, y = term.getCursorPos()
      nLinesPrinted = nLinesPrinted + 1
    end
    sText = tostring(sText)
    while #sText > 0 do
      local whitespace = string.match(sText, "^[ \t]+")
      if whitespace then
        term.write(whitespace)
        x, y = term.getCursorPos()
        sText = string.sub(sText, #whitespace + 1)
      end
      local newline = string.match(sText, "^\n")
      if newline then
        newLine()
        sText = string.sub(sText, 2)
      end
      local text = string.match(sText, "^[^ \t\n]+")
      if text then
        sText = string.sub(sText, #text + 1)
        if #text > w then
          while #text > 0 do
            if x > w then newLine() end
            term.write(text)
            text = string.sub(text, w - x + 2)
            x, y = term.getCursorPos()
          end
        else
          if x + #text - 1 > w then newLine() end
          term.write(text)
          x, y = term.getCursorPos()
        end
      end
    end
    return nLinesPrinted
  end

  function G.print(...)
    local nLinesPrinted = 0
    local nLimit = select("#", ...)
    for n = 1, nLimit do
      local s = tostring(select(n, ...))
      if n < nLimit then s = s .. "\t" end
      nLinesPrinted = nLinesPrinted + G.write(s)
    end
    return nLinesPrinted + G.write("\n")
  end

  function G.printError(...)
    local old
    if term.isColour() then
      old = term.getTextColour()
      term.setTextColour(G.colors.red)
    end
    G.print(...)
    if term.isColour() then term.setTextColour(old) end
  end

  return G
end

-- -------------------------------------------------------------- event pump

-- Pop the next deliverable event, advancing virtual time when the queue is
-- empty. Returns event tuple, or nil + stop reason.
function Env:nextEvent(maxTick)
  for _ = 1, 100000 do
    if #self.queue > 0 then
      return table.remove(self.queue, 1)
    end
    -- earliest timer or scheduled item
    local bestTick, bestKind, bestKey
    for id, at in pairs(self.timers) do
      if not bestTick or at < bestTick then bestTick, bestKind, bestKey = at, "timer", id end
    end
    for i, item in ipairs(self.scheduled) do
      if not bestTick or item.atTick < bestTick
        or (item.atTick == bestTick and bestKind == "timer") then
        -- scheduled scenario items win ties so detach-then-render order is stable
        bestTick, bestKind, bestKey = item.atTick, "scheduled", i
      end
    end
    if not bestTick then return nil, "deadlock" end
    if bestTick > maxTick then return nil, "timeout" end
    self.ticks = math.max(self.ticks, bestTick)
    if bestKind == "timer" then
      self.timers[bestKey] = nil
      return table.pack("timer", bestKey)
    else
      local item = table.remove(self.scheduled, bestKey)
      if item.fn then
        item.fn(self)
        if self.abort then return nil, self.abort end
      else
        self:push(unpack(item.ev))
      end
    end
  end
  return nil, "livelock"
end

-- ---------------------------------------------------------------------- run

function Env:run(path, args, opts)
  opts = opts or {}
  -- maxTime is RELATIVE to the persistent virtual clock so multi-boot
  -- scenarios can call run() repeatedly (§11.5)
  local maxTick = self.ticks + toTicks(opts.maxTime or 10)
  args = args or {}

  -- fresh boot: real CC drops the event queue and all timers (C4); the
  -- scenario script (self.scheduled) survives — it is the test's world,
  -- not the computer's state. Peripherals present at boot are visible
  -- immediately, with no attach events.
  self.queue = {}
  self.timers = {}
  self.abort = nil
  if self.turtle then
    for _, side in ipairs({ "top", "bottom", "front", "back", "left", "right" }) do
      self.sideAttach[side] = self:computeSidePeriph(side)
    end
  end

  local src
  if opts.fromVirtualFs then
    -- boot from the in-memory fs (e.g. a startup.lua an installer wrote);
    -- part of the multi-boot driver (SLED-DESIGN §11.5)
    src = self.files[path]
    if not src then error("cannot open program (virtual): " .. path, 2) end
  else
    local f = io.open(path, "r")
    if not f then error("cannot open program: " .. path, 2) end
    src = f:read("*a")
    f:close()
  end

  local G = buildSandbox(self)
  local chunkName = "@" .. path:match("[^/]+$")
  local chunk, err = load(src, chunkName, "t", G)
  if not chunk then
    return { reason = "compile_error", err = err }
  end

  local co = coroutine.create(chunk)
  local resumeWith = args

  for _ = 1, 200000 do
    local ok, filter = coroutine.resume(co, unpack(resumeWith, 1, resumeWith.n or #resumeWith))
    if not ok then
      if filter == "__shutdown__" then
        return { reason = "shutdown" }
      end
      if filter == "__reboot__" then
        return { reason = "shutdown", reboot = true }
      end
      return { reason = "error", err = filter }
    end
    if coroutine.status(co) == "dead" then
      return { reason = "done" }
    end
    -- program yielded a pullEvent filter; find an event it will accept
    local ev, stop
    repeat
      ev, stop = self:nextEvent(maxTick)
      if not ev then return { reason = stop } end
    until filter == nil or ev[1] == filter or ev[1] == "terminate"
    resumeWith = ev
  end
  return { reason = "livelock" }
end

return M
