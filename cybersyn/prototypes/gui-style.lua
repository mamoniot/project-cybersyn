local constants = require("constants")

local data_util = require("__flib__.data-util")

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

styles.ltnm_train_minimap_button = {
	type = "button_style",
	parent = "button",
	size = 90,
	default_graphical_set = {},
	hovered_graphical_set = {
		base = { position = { 81, 80 }, size = 1, opacity = 0.7 },
	},
	clicked_graphical_set = { position = { 70, 146 }, size = 1, opacity = 0.7 },
}

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

styles.ltnm_main_content_frame = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
	height = constants.gui_content_frame_height,
}

styles.ltnm_main_toolbar_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	top_margin = 4,
	bottom_margin = 12,
	vertical_align = "center",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 12,
		vertical_align = "center",
	},
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

styles.ltnm_small_slot_table_frame_dark = {
	type = "frame_style",
	parent = "ltnm_table_inset_frame_dark",
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

styles.ltnm_table_inset_frame_dark = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
	graphical_set = {
		base = {
			position = { 51, 0 },
			corner_size = 8,
			center = { position = { 42, 8 }, size = { 1, 1 } },
			draw_type = "outer",
		},
		shadow = default_inner_shadow,
	},
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

styles.ltnm_table_toolbar_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	left_padding = 9,
	right_padding = 7 + 12,          -- For scrollbar
	horizontally_stretchable = "on", -- FIXME: This causes the GUI to jump when the scrollbar appears
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 10,
		vertical_align = "center",
	},
}

styles.ltnm_main_warning_frame = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
	height = constants.gui_content_frame_height,
	graphical_set = {
		base = {
			position = { 85, 0 },
			corner_size = 8,
			center = { position = { 411, 25 }, size = { 1, 1 } },
			draw_type = "outer",
		},
		shadow = default_inner_shadow,
	},
}

-- LABEL STYLES

--I am unsure what this was supposed to be in 1.1
local default_orange_color = {
	r = 255,
	g = 128,
	b = 0,
}

styles.ltnm_label_signal_count_inventory = {
	type = "label_style",
	parent = "count_label",
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

styles.ltnm_label_train_count = {
	type = "label_style",
	parent = "ltnm_label_train_count_inventory",
	right_padding = 6,
	top_padding = -5,
}

local hovered_label_color = {
	r = 0.5 * (1 + default_orange_color.r),
	g = 0.5 * (1 + default_orange_color.g),
	b = 0.5 * (1 + default_orange_color.b),
}

styles.ltnm_clickable_semibold_label = {
	type = "label_style",
	parent = "ltnm_semibold_label",
	hovered_font_color = hovered_label_color,
	disabled_font_color = hovered_label_color,
}

styles.ltnm_minimap_label = {
	type = "label_style",
	font = "default-game",
	font_color = default_font_color,
	size = 90,
	vertical_align = "bottom",
	horizontal_align = "right",
	right_padding = 4,
}

styles.ltnm_semibold_label = {
	type = "label_style",
	font = "default-semibold",
}

-- MINIMAP STYLES

styles.ltnm_train_minimap = {
	type = "minimap_style",
	size = 90,
}

-- SCROLL PANE STYLES

styles.ltnm_table_scroll_pane = {
	type = "scroll_pane_style",
	parent = "flib_naked_scroll_pane_no_padding",
	vertical_flow_style = {
		type = "vertical_flow_style",
		vertical_spacing = 0,
	},
}

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
		bottom_padding = 8,
	},
}

if settings.startup["cybersyn-manager-enabled"].value then
	data:extend({
		-- custom inputs
		{
			type = "custom-input",
			name = "cybersyn-toggle-gui",
			key_sequence = "CONTROL + T",
			action = "lua",
		},
		--{
		--  type = "custom-input",
		--  name = "ltnm-linked-focus-search",
		--  key_sequence = "",
		--  linked_game_control = "focus-search",
		--},
		-- shortcuts
		{
			type = "shortcut",
			name = "cybersyn-toggle-gui",
			icon = "__cybersyn__/graphics/shortcut/shortcut_icon.png",
			icon_size = 32,
			small_icon = "__cybersyn__/graphics/shortcut/shortcut_icon.png",
			small_icon_size = 24,
			--icon = data_util.build_sprite("nil", { 0, 0 }, util.paths.shortcut_icons, 32, 2),
			--disabled_icon = data_util.build_sprite(nil, { 48, 0 }, util.paths.shortcut_icons, 32, 2),
			--small_icon = data_util.build_sprite(nil, { 0, 32 }, util.paths.shortcut_icons, 24, 2),
			--disabled_small_icon = data_util.build_sprite(nil, { 36, 32 }, util.paths.shortcut_icons, 24, 2),
			toggleable = true,
			action = "lua",
			associated_control_input = "cybersyn-toggle-gui",
			technology_to_unlock = "cybersyn-train-network",
		},
	})
end
