--[[
fluxwall.lua - wall display client for fluxdash (ATM10 / CC:Tweaked)

Runs on a computer placed behind/beside your monitor wall, far away from
the ME system. Listens for fluxdash broadcasts over rednet (wireless or
ender modem) and renders a big, auto-scaled energy display on every
attached monitor.

Setup:
  1. Build the monitor wall (advanced monitors); place this computer so it
     touches the array (hide it behind the wall), or wire it with modems.
  2. Attach a wireless or ender modem to this computer AND to the fluxdash
     computer. Ender modems work at any distance/dimension.
  3. Run fluxwall (the installer sets it as startup, so it survives
     restarts/chunk reloads).

Display states:
  - live readings with a spinner that ticks on every received update
  - "NO SIGNAL (Ns)" if nothing has been heard for 10s (fluxdash off,
    chunk unloaded, or out of modem range)
]]

local REFRESH     = 1      -- seconds between repaints / staleness checks
local STALE_AFTER = 10     -- seconds without a broadcast = NO SIGNAL
local PROTOCOL    = "fluxdash"
local MIN_W, MIN_H = 24, 7 -- smallest grid the layout needs; the
                           -- auto-scaler picks the biggest text that fits

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

local SCALES = { 5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5 }

local mons = {}
local function refreshMonitors()
  mons = { peripheral.find("monitor") }
  for _, m in ipairs(mons) do
    for _, s in ipairs(SCALES) do
      if pcall(m.setTextScale, s) then
        local w, h = m.getSize()
        if w >= MIN_W and h >= MIN_H then break end
      end
    end
  end
end

local state, lastSeen, msgCount
local SPIN = { "|", "/", "-", "\\" }

local function renderTarget(t, isTerm)
  local w, h = t.getSize()
  local can = t.isColor and t.isColor()
  local function c(col)
    if can then t.setTextColor(col) end
  end
  local function lineAt(y, txt)
    if y >= 1 and y <= h and txt and #txt > 0 then
      t.setCursorPos(1, y)
      t.write(txt:sub(1, w))
    end
  end

  t.setBackgroundColor(colors.black)
  t.clear()

  c(colors.yellow)
  lineAt(1, "ME FLUX ENERGY")
  if msgCount and msgCount > 0 then
    c(colors.gray)
    t.setCursorPos(w, 1)
    t.write(SPIN[msgCount % 4 + 1])
  end

  local age = lastSeen and (os.clock() - lastSeen) or nil

  if not state then
    c(colors.red)
    lineAt(3, "NO SIGNAL")
    c(colors.gray)
    lineAt(4, "waiting for fluxdash...")
  elseif age and age > STALE_AFTER then
    c(colors.red)
    lineAt(3, ("NO SIGNAL (%ds)"):format(age))
    c(colors.gray)
    lineAt(4, "last: " .. fmt(state.trueE or state.e) .. " FE")
  else
    local e = state.trueE or state.e
    local cap = state.trueE and state.trueCap or state.cap
    c(colors.lime)
    lineAt(3, fmt(e) .. " FE")
    c(colors.white)
    local pct = (e and cap and cap > 0) and (e / cap * 100) or nil
    lineAt(4, "of " .. fmt(cap) .. " FE"
      .. (pct and ("  (%.1f%%)"):format(pct) or ""))
    if pct then
      local bw = w - 2
      local fill = math.floor(math.max(0, math.min(1, e / cap)) * bw + 0.5)
      t.setCursorPos(2, 5)
      c(colors.lime)
      t.write(("#"):rep(fill))
      c(colors.gray)
      t.write(("-"):rep(bw - fill))
      c(colors.white)
    end
    if state.rate then
      c(state.rate >= 0 and colors.lime or colors.red)
      lineAt(6, ("%s%s FE/t"):format(
        state.rate >= 0 and "+" or "", fmt(state.rate)))
      c(colors.white)
    end
    if h >= 9 and state.ae and state.aeMax then
      c(colors.lightBlue)
      lineAt(8, ("AE %s/%s%s"):format(fmt(state.ae), fmt(state.aeMax),
        state.aeUse and ("  -" .. fmt(state.aeUse) .. "/t") or ""))
      c(colors.white)
    end
  end

  if isTerm then
    c(colors.gray)
    lineAt(h, "[q] quit")
    c(colors.white)
  end
end

local function render()
  pcall(renderTarget, term.current(), true)
  for i = #mons, 1, -1 do
    if not pcall(renderTarget, mons[i], false) then
      table.remove(mons, i)
    end
  end
end

-- ------------------------------------------------------------------ main

if not openModems() then
  print("No modem found.")
  print("Attach a wireless or ender modem so this")
  print("display can hear the fluxdash computer.")
  return
end

refreshMonitors()
msgCount = 0
render()

local timer = os.startTimer(REFRESH)
while true do
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" or (ev[1] == "char" and ev[2] == "q") then
    break
  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL
    and type(ev[3]) == "table" then
    state = ev[3]
    lastSeen = os.clock()
    msgCount = msgCount + 1
    render()
  elseif ev[1] == "timer" and ev[2] == timer then
    render()
    timer = os.startTimer(REFRESH)
  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    openModems()
    refreshMonitors()
    render()
  elseif ev[1] == "monitor_resize" then
    refreshMonitors()
    render()
  end
end

for _, m in ipairs(mons) do
  pcall(function()
    m.setBackgroundColor(colors.black)
    m.clear()
    m.setCursorPos(1, 1)
  end)
end
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
print("fluxwall stopped.")
