--[[
console.lua - touch command panel for the base (ATM10 / CC:Tweaked)

An advanced computer wired to an advanced (touch) Monitor and a modem.
Right-click a button to fire a base-wide command:

  UPDATE ALL    push `update` to the whole stationary base, then show each
                ack and the version roll-call live on the panel
  VERSIONS      census every base computer and show the roll-call here,
                color-coded so an out-of-date box stands out
  UPDATE SLEDS  push `update` to the sled fleet (needs the sled token in
                sledctl.conf on this computer)

Buttons size themselves to the monitor (big and tappable on a wall) and the
results panel keeps the last output below them. This panel NEVER logs to
chat - only typing "update-all" in chat does that. It answers version
censuses and auto-updates with the base; a broadcast never loops back to its
sender, so tapping this panel's own buttons never reboots it - only an
update-all from chat/[u] does, when you're not standing here.
]]

local CTL_PROTOCOL  = "basectl"
local CTL_TOKEN     = "flux"        -- courtesy lock, matches the base programs
local SLED_PROTOCOL = "sledctl"
local CENSUS_WINDOW = 3             -- seconds to gather version replies
local ACK_WINDOW    = 3             -- seconds to gather acks on a push

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

-- nicer shades where the monitor supports a custom palette (no-op in the
-- harness / on a basic monitor)
pcall(function()
  mon.setPaletteColour(colors.blue,   0x3949ab)  -- indigo title
  mon.setPaletteColour(colors.red,    0xd64545)  -- soft red
  mon.setPaletteColour(colors.cyan,   0x2fa8c4)  -- teal
  mon.setPaletteColour(colors.green,  0x4caf50)  -- balanced green
  mon.setPaletteColour(colors.orange, 0xe6883c)
end)

local C = {
  title = colors.blue, titleText = colors.white, bg = colors.black,
  hint = colors.lightGray, head = colors.cyan, info = colors.white,
  ok = colors.lime, warn = colors.orange,
}
local buttons = {
  { label = "UPDATE ALL",   color = colors.red,   text = colors.white },
  { label = "VERSIONS",     color = colors.cyan,  text = colors.white },
  { label = "UPDATE SLEDS", color = colors.green, text = colors.white },
}

