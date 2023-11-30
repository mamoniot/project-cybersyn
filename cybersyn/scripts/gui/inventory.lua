local gui = require("__flib__.gui-lite")

local util = require("scripts.gui.util")
local templates = require("scripts.gui.templates")
local format = require("__flib__.format")

local inventory_tab = {}

function inventory_tab.create()
	return {
		tab = {
			name = "manager_inventory_tab",
			type = "tab",
			caption = { "cybersyn-gui.inventory" },
			ref = { "inventory", "tab" },
			handler = inventory_tab.handle.on_inventory_tab_selected
		},
		content = {
			name = "manager_inventory_content_frame",
			type = "flow",
			style_mods = { horizontal_spacing = 12 },
			direction = "horizontal",
			ref = { "inventory", "content_frame" },
			templates.inventory_slot_table("provided", 10),
			templates.inventory_slot_table("requested", 10),
			templates.inventory_slot_table("in_transit", 6),
		},
	}
end

---@param map_data MapData
---@param player_data PlayerData
function inventory_tab.build(map_data, player_data)
	local refs = player_data.refs

	local search_query = player_data.search_query
	local search_item = player_data.search_item
	local search_network_name = player_data.search_network_name
	local search_network_mask = player_data.search_network_mask
	local search_surface_idx = player_data.search_surface_idx

	local inventory_provided = {}
	local inventory_requested = {}
	local inventory_in_transit = {}

	for _, station in pairs(map_data.stations) do
		local entity = station.entity_stop
		if not entity.valid or not station.network_name then
			goto continue
		end

		if search_query then
			if not string.match(entity.backer_name, search_query) then
				goto continue
			end
		end

		if search_surface_idx then
			if station.surface_index ~= search_surface_idx then
				goto continue
			end
		end

		if search_network_name then
			if not bit32.btest(get_network_mask(station, search_network_name), search_network_mask) then
				goto continue
			end
		elseif search_network_mask ~= -1 then
			if station.network_name == NETWORK_EACH then
				for _, network_mask in pairs(station.network_mask--[[@as table]]) do
					if bit32.btest(network_mask, search_network_mask) then
						goto has_match
					end
				end
				goto continue
			elseif not bit32.btest(station.network_mask, search_network_mask) then
				goto continue
			end
			::has_match::
		end

		for item_name, item_count in pairs(station.p_item_counts) do
			if not search_item or item_name == search_item then
				inventory_provided[item_name] = (inventory_provided[item_name] or 0) + item_count
			end
		end

		for item_name, item_count in pairs(station.r_item_counts) do
			if not search_item or item_name == search_item then
				inventory_requested[item_name] = (inventory_requested[item_name] or 0) + item_count
			end
		end

		for item_name, item_count in pairs(station.deliveries) do
			if not search_item or item_name == search_item then
				if item_count > 0 then
					inventory_in_transit[item_name] = (inventory_in_transit[item_name] or 0) + item_count
				end
			end
		end

		::continue::
	end

	--TODO: add sorting options

	local function add_child(children, name, count, style)
		local sprite_path, image_path, item_string = util.generate_item_references(name)
		if sprite_path then
			children[#children+1] = {
				type = "sprite-button",
				enabled = false,
				style = style,
				sprite = sprite_path,
				number = count,
				tooltip = {"", image_path.." [font=default-semibold]", item_string, "[/font]\n"..format.number(count)},
			}
		end
	end

	local provided_children = {}
	local requested_children = {}
	local in_transit_children = {}

	for name, count in pairs(inventory_provided) do
		add_child(provided_children, name, count, "flib_slot_button_green")
	end
	for name, count in pairs(inventory_requested) do
		add_child(requested_children, name, count, "flib_slot_button_red")
	end
	for name, count in pairs(inventory_in_transit) do
		add_child(in_transit_children, name, count, "flib_slot_button_blue")
	end

	if next(refs.inventory_provided_table.children) ~= nil then
		refs.inventory_provided_table.clear()
	end
	if next(refs.inventory_requested_table.children) ~= nil then
		refs.inventory_requested_table.clear()
	end
	if next(refs.inventory_in_transit_table.children) ~= nil then
		refs.inventory_in_transit_table.clear()
	end

	gui.add(refs.inventory_provided_table, provided_children)
	gui.add(refs.inventory_requested_table, requested_children)
	gui.add(refs.inventory_in_transit_table, in_transit_children)
end

inventory_tab.handle = {}

---@param e {player_index: uint}
function inventory_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = global.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

---@param player LuaPlayer
---@param player_data PlayerData
function inventory_tab.handle.on_inventory_tab_selected(player, player_data)
	player_data.selected_tab = "inventory_tab"
end

gui.add_handlers(inventory_tab.handle, inventory_tab.wrapper)

return inventory_tab
