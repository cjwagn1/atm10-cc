--[[
console.lua - touch command panel for the base (ATM10 / CC:Tweaked)

An advanced computer wired to an advanced (touch) Monitor and a modem.
Right-click a button to fire a base-wide command:

  UPDATE ALL    push `update` to the whole stationary base (walls, dashes,
                ME sensor, historian); tap VERSIONS after to confirm
  VERSIONS      census every base computer and show the roll-call here
  UPDATE SLEDS  push `update` to the sled fleet (needs the sled token in
                sledctl.conf on this computer)

This is a controller: it sends commands and answers version censuses (so it
shows up in roll-calls), but it deliberately IGNORES `update` pushes itself -
a panel that reboots mid-tap is bad. Update it by hand with `update` on the
rare occasion its own code changes. Sleds keep their own "sledctl" channel.

Put the monitor above your base near the AE console and tap away.
]]

local CTL_PROTOCOL  = "basectl"
local CTL_TOKEN     = "flux"        -- courtesy lock, matches the base programs
local SLED_PROTOCOL = "sledctl"
local CENSUS_WINDOW = 3             -- seconds to gather version replies

-- optional sled token for the UPDATE SLEDS button (same file sledctl uses)
local sledToken
do
  local f = fs.open("sledctl.conf", "r")
  if f then
    local chunk = load(f.readLine() or "", "=sledctl.conf", "t", {})
    f.close()
    if chunk then
      local ok, c = pcall(chunk)
      if ok and type(c) == "table" then sledToken = c.token end
    end
  end
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

local function myVersion()
  local f = fs.open(".fluxversion", "r")
  if not f then return "?" end
  local v = (f.readLine() or ""):gsub("%s+", "")
  f.close()
  return v ~= "" and v or "?"
end

if not openModems() then
  print("No modem found - attach a wireless or ender")
  print("modem so the console can reach the base mesh.")
  return
end

local mon = peripheral.find("monitor")
if not mon then
  print("No monitor found - attach an Advanced Monitor")
  print("(touch) so this can be a button panel.")
  return
end
pcall(mon.setTextScale, 1)

local status = "ready - tap a command"

-- full-width buttons stacked top to bottom
local BTN_H = 3
local buttons = {
  { label = "UPDATE ALL" },
  { label = "VERSIONS" },
  { label = "UPDATE SLEDS" },
}
do
  local y = 2
  for _, b in ipairs(buttons) do
    b.y1, b.y2 = y, y + BTN_H - 1
    y = y + BTN_H + 1   -- one blank row between buttons
  end
end

local function draw()
  local w, h = mon.getSize()
  local can = mon.isColor and mon.isColor()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  for _, b in ipairs(buttons) do
    if can then mon.setBackgroundColor(colors.gray) end
    for row = b.y1, b.y2 do
      if row <= h then
        mon.setCursorPos(1, row)
        mon.write((" "):rep(w))
      end
    end
    local mid = math.floor((b.y1 + b.y2) / 2)
    if mid <= h then
      if can then mon.setTextColor(colors.white) end
      mon.setCursorPos(math.max(1, math.floor((w - #b.label) / 2) + 1), mid)
      mon.write(b.label)
    end
  end
  mon.setBackgroundColor(colors.black)
  if can then mon.setTextColor(colors.lightGray) end
  mon.setCursorPos(1, h)
  mon.write(status:sub(1, w))
  if can then mon.setTextColor(colors.white) end
end

-- ping every base computer for its version; return a sorted roll-call string
local function census()
  rednet.broadcast({ cmd = "version?", token = CTL_TOKEN }, CTL_PROTOCOL)
  local label = os.getComputerLabel() or "console"
  local seen, order = {}, { label .. " v" .. myVersion() }  -- include self
  seen[label] = true
  local deadline = os.clock() + CENSUS_WINDOW
  while true do
    local left = deadline - os.clock()
    if left <= 0 then break end
    local timer = os.startTimer(left)
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "terminate" then
      break
    elseif ev[1] == "timer" and ev[2] == timer then
      break
    elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
      and type(ev[3]) == "table" and ev[3].version ~= nil then
      local who = ev[3].label or ("id " .. tostring(ev[3].id))
      if not seen[who] then
        seen[who] = true
        order[#order + 1] = who .. " v" .. tostring(ev[3].version)
      end
    end
  end
  table.sort(order)
  return table.concat(order, ", ")
end

buttons[1].action = function()
  rednet.broadcast({ cmd = "update", token = CTL_TOKEN }, CTL_PROTOCOL)
  status = "update pushed - tap VERSIONS in a few sec to confirm"
end
buttons[2].action = function()
  status = "checking versions..."
  draw()
  status = census()
end
buttons[3].action = function()
  if not sledToken then
    status = "no sled token - add sledctl.conf to update sleds"
    return
  end
  rednet.broadcast({ cmd = "update", token = sledToken }, SLED_PROTOCOL)
  status = "sled update pushed"
end

local function hit(x, y)
  for _, b in ipairs(buttons) do
    if y >= b.y1 and y <= b.y2 then return b end
  end
end

-- answer version censuses so the console appears in roll-calls; ignore
-- `update` pushes (the console is the controller, updated by hand)
local function handleCtl(msg)
  if type(msg) ~= "table" or msg.token ~= CTL_TOKEN then return end
  if msg.cmd == "version?" then
    pcall(rednet.broadcast, { version = myVersion(), id = os.getComputerID(),
      label = os.getComputerLabel() }, CTL_PROTOCOL)
  end
end

draw()
while true do
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" or (ev[1] == "char" and ev[2] == "q") then
    break
  elseif ev[1] == "monitor_touch" then
    local b = hit(ev[3], ev[4])
    if b and b.action then
      b.action()
      draw()
    end
  elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
    and type(ev[3]) == "table" then
    handleCtl(ev[3])
  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    openModems()
    local m = peripheral.find("monitor")
    if m then mon = m; pcall(mon.setTextScale, 1); draw() end
  end
end

pcall(function()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  mon.setCursorPos(1, 1)
end)
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
print("console stopped.")