-- buttons fill the area under the title; the results panel takes the bottom
-- ~40%. So they're big and tappable on a wall yet always leave room for
-- output. Recomputed on resize.
local resultsRow = 6
local function relayout()
  local _, h = mon.getSize()
  local top = 3                                  -- below the title bar (rows 1-2)
  local resultsH = math.max(5, math.floor(h * 0.40))
  local gap = 1
  local btnArea = h - resultsH - top + 1
  local btnH = math.max(3, math.floor((btnArea - gap * (#buttons - 1)) / #buttons))
  local y = top
  for _, b in ipairs(buttons) do
    b.y1, b.y2 = y, y + btnH - 1
    y = y + btnH + gap
  end
  resultsRow = y
end
relayout()

local status = "ready - tap a command"
local resultLines = {}   -- { { text = , color = }, ... } shown below buttons

local function draw()
  local w, h = mon.getSize()
  local can = mon.isColor and mon.isColor()
  local function bg(c) mon.setBackgroundColor(can and c or colors.black) end
  local function fg(c) mon.setTextColor(can and c or colors.white) end

  bg(C.bg); mon.clear()

  -- title bar (two rows for presence) with our own version on the right
  bg(C.title); fg(C.titleText)
  for row = 1, 2 do mon.setCursorPos(1, row); mon.write((" "):rep(w)) end
  local title = "BASE CONTROL"
  mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
  mon.write(title)
  local vtag = "v" .. myVersion()
  mon.setCursorPos(math.max(1, w - #vtag), 2); mon.write(vtag)

  -- buttons: big solid blocks, label centered both ways
  for _, b in ipairs(buttons) do
    bg(b.color); fg(b.text)
    for row = b.y1, b.y2 do
      if row <= h then mon.setCursorPos(1, row); mon.write((" "):rep(w)) end
    end
    local mid = math.floor((b.y1 + b.y2) / 2)
    if mid <= h then
      local label = b.label
      mon.setCursorPos(math.max(1, math.floor((w - #label) / 2) + 1), mid)
      mon.write(label)
    end
  end

  -- results panel
  bg(C.bg)
  local row = resultsRow
  for _, line in ipairs(resultLines) do
    if row <= h - 1 then
      fg(line.color or C.info)
      mon.setCursorPos(2, row); mon.write(tostring(line.text):sub(1, w - 2))
      row = row + 1
    end
  end

  -- status / hint at the very bottom
  fg(C.hint)
  mon.setCursorPos(1, h); mon.write(status:sub(1, w))
  fg(colors.white)
end

-- ping every base computer for its version; return a sorted list, including
-- ourselves. Re-ping each second so a busy box (the flux computer's heavy
-- block-reader reads) isn't dropped by a single missed ping.
local function census(window)
  local label = os.getComputerLabel() or "console"
  local list = { { label = label, version = myVersion() } }
  local seen = { [label] = true }
  local deadline = os.clock() + (window or CENSUS_WINDOW)
  local nextPing = 0
  while true do
    local now = os.clock()
    if now >= deadline then break end
    if now >= nextPing then
      pcall(rednet.broadcast, { cmd = "version?", token = CTL_TOKEN }, CTL_PROTOCOL)
      nextPing = now + 1
    end
    local timer = os.startTimer(math.min(1, deadline - now))
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "terminate" then
      break
    elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
      and type(ev[3]) == "table" and ev[3].version ~= nil then
      local who = ev[3].label or ("id " .. tostring(ev[3].id))
      if not seen[who] then
        seen[who] = true
        list[#list + 1] = { label = who, version = tostring(ev[3].version) }
      end
    end
  end
  table.sort(list, function(a, b) return a.label < b.label end)
  return list
end

-- turn a census list into colored result lines (lime = in sync, orange =
-- out of date) and a one-line summary
local function showCensus(list)
  local counts = {}
  for _, e in ipairs(list) do counts[e.version] = (counts[e.version] or 0) + 1 end
  local mode, best = "?", -1
  for v, n in pairs(counts) do if n > best then best, mode = n, v end end
  resultLines = { { text = ("VERSIONS  (%d computers)"):format(#list),
    color = C.head } }
  for _, e in ipairs(list) do
    local sync = (e.version == mode and e.version ~= "?")
    resultLines[#resultLines + 1] = {
      text = ("  %-15s v%s%s"):format(e.label, e.version,
        sync and "" or "   <- check"),
      color = sync and C.ok or C.warn,
    }
  end
  status = (best == #list and #list > 0) and "all in sync"
    or "versions differ - see the orange rows"
  draw()
end

buttons[1].action = function()   -- UPDATE ALL
  resultLines = { { text = "Pushing update to the base...", color = C.head } }
  status = "updating the base..."
  draw()
  rednet.broadcast({ cmd = "update", token = CTL_TOKEN }, CTL_PROTOCOL)
  -- live acks as boxes hear the push (before they reboot)
  local seen = {}
  local deadline = os.clock() + ACK_WINDOW
  while true do
    local left = deadline - os.clock()
    if left <= 0 then break end
    local timer = os.startTimer(left)
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "terminate" then
      return
    elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
      and type(ev[3]) == "table" and ev[3].ack then
      local who = ev[3].label or ("id " .. tostring(ev[3].id))
      if not seen[who] then
        seen[who] = true
        resultLines[#resultLines + 1] = { text = "  ack " .. who, color = C.ok }
        draw()
      end
    end
  end
  -- let them reboot, then replace the acks with the confirmed version list
  resultLines[#resultLines + 1] = { text = "confirming versions...", color = C.hint }
  status = "confirming..."
  draw()
  sleep(4)
  showCensus(census(4))
end

buttons[2].action = function()   -- VERSIONS
  resultLines = { { text = "checking versions...", color = C.hint } }
  status = "checking versions..."
  draw()
  showCensus(census(CENSUS_WINDOW))
end

buttons[3].action = function()   -- UPDATE SLEDS
  if not sledToken then
    resultLines = { { text = "No sled token on this computer.", color = C.warn },
      { text = "add sledctl.conf to enable sled updates.", color = C.hint } }
    status = "no sled token"
    draw()
    return
  end
  resultLines = { { text = "Pushing update to the sled fleet...", color = C.head } }
  status = "updating sleds..."
  draw()
  rednet.broadcast({ cmd = "update", token = sledToken }, SLED_PROTOCOL)
  resultLines[#resultLines + 1] = { text = "  sent on the sledctl channel.", color = C.ok }
  resultLines[#resultLines + 1] = { text = "  sleds reboot when safe (journal-backed).", color = C.hint }
  status = "sled update pushed"
  draw()
end

local function hit(x, y)
  for _, b in ipairs(buttons) do
    if y >= b.y1 and y <= b.y2 then return b end
  end
end

-- answer version censuses, and auto-update with the base (only when an
-- update-all is fired from elsewhere; our own buttons never loop back)
local function handleCtl(msg)
  if type(msg) ~= "table" or msg.token ~= CTL_TOKEN then return end
  if msg.cmd == "update" then
    pcall(rednet.broadcast, { ack = true, id = os.getComputerID(),
      label = os.getComputerLabel() }, CTL_PROTOCOL)
    if shell and shell.run then shell.run("update") end
  elseif msg.cmd == "version?" then
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
  elseif ev[1] == "monitor_resize" then
    relayout()
    draw()
  elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
    and type(ev[3]) == "table" then
    handleCtl(ev[3])
  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    openModems()
    local m = peripheral.find("monitor")
    if m then mon = m; pcall(mon.setTextScale, 1); relayout(); draw() end
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
