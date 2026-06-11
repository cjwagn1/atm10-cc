--[[
fluxprobe.lua - read the TRUE flux total past the 2.147G int clamp.

Point an Advanced Peripherals Block Reader at the ME Drive that holds your
flux cells (reader face touching the drive), attach the reader to this
computer (adjacent or via wired modem), then run:

  fluxprobe            -- auto-find the block reader
  fluxprobe <name>     -- use a specific reader peripheral

Why this works: AppFlux stores each cell's energy as a long in the item
component "appflux:fe_energy" (no 32-bit limit), and the Block Reader's
getBlockData() returns the drive's full saved data. This program walks that
data, sums every fe_energy value it finds, and saves the raw dump to
fluxdump.txt so we can adapt if AE2's save layout differs.
]]

local args = { ... }

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
  if n % 1 == 0 and math.abs(n) < 2 ^ 53 then
    return ("%.0f"):format(n)
  end
  return tostring(n)
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local na, nb = type(a) == "number", type(b) == "number"
    if na ~= nb then return na end
    if na then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

-- self-contained serializer (textutils-free so the harness can run this)
local function serialize(v, out, indent)
  if type(v) == "table" then
    out[#out + 1] = "{\n"
    for _, k in ipairs(sortedKeys(v)) do
      out[#out + 1] = indent .. "  ["
        .. (type(k) == "string" and ("%q"):format(k) or tostring(k)) .. "] = "
      serialize(v[k], out, indent .. "  ")
      out[#out + 1] = ",\n"
    end
    out[#out + 1] = indent .. "}"
  elseif type(v) == "number" then
    out[#out + 1] = exact(v)
  elseif type(v) == "string" then
    out[#out + 1] = ("%q"):format(v)
  else
    out[#out + 1] = tostring(v)
  end
end

local function walk(t, path, hits, extras, seen)
  if seen[t] then return end
  seen[t] = true
  for _, k in ipairs(sortedKeys(t)) do
    local v = t[k]
    local p = path == "" and tostring(k) or (path .. "." .. tostring(k))
    if type(v) == "table" then
      walk(v, p, hits, extras, seen)
    elseif type(v) == "number" then
      local kl = tostring(k):lower()
      if kl:find("fe_energy", 1, true) then
        hits[#hits + 1] = { path = p, value = v }
      elseif kl:find("energy", 1, true) then
        extras[#extras + 1] = { path = p, value = v }
      end
    end
  end
end

-- ------------------------------------------------------------------ main

local reader
if args[1] then
  reader = peripheral.wrap(args[1])
else
  reader = peripheral.find("block_reader")
end
if not reader or type(reader.getBlockData) ~= "function" then
  print("No Block Reader found.")
  print("Craft one (Advanced Peripherals), place it with its")
  print("face touching the ME Drive that holds your flux")
  print("cells, connect it to this computer, and re-run.")
  return
end

local okN, blockName = pcall(reader.getBlockName)
local okD, data = pcall(reader.getBlockData)
if not okD or type(data) ~= "table" then
  print("Reader returned no block data.")
  print("Is its face touching the ME Drive?")
  return
end

print("Block: " .. tostring(okN and blockName or "?"))

local hits, extras = {}, {}
walk(data, "", hits, extras, {})

local report = { "Block: " .. tostring(okN and blockName or "?") }
local function say(s)
  print(s)
  report[#report + 1] = s
end

if #hits == 0 then
  say("No appflux:fe_energy keys in this block's data.")
  say("Point the reader at the ME Drive containing the")
  say("FE cells, or share fluxdump.txt so we can adapt.")
  if #extras > 0 then
    say("Other energy-like values seen:")
    for i = 1, math.min(#extras, 8) do
      say("  " .. extras[i].path .. " = " .. fmt(extras[i].value))
    end
  end
else
  say(("fe_energy values found: %d"):format(#hits))
  local total = 0
  for i, hit in ipairs(hits) do
    total = total + hit.value
    if i <= 12 then
      say("  " .. hit.path .. " = " .. fmt(hit.value))
    end
  end
  if #hits > 12 then say(("  ... and %d more"):format(#hits - 12)) end
  say(("TRUE TOTAL: %s FE"):format(fmt(total)))
  say("  (exact: " .. exact(total) .. ")")
end

local chunks = {}
serialize(data, chunks, "")
local ok, f = pcall(fs.open, "fluxdump.txt", "w")
if ok and f then
  f.write(table.concat(report, "\n") .. "\n\nFull block data:\n"
    .. table.concat(chunks) .. "\n")
  f.close()
  print("Saved full dump to fluxdump.txt")
  print("(pastebin put fluxdump.txt to share)")
end
