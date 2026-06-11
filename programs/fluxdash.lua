--[[
fluxdash.lua (v3) - AppliedFlux FE dashboard for ATM10 (CC:Tweaked)

Reads the FE stored in your ME network's flux cells. Two sources:
  1. BEST: an Advanced Peripherals Block Reader facing the ME Drive that
     holds the flux cells. Reads each cell's "appflux:fe_energy" component
     (a 64-bit value) straight from the drive's saved data - TRUE totals
     past the 2,147,483,647 FE int clamp, plus true capacity derived from
     the cell types. Verified in-game on extendedae:ex_drive.
  2. Fallback: the Flux Accessor's energy capability (generic
     "energy_storage" peripheral) - clamped at 2.147G FE.
Plus AE network stats via an Advanced Peripherals ME Bridge.

Verified against mod sources (ATM10 / MC 1.21.1):
  - AppFlux exposes ONLY the generic FE capability; readings saturate at
    2,147,483,647 FE (a single 4k flux cell already holds 4.29G, so the
    "clamped" banner is expected once your stockpile grows).
  - ME Bridge (Advanced Peripherals 0.7.62b) is peripheral type
    "me_bridge"; energy methods are getStoredEnergy / getEnergyCapacity /
    getEnergyUsage / getAverageEnergyInput and report AE units (1 AE = 2 FE).
    Note: that's the AE energy buffer (energy cells), not the flux cells.

Setup:
  1. Wired modem on the Flux Accessor, cable to a wired modem on this
     computer, right-click both modems (rings glow red).
  2. (Optional) ME Bridge touching the AE network and this computer or
     the same wired network.
  3. (Optional) one or more monitors for wall displays.
  4. (Recommended) Block Reader with its face touching each ME Drive that
     holds flux cells, attached to this computer or the wired network.

Usage:
  fluxdash scan          -- list peripherals + save report to fluxscan.txt
  fluxdash               -- run the dashboard (press q to quit)
  fluxdash <peripheral>  -- force a specific energy peripheral by name
]]

local REFRESH     = 1           -- seconds per update
local RATE_WINDOW = 10          -- seconds of samples for the FE/t rate
local BAR_WIDTH   = 26          -- max progress bar width
local MON_SCALE   = 0.5         -- text scale applied to monitors
local INT_MAX     = 2147483647  -- Forge Energy API int ceiling

local args = { ... }

