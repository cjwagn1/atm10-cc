-- Deploy manifest for the ATM10 telemetry mesh.
-- installer.lua / update.lua fetch this file, then download everything
-- listed below. Bump `version` whenever programs change; in-game
-- computers pick it up with a single `update`.
return {
  version = 6,
  files = {
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
    { path = "installer",
      url = "https://raw.githubusercontent.com/cjwagn1/atm10-cc/main/programs/installer.lua" },
  },
  roles = {
    dash = "fluxdash",
    wall = "fluxwall",
    me = "mesensor",
    historian = "historian",
  },
}
