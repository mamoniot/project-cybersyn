local train_util = require("__flib__.train")
local gui = require("__flib__.gui")

local constants = require("constants")
local util = require("scripts.gui.util")

local templates = require("scripts.gui.templates")

local trains_tab = {}

function trains_tab.create(widths)
	return {
		tab = {
			name = "manager_trains_tab",
			type = "tab",
			--caption = #trains_sorted == 0 and { "cybersyn-gui.trains" } or { "cybersyn-gui.trains", #train_list },
			caption = { "cybersyn-gui.trains" },
			--badge_text = format.number(#ltn_data.sorted_trains.composition),
			handler = trains_tab.handle.on_trains_tab_selected, --on_click
			tags = { tab = "trains_tab" },
		},
		content = {
			name = "manager_trains_tab_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			children = {
				{
					type = "frame",
					style = "ltnm_table_toolbar_frame",
					templates.sort_checkbox(widths, "trains", "train_id", true, nil, false, trains_tab.handle.on_trains_sort_checkbox_changed),
					templates.sort_checkbox(widths, "trains", "status", false, nil, false, trains_tab.handle.on_trains_sort_checkbox_changed),
					templates.sort_checkbox(widths, "trains", "layout", false, nil, false, trains_tab.handle.on_trains_sort_checkbox_changed),
					templates.sort_checkbox(widths, "trains", "depot", false, nil, false, trains_tab.handle.on_trains_sort_checkbox_changed),
					templates.column_label({ trains = { shipment = widths.trains.shipment - 50 } }, "trains", "shipment"),
				},
				{ name = "manager_trains_tab_scroll_pane", type = "scroll-pane", style = "ltnm_table_scroll_pane" },
				{
					name = "trains_warning_flow",
					type = "flow",
					style = "ltnm_warning_flow",
				},
			},
		},
	}
end

