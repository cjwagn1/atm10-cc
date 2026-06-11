--[[
fluxwall.lua (v2) - multi-source telemetry wall for ATM10 (CC:Tweaked)

Subscribes to the base telemetry mesh: every sensor computer broadcasts
{ v, source, tick, data } envelopes on the rednet protocol "telemetry"
(fluxdash publishes source "flux", mesensor publishes source "me", the
historian publishes source "alerts"). The wall keeps one page per source
and rotates between them; each page gets a purpose-built layout when one
exists ("flux", "me") and a generic key/value dump otherwise, so brand-new
sensors show up with zero wall changes.

Extras:
  - in-memory history per source -> sparkline row on tall monitors
  - red alert banner whenever the historian announces something
  - per-source "NO SIGNAL (Ns)" after 10s of silence
  - auto-scaled text: biggest size that fits the layout on each monitor
  - legacy fluxdash broadcasts (pre-mesh) still render fine

Keys: q quits, n flips to the next page early.
]]

local REFRESH      = 1     -- seconds between repaints
local STALE_AFTER  = 10    -- per-source silence -> NO SIGNAL
local PAGE_SECONDS = 8     -- auto-rotate interval between sources
local ALERT_FOR    = 60    -- how long an alert banner stays up
local RING_MAX     = 60    -- history points kept per source (sparkline)
local PROTOCOL     = "telemetry"
local MIN_W, MIN_H = 24, 7

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

local function fmtSpan(sec)
  if sec ~= sec or sec >= 999 * 86400 then return ">999d" end
  if sec < 60 then return ("%ds"):format(math.floor(sec)) end
  if sec < 3600 then return ("%dm"):format(math.floor(sec / 60)) end
  if sec < 48 * 3600 then
    return ("%dh %dm"):format(
      math.floor(sec / 3600), math.floor(sec % 3600 / 60))
  end
  return ("%dd %dh"):format(
    math.floor(sec / 86400), math.floor(sec % 86400 / 3600))
end

local function etaText(e, cap, rate)
  if type(e) ~= "number" or type(rate) ~= "number" then return nil end
  if rate >= 1 then
    if not cap or cap <= e then return nil end
    return "full in " .. fmtSpan((cap - e) / (rate * 20))
  elseif rate <= -1 then
    if e <= 0 then return nil end
    return "empty in " .. fmtSpan(e / (-rate * 20))
  end
  return nil
end

