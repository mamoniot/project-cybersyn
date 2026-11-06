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

--- A sortable column header. It starts unchecked (arrow down) on every column; listing.sync_sort_header reads `column`
--- and `default_state` from its tags to restyle it from the stored sort after the window is rebuilt.
--- @param tab string canonical tab name, e.g. "stations_tab"
--- @param column string
--- @param caption LocalisedString
--- @param tooltip LocalisedString
--- @param selected boolean whether this is the default sort column
--- @param handler GuiElemHandler on_gui_checked_state_changed handler, normally listing.handle.sort_click
function templates.sort_checkbox(tab, column, caption, tooltip, selected, handler)
	return {
		type = "checkbox",
		style = selected and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox",
		caption = caption,
		tooltip = tooltip,
		state = false,
		tags = { sort_tab = tab, column = column, default_state = false },
		handler = { [defines.events.on_gui_checked_state_changed] = handler },
	}
end

--- A column header label (no sorting).
--- @param caption LocalisedString
--- @param tooltip LocalisedString?
function templates.column_label(caption, tooltip)
	return { type = "label", style = "ltnm_column_label", caption = caption, tooltip = tooltip }
end

--- Pager row `[«] [‹] "1–50 of 1,921" [›] [»]` for a tab. Element names are `<tab>_pager`, `<tab>_pager_first`,
--- `_prev`, `_label`, `_next`, `_last`; listing.paginate keeps them current. Shift+‹/› moves 10 pages.
--- @param tab string canonical tab name, e.g. "stations_tab"
--- @param handler GuiElemHandler click handler, normally listing.handle.pager_click
function templates.pager(tab, handler)
	local function button(action, caption)
		return {
			type = "button",
			name = tab .. "_pager_" .. action,
			style = "tool_button",
			caption = caption,
			tooltip = { "cybersyn-gui.pager-" .. action },
			enabled = false,
			tags = { pager_tab = tab, pager_action = action },
			handler = { [defines.events.on_gui_click] = handler },
		}
	end
	return {
		type = "flow",
		name = tab .. "_pager",
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 4 },
		button("first", "«"),
		button("prev", "‹"),
		{
			type = "label",
			name = tab .. "_pager_label",
			style = "bold_label",
			style_mods = { minimal_width = 140, horizontal_align = "center" },
			caption = { "cybersyn-gui.pager-empty" },
		},
		button("next", "›"),
		button("last", "»"),
	}
end

--- The strips at the top of every tab: the dispatch-paused banner, then the subheader with the
--- station-name search field (left, on a tab that applies it), the item filter chip, the station chip, the train chip
--- (on a tab that applies it), the collecting progress and `right` (right-aligned).
--- Element names are `<tab>_banner`, `<tab>_banner_label`, `<tab>_search_field`, `<tab>_chip_flow`,
--- `<tab>_chip_icon`, `<tab>_chip`, `<tab>_station_chip_flow`, `<tab>_station_chip_icon`, `<tab>_station_chip`,
--- `<tab>_train_chip_flow`, `<tab>_train_chip_icon`, `<tab>_train_chip`, `<tab>_collecting`.
--- @param entry ManagerTab
--- @param handlers {search_changed: function, chip_click: function}
--- @param right flib.GuiElemDef[]? subheader children after the pusher
--- @return flib.GuiElemDef banner
--- @return flib.GuiElemDef subheader
function templates.tab_header(entry, handlers, right)
	local tab = entry.name
	local banner = {
		type = "frame",
		name = tab .. "_banner",
		style = "cybersyn_banner_frame",
		visible = false,
		{ type = "label", name = tab .. "_banner_label", style = "cybersyn_banner_label" },
	}
	local subheader = {
		type = "frame",
		name = tab .. "_subheader",
		style = "cybersyn_tab_subheader",
	}
	if entry.search then
		subheader[#subheader + 1] = {
			type = "textfield",
			name = tab .. "_search_field",
			style = "cybersyn_search_field",
			visible = false,
			lose_focus_on_confirm = true,
			icon_selector = true,
			tooltip = { "cybersyn-gui.search-tooltip" },
			tags = { tab = tab },
			handler = {
				[defines.events.on_gui_text_changed] = handlers.search_changed,
			},
		}
	end
	subheader[#subheader + 1] = {
		type = "flow",
		name = tab .. "_chip_flow",
		direction = "horizontal",
		visible = false,
		style_mods = { horizontal_spacing = 0, vertical_align = "center" },
		{
			type = "sprite-button",
			name = tab .. "_chip_icon",
			style = "cybersyn_item_chip_icon",
			mouse_button_filter = { "left", "right" },
			handler = { [defines.events.on_gui_click] = handlers.chip_click },
		},
		{
			type = "button",
			name = tab .. "_chip",
			style = "cybersyn_item_chip",
			mouse_button_filter = { "left", "right" },
			handler = { [defines.events.on_gui_click] = handlers.chip_click },
		},
	}
	subheader[#subheader + 1] = {
		type = "flow",
		name = tab .. "_station_chip_flow",
		direction = "horizontal",
		visible = false,
		style_mods = { horizontal_spacing = 0, vertical_align = "center" },
		{
			type = "sprite-button",
			name = tab .. "_station_chip_icon",
			style = "cybersyn_item_chip_icon",
			sprite = "item/train-stop",
			tags = { chip = "station" },
			mouse_button_filter = { "left", "right" },
			handler = { [defines.events.on_gui_click] = handlers.chip_click },
		},
		{
			type = "button",
			name = tab .. "_station_chip",
			style = "cybersyn_item_chip",
			tags = { chip = "station" },
			mouse_button_filter = { "left", "right" },
			handler = { [defines.events.on_gui_click] = handlers.chip_click },
		},
	}
	if entry.train then
		subheader[#subheader + 1] = {
			type = "flow",
			name = tab .. "_train_chip_flow",
			direction = "horizontal",
			visible = false,
			style_mods = { horizontal_spacing = 0, vertical_align = "center" },
			{
				type = "sprite-button",
				name = tab .. "_train_chip_icon",
				style = "cybersyn_item_chip_icon",
				sprite = "item/locomotive",
				tooltip = { "cybersyn-gui.train-chip-tooltip" },
				tags = { chip = "train" },
				mouse_button_filter = { "left", "right" },
				handler = { [defines.events.on_gui_click] = handlers.chip_click },
			},
			{
				type = "button",
				name = tab .. "_train_chip",
				style = "cybersyn_item_chip",
				tooltip = { "cybersyn-gui.train-chip-tooltip" },
				tags = { chip = "train" },
				mouse_button_filter = { "left", "right" },
				handler = { [defines.events.on_gui_click] = handlers.chip_click },
			},
		}
	end
	subheader[#subheader + 1] = {
		type = "label",
		name = tab .. "_collecting",
		style = "cybersyn_subheader_note",
		visible = false,
	}
	subheader[#subheader + 1] = { type = "empty-widget", style = "flib_horizontal_pusher" }
	for _, def in ipairs(right or {}) do
		subheader[#subheader + 1] = def
	end
	return banner, subheader
end

return templates
