--[[
update.lua - refresh every installed flux program from the deploy manifest
recorded by installer.lua, then reboot into the new version.
]]

-- `update fromall` is how update-all (and a box answering its push) invokes
-- us; a human typing `update` passes nothing. Only the fromall path leaves
-- the chat-announce breadcrumb, so manual updates stay silent.
local fromAll = (select(1, ...) == "fromall")

local f = fs.open(".fluxdeploy", "r")
if not f then
  print("Not installed - run the installer first.")
  return
end
local role = f.readLine()
local manifestUrl = f.readLine()
f.close()

local function fetch(url)
  if not http then
    return nil, "http API is disabled on this server"
  end
  -- cache-buster: github's raw CDN caches ~5 min; a unique query string
  -- makes it fetch fresh, so updates apply the moment they're pushed
  local bust = url .. (url:find("?", 1, true) and "&" or "?")
    .. "cb=" .. tostring(os.epoch("utc"))
  local h, err = http.get(bust)
  if not h then return nil, err end
  local body = h.readAll()
  h.close()
  return body
end

print("Fetching manifest...")
local body, err = fetch(manifestUrl)
if not body then
  print("Failed: " .. tostring(err))
  return
end

local chunk, lerr = load(body, "=manifest", "t", {})
local ok, manifest = false, nil
if chunk then ok, manifest = pcall(chunk) end
if not ok or type(manifest) ~= "table" or type(manifest.files) ~= "table" then
  print("Bad manifest: " .. tostring(lerr or manifest))
  return
end

for _, file in ipairs(manifest.files) do
  local data, ferr = fetch(file.url)
  if not data then
    print(("Failed to fetch %s: %s"):format(file.path, tostring(ferr)))
    return
  end
  local out = fs.open(file.path, "w")
  out.write(data)
  out.close()
  print("  updated " .. file.path)
end

local startupProg = manifest.roles and manifest.roles[role]
if startupProg then
  local out = fs.open("startup.lua", "w")
  out.write(('shell.run(%q)\n'):format(startupProg))
  out.close()
end

-- always record the running version (persistent) so any box can answer a
-- version census; only the fromall path leaves the one-shot .fluxupdated
-- breadcrumb that makes the historian announce + census in chat on reboot
local ver = tostring(manifest.version)
local vf = fs.open(".fluxversion", "w")
if vf then
  vf.write(ver)
  vf.close()
end
if fromAll then
  local stamp = fs.open(".fluxupdated", "w")
  if stamp then
    stamp.write(ver)
    stamp.close()
  end
end

print(("Now at v%s. Rebooting..."):format(ver))
sleep(1)
os.reboot()