local SPARK = { ".", ":", "-", "=", "+", "*", "#" }
local function sparkline(ring, width)
  if #ring < 2 then return nil end
  local n = math.min(width, #ring)
  local pts = {}
  for i = #ring - n + 1, #ring do pts[#pts + 1] = ring[i] end
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(pts) do
    lo = math.min(lo, v)
    hi = math.max(hi, v)
  end
  if hi <= lo then return ("-"):rep(#pts) end
  local out = {}
  for _, v in ipairs(pts) do
    local idx = 1 + math.floor((v - lo) / (hi - lo) * (#SPARK - 1) + 0.5)
    out[#out + 1] = SPARK[idx]
  end
  return table.concat(out)
end

-- ----------------------------------------------------------- peripherals

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

-- --------------------------------------------------------- source registry

local sources = {}  -- name -> { data, lastSeen, msgCount, ring }
local order = {}    -- page order (sorted source names)
local page = 1
local pageStart = 0
local alertMsg, alertAt
local totalMsgs = 0

local function rebuildOrder()
  order = {}
  for name in pairs(sources) do order[#order + 1] = name end
  table.sort(order)
  if page > #order then page = 1 end
end

-- ------------------------------------------------------------- renderers

-- Each renderer: title shown on row 1, metric() feeds the sparkline ring,
-- draw() paints rows 3..h-1. Unknown sources fall back to the generic one.

local function drawFlux(t, w, h, d, ring, c, lineAt)
  local e = d.trueE or d.e
  local cap = d.trueE and d.trueCap or d.cap
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
  if d.rate then
    c(d.rate >= 0 and colors.lime or colors.red)
    lineAt(6, ("%s%s FE/t"):format(d.rate >= 0 and "+" or "", fmt(d.rate)))
    c(colors.white)
  end
  local eta = etaText(e, cap, d.rate)
  if eta then
    c(colors.white)
    lineAt(7, eta)
  end
  if h >= 9 and d.ae and d.aeMax then
    c(colors.lightBlue)
    lineAt(8, ("AE %s/%s%s"):format(fmt(d.ae), fmt(d.aeMax),
      d.aeUse and ("  -" .. fmt(d.aeUse) .. "/t") or ""))
    c(colors.white)
  end
  if h >= 11 then
    local line = sparkline(ring, w - 2)
    if line then
      t.setCursorPos(2, 10)
      c(colors.green)
      t.write(line)
      c(colors.white)
    end
  end
end

local function drawMe(t, w, h, d, ring, c, lineAt)
  local used, total = d.usedBytes, d.totalBytes
  c(colors.lime)
  lineAt(3, fmt(used) .. " B used")
  c(colors.white)
  local pct = (used and total and total > 0) and (used / total * 100) or nil
  lineAt(4, "of " .. fmt(total) .. " B"
    .. (pct and ("  (%.1f%%)"):format(pct) or ""))
  if pct then
    local bw = w - 2
    local fill = math.floor(math.max(0, math.min(1, used / total)) * bw + 0.5)
    t.setCursorPos(2, 5)
    c(colors.lime)
    t.write(("#"):rep(fill))
    c(colors.gray)
    t.write(("-"):rep(bw - fill))
    c(colors.white)
  end
  if d.cpus then
    c(colors.lightBlue)
    lineAt(6, ("Craft CPUs: %d/%d busy"):format(d.cpusBusy or 0, d.cpus))
    c(colors.white)
  end
  if d.aeUse then
    lineAt(7, "AE use: " .. fmt(d.aeUse) .. "/t")
  end
  if h >= 11 then
    local line = sparkline(ring, w - 2)
    if line then
      t.setCursorPos(2, 10)
      c(colors.green)
      t.write(line)
      c(colors.white)
    end
  end
end

local function drawGeneric(t, w, h, d, ring, c, lineAt)
  local keys = {}
  for k, v in pairs(d) do
    if type(v) == "number" or type(v) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local y = 3
  for _, k in ipairs(keys) do
    if y > h - 1 then break end
    local v = d[k]
    lineAt(y, ("%s: %s"):format(k,
      type(v) == "number" and fmt(v) or tostring(v)))
    y = y + 1
  end
end

local RENDERERS = {
  flux = {
    title = "ME FLUX ENERGY",
    metric = function(d) return d.trueE or d.e end,
    draw = drawFlux,
  },
  me = {
    title = "ME STORAGE",
    metric = function(d) return d.usedBytes end,
    draw = drawMe,
  },
}

local function rendererFor(name)
  return RENDERERS[name] or {
    title = name:upper(),
    metric = function(d)
      for _, k in ipairs({ "value", "e", "energy", "count" }) do
        if type(d[k]) == "number" then return d[k] end
      end
    end,
    draw = drawGeneric,
  }
end

-- ---------------------------------------------------------------- render

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

  local name = order[page]
  local src = name and sources[name]
  local r = name and rendererFor(name)

  c(colors.yellow)
  lineAt(1, r and r.title or "TELEMETRY")
  if #order > 1 then
    c(colors.gray)
    local tag = ("%d/%d"):format(page, #order)
    t.setCursorPos(w - #tag - 1, 1)
    t.write(tag)
  end
  if totalMsgs > 0 then
    c(colors.gray)
    t.setCursorPos(w, 1)
    t.write(SPIN[totalMsgs % 4 + 1])
  end

  if alertAt and (os.clock() - alertAt) <= ALERT_FOR and alertMsg then
    c(colors.red)
    lineAt(2, "! " .. alertMsg)
    c(colors.white)
  end

  if not src then
    c(colors.red)
    lineAt(3, "NO SIGNAL")
    c(colors.gray)
    lineAt(4, "waiting for telemetry...")
  else
    local age = os.clock() - src.lastSeen
    if age > STALE_AFTER then
      c(colors.red)
      lineAt(3, ("NO SIGNAL (%ds)"):format(age))
      c(colors.gray)
      local last = r.metric(src.data)
      if last then lineAt(4, "last: " .. fmt(last)) end
    else
      r.draw(t, w, h, src.data, src.ring, c, lineAt)
    end
  end

  if isTerm then
    c(colors.gray)
    lineAt(h, "[q] quit  [n] next page")
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

local function ingest(envelope)
  local name = envelope.source
  if type(name) ~= "string" or type(envelope.data) ~= "table" then return end
  totalMsgs = totalMsgs + 1
  if name == "alerts" then
    alertMsg = tostring(envelope.data.msg or "alert")
    alertAt = os.clock()
    return
  end
  local src = sources[name]
  if not src then
    src = { ring = {}, msgCount = 0 }
    sources[name] = src
    rebuildOrder()
  end
  src.data = envelope.data
  src.lastSeen = os.clock()
  src.msgCount = src.msgCount + 1
  local v = rendererFor(name).metric(envelope.data)
  if type(v) == "number" then
    src.ring[#src.ring + 1] = v
    if #src.ring > RING_MAX then table.remove(src.ring, 1) end
  end
end

-- ------------------------------------------------------------------ main

if not openModems() then
  print("No modem found.")
  print("Attach a wireless or ender modem so this")
  print("display can hear the sensor computers.")
  return
end

refreshMonitors()
pageStart = os.clock()
render()

local timer = os.startTimer(REFRESH)
while true do
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" or (ev[1] == "char" and ev[2] == "q") then
    break
  elseif ev[1] == "char" and ev[2] == "n" and #order > 1 then
    page = page % #order + 1
    pageStart = os.clock()
    render()
  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL
    and type(ev[3]) == "table" then
    ingest(ev[3])
    render()
  elseif ev[1] == "rednet_message" and ev[4] == "fluxdash"
    and type(ev[3]) == "table" then
    -- legacy pre-mesh fluxdash broadcast: treat as a flux envelope
    ingest({ v = 1, source = "flux", data = ev[3] })
    render()
  elseif ev[1] == "timer" and ev[2] == timer then
    if #order > 1 and (os.clock() - pageStart) >= PAGE_SECONDS then
      page = page % #order + 1
      pageStart = os.clock()
    end
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
