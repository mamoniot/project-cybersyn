local gui = require("__flib__.gui-lite")

local constants = require("scripts.gui.constants")
local util = require("scripts.gui.util")
local templates = require("scripts.gui.templates")

local stations_tab = {}

function stations_tab.create(widths)
	return {
		tab = {
			name = "manager_stations_tab",
			type = "tab",
			caption = { "cybersyn-gui.stations" },
			ref = { "stations", "tab" },
			handler = stations_tab.handle.on_stations_tab_selected
		},
		content = {
			name = "manager_stations_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			ref = { "stations", "content_frame" },
			{
				type = "frame",
				style = "ltnm_table_toolbar_frame",
				templates.sort_checkbox(widths, "stations", "name", true),
				templates.sort_checkbox(widths, "stations", "status", false), --repurposed status column, description no longer necessary
				templates.sort_checkbox(widths, "stations", "network_id", false),
				templates.sort_checkbox(
				widths,
				"stations",
				"provided_requested",
				false,
				{ "cybersyn-gui-provided-requested-description" }
			),
			templates.sort_checkbox(widths, "stations", "shipments", false, { "cybersyn-gui-shipments-description" }),
			templates.sort_checkbox(widths, "stations", "control_signals", false),
		},
		{ name = "manager_stations_tab_scroll_pane", type = "scroll-pane", style = "ltnm_table_scroll_pane", ref = { "stations", "scroll_pane" } },
		{
			type = "flow",
			style = "ltnm_warning_flow",
			visible = false,
			ref = { "stations", "warning_flow" },
			{
				type = "label",
				style = "ltnm_semibold_label",
				caption = { "cybersyn-gui-no-stations" },
				ref = { "stations", "warning_label" },
			},
		},
	},
}
end

