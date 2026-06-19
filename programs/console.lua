--[[
console.lua - touch command panel for the base (ATM10 / CC:Tweaked)

An advanced computer wired to an advanced (touch) Monitor and a modem.
Right-click a button to fire a base-wide command:

  UPDATE ALL    push `update` to the whole stationary base (walls, dashes,
                ME sensor, historian); tap VERSIONS after to confirm
  VERSIONS      census every base computer and show the roll-call here,
                color-coded so an out-of-date box stands out
  UPDATE SLEDS  push `update` to the sled fleet (needs the sled token in
                sledctl.conf on this computer)

This is a controller, but it stays in version-sync: it answers version
censuses and AUTO-UPDATES with the base. A broadcast never loops back to its
sender, so tapping this panel's own UPDATE ALL never reboots it - only an
update-all fired from elsewhere (chat / [u]) does, when you're not at the
panel. Its own pushes are quiet (no chat); type "update-all" in chat for the
narrated version. Sleds keep their own channel.
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

-- palette (gracefully ignored on a non-color monitor)
local C = {
  title = colors.blue, titleText = colors.white, bg = colors.black,
  hint = colors.lightGray, head = colors.cyan, info = colors.white,
  ok = colors.lime, warn = colors.orange,
}
local buttons = {
  { label = "UPDATE ALL",   color = colors.red,   text = colors.white },
  { label = "VERSIONS",     color = colors.cyan,  text = colors.black },
  { label = "UPDATE SLEDS", color = colors.green, text = colors.white },
}

-- full-width buttons stacked under a title bar; results fill the space below
local BTN_H = 2
local resultsRow
do
  local y = 3
  for _, b in ipairs(buttons) do
    b.y1, b.y2 = y, y + BTN_H - 1
    y = y + BTN_H + 1   -- one blank row between buttons
  end
  resultsRow = y
end

local status = "ready - tap a command"
local resultLines = {}   -- { { text = , color = }, ... } shown below buttons

local function draw()
  local w, h = mon.getSize()
  local can = mon.isColor and mon.isColor()
  local function bg(c) mon.setBackgroundColor(can and c or colors.black) end
  local function fg(c) mon.setTextColor(can and c or colors.white) end
  local function bar(row, text, padColor, txtColor)
    bg(padColor); fg(txtColor)
    if row <= h then
      mon.setCursorPos(1, row); mon.write((" "):rep(w))
      mon.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), row)
      mon.write(text)
    end
  end

  bg(C.bg); mon.clear()

  -- title bar with our own version on the right
  bg(C.title); fg(C.titleText)
  mon.setCursorPos(1, 1); mon.write((" "):rep(w))
  local title = "BASE CONTROL"
  mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
  mon.write(title)
  local vtag = "v" .. myVersion()
  mon.setCursorPos(math.max(1, w - #vtag + 1), 1); mon.write(vtag)

  -- buttons
  for _, b in ipairs(buttons) do
    bg(b.color); fg(b.text)
    for row = b.y1, b.y2 do
      if row <= h then mon.setCursorPos(1, row); mon.write((" "):rep(w)) end
    end
    local mid = math.floor((b.y1 + b.y2) / 2)
    if mid <= h then
      mon.setCursorPos(math.max(1, math.floor((w - #b.label) / 2) + 1), mid)
      mon.write(b.label)
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

-- census: returns { { label = , version = }, ... } including ourselves,
-- sorted by label. We re-ping every second across the window: the flux
-- computer does heavy block-reader reads and can miss a single ping, so a
-- one-shot drops it. Several pings give every box a chance to answer.
local function census()
  local label = os.getComputerLabel() or "console"
  local list = { { label = label, version = myVersion() } }
  local seen = { [label] = true }
  local deadline = os.clock() + CENSUS_WINDOW
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
    -- timer events just wake us to re-ping / re-check the deadline
  end
  table.sort(list, function(a, b) return a.label < b.label end)
  return list
end

local function showVersions()
  status = "checking versions..."
  draw()
  local list = census()
  -- the most common version is "current"; flag the odd ones out
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
  status = (best == #list and #list > 0)
    and "all in sync" or "versions differ - see the orange rows"
end

buttons[1].action = function()
  rednet.broadcast({ cmd = "update", token = CTL_TOKEN }, CTL_PROTOCOL)
  resultLines = {
    { text = "UPDATE pushed to the base.", color = C.info },
    { text = "tap VERSIONS in a few seconds to confirm.", color = C.hint },
  }
  status = "update pushed"
end
buttons[2].action = showVersions
buttons[3].action = function()
  if not sledToken then
    resultLines = { { text = "No sled token on this computer.", color = C.warn },
      { text = "add sledctl.conf to enable sled updates.", color = C.hint } }
    status = "no sled token"
    return
  end
  rednet.broadcast({ cmd = "update", token = sledToken }, SLED_PROTOCOL)
  resultLines = { { text = "Sled fleet update pushed.", color = C.ok } }
  status = "sled update pushed"
end

local function hit(x, y)
  for _, b in ipairs(buttons) do
    if y >= b.y1 and y <= b.y2 then return b end
  end
end

-- answer version censuses, and auto-update with the base. A broadcast never
-- loops back to its sender, so tapping our OWN UPDATE ALL never reboots us -
-- only an update-all fired from elsewhere (chat / [u]) does, when you're not
-- standing at this panel anyway. So the console stays in version-sync.
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
