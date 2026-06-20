--[[
mesensor.lua - ME network telemetry sensor (ATM10 / CC:Tweaked)

Sits next to (or on the wired network of) an Advanced Peripherals ME
Bridge and publishes storage + crafting stats to the telemetry mesh every
few seconds: { v, source = "me", tick, data } on protocol "telemetry".
fluxwall picks it up as its own page automatically.

data fields: usedBytes, totalBytes, availBytes (item storage cells),
cpus / cpusBusy (crafting CPUs), aeUse (avg AE/t drawn by the grid).

Usage: mesensor [sourceName]   -- default source name "me"
]]

local REFRESH  = 2
local PROTOCOL = "telemetry"

local args = { ... }
local SOURCE = args[1] or "me"

-- This AE computer already has the ME Bridge, so it also reads the seven
-- tracked Mekanism chemicals off the same bridge and publishes their
-- production balance as a SECOND telemetry source, "chem" (chemwall renders
-- it). Net rate = change in stored amount over CHEM_WINDOW seconds, in mB/t;
-- a chemical absent from the network reads 0. Edit TRACK to change the set.
local CHEM_SOURCE = "chem"
local CHEM_WINDOW = 10
local TRACK = {
  "mekanism:oxygen",
  "mekanism:hydrogen",
  "mekanism:chlorine",
  "mekanism:hydrogen_chloride",
  "mekanism:sulfur_dioxide",
  "mekanism:sulfur_trioxide",
  "mekanism:sulfuric_acid",
}

local function fmt(n)
  if type(n) ~= "number" then return "?" end
  local neg = n < 0
  n = math.abs(n)
  local units = { "", "k", "M", "G", "T", "P" }
  local i = 1
  while n >= 1000 and i < #units do
    n = n / 1000
    i = i + 1
  end
  local s
  if i == 1 then
    s = ("%d"):format(math.floor(n + 0.5))
  else
    s = ("%.2f%s"):format(n, units[i])
  end
  if neg then s = "-" .. s end
  return s
end

local function openModems()
  local opened = false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType and peripheral.hasType(name, "modem") then
      if pcall(rednet.open, name) then opened = true end
    end
  end
  return opened
end

local function findBridge()
  for _, name in ipairs(peripheral.getNames()) do
    for _, ty in ipairs({ peripheral.getType(name) }) do
      if ty:lower():find("bridge", 1, true) then
        return name, peripheral.wrap(name)
      end
    end
  end
end

local bridgeName, bridge = findBridge()
if not bridge then
  print("No ME bridge found.")
  print("Place this computer next to an ME Bridge")
  print("(or join them with wired modems) and re-run.")
  return
end
if not openModems() then
  print("No modem found - attach a wireless or ender")
  print("modem so the mesh can hear this sensor.")
  return
end

local data = {}

-- ------------------------------------------------------------- chemicals

-- "mekanism:sulfur_dioxide" -> "Sulfur Dioxide" (fallback name when a chemical
-- is absent from the network so the bridge gives us no displayName)
local function prettify(id)
  local base = tostring(id):gsub("^.-:", ""):gsub("_", " ")
  if base == "" then return tostring(id) end
  return (base:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b:lower() end))
end

-- per-chemical sliding window of { t, c } samples feeding the net rate
local chemWindows = {}
local chemStarted

