local gui = require("__flib__.gui")
local analytics = require("scripts.analytics")
local suggestions_engine = require("scripts.suggestions")

local suggestions_tab = {}

local CACHE_DURATION_TICKS = 300  -- 5 seconds at 60 UPS

local CATEGORIES = {
	{ types = {"loading"}, header = "suggestions-loading", recommendation = "suggestions-rec-loading" },
	{ types = {"unloading"}, header = "suggestions-unloading", recommendation = "suggestions-rec-unloading" },
	{ types = {"wait"}, header = "suggestions-wait", recommendation = "suggestions-rec-wait" },
	{ types = {"travel"}, header = "suggestions-travel", recommendation = "suggestions-rec-travel" },
	{ types = {"low_util"}, header = "suggestions-low-util", recommendation = "suggestions-rec-low-util" },
	{ types = {"high_util"}, header = "suggestions-high-util", recommendation = "suggestions-rec-high-util" },
	{ types = {"slow_item"}, header = "suggestions-slow-items", recommendation = "suggestions-rec-slow-item" },
}

function suggestions_tab.create()
	return {
		tab = {
			name = "manager_suggestions_tab",
			type = "tab",
			caption = { "cybersyn-gui.suggestions-tab" },
			ref = { "suggestions_tab" },
			handler = suggestions_tab.handle.on_suggestions_tab_selected,
		},
		content = {
			name = "manager_suggestions_content_frame",
			type = "flow",
			direction = "vertical",
			ref = { "suggestions_content_frame" },
			style_mods = { horizontally_stretchable = true, vertically_stretchable = true },
			{
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 8, bottom_margin = 8 },
				{
					name = "suggestions_show_dismissed",
					type = "checkbox",
					state = false,
					caption = { "cybersyn-gui.show-dismissed" },
					ref = { "suggestions_show_dismissed" },
					handler = suggestions_tab.handle.on_show_dismissed_changed,
				},
				{ type = "empty-widget", style = "flib_horizontal_pusher" },
			},
			{
				type = "scroll-pane",
				style = "flib_naked_scroll_pane",
				style_mods = {
					horizontally_stretchable = true,
					vertically_stretchable = true,
					padding = 4,
				},
				ref = { "suggestions_scroll_pane" },
				{
					name = "suggestions_content",
					type = "flow",
					direction = "vertical",
					ref = { "suggestions_content" },
					style_mods = { horizontally_stretchable = true },
				},
			},
			{
				name = "suggestions_empty_label",
				type = "label",
				caption = { "cybersyn-gui.no-suggestions" },
				ref = { "suggestions_empty_label" },
				visible = true,
			},
		},
	}
end

---Create a compact suggestion row element
---@param suggestion Suggestion
---@param is_dismissed boolean
---@return table
local function create_suggestion_row(suggestion, is_dismissed)
	local time_str = suggestion.avg_time and suggestions_engine.format_time(suggestion.avg_time) or nil
	local dimmed = is_dismissed and {r = 0.6, g = 0.6, b = 0.6} or nil

	-- Build stats string based on suggestion type
	local stats
	if suggestion.type == "low_util" or suggestion.type == "high_util" then
		stats = string.format("%.0f%% utilized", suggestion.percentage)
	elseif suggestion.type == "slow_item" then
		stats = time_str and ("avg " .. time_str) or ""
	else
		-- loading, unloading, wait, travel - show percentage of delivery time
		stats = string.format("%.0f%%", suggestion.percentage)
		if time_str then
			stats = stats .. " (avg " .. time_str .. ")"
		end
	end

	return {
		type = "flow",
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 4, left_padding = 8 },
		{
			type = "sprite-button",
			sprite = suggestion.icon,
			tooltip = { "cybersyn-gui.filter-by-item" },
			tags = { item_name = suggestion.identifier },
			handler = suggestions_tab.handle.on_item_click,
			style = "slot_button",
			style_mods = { size = 32 },
		},
		{
			type = "button",
			caption = suggestion.title,
			tooltip = { "cybersyn-gui.filter-by-item" },
			tags = { item_name = suggestion.identifier },
			handler = suggestions_tab.handle.on_item_click,
			style = "list_box_item",
			style_mods = {
				width = 180,
				font_color = dimmed,
				left_padding = 4,
				right_padding = 4,
			},
		},
		{
			type = "label",
			caption = stats,
			style_mods = {
				width = 140,
				font_color = dimmed,
			},
		},
		{ type = "empty-widget", style = "flib_horizontal_pusher" },
		{
			type = "sprite-button",
			sprite = "utility/close",
			style = "frame_action_button",
			tooltip = is_dismissed and { "cybersyn-gui.restore" } or { "cybersyn-gui.dismiss" },
			tags = { dismissal_key = suggestion.dismissal_key, is_dismissed = is_dismissed },
			handler = suggestions_tab.handle.on_dismiss_click,
		},
	}
end

