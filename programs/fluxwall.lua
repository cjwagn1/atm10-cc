--[[
fluxwall.lua (v3) - unified telemetry wall for ATM10 (CC:Tweaked)

Subscribes to the base telemetry mesh: every sensor computer broadcasts
{ v, source, tick, data } envelopes on the rednet protocol "telemetry"
(fluxdash publishes source "flux", mesensor publishes source "me", the
historian publishes source "alerts").

Unlike the paged v2, this shows EVERY source at once, stacked as compact
cards on a single screen - no rotation, nothing to wait for. Each source
gets an equal vertical band; cards render as much detail as their band
allows (headline -> bar -> rate/ETA -> sparkline), so the same program
looks right on a tiny monitor and a huge wall. New sensors appear as new
cards automatically via the generic renderer.

Extras: red alert banner from the historian, per-source "NO SIGNAL (Ns)"
inline when a sensor goes quiet, auto-scaled text. Press q to quit.
]]

local REFRESH     = 1     -- seconds between repaints
local STALE_AFTER = 10    -- per-source silence -> NO SIGNAL
local ALERT_FOR   = 60    -- how long an alert banner stays up
local RING_MAX    = 120   -- history points kept per source (sparkline)
local PROTOCOL    = "telemetry"
local MIN_W, MIN_H = 22, 6

