local constants = require("constants")

local data_util = require("__flib__.data-util")
local M = require("scripts.gui.metrics")

local util = {}

for key, value in pairs(require("__core__.lualib.util")) do
	util[key] = value
end

util.paths = {
	nav_icons = "__cybersyn__/graphics/gui/frame-action-icons.png",
	shortcut_icons = "__cybersyn__/graphics/shortcut/ltn-manager-shortcut.png",
}

util.empty_checkmark = {
	filename = data_util.empty_image,
	priority = "very-low",
	width = 1,
	height = 1,
	frame_count = 1,
	scale = 8,
}

data:extend({
	data_util.build_sprite("ltnm_pin_black", { 0, 32 }, util.paths.nav_icons, 32),
	data_util.build_sprite("ltnm_pin_white", { 32, 32 }, util.paths.nav_icons, 32),
	data_util.build_sprite("ltnm_refresh_black", { 0, 0 }, util.paths.nav_icons, 32),
	data_util.build_sprite("ltnm_refresh_white", { 32, 0 }, util.paths.nav_icons, 32),
	-- utility/pause is dark grey, which vanishes on an unselected frame action button; the button style inverts a
	-- light sprite on hover by itself.
	data_util.build_sprite("cybersyn_pause_white", { 0, 0 }, "__cybersyn__/graphics/gui/pause-white.png", 32),
})




local styles = data.raw["gui-style"]["default"]

-- local depot_button_height = 89

-- BUTTON STYLES

-- smaller flib slot buttons
for _, color in ipairs({ "default", "red", "green", "blue", "orange" }) do
	styles["ltnm_small_slot_button_" .. color] = {
		type = "button_style",
		parent = "flib_slot_button_" .. color,
		size = 36,
	}
	styles["ltnm_selected_small_slot_button_" .. color] = {
		type = "button_style",
		parent = "flib_selected_slot_button_" .. color,
		size = 36,
	}
end

-- CHECKBOX STYLES

-- inactive is grey until hovered
-- checked = ascending, unchecked = descending
styles.ltnm_sort_checkbox = {
	type = "checkbox_style",
	font = "default-bold",
	-- font_color = bold_font_color,
	padding = 0,
	default_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	hovered_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-hover.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	clicked_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	disabled_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_hovered_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-hover.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_clicked_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_disabled_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	checkmark = util.empty_checkmark,
	disabled_checkmark = util.empty_checkmark,
	text_padding = 5,
}

-- selected is orange by default
styles.ltnm_selected_sort_checkbox = {
	type = "checkbox_style",
	parent = "ltnm_sort_checkbox",
	-- font_color = bold_font_color,
	default_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-active.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-active.png",
		size = { 16, 16 },
		scale = 0.5,
	},
}

-- FLOW STYLES

styles.ltnm_warning_flow = {
	type = "horizontal_flow_style",
	padding = 12,
	horizontal_align = "center",
	vertical_align = "center",
	vertical_spacing = 8,
	horizontally_stretchable = "on",
	vertically_stretchable = "on",
}

-- FRAME STYLES

-- The height comes from the player's screen at runtime (scripts/gui/sizing.lua).
styles.ltnm_main_content_frame = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
}


styles.ltnm_small_slot_table_frame_light = {
	type = "frame_style",
	parent = "ltnm_table_inset_frame_light",
	minimal_height = 36,
	background_graphical_set = {
		base = {
			position = { 282, 17 },
			corner_size = 8,
			overall_tiling_horizontal_padding = 4,
			overall_tiling_horizontal_size = 28,
			overall_tiling_horizontal_spacing = 8,
			overall_tiling_vertical_padding = 4,
			overall_tiling_vertical_size = 28,
			overall_tiling_vertical_spacing = 8,
		},
	},
}

styles.ltnm_table_inset_frame_light = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
}

