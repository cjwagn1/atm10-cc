--[[
sledctl.lua - Project Sled fleet console (ATM10 / CC:Tweaked)

An advanced computer at base that listens to the telemetry mesh like any
client and renders a compact status table for every `sled*` source:
state, step, stations completed, fuel, last-heard age, and the RECOVER
reason. Press `u` to broadcast a token-gated `update` command that makes
every sled (and this console) pull the latest release via the standard
wget-based updater and reboot — rednet carries only the COMMAND; file
transfer stays HTTP-from-GitHub (AM-5).

The shared token lives in sledctl.conf (`return { token = "..." }`) and in
each sled's sled.conf. It is a courtesy lock against accidental commands
from friends on the shared server, not cryptography.
]]

local PROTOCOL = "telemetry"
local CTL_PROTOCOL = "sledctl"
local REFRESH = 1      -- seconds between repaints
local STALE_AFTER = 60 -- matches the historian's silence rule (E2)

local function loadConf()
  local f = fs.open("sledctl.conf", "r")
  if not f then return {} end
  local txt = f.readAll()
  f.close()
  local chunk = load(txt, "=sledctl.conf", "t", {})
  if not chunk then return {} end
  local ok, conf = pcall(chunk)
  if not ok or type(conf) ~= "table" then return {} end
  return conf
end

local cfg = loadConf()

local function fmt(n)
  if type(n) ~= "number" then return "-" end
  local neg = n < 0
  n = math.abs(n)
  local units = { "", "k", "M", "G" }
  local i = 1
  while n >= 1000 and i < #units do
    n = n / 1000
    i = i + 1
  end
  local s = i == 1 and ("%d"):format(math.floor(n + 0.5))
    or ("%.2f%s"):format(n, units[i])
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

local fleet = {} -- name -> { d = data, lastSeen = clock }
local order = {}
local status = "listening"

local function rebuildOrder()
  order = {}
  for name in pairs(fleet) do order[#order + 1] = name end
  table.sort(order)
end

local function render()
  local t = term.current()
  local w = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setCursorPos(1, 1)
  if t.isColor and t.isColor() then t.setTextColor(colors.yellow) end
  t.write("SLED FLEET")
  if t.isColor and t.isColor() then t.setTextColor(colors.gray) end
  t.setCursorPos(math.max(1, w - 21), 1)
  t.write("[u] update  [q] quit")
  if t.isColor and t.isColor() then t.setTextColor(colors.lightGray) end
  t.setCursorPos(1, 3)
  t.write(("%-8s%-9s%-14s%-5s%-8s%-5s%s"):format(
    "name", "state", "step", "hops", "fuel", "age", "err"))
  local y = 4
  for _, name in ipairs(order) do
    local s = fleet[name]
    local d = s.d
    local age = math.floor(os.clock() - s.lastSeen)
    t.setCursorPos(1, y)
    if t.isColor and t.isColor() then
      if age > STALE_AFTER then t.setTextColor(colors.gray)
      elseif d.state == "RECOVER" then t.setTextColor(colors.red)
      elseif d.state == "RELOCATE" then t.setTextColor(colors.yellow)
      else t.setTextColor(colors.lime) end
    end
    t.write(("%-8s%-9s%-14s%-5s%-8s%-5s%s"):format(
      name:sub(1, 7), tostring(d.state or "?"):sub(1, 8),
      tostring(d.step or ""):sub(1, 13), fmt(d.hops),
      fmt(d.fuel), age .. "s", tostring(d.err or "-")))
    y = y + 1
  end
  if #order == 0 then
    t.setCursorPos(1, 4)
    if t.isColor and t.isColor() then t.setTextColor(colors.gray) end
    t.write("waiting for sled telemetry...")
  end
  t.setCursorPos(1, y + 1)
  if t.isColor and t.isColor() then t.setTextColor(colors.gray) end
  t.write(status)
  if t.isColor and t.isColor() then t.setTextColor(colors.white) end
end

local function runUpdate()
  status = "updating..."
  render()
  shell.run("update") -- reboots on success
  status = "update failed - check the manifest URL"
  render()
end

local function broadcastUpdate()
  if not cfg.token then
    status = "no token in sledctl.conf - update command disabled"
    return
  end
  -- command goes over rednet; every sled verifies the token and runs the
  -- standard wget-based updater itself (AM-5)
  pcall(rednet.broadcast, { cmd = "update", token = cfg.token }, CTL_PROTOCOL)
  status = "update broadcast sent - updating self next"
  render()
  runUpdate()
end

if not openModems() then
  print("No modem found - attach a wireless or ender")
  print("modem so sledctl can hear the fleet.")
  return
end

render()
local timer = os.startTimer(REFRESH)
while true do
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" or (ev[1] == "char" and ev[2] == "q") then
    break
  elseif ev[1] == "char" and ev[2] == "u" then
    broadcastUpdate()
  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL
    and type(ev[3]) == "table" then
    local m = ev[3]
    if type(m.source) == "string" and m.source:match("^sled")
      and type(m.data) == "table" then
      if not fleet[m.source] then
        fleet[m.source] = {}
        rebuildOrder()
      end
      fleet[m.source].d = m.data
      fleet[m.source].lastSeen = os.clock()
      render()
    end
  elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
    and type(ev[3]) == "table" then
    -- another console pushed an update: join in (same token gate)
    if cfg.token and ev[3].token == cfg.token and ev[3].cmd == "update" then
      runUpdate()
    end
  elseif ev[1] == "timer" and ev[2] == timer then
    render()
    timer = os.startTimer(REFRESH)
  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    openModems()
    render()
  end
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
print("sledctl stopped.")
