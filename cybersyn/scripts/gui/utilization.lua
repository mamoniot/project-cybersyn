local gui = require("__flib__.gui")
local analytics = require("scripts.analytics")

local utilization_tab = {}

local CACHE_DURATION_TICKS = 300  -- 5 seconds at 60 UPS

local interval_names = {"5s", "1m", "10m", "1h", "10h", "50h", "250h", "1000h"}

-- Graph dimensions (pixels) - sized to fill the manager window
local GRAPH_WIDTH = 900
local GRAPH_HEIGHT = 700

function utilization_tab.create()
	local interval_buttons = {}
	for i, name in ipairs(interval_names) do
		interval_buttons[i] = {
			type = "button",
			caption = name,
			style = i == 1 and "flib_selected_tool_button" or "tool_button",
			tags = { interval_name = name, interval_index = i },
			handler = utilization_tab.handle.on_utilization_interval_click,
		}
	end

	return {
		tab = {
			name = "manager_utilization_tab",
			type = "tab",
			caption = { "cybersyn-gui.utilization-tab" },
			ref = { "utilization", "tab" },
			handler = utilization_tab.handle.on_utilization_tab_selected,
		},
		content = {
			name = "manager_utilization_content_frame",
			type = "flow",
			direction = "vertical",
			ref = { "utilization", "content_frame" },
			-- Time range selector at top
			{
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 8, bottom_margin = 4 },
				{
					type = "label",
					caption = { "cybersyn-gui.time-range" },
					style = "caption_label",
				},
				{
					name = "utilization_interval_buttons",
					type = "flow",
					direction = "horizontal",
					ref = { "utilization", "interval_buttons" },
					table.unpack(interval_buttons),
				},
			},
			-- Main content: sidebar + graph
			{
				name = "utilization_main_flow",
				type = "flow",
				direction = "horizontal",
				style_mods = {
					horizontal_spacing = 8,
					horizontally_stretchable = true,
					vertically_stretchable = true,
				},
				ref = { "utilization", "main_flow" },
				visible = false,
				-- Left sidebar: train types legend
				{
					name = "utilization_legend_flow",
					type = "flow",
					direction = "vertical",
					style_mods = { width = 150, vertically_stretchable = true },
					ref = { "utilization", "legend_flow" },
					{
						type = "label",
						caption = { "cybersyn-gui.train-types" },
						style = "caption_label",
					},
					{
						type = "scroll-pane",
						style = "flib_naked_scroll_pane_no_padding",
						style_mods = { vertically_stretchable = true },
						ref = { "utilization", "legend_scroll" },
						{
							name = "utilization_legend_table",
							type = "table",
							column_count = 1,
							ref = { "utilization", "legend_table" },
						},
					},
				},
				-- Right: large graph (stretchable to fill available space)
				{
					name = "utilization_camera_frame",
					type = "frame",
					style = "deep_frame_in_shallow_frame",
					style_mods = {
						horizontally_stretchable = true,
						vertically_stretchable = true,
						minimal_width = GRAPH_WIDTH,
						minimal_height = GRAPH_HEIGHT,
					},
					ref = { "utilization", "camera_frame" },
					{
						name = "utilization_camera",
						type = "camera",
						position = { 0, 0 },
						surface_index = 1,
						zoom = 1,
						ref = { "utilization", "camera" },
						style_mods = {
							horizontally_stretchable = true,
							vertically_stretchable = true,
							minimal_width = GRAPH_WIDTH,
							minimal_height = GRAPH_HEIGHT,
						},
					},
				},
			},
			-- No data message
			{
				name = "utilization_no_data_label",
				type = "label",
				caption = { "cybersyn-gui.no-analytics-data" },
				ref = { "utilization", "no_data_label" },
				visible = true,
			},
		},
	}
end