---@param map_data MapData
---@param player_data PlayerData
function suggestions_tab.build(map_data, player_data)
	if not analytics.is_enabled() then
		return
	end

	-- Ensure analytics is initialized
	analytics.init(map_data)
	if not map_data.analytics then
		return
	end

	local refs = player_data.refs
	local content = refs.suggestions_content
	if not content then return end

	content.clear()

	if not player_data.dismissed_suggestions then
		player_data.dismissed_suggestions = {}
	end

	local show_dismissed = player_data.show_dismissed_suggestions or false
	if refs.suggestions_show_dismissed then
		refs.suggestions_show_dismissed.state = show_dismissed
	end

	local current_tick = game.tick
	local cache = player_data.suggestions_cache
	local all_suggestions

	if cache and (current_tick - cache.tick) < CACHE_DURATION_TICKS then
		all_suggestions = cache.suggestions
	else
		all_suggestions = suggestions_engine.generate(map_data)
		player_data.suggestions_cache = {
			tick = current_tick,
			suggestions = all_suggestions,
		}
	end

	local by_type = {}
	for _, s in ipairs(all_suggestions) do
		if not by_type[s.type] then
			by_type[s.type] = {}
		end
		by_type[s.type][#by_type[s.type] + 1] = s
	end

	local visible_count = 0
	local dismissed_count = 0

	for _, s in ipairs(all_suggestions) do
		if player_data.dismissed_suggestions[s.dismissal_key] then
			dismissed_count = dismissed_count + 1
		else
			visible_count = visible_count + 1
		end
	end

	local rendered_any = false
	for _, category in ipairs(CATEGORIES) do
		local category_suggestions = {}
		for _, type_name in ipairs(category.types) do
			if by_type[type_name] then
				for _, s in ipairs(by_type[type_name]) do
					category_suggestions[#category_suggestions + 1] = s
				end
			end
		end

		if #category_suggestions > 0 then
			local visible_in_category = {}
			for _, s in ipairs(category_suggestions) do
				local is_dismissed = player_data.dismissed_suggestions[s.dismissal_key] or false
				if show_dismissed or not is_dismissed then
					visible_in_category[#visible_in_category + 1] = { suggestion = s, dismissed = is_dismissed }
				end
			end

			table.sort(visible_in_category, function(a, b)
				return a.suggestion.percentage > b.suggestion.percentage
			end)

			if #visible_in_category > 0 then
				gui.add(content, {
					{
						type = "flow",
						direction = "vertical",
						style_mods = { top_margin = rendered_any and 12 or 0, bottom_margin = 4 },
						{
							type = "label",
							caption = { "cybersyn-gui." .. category.header },
							style = "caption_label",
						},
						{
							type = "label",
							caption = { "cybersyn-gui." .. category.recommendation },
							style_mods = { single_line = false, font_color = {r = 0.8, g = 0.8, b = 0.6} },
						},
					}
				})

				for _, entry in ipairs(visible_in_category) do
					gui.add(content, { create_suggestion_row(entry.suggestion, entry.dismissed) })
				end

				rendered_any = true
			end
		end
	end

	if refs.suggestions_empty_label then
		if not rendered_any then
			if dismissed_count > 0 then
				refs.suggestions_empty_label.caption = { "cybersyn-gui.suggestions-dismissed", dismissed_count }
			else
				refs.suggestions_empty_label.caption = { "cybersyn-gui.no-suggestions" }
			end
			refs.suggestions_empty_label.visible = true
		else
			refs.suggestions_empty_label.visible = false
		end
	end
end

suggestions_tab.handle = {}

--- @param e {player_index: uint}
function suggestions_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	if not player_data then return end
	handler(player, player_data, player_data.refs, e)
end

---@param player LuaPlayer
---@param player_data PlayerData
function suggestions_tab.handle.on_suggestions_tab_selected(player, player_data)
	player_data.selected_tab = "suggestions_tab"
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_checked_state_changed
function suggestions_tab.handle.on_show_dismissed_changed(player, player_data, refs, e)
	player_data.show_dismissed_suggestions = e.element.state
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_click
function suggestions_tab.handle.on_item_click(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end

	local item_name = element.tags.item_name
	if not item_name then return end

	local base_name = item_name:match("^([^:]+)") or item_name
	player_data.search_item = base_name

	if refs.manager_item_filter then
		local signal_id
		if prototypes.item[base_name] then
			signal_id = { type = "item", name = base_name }
		elseif prototypes.fluid[base_name] then
			signal_id = { type = "fluid", name = base_name }
		elseif prototypes.virtual_signal[base_name] then
			signal_id = { type = "virtual", name = base_name }
		end
		if signal_id then
			refs.manager_item_filter.elem_value = signal_id
		end
	end

	if refs.manager_tabbed_pane then
		refs.manager_tabbed_pane.selected_tab_index = 2
		player_data.selected_tab = "stations_tab"
	end
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_click
function suggestions_tab.handle.on_dismiss_click(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end

	local dismissal_key = element.tags.dismissal_key
	if not dismissal_key then return end

	if not player_data.dismissed_suggestions then
		player_data.dismissed_suggestions = {}
	end

	local is_dismissed = element.tags.is_dismissed
	if is_dismissed then
		player_data.dismissed_suggestions[dismissal_key] = nil
	else
		player_data.dismissed_suggestions[dismissal_key] = true
	end

	player_data.suggestions_cache = nil
end

gui.add_handlers(suggestions_tab.handle, suggestions_tab.wrapper)

return suggestions_tab