styles.ltnm_table_row_frame_light = {
	type = "frame_style",
	--parent = "statistics_table_item_frame",
	--this is likely incorrect, unsure what the 2.0 equivalent is
	parent = "neutral_message_frame",
	top_padding = 8,
	bottom_padding = 8,
	left_padding = 8,
	right_padding = 8,
	minimal_height = 52,
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		vertical_align = "center",
		horizontal_spacing = 10,
		horizontally_stretchable = "on",
	},
	graphical_set = {
		base = {
			center = { position = { 76, 8 }, size = { 1, 1 } },
			-- bottom = {position = {8, 40}, size = {1, 8}},
		},
	},
}

styles.ltnm_table_row_frame_dark = {
	type = "frame_style",
	parent = "ltnm_table_row_frame_light",
	-- graphical_set = {
	--   base = {bottom = {position = {8, 40}, size = {1, 8}}},
	-- },
	graphical_set = {},
}

-- LABEL STYLES

-- The count font one size down, outline kept: "-200k" in the 13 px count font ellipsised ("-20…") in the 36 px slots
-- at UI scale 1.5 and in the Inventory's 40 px slots at 2.0.
data:extend({ { type = "font", name = "cybersyn-count-12", from = "default-bold", size = 12, border = true, border_color = {} } })

styles.ltnm_label_signal_count_inventory = {
	type = "label_style",
	parent = "count_label",
	font = "cybersyn-count-12",
	size = 36,
	width = 36,
	horizontal_align = "right",
	vertical_align = "bottom",
	right_padding = 2,
	parent_hovered_font_color = { 1, 1, 1 },
}

styles.ltnm_label_signal_count = {
	type = "label_style",
	parent = "ltnm_label_signal_count_inventory",
	bottom_padding = 3,
	right_padding = 4,
}

styles.ltnm_label_train_count_inventory = {
	type = "label_style",
	parent = "count_label",
	size = 36,
	width = 36,
	horizontal_align = "right",
	vertical_align = "top",
	right_padding = 3,
	top_padding = -4,
	parent_hovered_font_color = { 1, 1, 1 },
}

styles.ltnm_semibold_label = {
	type = "label_style",
	font = "default-semibold",
}

styles.ltnm_column_label = {
	type = "label_style",
	font = "default-bold",
	left_padding = 8,
}

-- SUBFOOTER STYLES

styles.ltnm_subfooter_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	left_padding = 8,
	right_padding = 8,
	horizontally_stretchable = "on",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 12,
		vertical_align = "center",
	},
}

-- CHART OVERLAY BUTTON STYLE

styles.cybersyn_chart_overlay_button = {
	type = "button_style",
	parent = "button",
	default_graphical_set = {},
	hovered_graphical_set = {},
	clicked_graphical_set = {},
	padding = 0,
	minimal_width = 1,
	minimal_height = 1,
}

-- SCROLL PANE STYLES

styles.ltnm_slot_table_scroll_pane = {
	type = "scroll_pane_style",
	parent = "flib_naked_scroll_pane_no_padding",
	horizontally_squashable = "off",
	background_graphical_set = {
		base = {
			position = { 282, 17 },
			corner_size = 8,
			overall_tiling_horizontal_padding = 4,
			overall_tiling_horizontal_size = 32,
			overall_tiling_horizontal_spacing = 8,
			overall_tiling_vertical_padding = 4,
			overall_tiling_vertical_size = 32,
			overall_tiling_vertical_spacing = 8,
		},
	},
}

-- TABBED PANE STYLES

styles.ltnm_tabbed_pane = {
	type = "tabbed_pane_style",
	tab_content_frame = {
		type = "frame_style",
		parent = "tabbed_pane_frame",
		left_padding = 12,
		right_padding = 12,
		bottom_padding = 12,
	},
}


data:extend({
	-- custom inputs
	{
		type = "custom-input",
		name = "cybersyn-toggle-gui",
		key_sequence = "CONTROL + T",
		action = "lua",
	},
	{
		type = "shortcut",
		name = "cybersyn-toggle-gui",
		icon = "__cybersyn__/graphics/shortcut/manager-toolbar-white.png",
		icon_size = 32,
		small_icon = "__cybersyn__/graphics/shortcut/manager-toolbar-white.png",
		small_icon_size = 32,
		style = "green",
		toggleable = true,
		action = "lua",
		associated_control_input = "cybersyn-toggle-gui",
		technology_to_unlock = "cybersyn-train-network",
	},
})

