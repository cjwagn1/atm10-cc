--[[
chemwall.lua - dedicated Mekanism chemical-balance wall (ATM10 / CC:Tweaked)

A full-screen Advanced Monitor view of the seven tracked chemicals' production
balance. Subscribes to the telemetry mesh and renders whatever the chemical
sensor (mesensor, on the AE computer) publishes as source "chem": one row per
chemical, biggest text that still fits.

Each row: name | stored amount | NET rate of change (mB/t, signed) | trend.
  green  rate >= 0   producing >= consuming (surplus / balanced-up)
  red    rate <  0   falling behind - that chemical is a bottleneck, add makers
  yellow rate ~ 0    holding steady (see the storage line to read which kind)
A chemical stuck near empty is flagged LOW so a starved bottleneck is obvious.

Because AE pools chemicals across cells (no clean per-chemical fill %), the
header shows the pooled chemical-cell storage (used/total bytes, % full). That
disambiguates the two "rate ~ 0" states: ~0 with cells full = surplus pegged by
back-pressure (good); ~0 with a chemical sitting near empty = starved (bad).

Run it on the computer wired to your empty chemical monitor (+ a wireless/ender
modem to hear the sensor). Press q to quit.

Usage: chemwall [key=value ...]
  source=chem     mesh source to render
  title=...       header title
  near=1000       a chemical at/below this many mB is flagged LOW (bottleneck)
  stale=10        seconds of silence before NO SIGNAL
Config may also live in chemwall.conf, one key=value per line.
]]

local PROTOCOL = "telemetry"
local CTL_PROTOCOL = "basectl"
local CTL_TOKEN    = "flux"

-- ------------------------------------------------------------------- config

local cfg = { source = "chem", title = "CHEMICAL BALANCE",
  near = 1000, stale = 10 }

local function applyKV(k, v)
  if k == "source" then cfg.source = v
  elseif k == "title" then cfg.title = v
  elseif k == "near" then cfg.near = tonumber(v) or cfg.near
  elseif k == "stale" then cfg.stale = tonumber(v) or cfg.stale end
end

do
  local f = fs.open("chemwall.conf", "r")
  if f then
    while true do
      local line = f.readLine()
      if not line then break end
      if not line:match("^%s*#") then
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then applyKV(k, v) end
      end
    end
    f.close()
  end
  for _, a in ipairs({ ... }) do
    local k, v = a:match("^([%w_]+)=(.+)$")
    if k then applyKV(k, v) end
  end
end

local SOURCE      = cfg.source
local STALE_AFTER = cfg.stale
local NEAR_ZERO   = cfg.near
local RATE_EPS    = 0.5    -- |rate| below this reads as "holding" (yellow)
local REFRESH     = 1
local RING_MAX    = 80     -- per-chemical sparkline history

