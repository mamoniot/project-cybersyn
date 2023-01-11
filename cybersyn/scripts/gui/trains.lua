local format = require("__flib__.format")
local gui = require("__flib__.gui-lite")

local constants = require("constants")
local util = require("scripts.gui.util")

local templates = require("scripts.gui.templates")

local trains_tab = {}


--- @param map_data MapData
--- @param player_data PlayerData
--- @return GuiElemDef
function trains_tab.build(map_data, player_data)
	local widths = constants.gui["en"]

	local search_item = player_data.search_item
	local search_network_name = player_data.search_network_name
	local search_network_mask = player_data.search_network_mask
	local search_surface_idx = player_data.search_surface_idx


	local trains_sorted = {}
	for id, train in pairs(map_data.trains) do
		if search_network_name then
			if search_network_name ~= train.network_name then
				goto continue
			end
			local train_flag = get_network_flag(train, search_network_name)
			if not bit32.btest(search_network_mask, train_flag) then
				goto continue
			end
		elseif search_network_mask ~= -1 then
			if train.network_name == NETWORK_EACH then
				local masks = train.network_flag--[[@as {}]]
				for _, network_flag in pairs(masks) do
					if bit32.btest(search_network_mask, network_flag) then
						goto has_match
					end
				end
				goto continue
				::has_match::
			elseif not bit32.btest(search_network_mask, train.network_flag) then
				goto continue
			end
		end

		if search_surface_idx then
			local entity = get_any_train_entity(train.entity)
			if not entity then
				goto continue
			end
			if entity.surface.index ~= search_surface_idx then
				goto continue
			end
		end

		if search_item then
			if not train.manifest then
				goto continue
			end
			for i, v in ipairs(train.manifest) do
				if v.name == search_item then
					goto has_match
				end
			end
			goto continue
			::has_match::
		end

		trains_sorted[#trains_sorted + 1] = id
		::continue::
	end


	table.sort(trains_sorted, function(a, b)
		local train1 = map_data.trains[a]
		local train2 = map_data.trains[b]
		for i, v in ipairs(player_data.trains_orderings) do
			local invert = player_data.trains_orderings_invert[i]
			if v == ORDER_LAYOUT then
				if train1.layout_id ~= train2.layout_id then
					local layout1 = map_data.layouts[train1.layout_id]
					local layout2 = map_data.layouts[train2.layout_id]
					for j, c1 in ipairs(layout1) do
						local c2 = layout2[j]
						if c1 ~= c2 then
							return invert ~= (c2 and c1 < c2)
						end
					end
					if layout2[#layout1 + 1] then
						return invert ~= true
					end
				end
			elseif v == ORDER_DEPOT then
				local depot1 = map_data.depots[train1.depot_id]
				local depot2 = map_data.depots[train2.depot_id]
				local name1 = depot1.entity_stop.valid and depot1.entity_stop.backer_name
				local name2 = depot2.entity_stop.valid and depot2.entity_stop.backer_name
				if name1 ~= name2 then
					return invert ~= (name1 and (name2 and name1 < name2 or true) or false)
				end
			elseif v == ORDER_STATUS then
				if train1.status ~= train2.status then
					return invert ~= (train1.status < train2.status)
				end
			elseif v == ORDER_MANIFEST then
				if not train1.manifest then
					if train2.manifest then
						return invert ~= true
					end
				elseif not train2.manifest then
					return invert ~= false
				else
					local primary_item1 = train1.manifest[1]
					local primary_item2 = train2.manifest[1]
					if primary_item1.name ~= primary_item2.name then
						return invert ~= (primary_item1.type == primary_item2.type and primary_item1.name < primary_item2.name or primary_item1.type == "item")
					elseif primary_item1.count ~= primary_item2.count then
						return invert ~= (primary_item1.count < primary_item2.count)
					end
				end
			end
		end
		return a < b
	end)


	---@type GuiElemDef
	local train_list = {}
	if #trains_sorted == 0 then
		train_list[1] = {
			type = "label",
			style = "ltnm_semibold_label",
			caption = { "gui.ltnm-no-trains" },
		}
	else
		for idx, train_id in ipairs(trains_sorted) do
			local train = map_data.trains[train_id]
			local depot = map_data.depots[train.depot_id]
			local depot_name = depot.entity_stop.valid and depot.entity_stop.backer_name or ""

			local color = idx % 2 == 0 and "dark" or "light"
			train_list[idx] = {
				type = "frame",
				style = "ltnm_table_row_frame_" .. color,
				children = {
					{
						type = "frame",
						style = "ltnm_table_inset_frame_" .. color,
						children = {
							type = "minimap",
							style = "ltnm_train_minimap",
							{ type = "label", style = "ltnm_minimap_label" },
							{
								type = "button",
								style = "ltnm_train_minimap_button",
								tooltip = { "gui.ltnm-open-train-gui" },
								elem_mods = { entity = get_any_train_entity(train.entity) },
								handler = trains_tab.handle.open_train_gui, --on_click
								tags = { train_id = train_id },
							},
						},
					},
					{
						type = "label",
						style_mods = { width = widths.trains.composition },
						elem_mods = { caption = train.layout_id },
					},
					{
						type = "label",
						style_mods = { width = widths.trains.depot },
						elem_mods = { caption = depot_name },
					},
					{
						type = "frame",
						name = "shipment_frame",
						style = "ltnm_small_slot_table_frame_" .. color,
						style_mods = { width = widths.trains.shipment },
						children = {
							{
								type = "table",
								name = "shipment_table",
								style = "slot_table",
								column_count = widths.trains.shipment_columns,
								children = util.slot_table_build(train.manifest, "default"),
							},
						},
					},
				},
			}
		end
	end

	return {
		tab = {
			name = "trains_tab",
			type = "tab",
			caption = #trains_sorted == 0 and { "gui.ltnm-trains" } or { "gui.ltnm-trains", #train_list },
			--badge_text = format.number(#ltn_data.sorted_trains.composition),
			handler = trains_tab.handle.change_tab, --on_click
			tags = { tab = "trains_tab" },
		},
		content = {
			name = "trains_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			children = {
				{
					type = "frame",
					style = "ltnm_table_toolbar_frame",
					templates.sort_checkbox(widths, "trains", "status", false),
					templates.sort_checkbox(widths, "trains", "layout", false, { "gui.ltnm-composition-description" }),
					templates.sort_checkbox(widths, "trains", "depot", false),
					templates.sort_checkbox(widths, "trains", "shipment", false),
				},
				{ name = "trains_scroll_pane", type = "scroll-pane", style = "ltnm_table_scroll_pane" },
				{
					name = "trains_warning_flow",
					type = "flow",
					style = "ltnm_warning_flow",
					children = train_list,
				},
			},
		},
	}
end

return trains_tab