-- WINDOW

data:extend({
	data_util.build_sprite("cybersyn_filter_white", { 0, 0 }, "__cybersyn__/graphics/gui/filter-white.png", 32),
	{
		-- Ctrl+F (or whatever the player bound to the game's search) while the manager is open.
		type = "custom-input",
		name = "cybersyn-manager-search",
		key_sequence = "",
		linked_game_control = "focus-search",
		action = "lua",
	},
})

styles.cybersyn_tab_subheader = {
	type = "frame_style",
	parent = "subheader_frame",
	height = M.SUBHEADER_HEIGHT,
	horizontally_stretchable = "on",
	left_padding = M.SUBHEADER_PADDING,
	right_padding = M.SUBHEADER_PADDING,
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = M.SUBHEADER_SPACING,
		vertical_align = "center",
	},
}

styles.cybersyn_filter_row = {
	type = "frame_style",
	parent = "cybersyn_tab_subheader",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 12,
		vertical_align = "center",
	},
}

-- The red of the negative subheader, without its negative margin; laid out as cybersyn_tab_subheader.
styles.cybersyn_banner_frame = {
	type = "frame_style",
	parent = "negative_subheader_frame",
	bottom_margin = 0,
	height = M.SUBHEADER_HEIGHT,
	left_padding = M.SUBHEADER_PADDING,
	right_padding = M.SUBHEADER_PADDING,
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = M.SUBHEADER_SPACING,
		vertical_align = "center",
	},
}

styles.cybersyn_banner_label = {
	type = "label_style",
	parent = "bold_label",
	font_color = { 1, 1, 1 },
}

styles.cybersyn_subheader_note = {
	type = "label_style",
	font_color = { 0.7, 0.7, 0.7 },
	horizontally_squashable = "on",
}

styles.cybersyn_search_field = {
	type = "textbox_style",
	width = M.SEARCH_FIELD_WIDTH,
}

-- Item filter chip: "[icon] Filtered: Iron plate ×".
styles.cybersyn_item_chip_icon = {
	type = "button_style",
	parent = "flib_slot_button_orange",
	size = 28,
}

-- The chips copy vanilla `button`'s atlas positions: a tint needs a graphical_set of its own, which replaces the
-- parent's whole set.
styles.cybersyn_item_chip = {
	type = "button_style",
	parent = "button",
	height = 28,
	minimal_width = 0,
	left_padding = 8,
	right_padding = 8,
	default_font_color = { 0, 0, 0 },
	default_graphical_set = {
		base = { position = { 0, 17 }, corner_size = 8, tint = { 1, 0.78, 0.45 } },
		shadow = default_dirt,
	},
	hovered_graphical_set = {
		base = { position = { 34, 17 }, corner_size = 8, tint = { 1, 0.78, 0.45 } },
		shadow = default_dirt,
		glow = default_glow(default_glow_color, 0.5),
	},
	clicked_graphical_set = {
		base = { position = { 51, 17 }, corner_size = 8, tint = { 1, 0.78, 0.45 } },
		shadow = default_dirt,
	},
}

-- Reason chips: red = nothing changes on its own, orange = waiting on stock or capacity, grey = a setting.
local function chip(tint)
	local style = {
		type = "button_style",
		parent = "button",
		height = 28,
		minimal_width = 0,
		left_padding = 8,
		right_padding = 8,
		horizontally_squashable = "on",
		font = "default-semibold",
		default_font_color = { 0, 0, 0 },
		hovered_font_color = { 0, 0, 0 },
		clicked_font_color = { 0, 0, 0 },
	}
	if tint then
		style.default_graphical_set = {
			base = { position = { 0, 17 }, corner_size = 8, tint = tint },
			shadow = default_dirt,
		}
		style.hovered_graphical_set = {
			base = { position = { 34, 17 }, corner_size = 8, tint = tint },
			shadow = default_dirt,
			glow = default_glow(default_glow_color, 0.5),
		}
		style.clicked_graphical_set = {
			base = { position = { 51, 17 }, corner_size = 8, tint = tint },
			shadow = default_dirt,
		}
	end
	return style
