--By Mami
debug_log = false

require("scripts.constants")
require("scripts.lib")
require("scripts.commands")
require("scripts.global")
require("scripts.factorio-api")
require("scripts.layout")
require("scripts.surface-connections")
require("scripts.mod-compatibility.se-elevator-connection")
require("scripts.mod-compatibility.se-elevator-travel")
require("scripts.central-planning")
require("scripts.train-events")
require("scripts.gui")
require("scripts.migrations")
require("scripts.main")
require("scripts.remote-interface")

-- Enable support for the Global Variable Viewer debugging mod, if it is installed.
if script.active_mods["gvv"] then require("__gvv__.gvv")() end
