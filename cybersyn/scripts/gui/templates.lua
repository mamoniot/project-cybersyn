local constants = require("constants")

local templates = {}

--- Creates a frame action button, automatically accounting for inverted sprites.
--- @param name string?
--- @param sprite string?
--- @param tooltip LocalisedString?
--- @param handler GuiElemHandler?
--- @param tags Tags?
function templates.frame_action_button(name, sprite, tooltip, handler, tags)
	return {
		type = "sprite-button",
		name = name,
		style = "frame_action_button",
		sprite = sprite .. "",
		hovered_sprite = sprite .. "",
		clicked_sprite = sprite .. "",
		mouse_button_filter = { "left" },
		tooltip = tooltip,
		handler = handler,
		tags = tags,
	}
end

--- Creates a full-sized scrollable slot table for the inventory tab.
--- @param name string
--- @param columns uint
function templates.inventory_slot_table(name, columns)
	return {
		type = "flow",
		direction = "vertical",
		{ type = "label", style = "bold_label", caption = { "cybersyn-gui." .. string.gsub(name, "_", "-") } },
		{
			type = "frame",
			style = "deep_frame_in_shallow_frame",
			style_mods = { height = constants.gui_inventory_table_height },
			ref = { "inventory", name, "frame" },
			{
				type = "scroll-pane",
				style = "ltnm_slot_table_scroll_pane",
				style_mods = { width = 40 * columns + 12, minimal_height = constants.gui_inventory_table_height },
				vertical_scroll_policy = "auto-and-reserve-space",
				-- vertical_scroll_policy = "always",
				ref = { "inventory", name, "scroll_pane" },
				{
					type = "table",
					name = "inventory_" .. name .. "_table",
					style = "slot_table",
					column_count = columns,
					ref = { "inventory", name, "table" }
				},
			},
		},
	}
end

--- Creates a small non-scrollable slot table.
--- @param widths table
--- @param color string
--- @param name string
function templates.small_slot_table(widths, color, name)
	return {
		type = "frame",
		name = name .. "_frame",
		style = "ltnm_small_slot_table_frame_" .. color,
		style_mods = { width = widths[name] },
		{ type = "table", name = name .. "_table", style = "slot_table", column_count = widths[name .. "_columns"] },
	}
end

--- Creates a column header with a sort toggle.
--- @param widths table
--- @param tab string
--- @param column string
--- @param selected boolean
--- @param tooltip LocalisedString
function templates.sort_checkbox(widths, tab, column, selected, tooltip, state)
	if state == nil then
		state = false
	end
	return {
		type = "checkbox",
		style = selected and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox",
		style_mods = { width = widths and widths[tab][column] or nil, horizontally_stretchable = not widths },
		caption = { "cybersyn-gui." .. string.gsub(column, "_", "-") },
		tooltip = tooltip,
		state = state,
		ref = { tab, "toolbar", column .. "_checkbox" },
		actions = {
			on_checked_state_changed = { gui = "main", tab = tab, action = "toggle_sort", column = column },
		},
	}
end

function templates.status_indicator(width, center)
	return {
		type = "flow",
		style = "flib_indicator_flow",
		style_mods = { horizontal_align = center and "center" or nil, width = width },
		{ type = "sprite", style = "flib_indicator" },
		{ type = "label" },
	}
end

return templates