end
styles.cybersyn_chip_red = chip({ 1, 0.5, 0.45 })
styles.cybersyn_chip_orange = chip({ 1, 0.78, 0.45 })
styles.cybersyn_chip_grey = chip(nil)
-- An acknowledged reason or finding: darker than an info chip, so the two never read alike.
styles.cybersyn_chip_acked = chip({ 0.55, 0.55, 0.55 })
styles.cybersyn_chip_acked.default_font_color = { 0.22, 0.22, 0.22 }
styles.cybersyn_chip_acked.hovered_font_color = { 0.22, 0.22, 0.22 }
styles.cybersyn_chip_acked.clicked_font_color = { 0.22, 0.22, 0.22 }

-- A link cell: text that opens what it names (scripts/gui/utils/links.lua links.handle_link_click).
styles.cybersyn_link_button = {
	type = "button_style",
	parent = "transparent_button",
	font = "default-semibold",
	horizontal_align = "left",
	minimal_width = 0,
	height = 32,
	left_padding = 2,
	right_padding = 2,
	horizontally_squashable = "on",
	default_font_color = { 0.9, 0.9, 0.9 },
	hovered_font_color = { 1, 0.74, 0.4 },
	clicked_font_color = { 1, 0.74, 0.4 },
	disabled_font_color = { 0.5, 0.5, 0.5 },
	disabled_graphical_set = {},
}

styles.cybersyn_link_button_acked = {
	type = "button_style",
	parent = "cybersyn_link_button",
	default_font_color = { 0.5, 0.5, 0.5 },
}

styles.cybersyn_name_icon = {
	type = "button_style",
	parent = "transparent_slot",
	size = 20,
}

-- OVERVIEW TAB STYLES

styles.cybersyn_overview_content = {
	type = "vertical_flow_style",
	vertical_spacing = 0,
	horizontally_stretchable = "on",
}

styles.cybersyn_overview_tile_row = {
	type = "horizontal_flow_style",
	horizontal_spacing = 12,
	top_margin = 12,
	height = 108,
}

local shallow_base = {
	position = { 17, 0 },
	corner_size = 8,
	center = { position = { 76, 8 }, size = { 1, 1 } },
	draw_type = "outer",
}

-- A whole tile is one button (it jumps to the matching tab); it looks like a shallow frame and glows on hover.
styles.cybersyn_overview_tile = {
	type = "button_style",
	parent = "button",
	height = M.TILE_HEIGHT,
	padding = 0,
	minimal_width = 0,
	default_graphical_set = { base = shallow_base, shadow = default_inner_shadow },
	hovered_graphical_set = { base = shallow_base, shadow = default_inner_shadow, glow = default_glow(default_glow_color, 0.5) },
	clicked_graphical_set = { base = shallow_base, shadow = default_inner_shadow },
	disabled_graphical_set = { base = shallow_base, shadow = default_inner_shadow },
	clicked_vertical_offset = 0,
}

-- 4 + header 28 + four 18 px lines + 4 = the 108 px tile.
styles.cybersyn_overview_tile_body = {
	type = "vertical_flow_style",
	vertical_spacing = 0,
	top_padding = M.TILE_PADDING,
	bottom_padding = M.TILE_PADDING,
	left_padding = 10,
	right_padding = 10,
}

styles.cybersyn_overview_tile_header = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 6,
	height = 28,
}

styles.cybersyn_overview_tile_icon = {
	type = "image_style",
	size = 24,
	stretch_image_to_widget_size = true,
}

styles.cybersyn_overview_tile_caption = {
	type = "label_style",
	parent = "caption_label",
	horizontally_squashable = "on",
}

styles.cybersyn_overview_big_number = {
	type = "label_style",
	font = "default-large-bold",
	font_color = { 255, 230, 192 },
}

styles.cybersyn_overview_line_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 8,
	height = M.TILE_LINE_HEIGHT,
}

styles.cybersyn_overview_line_label = {
	type = "label_style",
	font_color = { 0.85, 0.85, 0.85 },
	horizontally_squashable = "on",
}

