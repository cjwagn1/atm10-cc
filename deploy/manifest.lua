-- Deploy manifest for the ATM10 telemetry mesh.
-- installer.lua / update.lua fetch this file, then download everything
-- listed below. Bump `version` whenever programs change; in-game
-- computers pick it up with a single `update`.
return {
  version = 20,
  files = {
    { path = "sled",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/sled.lua" },
    { path = "sledctl",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/sledctl.lua" },
    { path = "fluxdash",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/fluxdash.lua" },
    { path = "fluxwall",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/fluxwall.lua" },
    { path = "mesensor",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/mesensor.lua" },
    { path = "historian",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/historian.lua" },
    { path = "fluxprobe",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/fluxprobe.lua" },
    { path = "update",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/update.lua" },
    { path = "update-all",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/update-all.lua" },
    { path = "console",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/console.lua" },
    { path = "installer",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua" },
  },
  roles = {
    dash = "fluxdash",
    wall = "fluxwall",
    me = "mesensor",
    historian = "historian",
    sled = "sled",
    sledctl = "sledctl",
    console = "console",
  },
}
