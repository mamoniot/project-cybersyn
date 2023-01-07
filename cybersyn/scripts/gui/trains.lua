local gui = require("__flib__.gui-lite")

local constants = require("constants")
local util = require("scripts.gui.util")

local templates = require("templates")

local trains_tab = {}


function trains_tab.build(map_data, player_id, player_data)
	local widths = constants.gui["en"]

	local search_query = player_data.search_query
	local search_network_flag = player_data.network_flag
	local search_network = player_data.network

	local trains_sorted = player_data.trains_sorted

	---@type GuiElemDef
	local train_list = {}
	--if not sorted_trains then
	--  sorted_trains = {}
	--  ids = {}
	--  for id, train in pairs(map_data) do
	--    local i = #ids + 1
	--    ids[i] = id
	--    sorted_trains[i] = train
	--  end
	--  dual_sort(ids, sorted_trains)
	--end
	if #trains_sorted == 0 then
		train_list[1] = {
			type = "label",
			style = "ltnm_semibold_label",
			caption = { "gui.ltnm-no-trains" },
			ref = { "trains", "warning_label" },
		}
	else
		local start, finish, step
		if player_data.trains_ascending then
			start = #trains_sorted
			finish = 1
			step = -1
		else
			start = 1
			finish = #trains_sorted
			step = 1
		end

		local gui_idx = 1
		for idx = start, finish, step do
			local train_id = trains_sorted[idx]
			local train = map_data.trains[train_id]

			if
			true
			then
				local color = gui_idx % 2 == 0 and "dark" or "light"
				train_list[gui_idx] = {
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
									actions = {
										on_click = { gui = "main", action = "open_train_gui", train_id = train_id },
									},
								},
							},
						},
						{
							type = "label",
							style_mods = { width = widths.trains.composition },
							elem_mods = { caption = train.composition },
						},
						{
							type = "label", style_mods = { width = widths.trains.depot },
							elem_mods = { caption = train.depot },
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
				gui_idx = gui_idx + 1
			end
		end
	end

	return {
		tab = {
			type = "tab",
			caption = #trains_sorted == 0 and { "gui.ltnm-trains" } or { "gui.ltnm-trains", #train_list },
			badge_text = misc.delineate_number(#ltn_data.sorted_trains.composition),
			ref = { "trains", "tab" },
			actions = {
				on_click = { gui = "main", action = "change_tab", tab = "trains" },
			},
		},
		content = {
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			ref = { "trains", "content_frame" },
			children = {
				{
					type = "frame",
					style = "ltnm_table_toolbar_frame",
					templates.sort_checkbox(widths, "trains", "train_id", true),
					templates.sort_checkbox(widths, "trains", "status", false),
					templates.sort_checkbox(widths, "trains", "composition", false, { "gui.ltnm-composition-description" }),
					templates.sort_checkbox(widths, "trains", "depot", false),
					templates.sort_checkbox(widths, "trains", "shipment", false),
				},
				{ type = "scroll-pane", style = "ltnm_table_scroll_pane", ref = { "trains", "scroll_pane" } },
				{
					type = "flow",
					style = "ltnm_warning_flow",
					visible = false,
					ref = { "trains", "warning_flow" },
					children = train_list,
				},
			},
		},
	}
end

return trains_tab