styles.cybersyn_overview_line_value = {
	type = "label_style",
	font = "default-semibold",
	horizontal_align = "right",
	minimal_width = 40,
}

-- The Stations failing tile's Misconfigured line: a link of its own that must read like the plain lines
-- above it; the orange hover is its own cue.
styles.cybersyn_overview_line_link = {
	type = "button_style",
	parent = "cybersyn_link_button",
	font = "default",
	default_font_color = { 0.85, 0.85, 0.85 },
	height = M.TILE_LINE_HEIGHT,
	padding = 0,
}

styles.cybersyn_overview_period_dropdown = {
	type = "dropdown_style",
	parent = "dropdown",
	width = 140,
}

styles.cybersyn_unserved_frame = {
	type = "frame_style",
	parent = "inside_deep_frame",
	top_margin = 12,
	horizontally_stretchable = "on",
	vertical_flow_style = {
		type = "vertical_flow_style",
		vertical_spacing = 0,
	},
}

styles.cybersyn_unserved_caption_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	horizontally_stretchable = "on",
	left_padding = 8,
	right_padding = 8,
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 8,
		vertical_align = "center",
	},
}

styles.cybersyn_unserved_count_button = {
	type = "button_style",
	parent = "cybersyn_link_button",
	height = 28,
	font = "default-bold",
}

-- The row tint copies vanilla `removed_content_table`'s: parenting it would bring that table's column widths.
styles.cybersyn_unserved_table = {
	type = "table_style",
	parent = "table",
	horizontal_spacing = M.TABLE_SPACING,
	vertical_spacing = 0,
	left_padding = M.TABLE_LEFT_PADDING,
	right_padding = M.TABLE_RIGHT_PADDING,
	odd_row_graphical_set = {
		filename = "__core__/graphics/gui-new.png",
		position = { 472, 25 },
		size = 1,
	},
}

-- The drill-down's rows: no header row precedes them, so the first row keeps its tint.
styles.cybersyn_item_rows_table = {
	type = "table_style",
	parent = "cybersyn_unserved_table",
	odd_row_graphical_set = {},
	even_row_graphical_set = {
		filename = "__core__/graphics/gui-new.png",
		position = { 472, 25 },
		size = 1,
	},
}

-- No inner-shadow outline, and no dark background showing through the bar space a short table reserves.
styles.cybersyn_item_scroll_pane = {
	type = "scroll_pane_style",
	parent = "flib_naked_scroll_pane_no_padding",
	graphical_set = {},
	background_graphical_set = {},
}

styles.cybersyn_unserved_item = {
	type = "button_style",
	parent = "transparent_slot",
	size = 32,
}

styles.cybersyn_unserved_cell = {
	type = "label_style",
	height = 32,
	vertical_align = "center",
}

styles.cybersyn_unserved_cell_acked = {
	type = "label_style",
	parent = "cybersyn_unserved_cell",
	font_color = { 0.5, 0.5, 0.5 },
}

styles.cybersyn_unserved_value = {
	type = "label_style",
	parent = "cybersyn_unserved_cell",
	horizontal_align = "right",
}

styles.cybersyn_unserved_value_acked = {
	type = "label_style",
	parent = "cybersyn_unserved_value",
	font_color = { 0.5, 0.5, 0.5 },
}

-- A column header that does not sort: the sort checkboxes' caption without the arrow.
styles.cybersyn_list_header_label = {
	type = "label_style",
	font = "default-bold",
}

styles.cybersyn_unserved_header = {
	type = "label_style",
	font = "default-small-semibold",
	font_color = { 0.6, 0.6, 0.6 },
	height = 20,
	vertical_align = "center",
	horizontally_squashable = "on",
}

styles.cybersyn_unserved_header_value = {
	type = "label_style",
	parent = "cybersyn_unserved_header",
	horizontal_align = "right",
}

styles.cybersyn_unserved_cell_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 4,
	height = 32,
}

styles.cybersyn_unserved_ack = {
	type = "button_style",
	parent = "tool_button",
	size = 28,
}

