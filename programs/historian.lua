--[[
historian.lua - telemetry recorder + alert engine (ATM10 / CC:Tweaked)

Subscribes to every envelope on the "telemetry" protocol, keeps a rolling
history per source, and:

  1. persists rings to disk (telemetry/<source>.log, rewritten every 10s;
     telemetry/alerts.log is append-only) - survives reboots, exportable
  2. evaluates alert rules (drops over a window, thresholds, silence)
  3. announces alerts in chat via an Advanced Peripherals Chat Box (if one
     is attached) AND broadcasts them as source "alerts" so every fluxwall
     shows a red banner

Optional bridge: create a file "bridge.conf" whose first line is a
websocket URL (e.g. ws://yourhost:8466) and the historian will stream
every envelope + alert to it (see bridge/ in the repo). Requires the
server config to allow that address if it's on a private/LAN IP.

Rules live in the ALERTS table below - edit and reboot.
]]

local PROTOCOL   = "telemetry"
local SNAP_EVERY = 10    -- seconds between disk flushes
local RING_MAX   = 360   -- samples kept per source
local COOLDOWN   = 300   -- seconds between repeats of the same alert
local HEARTBEAT  = 1800  -- seconds between "base ok" digest pulses

-- Rule types (all keyed on `source`: an exact name, "*", or a trailing-*
-- prefix like "sled*"):
--   dropPct/window  - newest sample fell dropPct% below the window's oldest
--   silentFor       - no envelope for N seconds (sensor offline)
--   equals/forSeconds - a STRING field held one value for N seconds (stuck)
--   metric + below/above + forSeconds - a NUMBER metric stayed past a
--     threshold for N seconds (the "deficit"/"too full" sustained alerts)
--   runway = "empty"|"full", withinSeconds - the level is PROJECTED to hit
--     0 (or capacity) within N seconds at its measured rate (lead-time)
-- `metric` is a computed value, not a raw field: "pct" (energy/capacity),
-- "usedPct" (ME bytes), "rate", "energy", or any literal data key.
local ALERTS = {
  { source = "flux", key = "energy", dropPct = 40, window = 300 },
  { source = "*", silentFor = 60 },
  { source = "sled*", key = "state", equals = "RELOCATE", forSeconds = 900 },
  { source = "sled*", key = "state", equals = "RECOVER", forSeconds = 30 },
  -- power you can't see on the wall: lead time to empty. (A fill-% "low
  -- power" rule was removed: on a trillions-capacity Applied Flux Drive any
  -- realistic charge reads ~0%, so it only ever cried wolf. Time-to-empty
  -- from the measured rate is the honest "you're about to be broke" signal.)
  { source = "flux", runway = "empty", withinSeconds = 600, rateWindow = 30 },
  -- the silent base-killer: ME storage filling toward a crafting jam
  { source = "me", metric = "usedPct", above = 90, forSeconds = 60,
    label = "ME storage over 90% full" },
  { source = "me", runway = "full", withinSeconds = 1200, rateWindow = 120 },
}

-- ------------------------------------------------------------- utilities

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

local function exact(n)
  if type(n) == "number" and n % 1 == 0 and math.abs(n) < 2 ^ 53 then
    return ("%.0f"):format(n)
  end
  return tostring(n)
end

-- fmt with trailing decimal zeros trimmed, for the human-facing digest:
-- 550.00G -> 550G, 2.50M -> 2.5M, 2.49M stays 2.49M. (fmt keeps two
-- decimals everywhere else so alert text stays aligned.)
local function fmtc(n)
  local s = fmt(n)
  local body, unit = s:match("^(%-?[%d.]+)([kMGTP]?)$")
  if body and body:find(".", 1, true) then
    body = body:gsub("0+$", ""):gsub("%.$", "")
    return body .. unit
  end
  return s
end

