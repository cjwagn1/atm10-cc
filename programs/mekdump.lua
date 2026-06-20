--[[
mekdump.lua - dump what attached Mekanism machines expose to ComputerCraft.

Used to build a chemical-production probe (chemprobe) for YOUR specific
machines: wire this computer to a chemical-PRODUCING machine (a wired modem
cable from the computer to the machine, then right-click both modems), run
`mekdump`, and paste what it prints. It also saves mekdump.txt.

We need this because a Pressurized Tube only reports its buffer (what's sitting
in the pipe, ~0 while flowing), not a flow rate - but the producing machine
reports its own output rate (getProductionRate / getProcessRate / etc.), and
that method name differs per machine. This shows which one your machine has.

  wget https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/mekdump.lua
  mekdump
]]

-- peripherals that are NOT the machine we're after (don't dump these)
local SKIP = {
  modem = true, monitor = true, me_bridge = true, rs_bridge = true,
  chat_box = true, block_reader = true, computer = true, drive = true,
  printer = true, speaker = true,
}

-- method names worth CALLING (zero-arg getters that hint at a chemical or a
-- rate); everything is pcall'd so a method that needs args just gets skipped
local function looksUseful(m)
  local ml = m:lower()
  return ml:find("rate") or ml:find("output") or ml:find("buffer")
    or ml:find("chemical") or ml:find("production") or ml:find("active")
    or ml:find("process") or ml:find("stored") or ml:find("injection")
    or ml:find("getgas") or ml:find("recipe") or ml:find("capacity")
end

local out = {}
local function emit(s) out[#out + 1] = s; print(s) end

-- self-contained one-line serializer (textutils-free so the test harness, which
-- has no textutils, can run this too), deterministic key order
local function compact(v, depth)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return ("%q"):format(v) end
  if t ~= "table" then return "<" .. t .. ">" end
  if (depth or 0) > 2 then return "{...}" end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    local ks = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
    parts[#parts + 1] = ks .. "=" .. compact(v[k], (depth or 0) + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

emit("=== mekdump ===")
local found = 0
for _, name in ipairs(peripheral.getNames()) do
  local types = { peripheral.getType(name) }
  local skip = false
  for _, t in ipairs(types) do if SKIP[t] then skip = true end end
  if not skip then
    found = found + 1
    emit(("peripheral %q  [%s]"):format(name, table.concat(types, ",")))
    local methods = (peripheral.getMethods and peripheral.getMethods(name)) or {}
    table.sort(methods)
    emit("  methods: " .. table.concat(methods, ", "))
    for _, m in ipairs(methods) do
      if looksUseful(m) then
        local ok, v = pcall(peripheral.call, name, m)
        if ok then
          emit(("    %s() = %s"):format(m, compact(v)))
        else
          emit(("    %s() needs args / errored"):format(m))
        end
      end
    end
    emit("")
  end
end

if found == 0 then
  emit("No machine peripherals found.")
  emit("Wire a wired modem from this computer to a chemical machine,")
  emit("right-click BOTH modems (they glow red), then re-run mekdump.")
end

local f = fs.open("mekdump.txt", "w")
if f then f.write(table.concat(out, "\n")); f.close(); emit("(saved mekdump.txt)") end