local function pushChemRate(id, amount, now)
  local w = chemWindows[id]
  if not w then w = {}; chemWindows[id] = w end
  w[#w + 1] = { t = now, c = amount }
  while #w > 1 and w[1].t < now - CHEM_WINDOW do table.remove(w, 1) end
  local first, last = w[1], w[#w]
  if #w >= 2 and last.t > first.t then
    return (last.c - first.c) / ((last.t - first.t) * 20)
  end
  return nil
end

-- publish source "chem": the seven tracked chemicals with amount + net rate,
-- plus pooled chemical-cell storage (bytes). If the bridge read FAILS (errors,
-- or returns a non-table because Applied Mekanistics isn't loaded), we skip the
-- publish entirely rather than fabricate a screen of zeros and fake deficits.
local function sampleChem()
  if not bridge then return end
  local ok, chems = pcall(bridge.getChemicals)
  if not ok or type(chems) ~= "table" then return end

  local present = {}
  for _, c in ipairs(chems) do
    if type(c) == "table" and type(c.name) == "string" then present[c.name] = c end
  end

  local now = os.clock()
  chemStarted = chemStarted or now
  local out = {}
  for _, id in ipairs(TRACK) do
    local c = present[id]
    local amount = c and tonumber(c.count) or 0   -- absent -> 0, never an error
    out[#out + 1] = {
      id = id, label = (c and c.displayName) or prettify(id),
      amount = amount, rate = pushChemRate(id, amount, now),
    }
  end

  local okT, total = pcall(bridge.getTotalChemicalStorage)
  local okU, used = pcall(bridge.getUsedChemicalStorage)
  pcall(rednet.broadcast, { v = 1, source = CHEM_SOURCE, tick = now, data = {
    chems = out,
    totalBytes = okT and tonumber(total) or nil,
    usedBytes = okU and tonumber(used) or nil,
    up = now - chemStarted,
  } }, PROTOCOL)
end

local function sample()
  -- the bridge can vanish (chunk unload, broken cable, detach); the timer keeps
  -- firing, so bail rather than index a nil bridge until it is re-found
  if not bridge then return end
  local ok
  local used, total, avail, use, cpus
  ok, used = pcall(bridge.getUsedItemStorage)
  data.usedBytes = ok and tonumber(used) or nil
  ok, total = pcall(bridge.getTotalItemStorage)
  data.totalBytes = ok and tonumber(total) or nil
  ok, avail = pcall(bridge.getAvailableItemStorage)
  data.availBytes = ok and tonumber(avail) or nil
  ok, use = pcall(bridge.getEnergyUsage)
  data.aeUse = ok and tonumber(use) or nil
  ok, cpus = pcall(bridge.getCraftingCPUs)
  if ok and type(cpus) == "table" then
    data.cpus = #cpus
    local busy = 0
    for _, cpu in ipairs(cpus) do
      if type(cpu) == "table" and cpu.isBusy then busy = busy + 1 end
    end
    data.cpusBusy = busy
  else
    data.cpus, data.cpusBusy = nil, nil
  end

  pcall(rednet.broadcast,
    { v = 1, source = SOURCE, tick = os.clock(), data = data }, PROTOCOL)

  -- ...and the chemical balance off the same bridge, as source "chem"
  sampleChem()
end

local function render()
  local t = term.current()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setCursorPos(1, 1)
  if t.isColor and t.isColor() then t.setTextColor(colors.yellow) end
  t.write("mesensor -> '" .. SOURCE .. "'")
  if t.isColor and t.isColor() then t.setTextColor(colors.white) end
  t.setCursorPos(1, 2)
  t.write("Bridge: " .. tostring(bridgeName))
  t.setCursorPos(1, 4)
  t.write("Storage: " .. fmt(data.usedBytes) .. " / "
    .. fmt(data.totalBytes) .. " B")
  t.setCursorPos(1, 5)
  t.write("CPUs:    " .. tostring(data.cpusBusy or "?") .. "/"
    .. tostring(data.cpus or "?") .. " busy")
  t.setCursorPos(1, 6)
  t.write("AE use:  " .. fmt(data.aeUse) .. "/t")
  t.setCursorPos(1, 8)
  if t.isColor and t.isColor() then t.setTextColor(colors.gray) end
  t.write("[q] quit")
  if t.isColor and t.isColor() then t.setTextColor(colors.white) end
end

sample()
render()

-- ------------------------------------------------------- base control
-- token-gated "update" pushed by `update-all` / the historian's [u]: ack,
-- hand the terminal back, then run the standard updater (download + reboot
-- into our role). Sleds keep their own "sledctl" channel.
local CTL_PROTOCOL = "basectl"
local CTL_TOKEN    = "flux"  -- courtesy lock, not cryptography

local function handleCtl(msg)
  if type(msg) ~= "table" or msg.token ~= CTL_TOKEN then return end
  if msg.cmd == "update" then
    pcall(rednet.broadcast, { ack = true, id = os.getComputerID(),
      label = os.getComputerLabel() }, CTL_PROTOCOL)
    pcall(function() term.redirect(term.native()) end)
    -- loud push -> leave the announce breadcrumb (fromall); quiet push -> not
    if shell and shell.run then
      if msg.loud then shell.run("update", "fromall") else shell.run("update") end
    end
  elseif msg.cmd == "version?" then
    -- a version census: reply with the version update.lua recorded for us
    local v
    local vf = fs.open(".fluxversion", "r")
    if vf then v = (vf.readLine() or ""):gsub("%s+", ""); vf.close() end
    pcall(rednet.broadcast, { version = v or "?", id = os.getComputerID(),
      label = os.getComputerLabel() }, CTL_PROTOCOL)
  end
end

local timer = os.startTimer(REFRESH)
while true do
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" or (ev[1] == "char" and ev[2] == "q") then
    break
  elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
    and type(ev[3]) == "table" then
    handleCtl(ev[3])
  elseif ev[1] == "timer" and ev[2] == timer then
    sample()
    render()
    timer = os.startTimer(REFRESH)
  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    openModems()
    bridgeName, bridge = findBridge()
    if bridge then
      sample()
      render()
    end
  end
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
print("mesensor stopped.")
