--[[
update-all.lua - push the standard updater to every stationary base
computer at once (fluxwall / fluxdash / mesensor / historian), then update
this computer too.

Each listening computer verifies a shared courtesy token, acks so we can
tally who's alive, then runs `update` itself - which downloads the latest
files from the deploy manifest and reboots back into its role (startup.lua).

Run it anywhere on the base mesh:  update-all
The historian's [u] key runs this same program.

Sleds are deliberately NOT included - they listen on their own "sledctl"
channel, so one never reboots mid-relocation by surprise. Update the fleet
from sledctl (press u) when it's safe.
]]

local CTL_PROTOCOL = "basectl"
local CTL_TOKEN    = "flux"  -- courtesy lock, not cryptography; matches the
                             -- listeners baked into each base program
local ACK_WINDOW   = 3       -- seconds to gather acks before updating self

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

-- best-effort: which manifest version are we about to pull? Purely for the
-- chat/console confirmation - each box re-fetches the same manifest itself.
local function targetVersion()
  if not http then return nil end
  local f = fs.open(".fluxdeploy", "r")
  if not f then return nil end
  f.readLine()                 -- role (unused here)
  local url = f.readLine()
  f.close()
  if not url then return nil end
  local bust = url .. (url:find("?", 1, true) and "&" or "?")
    .. "cb=" .. tostring(os.epoch and os.epoch("utc") or os.clock())
  local h = http.get(bust)
  if not h then return nil end
  local body = h.readAll()
  h.close()
  local chunk = load(body, "=manifest", "t", {})
  if not chunk then return nil end
  local ok, m = pcall(chunk)
  if ok and type(m) == "table" then return m.version end
  return nil
end

if not openModems() then
  print("No modem found - attach a wireless or ender")
  print("modem so this computer can reach the base mesh.")
  return
end

local chatBox = findChatBox()
local ver     = targetVersion()
local vtag    = ver and ("v" .. tostring(ver)) or "the latest version"

if chatBox then
  pcall(chatBox.sendMessage, "base updating to " .. vtag .. "...", "base")
end

print("Broadcasting update to the base (" .. vtag .. ")...")
rednet.broadcast({ cmd = "update", token = CTL_TOKEN }, CTL_PROTOCOL)

-- gather acks for a rough "who heard us" tally. Best-effort: every box
-- updates whether or not its ack lands inside the window, so a missing name
-- means "ack was slow", not necessarily "didn't update" - check it if unsure.
local seen, order = {}, {}
local deadline = os.clock() + ACK_WINDOW
while true do
  local left = deadline - os.clock()
  if left <= 0 then break end
  local timer = os.startTimer(left)
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then
    break
  elseif ev[1] == "rednet_message" and ev[4] == CTL_PROTOCOL
    and type(ev[3]) == "table" and ev[3].ack then
    local who = ev[3].label or ("id " .. tostring(ev[3].id))
    if not seen[who] then
      seen[who] = true
      order[#order + 1] = who
      print("  ack  " .. who)
    end
  end
end

-- one consolidated line to console AND chat, so you can confirm from either
-- which version is going out and which computers answered
local summary
if #order > 0 then
  summary = ("%s: %d updating - %s"):format(
    vtag, #order, table.concat(order, ", "))
else
  summary = vtag .. ": broadcast sent (no acks in " .. ACK_WINDOW .. "s)"
end
print(summary)
print("Updating self...")
if chatBox then pcall(chatBox.sendMessage, summary, "base") end

-- hand the terminal back in case a display had it redirected to a monitor
pcall(function() term.redirect(term.native()) end)
if shell and shell.run then
  shell.run("update")  -- downloads + reboots into our own role
end
print("update failed - run 'update' by hand to see why.")