--- @param map_data MapData
--- @param player_data PlayerData
function stations_tab.build(map_data, player_data, query_limit)

	local widths = constants.gui["en"]
	local refs = player_data.refs

	local search_query = player_data.search_query
	local search_item = player_data.search_item
	local search_network_name = player_data.search_network_name
	local search_network_mask = player_data.search_network_mask
	local search_surface_idx = player_data.search_surface_idx

	local stations = map_data.stations

	local stations_sorted = {}
	local to_sorted_manifest = {}

	local i = 0
	for id, station in pairs(stations) do
		local entity = station.entity_stop
		if not entity.valid then
			goto continue
		end



		if search_query then
			if not string.match(entity.backer_name, search_query) then
				goto continue
			end
		end

		-- move surface comparison up higher in query to short circuit query earlier if surface doesn't match; this can exclude hundreds of stations instantly in SE
		if search_surface_idx then
			if search_surface_idx == -1 then
				goto has_match
			elseif entity.surface.index ~= search_surface_idx then
				goto continue
			end
			::has_match::
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
				local masks = station.network_mask--[[@as {}]]
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
		i = i + 1
		if query_limit ~= -1 and i >= query_limit then
			break
		end
		::continue::
	end


	table.sort(stations_sorted, function(a, b)
		local station1 = map_data.stations[a]
		local station2 = map_data.stations[b]
		for i, v in ipairs(player_data.trains_orderings) do
			local invert = player_data.trains_orderings_invert[i]
			if v == ORDER_LAYOUT then
				if not station1.allows_all_trains and not station2.allows_all_trains then
					local layout1 = station1.layout_pattern--[[@as uint[] ]]
					local layout2 = station2.layout_pattern--[[@as uint[] ]]
					for j, c1 in ipairs(layout1) do
						local c2 = layout2[j]
						if c1 ~= c2 then
							return invert ~= (c2 and c1 < c2)
						end
					end
					if layout2[#layout1 + 1] then
						return invert ~= true
					end
				elseif station1.allows_all_trains ~= station2.allows_all_trains then
					return invert ~= station2.allows_all_trains
				end
			elseif v == ORDER_NAME then
				local name1 = station1.entity_stop.valid and station1.entity_stop.backer_name
				local name2 = station2.entity_stop.valid and station2.entity_stop.backer_name
				if name1 ~= name2 then
					return invert ~= (name1 and (name2 and name1 < name2 or true) or false)
				end
			elseif v == ORDER_TOTAL_TRAINS then
				if station1.deliveries_total ~= station2.deliveries_total then
					return invert ~= (station1.deliveries_total < station2.deliveries_total)
				end
			elseif v == ORDER_MANIFEST then
				if not next(station1.deliveries) then
					if next(station2.deliveries) then
						return invert ~= true
					end
				elseif not next(station2.deliveries) then
					return invert ~= false
				else
					local first_item = nil
					local first_direction = nil
					for item_name in dual_pairs(station1.deliveries, station2.deliveries) do
						if not first_item or item_lt(map_data.manager, item_name, first_item) then
							local count1 = station1.deliveries[item_name] or 0
							local count2 = station2.deliveries[item_name] or 0
							if count1 ~= count2 then
								first_item = item_name
								first_direction = count1 < count2
							end
						end
					end
					if first_direction ~= nil then
						return invert ~= first_direction
					end
				end
			end
		end
		return (not player_data.trains_orderings_invert[#player_data.trains_orderings_invert]) == (a < b)
	end)

	local scroll_pane = refs.manager_stations_tab_scroll_pane
	if next(scroll_pane.children) ~= nil then
		refs.manager_stations_tab_scroll_pane.clear()
	end

	for i, station_id in pairs(stations_sorted) do
		--- @type Station
		local station = stations[station_id]
		local network_sprite = "utility/close_black"
		local network_name = station.network_name
		local network_mask = -1;
		if network_name then
			network_mask = get_network_mask(station, network_name)
			network_sprite, _, _ = util.generate_item_references(network_name)
		end
		local color = i % 2 == 0 and "dark" or "light"
		gui.add(scroll_pane, {
			type = "frame",
			{
				type = "label",
				style = "ltnm_clickable_semibold_label",
				style_mods = { width = widths.stations.name },
				tooltip = constants.open_station_gui_tooltip,
				caption = station.entity_stop.backer_name,
				handler = stations_tab.handle.open_station_gui,
				tags = { station_id = station_id }
			},
			--templates.status_indicator(widths.stations.status, true), --repurposing status column for network name
			{ type = "sprite-button", style = "ltnm_small_slot_button_default", enabled = false, sprite = network_sprite, },
			{ type = "label", style_mods = { width = widths.stations.network_id, horizontal_align = "center" }, caption = network_mask },
			templates.small_slot_table(widths.stations, color, "provided_requested"),
			templates.small_slot_table(widths.stations, color, "shipments"),
			templates.small_slot_table(widths.stations, color, "control_signals"),
		}, refs)

		gui.add(refs.provided_requested_table, util.slot_table_build_from_station(station))
		gui.add(refs.shipments_table, util.slot_table_build_from_deliveries(station))
		gui.add(refs.control_signals_table, util.slot_table_build_from_control_signals(station, map_data))

	end

	if #stations_sorted == 0 then
		--refs.warning_flow.visible = true
		scroll_pane.visible = false
		--refs.content_frame.style = "ltnm_main_warning_frame"
	else
		--refs.warning_flow.visible = false
		scroll_pane.visible = true
		--refs.content_frame.style = "ltnm_main_content_frame"
	end
end


stations_tab.handle = {}

--- @param e {player_index: uint}
function stations_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = global.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param e GuiEventData
--- @param player LuaPlayer
--- @param player_data PlayerData
function stations_tab.handle.open_station_gui(player, player_data, refs, e)
	local station_id = e.element.tags.station_id
	--- @type Station
	local station = global.stations[station_id]
	local station_entity = station.entity_stop
	local station_comb1 = station.entity_comb1
	local station_comb2 = station.entity_comb2

	if not station_entity or not station_entity.valid then
		util.error_flying_text(player, { "message.ltnm-error-station-is-invalid" })
		return
	end

	if e.shift then
		if station_entity.surface ~= player.surface then
			util.error_flying_text(player, { "cybersyn-message.error-cross-surface-camera-invalid" })
		else
			player.zoom_to_world(station_entity.position, 1, station_entity)

			rendering.draw_circle({
				color = constants.colors.red.tbl,
				target = station_entity.position,
				surface = station_entity.surface,
				radius = 0.5,
				filled = false,
				width = 5,
				time_to_live = 60 * 3,
				players = { player },
			})

			if not player_data.pinning then util.close_manager_window(player, player_data, refs) end
		end
	elseif e.control then
		if station_comb1 ~= nil and station_comb1.valid then
			player.opened = station_comb1
		else
			util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
		end

	elseif e.alt then
		if station_comb2 ~= nil and station_comb2.valid then
			player.opened = station_comb2
		else
			util.error_flying_text(player, { "cybersyn-message.error-station-control-combinator-not-found" })
		end
	else
		player.opened = station_entity
	end
end

---@param player LuaPlayer
---@param player_data PlayerData
function stations_tab.handle.on_stations_tab_selected(player, player_data)
	player_data.selected_tab = "stations_tab"
end

gui.add_handlers(stations_tab.handle, stations_tab.wrapper)

return stations_tab