styles.cybersyn_overview_empty_flow = {
	type = "horizontal_flow_style",
	horizontal_align = "center",
	vertical_align = "center",
	horizontally_stretchable = "on",
}

styles.cybersyn_overview_empty_label = {
	type = "label_style",
	font_color = { 0.6, 0.6, 0.6 },
	single_line = false,
	horizontal_align = "center",
	vertical_align = "center",
	maximal_width = 600,
}

-- STATIONS, TRAINS AND INVENTORY TABS

-- Slot buttons that fit a 32 px row (Stations items, Trains shipments).
for _, color in ipairs({ "default", "red", "green", "blue", "orange", "pink", "grey" }) do
	styles["cybersyn_slot_32_" .. color] = {
		type = "button_style",
		parent = "flib_slot_button_" .. color,
		size = 32,
	}
	styles["cybersyn_selected_slot_32_" .. color] = {
		type = "button_style",
		parent = "flib_selected_slot_button_" .. color,
		size = 32,
	}
end

-- List rows: fixed height so the window's row arithmetic holds whatever a row holds (scripts/gui/sizing.lua).
local function list_row(height, light)
	return {
		type = "frame_style",
		parent = light and "ltnm_table_row_frame_light" or "ltnm_table_row_frame_dark",
		top_padding = 0,
		bottom_padding = 0,
		left_padding = M.LIST_ROW_PADDING,
		right_padding = M.LIST_ROW_PADDING,
		height = height,
		horizontally_stretchable = "on",
		horizontal_flow_style = {
			type = "horizontal_flow_style",
			vertical_align = "center",
			horizontal_spacing = M.LIST_SPACING,
		},
	}
end
styles.cybersyn_station_row_light = list_row(32, true)
styles.cybersyn_station_row_dark = list_row(32, false)
styles.cybersyn_train_row_light = list_row(36, true)
styles.cybersyn_train_row_dark = list_row(36, false)
-- The train the Trains detail pane shows: a neutral grey (colours are for status only), the centre of the
-- default button face dimmed so white captions stay readable. Centre only, like the light row: a tile with corners
-- shifts the cells.
styles.cybersyn_train_row_selected = list_row(36, true)
styles.cybersyn_train_row_selected.graphical_set = {
	base = { center = { position = { 8, 25 }, size = { 1, 1 } }, opacity = 0.8 },
}
-- A depot group on Trains: a subheader strip as tall as a train row.
styles.cybersyn_group_row = {
	type = "frame_style",
	parent = "subheader_frame",
	height = 36,
	top_padding = 0,
	bottom_padding = 0,
	left_padding = 4,
	right_padding = 4,
	horizontally_stretchable = "on",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		vertical_align = "center",
		horizontal_spacing = 8,
	},
}

-- Column header: its cells are flows so number columns can sit on the numbers' right edge.
styles.cybersyn_list_header = {
	type = "frame_style",
	parent = "subheader_frame",
	height = M.SUBHEADER_HEIGHT,
	-- As the rows' padding, so a header cell starts where its column's cells do.
	left_padding = M.LIST_ROW_PADDING,
	right_padding = M.LIST_ROW_PADDING,
	horizontally_stretchable = "on",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = M.LIST_SPACING,
		vertical_align = "center",
	},
}

styles.cybersyn_list_subfooter = {
	type = "frame_style",
	parent = "ltnm_subfooter_frame",
	height = M.SUBHEADER_HEIGHT,
}

styles.cybersyn_list_rows = {
	type = "vertical_flow_style",
	vertical_spacing = 0,
	vertically_stretchable = "on",
	horizontally_stretchable = "on",
}

styles.cybersyn_cell_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 4,
}

styles.cybersyn_cell_label = {
	type = "label_style",
	horizontally_squashable = "on",
}

-- Numbers in a row share their column's right edge.
styles.cybersyn_cell_value = {
	type = "label_style",
	horizontal_align = "right",
}

styles.cybersyn_cell_value_orange = {
	type = "label_style",
	parent = "cybersyn_cell_value",
	font_color = { 1, 0.6, 0.2 },
}

