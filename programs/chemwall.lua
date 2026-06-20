--[[
chemwall.lua - dedicated Mekanism chemical-balance wall (ATM10 / CC:Tweaked)

A full-screen Advanced Monitor view of the seven tracked chemicals' production
balance. Subscribes to the telemetry mesh and renders whatever the chemical
sensor (mesensor, on the AE computer) publishes as source "chem": one row per
chemical, biggest text that still fits.

Each row: name | stored amount (Buckets) | NET rate of change (mB/t) | trend.
  green  rate >= 0   producing >= consuming (surplus / balanced-up)
  red    rate <  0   falling behind - that chemical is a bottleneck, add makers
  yellow rate ~ 0    holding steady (see the storage line to read which kind)
A chemical stuck near empty gets a verdict (the tiny net rate alone is useless):
  BEHIND  net < 0 at ~empty -> production can't keep up; THE bottleneck to fix
  TIGHT   net ~ 0 at ~empty -> keeping up exactly, but no buffer/safety margin

Because AE pools chemicals across cells (no clean per-chemical fill %), the
header shows the pooled chemical-cell storage (used/total bytes, % full). That
disambiguates the two "rate ~ 0" states: ~0 with cells full = surplus pegged by
back-pressure (good); ~0 with a chemical sitting near empty = starved (bad).

Run it on the computer wired to your empty chemical monitor (+ a wireless/ender
modem to hear the sensor). Press q to quit.

Rows are split into two groups - END PRODUCTS (the chemicals you want out in
useful form) and FEEDSTOCK (the creation chemicals used to make them). Order is
FIXED by default so rows stay put as rates swing (just-in-time chemicals that
cycle empty<->full would otherwise reorder constantly). Amounts show in Buckets
(B) to match Mekanism.

Usage: chemwall [key=value ...]
  source=chem      mesh source to render
  title=...        header title
  unit=B|mB        amount unit (default B = Buckets, matching the game)
  sort=fixed|rate  row order: fixed/tracked (default, stable) or by net rate
  products=a,b     registry ids that count as END PRODUCTS (the rest are FEEDSTOCK)
  prodtitle=...    END PRODUCTS section header text
  feedtitle=...    FEEDSTOCK section header text
  near=1           a chemical at/below this many Buckets gets a BEHIND/TIGHT verdict
  stale=10         seconds of silence before NO SIGNAL
Config may also live in chemwall.conf, one key=value per line.
]]

local PROTOCOL = "telemetry"
local CTL_PROTOCOL = "basectl"
local CTL_TOKEN    = "flux"

-- ------------------------------------------------------------------- config

local cfg = { source = "chem", title = "CHEMICAL BALANCE",
  near = 1, stale = 10, unit = "B", sort = "fixed",
  -- the end products (what you want OUT in useful form); everything else is a
  -- creation/feedstock chemical used to make them. They render in two groups.
  products = "mekanism:sulfuric_acid,mekanism:hydrogen_chloride",
  prodtitle = "END PRODUCTS", feedtitle = "FEEDSTOCK" }

local function applyKV(k, v)
  if k == "source" then cfg.source = v
  elseif k == "title" then cfg.title = v
  elseif k == "near" then cfg.near = tonumber(v) or cfg.near
  elseif k == "stale" then cfg.stale = tonumber(v) or cfg.stale
  elseif k == "unit" then cfg.unit = v
  elseif k == "sort" then cfg.sort = v
  elseif k == "products" then cfg.products = v
  elseif k == "prodtitle" then cfg.prodtitle = v
  elseif k == "feedtitle" then cfg.feedtitle = v end
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
local NEAR_ZERO   = cfg.near * 1000   -- cfg.near is in Buckets; data is in mB
local RATE_EPS    = 0.5    -- |rate| below this reads as "holding" (yellow)
local REFRESH     = 1
local RING_MAX    = 80     -- per-chemical history

-- the set of registry ids that count as end products
local productSet = {}
for id in (cfg.products or ""):gmatch("[^,%s]+") do productSet[id] = true end

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

-- stored amounts: Mekanism shows chemicals in Buckets (B), but the bridge (and
-- mesensor) speak millibuckets, so divide by 1000 for display. unit=mB keeps mB.
local function fmtAmt(mB)
  if type(mB) ~= "number" then return "?" end
  if cfg.unit == "mB" then return fmt(mB) .. " mB" end
  return fmt(mB / 1000) .. " B"
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

