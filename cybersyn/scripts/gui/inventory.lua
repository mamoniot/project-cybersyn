local gui = require("__flib__.gui")

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
			handler = inventory_tab.handle.on_inventory_tab_selected,
		},
		content = {
			name = "manager_inventory_content_frame",
			type = "flow",
			style_mods = { horizontal_spacing = 12 },
			direction = "horizontal",
			ref = { "inventory", "content_frame" },
			templates.inventory_slot_table("provided", 12),
			templates.inventory_slot_table("in_transit", 8),
			templates.inventory_slot_table("requested", 7),
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
	local inventory_in_transit = {}
	local inventory_requested = {}

	local stations_sorted = {}

	for id, station in pairs(map_data.stations) do
		local entity = station.entity_stop
		if not entity.valid then
			goto continue
		end

		if search_query then
			if not string.match(entity.backer_name, search_query) then
				goto continue
			end
		end
		-- move surface comparison up higher in query to short circuit query earlier if surface doesn't match
		if search_surface_idx then
			if entity.surface.index ~= search_surface_idx then
				goto continue
			end
		end
		if search_network_name then
			if search_network_name ~= station.network_name then
				goto continue
			end
			local train_flag = get_network_mask(station, station.network_name)
			if not bit32.btest(search_network_mask, train_flag) then
				goto continue
			end
		elseif search_network_mask ~= -1 then
			if station.network_name == NETWORK_EACH then
				local masks = station.network_mask --[[@as {}]]
				for _, network_mask in pairs(masks) do
					if bit32.btest(search_network_mask, network_mask) then
						goto has_match
					end
				end
				goto continue
				::has_match::
			elseif not bit32.btest(search_network_mask, station.network_mask) then
				goto continue
			end
		end

		if search_item then
			if station.deliveries then
				for item_name, _ in pairs(station.deliveries) do
					if item_name == search_item then
						goto has_match
					end
				end
			end
			local comb1_signals, _ = get_signals(station)
			if comb1_signals then
				for _, signal_ID in pairs(comb1_signals) do
					local item = signal_ID.signal.name
					-- FIXME handle signal_ID.signal.quality
					if item then
						if item == search_item then
							goto has_match
						end
					end
				end
			end
			goto continue
			::has_match::
		end

		stations_sorted[#stations_sorted + 1] = id
		::continue::
	end

	for i, station_id in pairs(stations_sorted) do
		--- @class Station
		local station = map_data.stations[station_id]

		local comb1_signals, _ = get_signals(station)
		if comb1_signals then
			for _, v in pairs(comb1_signals) do
				local item = v.signal
				local count = v.count
				local item_hash = hash_signal(item)
				if item.type ~= "virtual" then
					if station.is_p and count > 0 then
						if inventory_provided[item_hash] == nil then
							inventory_provided[item_hash] = {count, 1}
						else
							inventory_provided[item_hash][1] = inventory_provided[item_hash][1] + count
							inventory_provided[item_hash][2] = inventory_provided[item_hash][2] + 1
						end
					end
					if station.is_r and count < 0 then
						local r_threshold = station.item_thresholds and station.item_thresholds[item.name] or station.r_threshold
						if station.is_stack and item.type ~= "fluid" then
							r_threshold = r_threshold * get_stack_size(map_data, item.name)
						end

						if -count >= r_threshold then
							if inventory_requested[item_hash] == nil then
								inventory_requested[item_hash] = {count, 1}
							else
								inventory_requested[item_hash][1] = inventory_requested[item_hash][1] + count
								inventory_requested[item_hash][2] = inventory_requested[item_hash][2] + 1
							end
						end
					end
				end
			end
		end

		local deliveries = station.deliveries
		if deliveries then
			for item_hash, count in pairs(deliveries) do
				if count > 0 then
					if inventory_in_transit[item_hash] == nil then
						inventory_in_transit[item_hash] = {count, 1}
					else
						inventory_in_transit[item_hash][1] = inventory_in_transit[item_hash][1] + count
						inventory_in_transit[item_hash][2] = inventory_in_transit[item_hash][2] + 1
					end
				end
			end
		end
	end

	local inventory_provided_table = refs.inventory_provided_table
	local provided_children = {}

	for item_hash, counts in pairs(inventory_provided) do
		item, quality = unhash_signal(item_hash)
		local item_count, station_count = table.unpack(counts)
		local item_prototype = util.prototype_from_name(item)
		local signal = util.signalid_from_name(item, quality)
		provided_children[#provided_children + 1] = {
			type = "choose-elem-button",
			elem_type = "signal",
			signal = signal,
			enabled = false,
			style = "flib_slot_button_green",
			tooltip = {
				"",
				util.rich_text_from_signal(signal),
				" ", item_prototype.localised_name, "\n",
				"Provided by ", tostring(station_count), " station",
				(station_count > 1 and "s" or ""), "\n",
				"Amount: " .. format.number(item_count),
			},
			children = {
				{
					type = "label",
					style = "ltnm_label_signal_count_inventory",
					ignored_by_interaction = true,
					caption = format_signal_count(item_count),
				},
				{
					type = "label",
					style = "ltnm_label_train_count_inventory",
					ignored_by_interaction = true,
					caption = format_signal_count(station_count),
				},
			},
		}
	end

	local inventory_requested_table = refs.inventory_requested_table
	local requested_children = {}

	for item_hash, counts in pairs(inventory_requested) do
		item, quality = unhash_signal(item_hash)
		local item_count, station_count = table.unpack(counts)
		local item_prototype = util.prototype_from_name(item)
		local signal = util.signalid_from_name(item, quality)
		requested_children[#requested_children + 1] = {
			type = "choose-elem-button",
			elem_type = "signal",
			signal = signal,
			enabled = false,
			style = "flib_slot_button_red",
			tooltip = {
				"",
				util.rich_text_from_signal(signal),
				" ", item_prototype.localised_name, "\n",
				"Requested by ", tostring(station_count), " station",
				(station_count > 1 and "s" or ""), "\n",
				"Amount: " .. format.number(item_count),
			},
			children = {
				{
					type = "label",
					style = "ltnm_label_signal_count_inventory",
					ignored_by_interaction = true,
					caption = format_signal_count(item_count),
				},
				{
					type = "label",
					style = "ltnm_label_train_count_inventory",
					ignored_by_interaction = true,
					caption = format_signal_count(station_count),
				},
			},
		}
	end

	local inventory_in_transit_table = refs.inventory_in_transit_table
	local in_transit_children = {}

	for item_hash, counts in pairs(inventory_in_transit) do
		item, quality = unhash_signal(item_hash)
		local item_count, station_count = table.unpack(counts)
		local item_prototype = util.prototype_from_name(item)
		local signal = util.signalid_from_name(item, quality)
		in_transit_children[#in_transit_children + 1] = {
			type = "choose-elem-button",
			elem_type = "signal",
			signal = signal,
			enabled = false,
			style = "flib_slot_button_blue",
			tooltip = {
				"",
				util.rich_text_from_signal(signal),
				" ", item_prototype.localised_name, "\n",
				"In transit to ", tostring(station_count), " station",
				(station_count > 1 and "s" or ""), "\n",
				"Amount: " .. format.number(item_count),
			},
			children = {
				{
					type = "label",
					style = "ltnm_label_signal_count_inventory",
					ignored_by_interaction = true,
					caption = format_signal_count(item_count),
				},
				{
					type = "label",
					style = "ltnm_label_train_count_inventory",
					ignored_by_interaction = true,
					caption = format_signal_count(station_count),
				},
			},
		}
	end

	if next(inventory_provided_table.children) ~= nil then
		refs.inventory_provided_table.clear()
	end
	if next(inventory_requested_table.children) ~= nil then
		refs.inventory_requested_table.clear()
	end
	if next(inventory_in_transit_table.children) ~= nil then
		refs.inventory_in_transit_table.clear()
	end
	gui.add(refs.inventory_provided_table, provided_children)
	gui.add(refs.inventory_requested_table, requested_children)
	gui.add(refs.inventory_in_transit_table, in_transit_children)
end

inventory_tab.handle = {}

--- @param e {player_index: uint}
function inventory_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

---@param player LuaPlayer
---@param player_data PlayerData
function inventory_tab.handle.on_inventory_tab_selected(player, player_data)
	player_data.selected_tab = "inventory_tab"
end

gui.add_handlers(inventory_tab.handle, inventory_tab.wrapper)

return inventory_tab