local colors = colors
local function col(name) return colors[name] end

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
    lo, hi = math.min(lo, v), math.max(hi, v)
  end
  if hi <= lo then return ("-"):rep(#pts) end
  local out = {}
  for _, v in ipairs(pts) do
    out[#out + 1] = SPARK[1 + math.floor((v - lo) / (hi - lo) * (#SPARK - 1) + 0.5)]
  end
  return table.concat(out)
end

-- a "line" is a list of {text, color} segments; row() drops nil segments
local function seg(text, color) return { text = text, color = color } end
local function row(...)
  local out, n = {}, select("#", ...)
  for i = 1, n do
    local s = select(i, ...)
    if s then out[#out + 1] = s end
  end
  return out
end

local function barLine(frac, w)
  frac = math.max(0, math.min(1, frac))
  local pct = (" %d%%"):format(math.floor(frac * 100 + 0.5))
  local bw = w - #pct - 1
  if bw < 4 then bw, pct = w - 1, "" end
  local fill = math.floor(frac * bw + 0.5)
  return row(seg(" ", col("white")), seg(("#"):rep(fill), col("lime")),
    seg(("-"):rep(bw - fill), col("gray")),
    pct ~= "" and seg(pct, col("white")) or nil)
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

-- ---------------------------------------------------------- card renderers

-- Each returns { label=, metric=, lines=function(d, ring, w) -> {line...} }
-- in descending priority; the band shows as many lines as fit.

local function fluxLines(d, ring, w)
  local e = d.trueE or d.e
  local cap = d.trueE and d.trueCap or d.cap
  local pct = (e and cap and cap > 0) and (e / cap * 100) or nil
  local L = {}
  L[#L + 1] = row(seg("FLUX ", col("yellow")),
    seg(fmt(e) .. (cap and "/" .. fmt(cap) or "") .. " FE", col("lime")),
    pct and seg((" %.0f%%"):format(pct), col("white")) or nil)
  if pct then L[#L + 1] = barLine(e / cap, w) end
  if d.rate then
    L[#L + 1] = row(seg((d.rate >= 0 and "+" or "") .. fmt(d.rate) .. " FE/t",
      d.rate >= 0 and col("lime") or col("red")))
  end
  local eta = etaText(e, cap, d.rate)
  if eta then L[#L + 1] = row(seg(eta, col("white"))) end
  if d.ae and d.aeMax then
    L[#L + 1] = row(seg("AE " .. fmt(d.ae) .. "/" .. fmt(d.aeMax)
      .. (d.aeUse and ("  -" .. fmt(d.aeUse) .. "/t") or ""), col("lightBlue")))
  end
  local sl = sparkline(ring, w - 1)
  if sl then L[#L + 1] = row(seg(" " .. sl, col("green"))) end
  return L
end

local function meLines(d, ring, w)
  local used, total = d.usedBytes, d.totalBytes
  local pct = (used and total and total > 0) and (used / total * 100) or nil
  local L = {}
  L[#L + 1] = row(seg("ME   ", col("yellow")),
    seg(fmt(used) .. "/" .. fmt(total) .. " B", col("lime")),
    pct and seg((" %.0f%%"):format(pct), col("white")) or nil)
  if pct then L[#L + 1] = barLine(used / total, w) end
  local bits = {}
  if d.cpus then bits[#bits + 1] = ("CPU %d/%d"):format(d.cpusBusy or 0, d.cpus) end
  if d.aeUse then bits[#bits + 1] = "AE " .. fmt(d.aeUse) .. "/t" end
  if #bits > 0 then
    L[#L + 1] = row(seg(table.concat(bits, "  "), col("lightBlue")))
  end
  local sl = sparkline(ring, w - 1)
  if sl then L[#L + 1] = row(seg(" " .. sl, col("green"))) end
  return L
end

local function genericLines(label)
  return function(d, ring, w)
    local L = { row(seg(label .. " ", col("yellow"))) }
    local keys = {}
    for k, v in pairs(d) do
      if type(v) == "number" or type(v) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = d[k]
      L[#L + 1] = row(seg("  " .. k .. ": "
        .. (type(v) == "number" and fmt(v) or tostring(v)), col("white")))
    end
    return L
  end
end

local RENDERERS = {
  flux = { label = "FLUX", metric = function(d) return d.trueE or d.e end,
    lines = fluxLines },
  me = { label = "ME", metric = function(d) return d.usedBytes end,
    lines = meLines },
}

local function rendererFor(name)
  if RENDERERS[name] then return RENDERERS[name] end
  return {
    label = name:upper(),
    metric = function(d)
      for _, k in ipairs({ "value", "e", "energy", "count" }) do
        if type(d[k]) == "number" then return d[k] end
      end
    end,
    lines = genericLines(name:upper()),
  }
end

-- --------------------------------------------------------------- state

local sources = {}  -- name -> { data, lastSeen, ring }
local order = {}
local alertMsg, alertAt
local totalMsgs = 0

local function rebuildOrder()
  order = {}
  for name in pairs(sources) do order[#order + 1] = name end
  table.sort(order)
end

-- ---------------------------------------------------------------- render

local SPIN = { "|", "/", "-", "\\" }

local function renderTarget(t, isTerm)
  local w, h = t.getSize()
  local can = t.isColor and t.isColor()
  local function setc(c) if can and c then t.setTextColor(c) end end
  local function drawLine(y, segs)
    if y < 1 or y > h then return end
    t.setCursorPos(1, y)
    local x = 1
    for _, s in ipairs(segs) do
      if x > w then break end
      local txt = s.text
      if x + #txt - 1 > w then txt = txt:sub(1, w - x + 1) end
      setc(s.color)
      t.write(txt)
      x = x + #txt
    end
  end

  t.setBackgroundColor(col("black"))
  t.clear()

  local y = 1
  setc(col("yellow"))
  drawLine(1, row(seg("BASE TELEMETRY", col("yellow"))))
  if totalMsgs > 0 then
    setc(col("gray"))
    t.setCursorPos(w, 1)
    t.write(SPIN[totalMsgs % 4 + 1])
  end
  y = 2

  if alertAt and (os.clock() - alertAt) <= ALERT_FOR and alertMsg then
    drawLine(y, row(seg("! " .. alertMsg, col("red"))))
    y = y + 1
  end

  local bottom = isTerm and (h - 1) or h
  if #order == 0 then
    drawLine(y, row(seg("NO SIGNAL", col("red"))))
    drawLine(y + 1, row(seg("waiting for telemetry...", col("gray"))))
  else
    local avail = bottom - y + 1
    local band = math.max(1, math.floor(avail / #order))
    for idx, name in ipairs(order) do
      local src = sources[name]
      local r = rendererFor(name)
      local top = y + (idx - 1) * band
      local age = os.clock() - src.lastSeen
      if age > STALE_AFTER then
        drawLine(top, row(seg(r.label .. " ", col("yellow")),
          seg(("NO SIGNAL (%ds)"):format(math.floor(age)), col("red"))))
      else
        local lines = r.lines(src.data, src.ring, w)
        for i = 1, math.min(#lines, band) do
          drawLine(top + i - 1, lines[i])
        end
      end
    end
  end

  if isTerm then
    setc(col("gray"))
    drawLine(h, row(seg("[q] quit", col("gray"))))
  end
  setc(col("white"))
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
    src = { ring = {} }
    sources[name] = src
    rebuildOrder()
  end
  src.data = envelope.data
  src.lastSeen = os.clock()
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
render()

local timer = os.startTimer(REFRESH)
while true do
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" or (ev[1] == "char" and ev[2] == "q") then
    break
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
    m.setBackgroundColor(col("black"))
    m.clear()
    m.setCursorPos(1, 1)
  end)
end
term.setBackgroundColor(col("black"))
term.clear()
term.setCursorPos(1, 1)
print("fluxwall stopped.")
