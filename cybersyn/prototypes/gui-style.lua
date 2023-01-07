local constants = require("constants")

local util = require("prototypes.util")

local styles = data.raw["gui-style"]["default"]

-- local depot_button_height = 89

-- BUTTON STYLES

-- smaller flib slot buttons
for _, color in ipairs({ "default", "red", "green", "blue" }) do
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
  bottom_margin = 12,
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
  parent = "statistics_table_item_frame",
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
  right_padding = 7 + 12, -- For scrollbar
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
