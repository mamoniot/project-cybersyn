local gui = require("__flib__.gui-lite")
local mod_gui = require("__core__.lualib.mod-gui")

local manager = require("scripts.gui.manager")


--- @class PlayerData
--- @field refs {[string]: LuaGuiElement}?
--- @field search_query string?
--- @field search_network_name string?
--- @field search_network_mask int
--- @field search_surface_idx uint?
--- @field search_item string?
--- @field trains_orderings uint[]
--- @field trains_orderings_invert boolean[]
--- @field pinning boolean




local function top_left_button_update(player, player_data)
	local button_flow = mod_gui.get_button_flow(player)
	local button = button_flow["top_left_button"]
	if player_data.disable_top_left_button then
		if button then
			button.destroy()
		end
	elseif not button then
		gui.add(button_flow, {
			type = "sprite-button",
			name = "top_left_button",
			style = "mis_mod_gui_button_green",
			sprite = "mis_configure_white",
			tooltip = { "", "\n", { "mis-config-gui.configure-tooltip" } },
			handler = manager.handle.toggle,
		})
	end
end



local manager_gui = {}

function manager_gui.on_lua_shortcut(e)
	if e.prototype_name == "ltnm-toggle-gui" then
		manager.wrapper(e, manager.handle.toggle)
	end
end



function manager_gui.on_player_created(e)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = {
		search_network_mask = -1,
		trains_orderings = {},
		trains_orderings_invert = {},
		pinning = false,
		refs = manager.create(player),
	}
	global.manager_data.players[e.player_index] = player_data

	manager.update(global, player, player_data)
	top_left_button_update(player, player_data)
end

function manager_gui.on_player_removed(e)
	global.manager_data.players[e.player_index] = nil
end

--script.on_event(defines.events.on_player_joined_game, function(e)
--end)

--script.on_event(defines.events.on_player_left_game, function(e)
--end)

function manager_gui.on_runtime_mod_setting_changed(e)
	if e.setting == "cybersyn-disable-top-left-button" then
		if not e.player_index then return end
		local player = game.get_player(e.player_index)
		if not player then return end

		local player_data = global.manager_data.players[e.player_index]
		player_data.disable_top_left_button = player.mod_settings["cybersyn-disable-top-left-button"].value
		top_left_button_update(player, player_data)
	end
end


--gui.handle_events()

return manager_gui