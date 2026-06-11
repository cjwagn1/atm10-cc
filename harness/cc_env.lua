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
  self.advanced = opts.advanced ~= false
  self.strictColors = opts.strictColors or false
  -- exact string confirmed in-game on Carter's ATM10 v7.0 server
  self.host = opts.host or "ComputerCraft 1.117.1 (Minecraft 1.21.1)"
  local buf, t = newScreen(opts.termW or 51, opts.termH or 19,
    self.advanced, self.strictColors, "terminal")
  self.termBuf, self.termApi = buf, t
  self.monitors = {}         -- name -> buf (for assertions)
  return self
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

function Env:snapshotAt(seconds, key)
  self:scheduleAt(seconds, { fn = function()
    self.snapshots[key] = self:termText()
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
function Env:addMeBridge(name, o)
  return self:addPeripheral(name, { "me_bridge" }, {
    getStoredEnergy = function() return o.stored end,
    getEnergyCapacity = function() return o.max end,
    getEnergyUsage = function() return o.usage end,
    getAverageEnergyInput = function() return o.input or 0 end,
    isConnected = function() return true end,
    isOnline = function() return true end,
    getTotalItemStorage = function() return 0 end,
  })
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

-- --------------------------------------------------------- sandbox builder

local function buildPeripheralApi(env)
  local P = {}

  local function entryFor(name)
    local e = env.periph[name]
    if e and e.attached then return e end
    return nil
  end

  function P.getNames()
    local out = {}
    for _, name in ipairs(env.periphOrder) do
      if env.periph[name].attached then out[#out + 1] = name end
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
  function osT.shutdown() error("__shutdown__", 0) end
  osT.reboot = osT.shutdown
  G.os = osT

  function G.sleep(t)
    local timer = osT.startTimer(t or 0)
    repeat
      local _, param = osT.pullEvent("timer")
    until param == timer
  end
  osT.sleep = G.sleep

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
  local maxTick = toTicks(opts.maxTime or 10)
  args = args or {}

  local f = io.open(path, "r")
  if not f then error("cannot open program: " .. path, 2) end
  local src = f:read("*a")
  f:close()

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
