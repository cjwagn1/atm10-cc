--[[
fluxdash.lua - AppliedFlux FE dashboard for ATM10 (CC:Tweaked)

Reads the FE stored in your ME network's flux cells through the
Flux Accessor's energy capability, plus optional AE network stats
via an Advanced Peripherals ME Bridge.

Setup:
  1. Put a wired modem on the Flux Accessor, run networking cable
     to a wired modem on this computer, and right-click both modems
     so they show red rings (chat prints the peripheral name).
  2. (Optional) ME Bridge on your AE network, adjacent to this
     computer or on the same wired network.
  3. (Optional) attach a monitor for a wall display.

Usage:
  fluxdash scan   -- list every peripheral + its methods (run first)
  fluxdash        -- run the dashboard
]]

local REFRESH = 1            -- seconds per update
local INT_MAX = 2147483647   -- Forge Energy API int ceiling

local function fmt(n)
  if n == nil then return "?" end
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
    s = string.format("%d", n)
  else
    s = string.format("%.2f%s", n, units[i])
  end
  if neg then s = "-" .. s end
  return s
end

-- ------------------------------------------------------------- scan mode
local args = { ... }
if args[1] == "scan" then
  local names = peripheral.getNames()
  if #names == 0 then
    print("No peripherals found.")
    print("Attach wired modems and right-click them.")
    return
  end
  for _, name in ipairs(names) do
    print(("[%s] type: %s"):format(name, peripheral.getType(name) or "?"))
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and methods then
      print("   " .. table.concat(methods, ", "))
    end
  end
  return
end

-- -------------------------------------------------- find our peripherals
local function isEnergy(p)
  return p ~= nil and type(p.getEnergy) == "function"
      and type(p.getEnergyCapacity) == "function"
end

local function findFluxAccessor()
  local fallbackName, fallback
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if isEnergy(p) then
      if name:lower():find("flux") then
        return name, p
      end
      if not fallback then
        fallbackName, fallback = name, p
      end
    end
  end
  return fallbackName, fallback
end

local function findBridge()
  for _, name in ipairs(peripheral.getNames()) do
    local t = (peripheral.getType(name) or ""):lower()
    if t:find("bridge") then
      return name, peripheral.wrap(name)
    end
  end
end

local fluxName, flux = findFluxAccessor()
local bridgeName, bridge = findBridge()

local mon = peripheral.find("monitor")
if mon then
  mon.setTextScale(0.5)
  term.redirect(mon)
end

if not flux and not bridge then
  print("No FE peripheral or ME bridge found.")
  print("Run 'fluxdash scan' to see what's attached.")
  return
end

-- ---------------------------------------------------------------- helpers
local hasColor = term.isColor and term.isColor()

local function color(c)
  if hasColor then term.setTextColor(c) end
end

local function bar(frac, width)
  frac = math.max(0, math.min(1, frac or 0))
  local fill = math.floor(frac * width + 0.5)
  color(colors.lime)
  term.write(("#"):rep(fill))
  color(colors.gray)
  term.write(("-"):rep(width - fill))
  color(colors.white)
  print("")
end

-- ------------------------------------------------------------------- loop
local prevE, prevClock

while true do
  local e, cap
  if flux then
    local okE, vE = pcall(flux.getEnergy)
    local okC, vC = pcall(flux.getEnergyCapacity)
    if okE then e = vE end
    if okC then cap = vC end
  end

  local rate
  local now = os.clock()
  if e and prevE and prevClock and now > prevClock then
    rate = (e - prevE) / ((now - prevClock) * 20) -- FE per tick
  end

  if hasColor then term.setBackgroundColor(colors.black) end
  term.clear()
  term.setCursorPos(1, 1)
  color(colors.yellow)
  print("AppliedFlux / ME Energy")
  color(colors.white)

  if flux then
    print("Source: " .. tostring(fluxName))
    print("")
    color(colors.lime)
    print("Stored:   " .. fmt(e) .. " FE")
    color(colors.white)
    print("Capacity: " .. fmt(cap) .. " FE")
    if e and cap and cap > 0 then
      bar(e / cap, 26)
      print(string.format(" %.1f%%", (e / cap) * 100))
    end
    if rate then
      color(rate >= 0 and colors.lime or colors.red)
      print(("Rate:     %s%s FE/t"):format(rate >= 0 and "+" or "", fmt(rate)))
      color(colors.white)
    end
    if e == INT_MAX or cap == INT_MAX then
      color(colors.orange)
      print("")
      print("! FE capability clamped at 2.147G")
      print("  (real total is higher)")
      color(colors.white)
    end
  end

  if bridge then
    print("")
    color(colors.lightBlue)
    print("AE network (" .. tostring(bridgeName) .. ")")
    color(colors.white)
    local ok1, v1 = pcall(bridge.getEnergyStorage)
    local ok2, v2 = pcall(bridge.getMaxEnergyStorage)
    local ok3, v3 = pcall(bridge.getEnergyUsage)
    if ok1 and ok2 then
      print("Buffer: " .. fmt(v1) .. " / " .. fmt(v2))
    end
    if ok3 then
      print("Usage:  " .. fmt(v3) .. " /t")
    end
  end

  prevE, prevClock = e, now
  sleep(REFRESH)
end