--- @param map_data MapData
--- @param player_data PlayerData
function trains_tab.build(map_data, player_data, query_limit)
	local widths = constants.gui["en"]
	local refs = player_data.refs

	local search_query = player_data.search_query
	local search_item = player_data.search_item
	local search_network_name = player_data.search_network_name
	local search_network_mask = player_data.search_network_mask
	local search_surface_idx = player_data.search_surface_idx

	local trains = map_data.trains

	local trains_sorted = {}

	local layouts_table = util.build_train_layout_table(map_data)

	local i = 0
	for id, train in pairs(trains) do
		if not train.entity.valid then
			goto continue
		end
		if search_network_name then
			if train.network_name == NETWORK_EACH then
				-- NETWORK_EACH trains can have any network, check if this one exists
				local network_mask = train.network_mask[search_network_name]
				if not network_mask then
					goto continue
				end
				if not bit32.btest(search_network_mask, network_mask) then
					goto continue
				end
			else
				-- Regular trains must match the network name
				if search_network_name ~= train.network_name then
					goto continue
				end
				local train_flag = get_network_mask(train, search_network_name)
				if not bit32.btest(search_network_mask, train_flag) then
					goto continue
				end
			end
		elseif search_network_mask ~= -1 then
			if train.network_name == NETWORK_EACH then
				local masks = train.network_mask --[[@as {}]]
				for _, network_mask in pairs(masks) do
					if bit32.btest(search_network_mask, network_mask) then
						goto has_match
					end
				end
				goto continue
				::has_match::
			elseif not bit32.btest(search_network_mask, train.network_mask) then
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
		i = i + 1
		if query_limit ~= -1 and i >= query_limit then
			break
		end
		::continue::
	end

	table.sort(trains_sorted, function(a, b)
		local train1 = map_data.trains[a]
		local train2 = map_data.trains[b]

		if not train1 or not train2 then
			return a < b
		end

		local sort = player_data.trains_sort or { active = "train_id", ascending = {} }
		local column = sort.active or "train_id"
		local ascending = sort.ascending[column] ~= false  -- default to ascending

		local less_than = nil

		if column == "train_id" then
			if a ~= b then
				less_than = a < b
			end
		elseif column == "status" then
			local s1 = train1.status or 0
			local s2 = train2.status or 0
			if s1 ~= s2 then
				less_than = s1 < s2
			end
		elseif column == "layout" then
			if train1.layout_id ~= train2.layout_id then
				local layout1 = map_data.layouts[train1.layout_id]
				local layout2 = map_data.layouts[train2.layout_id]
				if layout1 and layout2 then
					for j, c1 in ipairs(layout1) do
						local c2 = layout2[j]
						if c2 == nil then
							less_than = false
							break
						end
						if c1 ~= c2 then
							less_than = c1 < c2
							break
						end
					end
					if less_than == nil and layout2[#layout1 + 1] then
						less_than = true
					end
				end
			end
		elseif column == "depot" then
			local depot1 = map_data.depots[train1.depot_id]
			local depot2 = map_data.depots[train2.depot_id]
			local name1 = (depot1 and depot1.entity_stop and depot1.entity_stop.valid) and depot1.entity_stop.backer_name or ""
			local name2 = (depot2 and depot2.entity_stop and depot2.entity_stop.valid) and depot2.entity_stop.backer_name or ""
			if name1 ~= name2 then
				less_than = name1 < name2
			end
		end

		if less_than ~= nil then
			if ascending then
				return less_than
			else
				return not less_than
			end
		end

		return a < b
	end)

	local scroll_pane = refs.manager_trains_tab_scroll_pane
	if next(scroll_pane.children) ~= nil then
		refs.manager_trains_tab_scroll_pane.clear()
	end

	if #trains_sorted == 0 then
		gui.add(scroll_pane, {
			type = "label",
			style = "ltnm_semibold_label",
			caption = { "cybersyn-gui.no-trains" },
		})
	else
		for idx, train_id in ipairs(trains_sorted) do
			local train = map_data.trains[train_id]
			local depot = map_data.depots[train.depot_id]
			local depot_name = depot.entity_stop.valid and depot.entity_stop.backer_name or ""
			local train_entity = train.entity
			local locomotive
			if train_entity.locomotives["front_movers"][1] then
				locomotive = train_entity.locomotives["front_movers"][1]
			else
				locomotive = train_entity.locomotives["back_movers"][1]
			end
			local manifest = train.manifest
			local network_sprite = "utility/close_black"
			local network_name = train.network_name
			---@type int?
			local network_id = nil
			---@type {name: string, sprite: string, mask: int?}[]
			local network_entries = {}
			if network_name then
				if network_name == NETWORK_EACH then
					local each_sprite = util.generate_item_references(NETWORK_EACH)
					if not each_sprite then
						each_sprite = "utility/close_black"
					end
					network_entries[#network_entries + 1] = { name = NETWORK_EACH, sprite = each_sprite, mask = nil }

					---@type {name: string, sprite: string, mask: int}[]
					local mask_entries = {}
					for name, mask in pairs(train.network_mask or {}) do
						local sprite = util.generate_item_references(name)
						if sprite then
							mask_entries[#mask_entries + 1] = { name = name, sprite = sprite, mask = mask }
						end
					end
					table.sort(mask_entries, function(a, b)
						return a.name < b.name
					end)
					for _, entry in ipairs(mask_entries) do
						network_entries[#network_entries + 1] = entry
					end
					if #mask_entries == 0 then
						network_entries[#network_entries + 1] = {
							name = "utility/close_black",
							sprite = "utility/close_black",
							mask = nil,
						}
					end
				else
					network_id = train.network_mask --[[@as int]]
					network_sprite, _, _ = util.generate_item_references(network_name)
				end
			end

			local network_children = {}
			if network_name == NETWORK_EACH and #network_entries > 0 then
				for _, entry in ipairs(network_entries) do
					network_children[#network_children + 1] = {
						type = "sprite-button",
						style = "ltnm_small_slot_button_default",
						enabled = true,
						ignored_by_interaction = true,
						sprite = entry.sprite,
						number = entry.mask,
					}
				end
			else
				network_children[1] = {
					type = "sprite-button",
					style = "ltnm_small_slot_button_default",
					enabled = true,
					ignored_by_interaction = true,
					sprite = network_sprite,
					number = network_id,
				}
			end

			local network_widget
			if network_name == NETWORK_EACH and #network_entries > 6 then
				network_widget = {
					type = "table",
					style = "slot_table",
					column_count = 6,
					style_mods = { horizontal_align = "center" },
					children = network_children,
				}
			else
				network_widget = {
					type = "flow",
					direction = "horizontal",
					style_mods = { horizontal_align = "center" },
					children = network_children,
				}
			end
			local color = idx % 2 == 0 and "dark" or "light"
			gui.add(scroll_pane, {
				type = "frame",
				style = "ltnm_table_row_frame_" .. color,
				{
					type = "frame",
					style = "ltnm_table_inset_frame_" .. color,
					{
						type = "minimap",
						name = "train_minimap",
						style = "ltnm_train_minimap",

						{ type = "label", style = "ltnm_minimap_label", caption = train_id },
						{
							type = "button",
							style = "ltnm_train_minimap_button",
							tooltip = { "cybersyn-gui.open-train-gui" },
							tags = { train_id = train_id },
							handler = trains_tab.handle.open_train_gui, --on_click
						},
					},
				},
				{
					type = "frame",
					style = "ltnm_table_row_frame_" .. color,
					style_mods = { width = widths.trains.status },
					network_widget,
				},
				{
					type = "label",
					style_mods = { width = widths.trains.layout },
					caption = layouts_table[train.layout_id],
				},
				{
					type = "label",
					style_mods = { width = widths.trains.depot },
					caption = depot_name,
				},
				{
					type = "frame",
					name = "shipment_frame",
					style = "ltnm_small_slot_table_frame_" .. color,
					style_mods = { width = widths.trains.shipment },
					{
						type = "table",
						name = "shipment_table",
						style = "slot_table",
						column_count = widths.trains.shipment_columns,
						{},
					},
				},
			}, refs)
			refs.train_minimap.entity = locomotive
			gui.add(refs.shipment_table, util.slot_table_build_from_manifest(manifest, "default"))
		end
	end
end

trains_tab.handle = {}

--- @param e {player_index: uint}
function trains_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param e GuiEventData
--- @param player_data PlayerData
function trains_tab.handle.open_train_gui(player, player_data, refs, e)
	local train_id = e.element.tags.train_id
	--- @type Train
	local train = storage.trains[train_id]
	local train_entity = train.entity

	if not train_entity or not train_entity.valid then
		util.error_flying_text(player, { "message.ltnm-error-train-is-invalid" })
		return
	end
	train_util.open_gui(player.index, train_entity)
end

---@param player LuaPlayer
---@param player_data PlayerData
function trains_tab.handle.on_trains_tab_selected(player, player_data)
	player_data.selected_tab = "trains_tab"
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_checked_state_changed
function trains_tab.handle.on_trains_sort_checkbox_changed(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end

	local column = element.tags.column
	if not column then return end

	if not player_data.trains_sort then
		player_data.trains_sort = { active = "train_id", ascending = {} }
	end

	local sort = player_data.trains_sort
	if sort.active == column then
		sort.ascending[column] = element.state
	else
		local old_column = sort.active
		sort.active = column
		sort.ascending[column] = element.state

		for _, child in pairs(element.parent.children) do
			if child.type == "checkbox" and child ~= element and child.tags and child.tags.column == old_column then
				child.style = "ltnm_sort_checkbox"
				if child.tags.width then child.style.width = child.tags.width end
				break
			end
		end
		element.style = "ltnm_selected_sort_checkbox"
		if element.tags.width then element.style.width = element.tags.width end
	end
end

gui.add_handlers(trains_tab.handle, trains_tab.wrapper)

return trains_tab