---Build sorted series list from interval data
---@param interval table The interval data
---@return table[] all_series Sorted list of {name, sum, count}
local function build_sorted_series(interval)
	local all_series = {}
	for name, count in pairs(interval.counts) do
		all_series[#all_series + 1] = {name = name, sum = interval.sum[name] or 0, count = count}
	end
	table.sort(all_series, function(a, b)
		if a.sum ~= b.sum then
			return a.sum > b.sum
		end
		return a.name < b.name
	end)
	return all_series
end

---@param map_data MapData
---@param player_data PlayerData
function utilization_tab.build(map_data, player_data)
	if not analytics.is_enabled() then
		return
	end
	-- Ensure analytics is initialized and surface settings are applied
	analytics.init(map_data)
	if not map_data.analytics then
		return
	end

	local refs = player_data.refs
	local data = map_data.analytics

	-- Get selected interval
	local interval_index = player_data.utilization_interval or 1
	local intervals = data.train_utilization
	local interval = intervals[interval_index]

	-- Update button styles to match current interval
	local interval_buttons = refs.utilization_interval_buttons
	if interval_buttons then
		for _, button in pairs(interval_buttons.children) do
			if button.tags and button.tags.interval_index then
				button.style = button.tags.interval_index == interval_index and "flib_selected_tool_button" or "tool_button"
			end
		end
	end

	-- Check if there's any data
	local has_data = false
	if interval and next(interval.counts) then
		has_data = true
	end

	-- Update visibility
	if refs.utilization_no_data_label then
		refs.utilization_no_data_label.visible = not has_data
	end
	if refs.utilization_main_flow then
		refs.utilization_main_flow.visible = has_data
	end

	if not has_data then
		return
	end

	-- Register the camera for this interval (only if not already registered)
	local player = game.get_player(player_data.player_index)
	if not player then return end

	-- Only register once per tab open, not every GUI update
	if not player_data.utilization_registered then
		analytics.interval_register_gui(map_data, interval, player, refs)
		player_data.utilization_registered = true
	end

	local chunk = interval.chunk
	if not chunk then
		return
	end

	-- Update camera position to point at analytics surface
	if refs.utilization_camera and chunk and chunk.coord then
		local cam_x = chunk.coord.x + GRAPH_WIDTH / 2 / 32
		local cam_y = chunk.coord.y + GRAPH_HEIGHT / 2 / 32
		refs.utilization_camera.position = { cam_x, cam_y }
		refs.utilization_camera.surface_index = data.surface.index
		refs.utilization_camera.zoom = 1
	end

	-- Get selected series
	local selected_series = player_data.utilization_selected or {}

	-- Check cache - use cached data if still valid
	local current_tick = game.tick
	local cache = player_data.utilization_cache
	local all_series
	local cache_hit = false

	if cache and cache.interval_index == interval_index and (current_tick - cache.tick) < CACHE_DURATION_TICKS then
		all_series = cache.all_series
		cache_hit = true
	else
		-- Cache miss - build sorted series list
		all_series = build_sorted_series(interval)
		player_data.utilization_cache = {
			tick = current_tick,
			interval_index = interval_index,
			all_series = all_series,
		}
	end

	-- Only render graph on cache miss
	if not cache_hit then
		analytics.render_graph(map_data, intervals, interval_index, selected_series, {0, 100})
	end

	-- Build legend from cached series data
	local legend_table = refs.utilization_legend_table
	if legend_table then
		legend_table.clear()

		local colors = analytics.get_colors()
		for i, entry in ipairs(all_series) do
			local layout_id = tonumber(entry.name)
			local layout = layout_id and map_data.layouts[layout_id]
			local layout_name = analytics.format_layout_name(layout, layout_id)
			local avg_util = entry.sum / (entry.count or 1)

			local color = colors[((i - 1) % #colors) + 1]
			local is_selected = selected_series[entry.name] ~= false

			gui.add(legend_table, {
				{
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
					{
						type = "progressbar",
						value = 1,
						style_mods = {
							width = 12,
							height = 4,
							color = is_selected and color or {r=0.5, g=0.5, b=0.5},
						},
					},
					{
						type = "checkbox",
						state = is_selected,
						caption = layout_name,
						tags = { series_name = entry.name },
						handler = utilization_tab.handle.on_utilization_legend_checkbox_changed,
					},
					{
						type = "label",
						caption = string.format("%.1f%%", avg_util),
						style_mods = { font_color = is_selected and color or {r=0.5, g=0.5, b=0.5} },
					},
				},
			})
		end
	end
end

---@param map_data MapData
---@param player_data PlayerData
function utilization_tab.cleanup(map_data, player_data)
	if not map_data.analytics then return end
	if not player_data.player_index then return end

	local interval_index = player_data.utilization_interval or 1
	local interval = map_data.analytics.train_utilization[interval_index]

	local player = game.get_player(player_data.player_index)
	if player and interval then
		analytics.interval_unregister_gui(map_data, interval, player)
	end

	-- Clear registration flag so we re-register next time
	player_data.utilization_registered = nil
end

utilization_tab.handle = {}

--- @param e {player_index: uint}
function utilization_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

---@param player LuaPlayer
---@param player_data PlayerData
function utilization_tab.handle.on_utilization_tab_selected(player, player_data)
	player_data.selected_tab = "utilization_tab"
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_click
function utilization_tab.handle.on_utilization_interval_click(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end

	local interval_index = element.tags.interval_index
	if not interval_index then return end

	-- Cleanup old interval (this also clears utilization_registered)
	utilization_tab.cleanup(storage, player_data)

	-- Update selected interval
	player_data.utilization_interval = interval_index
	-- Force re-registration for new interval
	player_data.utilization_registered = nil
	-- Invalidate cache for immediate refresh
	player_data.utilization_cache = nil

	-- Update button styles
	local interval_buttons = refs.utilization_interval_buttons
	if interval_buttons then
		for _, button in pairs(interval_buttons.children) do
			if button.tags and button.tags.interval_index then
				button.style = button.tags.interval_index == interval_index and "flib_selected_tool_button" or "tool_button"
			end
		end
	end
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_checked_state_changed
function utilization_tab.handle.on_utilization_legend_checkbox_changed(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end

	local series_name = element.tags.series_name
	if not series_name then return end

	-- Initialize selected series table if needed
	if not player_data.utilization_selected then
		player_data.utilization_selected = {}
	end

	-- Toggle series selection
	player_data.utilization_selected[series_name] = element.state

	-- Invalidate cache to re-render with new selection
	player_data.utilization_cache = nil
end

gui.add_handlers(utilization_tab.handle, utilization_tab.wrapper)

return utilization_tab