-- --------------------------------------------------------------- format

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
    -- math.floor keeps this safe on every Lua version; plain %d on a
    -- fractional double errors on Lua 5.3+ (fine on CC's Cobalt, but
    -- there's no reason to depend on that)
    s = ("%d"):format(math.floor(n + 0.5))
  else
    s = ("%.2f%s"):format(n, units[i])
  end
  if neg then s = "-" .. s end
  return s
end

-- ------------------------------------------------------------ peripherals

local function isEnergyTable(p)
  return p ~= nil and type(p.getEnergy) == "function"
      and type(p.getEnergyCapacity) == "function"
end

-- Find an FE-capable peripheral. Prefers anything with "flux" or
-- "accessor" in the name (the AppFlux accessor shows up as
-- "appflux:flux_accessor_N"), else falls back to the first energy
-- peripheral found. A forced name skips auto-detection entirely.
local function locate(forced)
  if forced then
    if not peripheral.isPresent(forced) then
      return nil, nil, ("'%s' is not attached (check fluxdash scan)"):format(forced)
    end
    local p = peripheral.wrap(forced)
    if not isEnergyTable(p) then
      return nil, nil, ("'%s' has no getEnergy/getEnergyCapacity"):format(forced)
    end
    return forced, p
  end
  local fallbackName, fallbackP
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if isEnergyTable(p) then
      local l = name:lower()
      if l:find("flux", 1, true) or l:find("accessor", 1, true) then
        return name, p
      end
      if not fallbackName then fallbackName, fallbackP = name, p end
    end
  end
  return fallbackName, fallbackP
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

-- ------------------------------------------- true totals via block reader

local FE_PER_BYTE = 1048576 -- AppFlux default config (flux_cell.amount)
local CELL_BYTES = {
  ["1k"] = 1024, ["4k"] = 4096, ["16k"] = 16384, ["64k"] = 65536,
  ["256k"] = 262144, ["1m"] = 1048576, ["4m"] = 4194304,
  ["16m"] = 16777216, ["64m"] = 67108864, ["256m"] = 268435456,
}

-- "appflux:fe_64k_cell" -> 68,719,476,736 FE; nil for unknown ids
local function cellCapacity(id)
  if type(id) ~= "string" then return nil end
  local size = id:lower():match("(%d+[km])")
  local bytes = size and CELL_BYTES[size]
  return bytes and bytes * FE_PER_BYTE or nil
end

-- Walk a Block Reader dump summing every appflux fe_energy component,
-- shape-agnostic (works on ae2:drive, extendedae:ex_drive, ME chests...).
-- Tracks the nearest enclosing item id so capacity can be derived.
local function walkFlux(t, curId, acc, seen)
  if seen[t] then return end
  seen[t] = true
  if type(t.id) == "string" then curId = t.id end
  for k, v in pairs(t) do
    if type(v) == "table" then
      walkFlux(v, curId, acc, seen)
    elseif type(v) == "number"
      and tostring(k):lower():find("fe_energy", 1, true) then
      acc.e = acc.e + v
      acc.cells = acc.cells + 1
      local cap = cellCapacity(curId)
      if cap then acc.cap = acc.cap + cap end
    end
  end
end

-- ------------------------------------------------------------------ scan

local function scan()
  local out = {}
  local function emit(s)
    print(s)
    out[#out + 1] = s
  end
  emit("Host: " .. tostring(_HOST))
  local names = peripheral.getNames()
  if #names == 0 then
    emit("No peripherals found.")
    emit("Attach wired modems and right-click them.")
  end
  for _, name in ipairs(names) do
    emit(("[%s]"):format(name))
    emit("  types: " .. table.concat({ peripheral.getType(name) }, ", "))
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      emit("  methods: " .. table.concat(methods, ", "))
    end
    if peripheral.hasType and peripheral.hasType(name, "energy_storage") then
      local p = peripheral.wrap(name)
      local okE, e = pcall(p.getEnergy)
      local okC, cap = pcall(p.getEnergyCapacity)
      if okE and okC then
        emit(("  energy: %s / %s FE%s"):format(fmt(e), fmt(cap),
          (e == INT_MAX or cap == INT_MAX) and "  (clamped at int max)" or ""))
      end
    end
  end
  local ok, f = pcall(fs.open, "fluxscan.txt", "w")
  if ok and f then
    f.write(table.concat(out, "\n") .. "\n")
    f.close()
    print("Saved to fluxscan.txt (pastebin put fluxscan.txt to share)")
  end
end

-- ------------------------------------------------------------- dashboard

local forced = args[1]
if forced == "scan" then
  scan()
  return
end

local fluxName, flux, locateErr = locate(forced)
local bridgeName, bridge = findBridge()

if forced and not flux then
  print(locateErr)
  return
end
if not flux and not bridge and not peripheral.find("block_reader") then
  print("No energy peripheral, block reader or ME bridge found.")
  print("Run 'fluxdash scan' to see what's attached.")
  return
end

local mons = {}
local function refreshMonitors()
  mons = { peripheral.find("monitor") }
  for _, m in ipairs(mons) do
    pcall(m.setTextScale, MON_SCALE)
  end
end

local readers = {}
local function refreshReaders()
  readers = { peripheral.find("block_reader") }
end

-- open every modem so wall displays (fluxwall) can hear our broadcasts
local function openModems()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType and peripheral.hasType(name, "modem") then
      pcall(rednet.open, name)
    end
  end
end

local state = {}     -- e, cap, trueE, trueCap, cells, rate, ae, aeMax, ...
local samples = {}   -- { {t, e}, ... } over RATE_WINDOW for the rate
local lost = false   -- true while the energy source is detached
local rateSrc        -- which reading feeds the rate; reset window on switch

local function sample()
  if flux then
    local okE, e = pcall(flux.getEnergy)
    local okC, cap = pcall(flux.getEnergyCapacity)
    if okE and type(e) == "number" and okC and type(cap) == "number" then
      state.e, state.cap, lost = e, cap, false
    else
      lost = true
    end
  end

  -- true totals from block readers (immune to the int clamp)
  local acc = { e = 0, cap = 0, cells = 0 }
  for _, r in ipairs(readers) do
    local ok, data = pcall(r.getBlockData)
    if ok and type(data) == "table" then
      walkFlux(data, nil, acc, {})
    end
  end
  if acc.cells > 0 then
    state.trueE = acc.e
    state.trueCap = acc.cap > 0 and acc.cap or nil
    state.cells = acc.cells
  else
    state.trueE, state.trueCap, state.cells = nil, nil, nil
  end

  -- FE/t over a sliding window, preferring the un-clamped reading.
  -- Mixing sources across one window would spike the rate, so the
  -- window resets when the source changes.
  local src = state.trueE and "reader"
    or (flux and not lost and "accessor" or nil)
  local er = state.trueE or (not lost and state.e or nil)
  if src ~= rateSrc then
    samples = {}
    rateSrc = src
  end
  if er then
    local now = os.clock()
    samples[#samples + 1] = { t = now, e = er }
    while #samples > 1 and samples[1].t < now - RATE_WINDOW do
      table.remove(samples, 1)
    end
    local first, last = samples[1], samples[#samples]
    if #samples >= 2 and last.t > first.t then
      state.rate = (last.e - first.e) / ((last.t - first.t) * 20)
    end
  else
    state.rate = nil
  end

  if bridge then
    local ok1, ae = pcall(bridge.getStoredEnergy)
    local ok2, aeMax = pcall(bridge.getEnergyCapacity)
    local ok3, aeUse = pcall(bridge.getEnergyUsage)
    local ok4, aeIn = pcall(bridge.getAverageEnergyInput)
    state.ae = ok1 and tonumber(ae) or nil
    state.aeMax = ok2 and tonumber(aeMax) or nil
    state.aeUse = ok3 and tonumber(aeUse) or nil
    state.aeIn = ok4 and tonumber(aeIn) or nil
  end

  -- feed any fluxwall displays listening on the network
  pcall(rednet.broadcast, {
    v = 1, e = state.e, cap = state.cap,
    trueE = state.trueE, trueCap = state.trueCap, cells = state.cells,
    rate = state.rate, srcName = fluxName,
    ae = state.ae, aeMax = state.aeMax,
    aeUse = state.aeUse, aeIn = state.aeIn,
  }, "fluxdash")
end

local function renderTarget(t, isTerm)
  local w, h = t.getSize()
  local can = t.isColor and t.isColor()
  local y = 1
  local function c(col)
    if can then t.setTextColor(col) end
  end
  local function line(txt)
    if y <= h and txt and #txt > 0 then
      t.setCursorPos(1, y)
      t.write(txt)
    end
    y = y + 1
  end

  t.setBackgroundColor(colors.black)
  t.clear()

  c(colors.yellow)
  line("AppliedFlux / ME Energy")
  c(colors.white)
  if flux then
    line("Source: " .. tostring(fluxName)
      .. (lost and " (lost - rescanning)" or ""))
  elseif state.trueE then
    line("Source: block reader (drive data)")
  else
    line("Source: (no energy peripheral)")
  end
  line("")

  -- prefer true (un-clamped) readings; never mix the two scales
  local dispE, dispCap
  if state.trueE then
    dispE, dispCap = state.trueE, state.trueCap
  else
    dispE, dispCap = state.e, state.cap
  end

  if dispE ~= nil or dispCap ~= nil then
    c(colors.lime)
    line("Stored:   " .. fmt(dispE) .. " FE")
    c(colors.white)
    line("Capacity: " .. fmt(dispCap) .. " FE")
    if dispE and dispCap and dispCap > 0 then
      local bw = math.min(BAR_WIDTH, w - 2)
      local fill = math.floor(
        math.max(0, math.min(1, dispE / dispCap)) * bw + 0.5)
      if y <= h then
        t.setCursorPos(1, y)
        c(colors.lime)
        t.write(("#"):rep(fill))
        c(colors.gray)
        t.write(("-"):rep(bw - fill))
        c(colors.white)
      end
      y = y + 1
      line((" %.1f%%"):format(dispE / dispCap * 100))
    end
    if state.rate then
      c(state.rate >= 0 and colors.lime or colors.red)
      line(("Rate:     %s%s FE/t"):format(
        state.rate >= 0 and "+" or "", fmt(state.rate)))
      c(colors.white)
    end
    if state.trueE then
      c(colors.gray)
      line(("(true totals: %d cell%s via block reader)"):format(
        state.cells, state.cells == 1 and "" or "s"))
      c(colors.white)
    elseif state.e == INT_MAX or state.cap == INT_MAX then
      line("")
      c(colors.orange)
      line("! FE reading clamped at 2.147G")
      line("  (real network total is higher)")
      c(colors.white)
    end
  end

  if bridge then
    line("")
    c(colors.lightBlue)
    line("AE network (" .. tostring(bridgeName) .. ")")
    c(colors.white)
    if state.ae and state.aeMax then
      line("Buffer: " .. fmt(state.ae) .. " / " .. fmt(state.aeMax) .. " AE")
    end
    if state.aeUse then
      local s = "Use: " .. fmt(state.aeUse) .. " AE/t"
      if state.aeIn then s = s .. "  In: " .. fmt(state.aeIn) .. " AE/t" end
      line(s)
    end
  end

  if isTerm then
    line("")
    c(colors.gray)
    line("[q] quit")
    c(colors.white)
  end
end

local function render()
  pcall(renderTarget, term.current(), true)
  for i = #mons, 1, -1 do
    if not pcall(renderTarget, mons[i], false) then
      table.remove(mons, i) -- monitor went away; re-found on attach event
    end
  end
end

local function relocate()
  local n, p = locate(forced)
  if n and p then
    fluxName, flux = n, p
  end
  if not bridge then
    bridgeName, bridge = findBridge()
  end
end

refreshMonitors()
refreshReaders()
openModems()
sample()
render()

local timer = os.startTimer(REFRESH)
while true do
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" or (ev[1] == "char" and ev[2] == "q") then
    break
  elseif ev[1] == "timer" and ev[2] == timer then
    if lost or not flux then relocate() end
    sample()
    render()
    timer = os.startTimer(REFRESH)
  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    if lost or not flux or ev[1] == "peripheral" then relocate() end
    refreshMonitors()
    refreshReaders()
    openModems()
    sample()
    render()
  elseif ev[1] == "monitor_resize" then
    render()
  end
end

-- clean exit: blank the monitors, give the terminal back
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
print("fluxdash stopped.")
