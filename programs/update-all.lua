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

if not openModems() then
  print("No modem found - attach a wireless or ender")
  print("modem so this computer can reach the base mesh.")
  return
end

local chatBox = findChatBox()
if chatBox then
  pcall(chatBox.sendMessage, "base updating to the latest version", "base")
end

print("Broadcasting update to the base...")
rednet.broadcast({ cmd = "update", token = CTL_TOKEN }, CTL_PROTOCOL)

-- gather acks for a rough "who heard us" tally. Best-effort: every box
-- updates whether or not its ack lands inside the window, so a missing name
-- means "ack was slow", not necessarily "didn't update" - check it if unsure.
local seen, n = {}, 0
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
      n = n + 1
      print("  ack  " .. who)
    end
  end
end

print(("%d responded in %ds. Updating self..."):format(n, ACK_WINDOW))
-- hand the terminal back in case a display had it redirected to a monitor
pcall(function() term.redirect(term.native()) end)
if shell and shell.run then
  shell.run("update")  -- downloads + reboots into our own role
end
print("update failed - run 'update' by hand to see why.")