-- compact one-line serializer (textutils-free, deterministic key order)
local function ser(v, out)
  if type(v) == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
      if i > 1 then out[#out + 1] = "," end
      out[#out + 1] = tostring(k) .. "="
      ser(v[k], out)
    end
    out[#out + 1] = "}"
  elseif type(v) == "number" then
    out[#out + 1] = exact(v)
  elseif type(v) == "string" then
    out[#out + 1] = ("%q"):format(v)
  else
    out[#out + 1] = tostring(v)
  end
end

local function serialize(v)
  local out = {}
  ser(v, out)
  return table.concat(out)
end

local function metricOf(rule, data)
  if rule.key == "energy" then return data.trueE or data.e end
  return data[rule.key]
end

local function sourceMatches(pattern, name)
  if pattern == "*" or pattern == name then return true end
  local prefix = pattern:match("^(.*)%*$")
  return prefix ~= nil and name:sub(1, #prefix) == prefix
end

local function fmtSpan(sec)
  if sec ~= sec or sec < 0 or sec >= 999 * 86400 then return ">999d" end
  if sec < 60 then return ("%ds"):format(math.floor(sec)) end
  if sec < 3600 then return ("%dm"):format(math.floor(sec / 60)) end
  if sec < 48 * 3600 then
    return ("%dh %dm"):format(math.floor(sec / 3600),
      math.floor(sec % 3600 / 60))
  end
  return ("%dd %dh"):format(math.floor(sec / 86400),
    math.floor(sec % 86400 / 3600))
end

-- A computed metric from a data payload, nil when not derivable. Lets a
-- rule watch a fraction/derived signal the envelope doesn't carry raw.
local function metricValue(metric, data)
  if metric == "pct" then
    local e = data.trueE or data.e
    local cap = data.trueE and data.trueCap or data.cap
    if type(e) == "number" and type(cap) == "number" and cap > 0 then
      return e / cap * 100
    end
    return nil
  elseif metric == "usedPct" then
    if type(data.usedBytes) == "number" and type(data.totalBytes) == "number"
      and data.totalBytes > 0 then
      return data.usedBytes / data.totalBytes * 100
    end
    return nil
  elseif metric == "energy" then
    return data.trueE or data.e
  end
  return data[metric]
end

-- (current level, capacity) of whichever family this source is — flux
-- (energy/cap) or ME (used/total bytes) — for runway projection.
local function levelOf(data)
  local e = data.trueE or data.e
  if type(e) == "number" then
    return e, (data.trueE and data.trueCap or data.cap)
  end
  if type(data.usedBytes) == "number" then
    return data.usedBytes, data.totalBytes
  end
  return nil, nil
end

-- units/second that levelOf is changing, measured from the ring over the
-- trailing window (so it works for ME, whose envelope carries no rate)
local function levelRate(src, window)
  local now = os.clock()
  local first, last
  for _, s in ipairs(src.ring) do
    if s.t >= now - window then
      local v = (levelOf(s.d))
      if v ~= nil then
        first = first or { t = s.t, v = v }
        last = { t = s.t, v = v }
      end
    end
  end
  if first and last and last.t > first.t then
    return (last.v - first.v) / (last.t - first.t)
  end
  return nil
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

local function findChatBox()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType and peripheral.hasType(name, "chat_box") then
      return peripheral.wrap(name)
    end
  end
end

-- ----------------------------------------------------------------- state

local sources = {}   -- name -> { ring = {{t, v, d}}, lastSeen, silenced }
local chatBox = nil
local lastAlert = "none yet"
local alertCount = 0
local fired = {}     -- rule index -> last fire clock (cooldown)

-- optional websocket bridge (see bridge/ in the repo)
local ws = nil
local wsUrl = nil
do
  local f = fs.open("bridge.conf", "r")
  if f then
    wsUrl = f.readLine()
    f.close()
  end
end
-- JSON when in-game (textutils), lua-style fallback in the harness
local function toJson(t)
  if textutils and textutils.serializeJSON then
    local ok, s = pcall(textutils.serializeJSON, t)
    if ok then return s end
  end
  return serialize(t)
end

local function wsSend(line)
  if not wsUrl or not http or not http.websocket then return end
  if not ws then
    local ok, sock = pcall(http.websocket, wsUrl)
    if ok and sock then ws = sock else return end
  end
  local ok = pcall(ws.send, line)
  if not ok then
    pcall(ws.close)
    ws = nil
  end
end

-- ----------------------------------------------------------------- alerts

local function announce(msg)
  lastAlert = msg
  alertCount = alertCount + 1
  if chatBox then
    pcall(chatBox.sendMessage, msg, "base")
  end
  pcall(rednet.broadcast, {
    v = 1, source = "alerts", tick = os.clock(), data = { msg = msg },
  }, PROTOCOL)
  local f = fs.open("telemetry/alerts.log", "a")
  if f then
    f.write(("%s %s\n"):format(exact(os.clock()), msg))
    f.close()
  end
  wsSend(toJson({ alert = msg, t = os.clock() }))
end

local function checkDropRules(name, src)
  local now = os.clock()
  for i, rule in ipairs(ALERTS) do
    if rule.dropPct and sourceMatches(rule.source, name)
      and (not fired[i] or now - fired[i] >= COOLDOWN) then
      local cur = src.ring[#src.ring]
      local baseline
      for _, s in ipairs(src.ring) do
        if s.t >= now - rule.window then
          baseline = s
          break
        end
      end
      if cur and baseline and baseline.v and cur.v
        and baseline.v > 0 and cur ~= baseline then
        local pct = (baseline.v - cur.v) / baseline.v * 100
        if pct >= rule.dropPct then
          fired[i] = now
          announce(("%s %s dropped %d%% in %dm (%s -> %s)"):format(
            name, rule.key, math.floor(pct + 0.5),
            math.floor(rule.window / 60),
            fmt(baseline.v), fmt(cur.v)))
        end
      end
    end
  end
end

local function checkSilenceRules()
  local now = os.clock()
  for _, rule in ipairs(ALERTS) do
    if rule.silentFor then
      for name, src in pairs(sources) do
        if sourceMatches(rule.source, name)
          and now - src.lastSeen > rule.silentFor and not src.silenced then
          src.silenced = true
          announce(("%s telemetry silent for %ds"):format(
            name, math.floor(now - src.lastSeen)))
        end
      end
    end
  end
end

-- "stuck" rules: scan the ring backwards for the contiguous trailing run
-- where data[key] == equals; fire when that run has lasted forSeconds.
-- Cooldown is keyed per rule AND source (one stuck sled must not silence
-- alerts for another) — the four E2 touch points.
local function checkStuckRules()
  local now = os.clock()
  for i, rule in ipairs(ALERTS) do
    if rule.equals then
      for name, src in pairs(sources) do
        if sourceMatches(rule.source, name) and #src.ring > 0 then
          local key = i .. ":" .. name
          if not fired[key] or now - fired[key] >= COOLDOWN then
            local firstT
            for k = #src.ring, 1, -1 do
              local s = src.ring[k]
              if s.d and s.d[rule.key] == rule.equals then
                firstT = s.t
              else
                break
              end
            end
            if firstT and now - firstT >= rule.forSeconds then
              fired[key] = now
              announce(("%s %s has been %s for %ds"):format(
                name, rule.key, rule.equals, math.floor(now - firstT)))
            end
          end
        end
      end
    end
  end
end

-- Sustained numeric rules: a computed metric stayed past a threshold for
-- the trailing forSeconds (the deficit / too-full alerts). Same contiguous
-- trailing-run logic as checkStuckRules, but numeric.
local function checkSustainedRules()
  local now = os.clock()
  for i, rule in ipairs(ALERTS) do
    if rule.metric and rule.forSeconds
      and (rule.below ~= nil or rule.above ~= nil) then
      for name, src in pairs(sources) do
        if sourceMatches(rule.source, name) and #src.ring > 0 then
          local key = i .. ":" .. name
          if not fired[key] or now - fired[key] >= COOLDOWN then
            local firstT
            for k = #src.ring, 1, -1 do
              local v = metricValue(rule.metric, src.ring[k].d)
              local hit = v ~= nil
                and (rule.below == nil or v < rule.below)
                and (rule.above == nil or v > rule.above)
              if hit then firstT = src.ring[k].t else break end
            end
            if firstT and now - firstT >= rule.forSeconds then
              fired[key] = now
              -- labels are self-contained sentences (they name their own
              -- source); the generic fallback prepends the source name
              announce(rule.label or (("%s %s %s %s"):format(name,
                rule.metric, rule.below ~= nil and "below" or "above",
                tostring(rule.below or rule.above))))
            end
          end
        end
      end
    end
  end
end

-- Runway rules: project time to hit 0 (empty) or capacity (full) at the
-- measured rate; fire when that lead time drops under withinSeconds.
local function checkRunwayRules()
  local now = os.clock()
  for i, rule in ipairs(ALERTS) do
    if rule.runway then
      for name, src in pairs(sources) do
        if sourceMatches(rule.source, name) and #src.ring > 0 then
          local key = i .. ":" .. name
          if not fired[key] or now - fired[key] >= COOLDOWN then
            local cur, cap = levelOf(src.ring[#src.ring].d)
            local rate = levelRate(src, rule.rateWindow or 60) -- units/sec
            local secs
            if cur and rate then
              if rule.runway == "empty" and rate < 0 then
                secs = cur / -rate
              elseif rule.runway == "full" and rate > 0 and cap and cap > cur then
                secs = (cap - cur) / rate
              end
            end
            if secs and secs > 0 and secs <= rule.withinSeconds then
              fired[key] = now
              announce(("%s %s in ~%s"):format(name,
                rule.runway == "empty" and "empty" or "full", fmtSpan(secs)))
            end
          end
        end
      end
    end
  end
end

-- A one-line "base ok" digest from the latest sample of each source. Sent
-- to chat + the bridge as a low-key HEARTBEAT (not a red wall alert), so
-- the historian visibly proves it's alive and gives a trend pulse the
-- instantaneous wall can't.
local function summaryLine()
  -- { priority, text } so flux leads, ME follows, other sensors trail (and
  -- sort stably within a tier). The chat box already tags the line [base],
  -- so the digest doesn't repeat "base:" itself.
  local parts = {}
  for name, src in pairs(sources) do
    local last = src.ring[#src.ring]
    if last then
      local d = last.d
      if name == "flux" then
        -- a fill % is meaningless on a trillions-capacity Applied Flux Drive
        -- (550G reads 0%). Show the absolute stored, the headroom it's
        -- swimming in (max capacity), and the throughput instead.
        local e = d.trueE or d.e
        local cap = d.trueE and d.trueCap or d.cap
        local s = "flux " .. (e and fmtc(e) or "?")
        if e and cap then s = s .. " / " .. fmtc(cap) end
        if type(d.rate) == "number" then
          s = s .. " " .. (d.rate >= 0 and "+" or "") .. fmtc(d.rate) .. "/t"
        end
        parts[#parts + 1] = { 1, s }
      elseif name == "me" then
        -- ME bytes ARE a real ratio (used/total), so the % stays useful
        local up = metricValue("usedPct", d)
        parts[#parts + 1] = { 2, "ME " .. (up and ("%.0f%%"):format(up) or "?") }
      else
        parts[#parts + 1] = { 3, name .. " " .. tostring(d.state or "ok") }
      end
    end
  end
  table.sort(parts, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  if #parts == 0 then return "no sensors heard" end
  local strs = {}
  for _, p in ipairs(parts) do strs[#strs + 1] = p[2] end
  return table.concat(strs, " \194\183 ")
end

local function heartbeat()
  local msg = summaryLine()
  if chatBox then pcall(chatBox.sendMessage, msg, "base") end
  wsSend(toJson({ heartbeat = msg, t = os.clock() }))
  local f = fs.open("telemetry/alerts.log", "a")
  if f then
    f.write(("%s [hb] %s\n"):format(exact(os.clock()), msg))
    f.close()
  end
end

-- ------------------------------------------------------------------ disk

local function flush()
  for name, src in pairs(sources) do
    local f = fs.open("telemetry/" .. name .. ".log", "w")
    if f then
      for _, s in ipairs(src.ring) do
        f.write(serialize({ t = s.t, data = s.d }) .. "\n")
      end
      f.close()
    end
  end
end

-- ---------------------------------------------------------------- ingest

local function ingest(envelope)
  local name = envelope.source
  if type(name) ~= "string" or type(envelope.data) ~= "table" then return end
  if name == "alerts" then return end -- don't record our own output
  local src = sources[name]
  if not src then
    src = { ring = {} }
    sources[name] = src
  end
  src.lastSeen = os.clock()
  src.silenced = false
  local v
  for _, rule in ipairs(ALERTS) do
    -- equals-rules watch STRING fields; they must never populate the
    -- numeric ring metric (E2 ingest guard)
    if rule.key and not rule.equals and sourceMatches(rule.source, name) then
      v = metricOf(rule, envelope.data)
      break
    end
  end
  if v == nil then v = envelope.data.trueE or envelope.data.e end
  src.ring[#src.ring + 1] = { t = os.clock(), v = v, d = envelope.data }
  if #src.ring > RING_MAX then table.remove(src.ring, 1) end
  wsSend(toJson({ source = name, t = os.clock(), data = envelope.data }))
  checkDropRules(name, src)
end

-- ---------------------------------------------------------------- status

local function render()
  local t = term.current()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setCursorPos(1, 1)
  if t.isColor and t.isColor() then t.setTextColor(colors.yellow) end
  t.write("historian")
  if t.isColor and t.isColor() then t.setTextColor(colors.white) end
  local y = 3
  for name, src in pairs(sources) do
    t.setCursorPos(1, y)
    t.write(("%s: %d samples, %ds ago"):format(
      name, #src.ring, math.floor(os.clock() - src.lastSeen)))
    y = y + 1
  end
  t.setCursorPos(1, y + 1)
  t.write(("alerts: %d  last: %s"):format(alertCount, lastAlert))
  t.setCursorPos(1, y + 3)
  if t.isColor and t.isColor() then t.setTextColor(colors.gray) end
  t.write("chat box: " .. (chatBox and "connected" or "none")
    .. "  ws: " .. (wsUrl and (ws and "up" or "configured") or "off"))
  t.setCursorPos(1, y + 4)
  t.write("[u] update entire base   [q] quit")
  if t.isColor and t.isColor() then t.setTextColor(colors.white) end
end

-- ------------------------------------------------------------------ main

if not openModems() then
  print("No modem found - attach a wireless or ender")
  print("modem so the historian can hear the mesh.")
  return
end
chatBox = findChatBox()

-- ------------------------------------------------------- base control
-- A token-gated "update" any computer can push with `update-all` (the [u]
-- key below runs it here). We ack so the console can tally who's alive,
-- hand the terminal back, then run the standard updater (download +
-- reboot into our role). Sleds use their own "sledctl" channel and are
-- deliberately untouched by this.
local CTL_PROTOCOL = "basectl"
local CTL_TOKEN    = "flux"  -- courtesy lock, not cryptography

local function handleCtl(msg)
  if type(msg) ~= "table" or msg.cmd ~= "update" or msg.token ~= CTL_TOKEN then
    return
  end
  pcall(rednet.broadcast, { ack = true, id = os.getComputerID(),
    label = os.getComputerLabel() }, CTL_PROTOCOL)
  pcall(function() term.redirect(term.native()) end)
  if shell and shell.run then shell.run("update") end
end

render()
local snapTimer = os.startTimer(SNAP_EVERY)
local tickTimer = os.startTimer(1)
local lastHeartbeat = os.clock()
while true do
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" or (ev[1] == "char" and ev[2] == "q") then
    break
  elseif ev[1] == "char" and ev[2] == "u" then
    -- push the latest version to the whole base, then update self
    pcall(function() term.redirect(term.native()) end)
    if shell and shell.run then shell.run("update-all") end
  elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
    and type(ev[3]) == "table" then
    handleCtl(ev[3])
  elseif ev[1] == "rednet_message" and ev[4] == PROTOCOL
    and type(ev[3]) == "table" then
    ingest(ev[3])
    render()
  elseif ev[1] == "timer" and ev[2] == snapTimer then
    flush()
    snapTimer = os.startTimer(SNAP_EVERY)
  elseif ev[1] == "timer" and ev[2] == tickTimer then
    checkSilenceRules()
    checkStuckRules()
    checkSustainedRules()
    checkRunwayRules()
    if os.clock() - lastHeartbeat >= HEARTBEAT then
      lastHeartbeat = os.clock()
      heartbeat()
    end
    render()
    tickTimer = os.startTimer(1)
  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    openModems()
    chatBox = findChatBox()
    render()
  end
end

flush()
if ws then pcall(ws.close) end
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
print("historian stopped.")
