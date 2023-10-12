local gui = require("__flib__.gui-lite")
local mod_gui = require("__core__.lualib.mod-gui")

local manager = require("scripts.gui.manager")

--- @class Manager
--- @field players table<uint, PlayerData>
--- @field item_order table<string, int>

--- @class PlayerData
--- @field is_manager_open boolean
--- @field refs {[string]: LuaGuiElement}
--- @field search_query string?
--- @field search_network_name string?
--- @field search_network_mask int
--- @field search_surface_idx uint?
--- @field search_item string?
--- @field trains_orderings uint[]
--- @field trains_orderings_invert boolean[]
--- @field pinning boolean
--- @field selected_tab string?




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
			tooltip = { "", "\n", { "cybersyn.gui.configure-tooltip" } },
			handler = manager.handle.manager_toggle,
		})
	end
end



local manager_gui = {}

function manager_gui.on_lua_shortcut(e)
	if e.prototype_name == "cybersyn-toggle-gui" or e.input_name == "cybersyn-toggle-gui" or e.element then
		if e.element then
			if e.element.name == "manager_window" then
				manager.wrapper(e, manager.handle.manager_toggle)
			elseif e.element.name == COMBINATOR_NAME and e.name == defines.events.on_gui_closed then
				-- With the manager enabled, this handler overwrites the combinator's
				-- on_gui_close handler. Copy the logic to close the combinator's GUI here
				-- as well.
				local player = game.get_player(e.player_index)
				if not player then return end
				if player.gui.screen[COMBINATOR_NAME] then
					player.gui.screen[COMBINATOR_NAME].destroy()
				end
			end
		else
			manager.wrapper(e, manager.handle.manager_toggle)
		end
	end
end



local function create_player(player_index)
	local player = game.get_player(player_index)
	if not player then return end

	local player_data = {
		search_network_mask = -1,
		trains_orderings = {},
		trains_orderings_invert = {},
		pinning = false,
		refs = manager.create(player),
		selected_tab = "stations_tab",
	}
	global.manager.players[player_index] = player_data

	--manager.update(global, player, player_data)
	--top_left_button_update(player, player_data)
end

function manager_gui.on_player_created(e)
	create_player(e.player_index)
end

function manager_gui.on_player_removed(e)
	global.manager.players[e.player_index] = nil
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

		local player_data = global.manager.players[e.player_index]
		player_data.disable_top_left_button = player.mod_settings["cybersyn-disable-top-left-button"].value
		top_left_button_update(player, player_data)
	end
end

commands.add_command("cybersyn_rebuild_manager_windows", nil, function(command)
	local manager_data = global.manager
	if manager_data then

		---@param v PlayerData
		for i, v in pairs(manager_data.players) do
			local player = game.get_player(i)
			if player ~= nil then
				v.refs.manager_window.destroy()
				v.refs = manager.create(player)
			end
		end
	end
end)


--- @param manager Manager
local function init_items(manager)
	local item_order = {}
	manager.item_order = item_order
	local i = 1

	for _, protos in pairs{game.item_prototypes, game.fluid_prototypes} do
		--- @type (LuaItemPrototype|LuaFluidPrototype)[]
		local all_items = {}
		for _, proto in pairs(protos) do
			all_items[#all_items + 1] = proto
		end
		table.sort(all_items, function(a, b)
			if a.group.order == b.group.order then
				if a.subgroup.order == b.subgroup.order then
					return a.order < b.order
				else
					return a.subgroup.order < b.subgroup.order
				end
			else
				return a.group.order < b.group.order
			end
		end)
		for _, v in ipairs(all_items) do
			item_order[v.name] = i
			i = i + 1
		end
	end
end


function manager_gui.on_migration()
	if not global.manager then
		manager_gui.on_init()
	end
	
	for i, p in pairs(game.players) do
		if global.manager.players[i] == nil then
			create_player(i)
		end
	end
	
	for i, v in pairs(global.manager.players) do
		manager_gui.reset_player(i, v)
	end

	init_items(global.manager)
end

function manager_gui.on_init()
	global.manager = {
		players = {},
	}
	init_items(global.manager)
end
--gui.handle_events()

---@param global cybersyn.global
function manager_gui.tick(global)
	local manager_data = global.manager
	if manager_data then
		for i, v in pairs(manager_data.players) do
			if v.is_manager_open then
				local query_limit = settings.get_player_settings(i)["cybersyn-manager-result-limit"].value
				manager.update(global, v, query_limit)
			end
		end
	end
end

---@param i string|uint
---@param v LuaPlayer
function manager_gui.reset_player(i, v)
	local player = game.get_player(i)
	if player ~= nil then
		v.refs.manager_window.destroy()
		v.refs = manager.create(player)
	end
end

return manager_gui
