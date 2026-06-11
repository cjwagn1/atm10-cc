--[[
demo.lua - render fluxdash v2 screens in realistic ATM10 scenarios so you
can eyeball the dashboard without booting Minecraft.

  toolchain/lua-5.2.4/src/lua harness/demo.lua
]]

local CC = dofile("harness/cc_env.lua")

local function banner(s)
  print(("="):rep(60))
  print("  " .. s)
  print(("="):rep(60))
end

local function show(label, text)
  print("--- " .. label .. " " .. ("-"):rep(40 - #label))
  print(text)
  print("")
end

-- 1. mid-game: charging hard, monitor on the wall, ME bridge attached
banner("Scenario 1: charging (laser drills feeding flux cells)")
local env = CC.new{ termW = 51, termH = 19 }
env:addModem("back")
env:addEnergyPeripheral("appflux:flux_accessor_0",
  { energy = 1.5e9, capacity = 2147483647, ratePerSec = 250000 })
env:addMeBridge("me_bridge_0",
  { stored = 740000, max = 1600000, usage = 96.4, input = 130 })
env:addMonitor("monitor_3", { w = 39, h = 13 })
env:run("programs/fluxdash.lua", {}, { maxTime = 12 })
show("computer terminal (51x19)", env:termText())
show("wall monitor (39x13 @ 0.5 scale)", env:monitorText("monitor_3"))

-- 2. endgame stockpile: reading saturates at the Forge int ceiling
banner("Scenario 2: endgame stockpile (int clamp)")
local env2 = CC.new{ termW = 51, termH = 19 }
env2:addModem("back")
env2:addEnergyPeripheral("appflux:flux_accessor_0",
  { energy = 99e9, capacity = 281474976710656 }) -- one 256M cell
env2:run("programs/fluxdash.lua", {}, { maxTime = 3 })
show("computer terminal", env2:termText())

-- 3. the scan Carter will run first in-game
banner("Scenario 3: fluxdash scan")
local env3 = CC.new{ termW = 51, termH = 19 }
env3:addModem("back")
env3:addEnergyPeripheral("appflux:flux_accessor_0",
  { energy = 4.2e9, capacity = 8.6e9 })
env3:addMeBridge("me_bridge_0",
  { stored = 740000, max = 1600000, usage = 96.4, input = 130 })
env3:run("programs/fluxdash.lua", { "scan" }, { maxTime = 3 })
show("computer terminal", env3:termText())
