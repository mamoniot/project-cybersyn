-- migrations/2.0.36.lua
-- Purpose:
-- 1. Detect old value of the startup setting "cybersyn-manager-enabled".
-- 2. If it was false, notify all players that they should enable it.
-- 3. (Optional) any other migration work you want to do.

-- Safety: settings.startup is still readable here.
local mgr_setting = settings.startup["cybersyn-manager-enabled"]

-- Only bother players if:
--   a) the setting exists (older versions had it),
--   b) it is currently false.
if mgr_setting and mgr_setting.value == false then
  -- Notify every connected player once during migration
  for _, player in pairs(game.players) do
    if player and player.valid then
       player.print({
        "",
        "[Project Cybersyn] The startup setting '",
        {"mod-setting-name.cybersyn-manager-enabled"},
        "' is now expected to be ON by default. If you want to enable it than exit the game to main menu → Settings → Mod Settings → Startup, enable it, and restart the save."
      })
    end
  end
end