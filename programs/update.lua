--[[
update.lua - refresh every installed flux program from the deploy manifest
recorded by installer.lua, then reboot into the new version.
]]

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
  local h, err = http.get(url)
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

print(("Now at v%s. Rebooting..."):format(tostring(manifest.version)))
sleep(1)
os.reboot()