styles.cybersyn_overflow_label = {
	type = "label_style",
	font = "default-semibold",
	font_color = { 0.7, 0.7, 0.7 },
	horizontal_align = "center",
	minimal_width = 24,
}

-- Filter chips in a tab's subheader: toggled when active, disabled at a count of 0.
styles.cybersyn_filter_chip = {
	type = "button_style",
	parent = "button",
	height = 28,
	minimal_width = 0,
	left_padding = 6,
	right_padding = 6,
}

styles.cybersyn_train_id_button = {
	type = "button_style",
	parent = "cybersyn_link_button",
	horizontal_align = "right",
	height = 36,
}

-- Inventory: one frame per grid with its own subheader (caption and sort buttons) over the slot grid.
styles.cybersyn_inventory_grid_frame = {
	type = "frame_style",
	parent = "inside_deep_frame",
	top_padding = 0,
	bottom_padding = 0,
	vertical_flow_style = {
		type = "vertical_flow_style",
		vertical_spacing = 0,
	},
}

styles.cybersyn_inventory_grid_header = {
	type = "frame_style",
	parent = "subheader_frame",
	height = M.SUBHEADER_HEIGHT,
	horizontally_stretchable = "on",
	left_padding = 8,
	right_padding = 4,
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 4,
		vertical_align = "center",
	},
}

styles.cybersyn_sort_tool_button = {
	type = "button_style",
	parent = "tool_button",
	size = 28,
	padding = 2,
}

-- The count on a 32 px slot button (ltnm_label_signal_count is sized for 36 px).
styles.cybersyn_slot_32_count = {
	type = "label_style",
	parent = "count_label",
	height = 32,
	-- The label starts after the slot button's own padding, so it is narrower than the button.
	width = 29,
	horizontal_align = "right",
	vertical_align = "bottom",
	right_padding = 0,
	bottom_padding = 1,
	-- The count font overflows a 32 px slot at UI scale 2.0 ("-4.2k"); one size down fits at every scale.
	font = "default-tiny-bold",
	parent_hovered_font_color = { 1, 1, 1 },
}

-- STATIONS PROBLEMS COLUMN: severity dot, check chip, detail numbers of a station's lint findings.

styles.cybersyn_lint_dot = {
	type = "image_style",
	size = 16,
	stretch_image_to_widget_size = true,
	left_margin = 2,
	right_margin = 2,
}

styles.cybersyn_lint_detail = {
	type = "label_style",
	parent = "cybersyn_unserved_cell",
	horizontally_squashable = "on",
}

styles.cybersyn_lint_detail_acked = {
	type = "label_style",
	parent = "cybersyn_lint_detail",
	font_color = { 0.5, 0.5, 0.5 },
}

-- The second line of the Stations chips when they do not fit beside the search field: one row high, so the page
-- gives up exactly one row for it.
styles.cybersyn_chip_row = {
	type = "frame_style",
	parent = "cybersyn_tab_subheader",
	height = 32,
}

-- A reason or queue state as plain coloured text where nothing happens on a click (a chip would invite one).
local function reason_label(color)
	return {
		type = "label_style",
		parent = "cybersyn_unserved_cell",
		font = "default-semibold",
		font_color = color,
		horizontally_squashable = "on",
	}
end
styles.cybersyn_reason_label_red = reason_label({ 1, 0.5, 0.45 })
styles.cybersyn_reason_label_orange = reason_label({ 1, 0.78, 0.45 })
styles.cybersyn_reason_label_grey = reason_label({ 0.8, 0.8, 0.8 })
styles.cybersyn_reason_label_acked = reason_label({ 0.5, 0.5, 0.5 })

-- LOG TAB STYLES (28 px rows; the rows table below gives the alternate-row tint)

styles.cybersyn_log_row = {
	type = "frame_style",
	padding = 0,
	left_padding = M.LOG_ROW_LEFT_PADDING,
	right_padding = M.LOG_ROW_RIGHT_PADDING,
	height = 28,
	horizontally_stretchable = "on",
	graphical_set = {},
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		vertical_align = "center",
		horizontal_spacing = M.LOG_SPACING,
	},
}