-- -------------------------------------------------------------- formatting

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
  if type(sec) ~= "number" or sec ~= sec then return "?" end
  if sec < 60 then return ("%ds"):format(math.floor(sec)) end
  if sec < 3600 then return ("%dm"):format(math.floor(sec / 60)) end
  if sec < 86400 then
    return ("%dh%dm"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
  end
  return ("%dd%dh"):format(math.floor(sec / 86400), math.floor(sec % 86400 / 3600))
end

local SPARK = { ".", ":", "-", "=", "+", "*", "#" }
local function sparkline(ring, width)
  if not ring or #ring < 2 then return nil end
  local n = math.min(width, #ring)
  local pts = {}
  for i = #ring - n + 1, #ring do pts[#pts + 1] = ring[i] end
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(pts) do lo, hi = math.min(lo, v), math.max(hi, v) end
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

-- rate -> color and trend glyph (surplus / deficit / holding)
local function rateColor(r)
  if type(r) ~= "number" then return col("gray") end
  if r > RATE_EPS then return col("lime") end
  if r < -RATE_EPS then return col("red") end
  return col("yellow")
end
local function trendGlyph(r)
  if type(r) ~= "number" then return " " end
  if r > RATE_EPS then return "\24" end   -- up
  if r < -RATE_EPS then return "\25" end  -- down
  return "\26"                            -- right / steady (will fall back fine)
end

-- --------------------------------------------------------------- state

local latest      -- last data payload for SOURCE
local lastSeen    -- os.clock() of last packet
local rings = {}  -- id -> ring of amounts (sparkline / trend)
local totalMsgs = 0

-- the chems list, hardened: a malformed/spoofed packet may set `chems` to a
-- non-table (or stuff non-table junk into it). `or {}` does NOT reject a truthy
-- non-table, so guard the type here and drop any non-table element. Every site
-- that walks chems goes through this, so none can be handed bad input.
local function chemList(d)
  local c = d and d.chems
  if type(c) ~= "table" then return {} end
  local out = {}
  for _, e in ipairs(c) do
    if type(e) == "table" then out[#out + 1] = e end
  end
  return out
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
local MIN_W  = 22

local mons = {}

-- the layout needs (title + cells line + one row per chemical + footer) lines
-- and a width that fits the longest "label amount rate" row. Pick the LARGEST
-- text scale that still shows all of it, so a 1-block or a 4x3 wall both fill.
local function needs()
  local chems = chemList(latest)
  local rows = 3 + math.max(#chems, 1)             -- title, cells, footer + rows
  local labelW = 6
  for _, c in ipairs(chems) do
    labelW = math.max(labelW, #tostring(c.label or c.id or ""))
  end
  local w = math.max(MIN_W, labelW + 18)           -- label + amount + rate + gaps
  return rows, w
end

local function refreshMonitors()
  mons = { peripheral.find("monitor") }
  local rows, minw = needs()
  for _, m in ipairs(mons) do
    local chosen
    for _, s in ipairs(SCALES) do
      if pcall(m.setTextScale, s) then
        local w, h = m.getSize()
        if h >= rows and w >= minw then chosen = s; break end
      end
    end
    if not chosen then pcall(m.setTextScale, 0.5) end  -- tiny screen: max room
  end
end

-- ------------------------------------------------------------- ingest

local function ingest(envelope)
  if type(envelope) ~= "table" or envelope.source ~= SOURCE then return end
  if type(envelope.data) ~= "table" then return end
  totalMsgs = totalMsgs + 1
  latest = envelope.data
  lastSeen = os.clock()
  for _, c in ipairs(chemList(latest)) do
    if c.id and type(c.amount) == "number" then
      local r = rings[c.id]
      if not r then r = {}; rings[c.id] = r end
      r[#r + 1] = c.amount
      if #r > RING_MAX then table.remove(r, 1) end
    end
  end
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

  -- header
  drawLine(1, row(seg(cfg.title, col("yellow"))))
  if totalMsgs > 0 then
    setc(col("gray"))
    t.setCursorPos(w, 1)
    t.write(SPIN[totalMsgs % 4 + 1])
  end

  local stale = (not lastSeen) or (os.clock() - lastSeen > STALE_AFTER)

  if not latest then
    drawLine(3, row(seg("waiting for chem telemetry...", col("gray"))))
    drawLine(4, row(seg("source '" .. SOURCE .. "' on the mesh", col("gray"))))
    if isTerm then drawLine(h, row(seg("[q] quit", col("gray")))) end
    setc(col("white"))
    return
  end

  -- pooled chemical-cell storage (the rate~0 disambiguator)
  local used, total = latest.usedBytes, latest.totalBytes
  if type(used) == "number" and type(total) == "number" and total > 0 then
    local pct = used / total * 100
    -- percentage first so it survives the clip on a narrow monitor (it is the
    -- signal that disambiguates a rate ~ 0); the byte detail trails it
    drawLine(2, row(seg("CELLS ", col("yellow")),
      seg(("%d%% full"):format(math.floor(pct + 0.5)),
        pct >= 95 and col("orange") or col("white")),
      seg("  " .. fmt(used) .. "/" .. fmt(total) .. " B", col("lightBlue"))))
  end

  if stale then
    local age = lastSeen and math.floor(os.clock() - lastSeen) or 0
    drawLine(2, row(seg(("NO SIGNAL (%ds)"):format(age), col("red"))))
  end

  -- one row per chemical
  local chems = chemList(latest)
  local labelW = 6
  for _, c in ipairs(chems) do
    labelW = math.max(labelW, #tostring(c.label or c.id or ""))
  end
  labelW = math.min(labelW, math.max(6, w - 14))

  local top = 3
  for i, c in ipairs(chems) do
    local y = top + i - 1
    local label = tostring(c.label or c.id or "?")
    if #label > labelW then label = label:sub(1, labelW) end
    label = label .. (" "):rep(labelW - #label)
    local amount = fmt(c.amount or 0)
    local low = type(c.amount) == "number" and c.amount <= NEAR_ZERO
    local rateStr
    if type(c.rate) == "number" then
      rateStr = ("%s%s/t"):format(c.rate >= 0 and "+" or "", fmt(c.rate))
    else
      rateStr = "--"
    end
    local spark = sparkline(rings[c.id], math.max(0, w - labelW - 26))
    drawLine(y, row(
      seg(label, low and col("orange") or col("white")),
      seg(" " .. amount, col("white")),
      seg(" " .. trendGlyph(c.rate), rateColor(c.rate)),
      seg(rateStr, rateColor(c.rate)),
      low and seg(" LOW", col("orange")) or nil,
      spark and seg("  " .. spark, col("gray")) or nil))
  end

  -- footer: freshness + uptime
  local foot = {}
  if lastSeen then foot[#foot + 1] = "upd " .. fmtSpan(os.clock() - lastSeen) .. " ago" end
  if type(latest.up) == "number" then foot[#foot + 1] = "up " .. fmtSpan(latest.up) end
  setc(col("gray"))
  drawLine(h, row(seg(table.concat(foot, "  ")
    .. (isTerm and "   [q] quit" or ""), col("gray"))))
  setc(col("white"))
end

local function render()
  pcall(renderTarget, term.current(), true)
  for i = #mons, 1, -1 do
    if not pcall(renderTarget, mons[i], false) then table.remove(mons, i) end
  end
end

-- ------------------------------------------------------------------ main

if not openModems() then
  print("No modem found.")
  print("Attach a wireless or ender modem so this")
  print("wall can hear the chemical sensor (mesensor).")
  return
end

refreshMonitors()
render()

-- ------------------------------------------------------- base control
local function handleCtl(msg)
  if type(msg) ~= "table" or msg.token ~= CTL_TOKEN then return end
  if msg.cmd == "update" then
    pcall(rednet.broadcast, { ack = true, id = os.getComputerID(),
      label = os.getComputerLabel() }, CTL_PROTOCOL)
    pcall(function() term.redirect(term.native()) end)
    if shell and shell.run then
      if msg.loud then shell.run("update", "fromall") else shell.run("update") end
    end
  elseif msg.cmd == "version?" then
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
  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL
    and type(ev[3]) == "table" then
    local before = #chemList(latest)
    ingest(ev[3])
    -- re-fit the text scale if the chemical count changed (first packet, or a
    -- reconfigured sensor) so the layout always fills the screen
    if before ~= #chemList(latest) then refreshMonitors() end
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
    m.setBackgroundColor(col("black")); m.clear(); m.setCursorPos(1, 1)
  end)
end
term.setBackgroundColor(col("black"))
term.clear()
term.setCursorPos(1, 1)
print("chemwall stopped.")