-- the layout needs (title + cells + 2 group headers + one row per chemical +
-- footer) lines, and a width that fits the longest "label amount rate" row.
-- Pick the LARGEST text scale that still shows all of it, so a 1-block or a 4x3
-- wall both fill.
local function needs()
  local chems = chemList(latest)
  local rows = 5 + math.max(#chems, 1)   -- title, cells, 2 headers, footer + rows
  local labelW = 6
  for _, c in ipairs(chems) do
    labelW = math.max(labelW, #tostring(c.label or c.id or ""))
  end
  local w = math.max(MIN_W, labelW + 20) -- label + amount(B) + rate + gaps
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

  -- pooled chemical-cell storage (the rate~0 disambiguator). AE reports 0 if
  -- the chemicals aren't kept in dedicated chemical storage cells - then we
  -- just skip this line rather than show a useless 0%.
  local used, total = latest.usedBytes, latest.totalBytes
  local headRow = false
  if type(used) == "number" and type(total) == "number" and total > 0 then
    local pct = used / total * 100
    drawLine(2, row(seg("CELLS ", col("yellow")),
      seg(("%d%% full"):format(math.floor(pct + 0.5)),
        pct >= 95 and col("orange") or col("white")),
      seg("  " .. fmt(used) .. "/" .. fmt(total) .. " B", col("lightBlue"))))
    headRow = true
  end
  if stale then
    local age = lastSeen and math.floor(os.clock() - lastSeen) or 0
    drawLine(2, row(seg(("NO SIGNAL (%ds)"):format(age), col("red"))))
    headRow = true
  end

  -- split into key END PRODUCTS (what you want OUT) vs FEEDSTOCK/creation
  -- chemicals. Order is FIXED (the tracked order) by default, so rows stay put
  -- as rates swing - just-in-time chemicals that cycle empty<->full would
  -- otherwise reorder constantly and be impossible to read. sort=rate opts into
  -- ordering each group by net rate instead.
  local chems = chemList(latest)
  local prods, feed = {}, {}
  for _, c in ipairs(chems) do
    if productSet[c.id] then prods[#prods + 1] = c else feed[#feed + 1] = c end
  end
  if cfg.sort == "rate" then
    local function byRate(a, b)
      local ra = type(a.rate) == "number" and a.rate or -math.huge
      local rb = type(b.rate) == "number" and b.rate or -math.huge
      return ra > rb
    end
    table.sort(prods, byRate)
    table.sort(feed, byRate)
  end

  local labelW = 6
  for _, c in ipairs(chems) do
    labelW = math.max(labelW, #tostring(c.label or c.id or ""))
  end
  labelW = math.min(labelW, math.max(6, w - 16))

  local function drawChem(y, c)
    local label = tostring(c.label or c.id or "?")
    if #label > labelW then label = label:sub(1, labelW) end
    label = label .. (" "):rep(labelW - #label)
    local r = type(c.rate) == "number" and c.rate or nil
    local low = type(c.amount) == "number" and c.amount <= NEAR_ZERO
    -- for an empty/low chemical the tiny net rate means little on its own, so
    -- translate it into a verdict: BEHIND (production can't keep up - the
    -- bottleneck), TIGHT (keeping up exactly, no buffer); a low chemical that's
    -- climbing (rate > 0) is refilling and needs no flag
    local flag, fcol
    if low then
      if r and r < -RATE_EPS then flag, fcol = " BEHIND", col("red")
      elseif not r or math.abs(r) <= RATE_EPS then flag, fcol = " TIGHT", col("orange") end
    end
    local rateStr = r and ("%s%s/t"):format(r >= 0 and "+" or "", fmt(r)) or "--"
    drawLine(y, row(
      seg(label, fcol or col("white")),
      seg(" " .. fmtAmt(c.amount), col("white")),
      seg(" " .. trendGlyph(c.rate), rateColor(c.rate)),
      seg(rateStr, rateColor(c.rate)),
      flag and seg(flag, fcol) or nil))
  end

  -- start right under the header/cells line; reserve the bottom row for the footer
  local y = headRow and 3 or 2
  local function section(title, list)
    if #list == 0 then return end
    if y < h then drawLine(y, row(seg(title, col("cyan")))); y = y + 1 end
    for _, c in ipairs(list) do
      if y >= h then break end
      drawChem(y, c); y = y + 1
    end
  end
  section(cfg.prodtitle, prods)
  section(cfg.feedtitle, feed)

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