styles.cybersyn_log_age = {
	type = "label_style",
	font_color = { 0.6, 0.6, 0.6 },
	horizontal_align = "right",
	height = 28,
	vertical_align = "center",
}

styles.cybersyn_log_dot = {
	type = "image_style",
	size = 16,
	stretch_image_to_widget_size = true,
}

styles.cybersyn_log_kind = {
	type = "image_style",
	size = 20,
	stretch_image_to_widget_size = true,
}

styles.cybersyn_log_link = {
	type = "button_style",
	parent = "cybersyn_link_button",
	height = 28,
}

styles.cybersyn_log_link_gone = {
	type = "button_style",
	parent = "cybersyn_log_link",
	default_font_color = { 0.5, 0.5, 0.5 },
}

styles.cybersyn_log_cell_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 4,
	height = 28,
}

styles.cybersyn_log_item = {
	type = "button_style",
	parent = "transparent_slot",
	size = 28,
}

styles.cybersyn_log_message = {
	type = "label_style",
	height = 28,
	vertical_align = "center",
	horizontally_squashable = "on",
}

styles.cybersyn_log_count = {
	type = "label_style",
	font = "default-semibold",
	horizontal_align = "right",
	height = 28,
	vertical_align = "center",
}

styles.cybersyn_log_print = {
	type = "button_style",
	parent = "tool_button",
	size = 24,
	padding = 2,
}

styles.cybersyn_log_sev_button = {
	type = "button_style",
	parent = "button",
	height = 28,
	minimal_width = 0,
	left_padding = 6,
	right_padding = 8,
}

styles.cybersyn_log_kind_dropdown = {
	type = "dropdown_style",
	parent = "dropdown",
	width = M.LOG_KIND_DROPDOWN_WIDTH,
}

styles.cybersyn_log_window_dropdown = {
	type = "dropdown_style",
	parent = "dropdown",
	width = M.LOG_WINDOW_DROPDOWN_WIDTH,
}

styles.cybersyn_log_train_field = {
	type = "textbox_style",
	width = M.LOG_TRAIN_FIELD_WIDTH,
}

styles.cybersyn_log_summary_frame = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
	vertical_flow_style = {
		type = "vertical_flow_style",
		vertical_spacing = 0,
	},
}

styles.cybersyn_log_summary_table = {
	type = "table_style",
	parent = "cybersyn_unserved_table",
	column_alignments = {
		{ column = 3, alignment = "right" },
	},
}

styles.cybersyn_log_rows_table = {
	type = "table_style",
	parent = "table",
	horizontal_spacing = 0,
	vertical_spacing = 0,
	cell_padding = 0,
	horizontally_stretchable = "on",
	odd_row_graphical_set = {
		filename = "__core__/graphics/gui-new.png",
		position = { 472, 25 },
		size = 1,
	},
}

-- The button above the vanilla trains window, and the opt-in HUD line.
styles.cybersyn_trains_anchor_frame = {
	type = "frame_style",
	parent = "frame",
	padding = 8,
}

styles.cybersyn_hud_frame = {
	type = "frame_style",
	parent = "frame",
	padding = 4,
	right_padding = 8,
	horizontal_flow_style = { type = "horizontal_flow_style", horizontal_spacing = 6 },
}

styles.cybersyn_hud_drag = {
	type = "empty_widget_style",
	parent = "draggable_space",
	width = 10,
	height = 40,
	left_margin = 0,
	right_margin = 0,
}

styles.cybersyn_hud_label = {
	type = "label_style",
	font = "default-bold",
}

styles.cybersyn_hud_note = {
	type = "label_style",
	font_color = { 0.7, 0.7, 0.7 },
}

-- ITEM DRILL-DOWN

-- A total in the drill-down's subheader: "Provided 12.3k".
styles.cybersyn_item_total = {
	type = "label_style",
	parent = "subheader_caption_label",
	left_margin = 8,
}

-- The train id link of a Trains-carrying-it row: a number, so it sits on the column's right edge.
styles.cybersyn_item_train_button = {
	type = "button_style",
	parent = "cybersyn_link_button",
	horizontal_align = "right",
}
