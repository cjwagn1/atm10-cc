--[[
installer.lua - one-shot setup for flux computers (ATM10 / CC:Tweaked)

Bootstrap a fresh computer with a single command:

  wget run <url-of-this-file> dash         -- the ME-side sensor computer
  wget run <url-of-this-file> wall         -- a monitor wall display

It downloads every program from the deploy manifest, writes a startup.lua
for the chosen role (so the computer auto-starts after server restarts and
chunk reloads), and records the manifest URL so `update` can refresh
everything later.
]]

local DEFAULT_MANIFEST =
  "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/deploy/manifest.lua"

local args = { ... }
local role = args[1]
local manifestUrl = args[2] or DEFAULT_MANIFEST

if role ~= "dash" and role ~= "wall" then
  print("Usage: installer <dash|wall> [manifestUrl]")
  print("  dash = the computer wired to the ME system")
  print("  wall = a monitor wall display computer")
  return
end
if manifestUrl:find("__MANIFEST", 1, true) then
  print("No manifest URL baked in - pass one:")
  print("  installer " .. role .. " <manifestUrl>")
  return
end

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
  local f = fs.open(file.path, "w")
  f.write(data)
  f.close()
  print("  installed " .. file.path)
end

local startupProg = manifest.roles and manifest.roles[role]
if startupProg then
  local f = fs.open("startup.lua", "w")
  f.write(('shell.run(%q)\n'):format(startupProg))
  f.close()
  print("  startup -> " .. startupProg)
end

local f = fs.open(".fluxdeploy", "w")
f.write(role .. "\n" .. manifestUrl .. "\n")
f.close()

print(("Installed v%s as role '%s'."):format(
  tostring(manifest.version), role))
print("Run 'update' anytime to pull the latest.")
if startupProg then
  print("Reboot (or run '" .. startupProg .. "') to start.")
end
