local gui = require("__flib__.gui")
local analytics = require("scripts.analytics")

local delivery_breakdown_tab = {}

local CACHE_DURATION_TICKS = 300  -- 5 seconds at 60 UPS

local interval_names = {"5s", "1m", "10m", "1h", "10h", "50h", "250h", "1000h"}

-- Graph dimensions (pixels) - sized to fill the manager window
local GRAPH_WIDTH = 900
local GRAPH_HEIGHT = 700

-- Phase colors for stacked bars
local PHASE_COLORS = {
	wait = {r = 0.8, g = 0.2, b = 0.2},        -- Red - waiting for train
	travel_to_p = {r = 1.0, g = 0.6, b = 0.0}, -- Orange - traveling to provider
	loading = {r = 1.0, g = 1.0, b = 0.0},     -- Yellow - loading
	travel_to_r = {r = 0.0, g = 0.8, b = 0.2}, -- Green - traveling to requester
	unloading = {r = 0.2, g = 0.6, b = 1.0},   -- Blue - unloading
}

local PHASE_ORDER = {"wait", "travel_to_p", "loading", "travel_to_r", "unloading"}
local PHASE_LABELS = {
	wait = "Matching",
	travel_to_p = "Travel to P",
	loading = "Loading",
	travel_to_r = "Travel to R",
	unloading = "Unloading",
}

local PHASE_TOOLTIPS = {
	wait = "Time from request until a provider and train are matched",
	travel_to_p = "Train traveling to provider station",
	loading = "Loading cargo at provider station",
	travel_to_r = "Train traveling to requester station",
	unloading = "Unloading cargo at requester station",
}

function delivery_breakdown_tab.create()
	local interval_buttons = {}
	for i, name in ipairs(interval_names) do
		interval_buttons[i] = {
			type = "button",
			caption = name,
			style = i == 1 and "flib_selected_tool_button" or "tool_button",
			tags = { interval_name = name, interval_index = i },
			handler = delivery_breakdown_tab.handle.on_breakdown_interval_click,
		}
	end

	-- Build phase legend items
	local legend_items = {}
	for i, phase in ipairs(PHASE_ORDER) do
		legend_items[i] = {
			type = "flow",
			direction = "horizontal",
			style_mods = { vertical_align = "center", horizontal_spacing = 4 },
			{
				type = "progressbar",
				value = 1,
				style_mods = {
					width = 16,
					height = 12,
					color = PHASE_COLORS[phase],
				},
			},
			{
				type = "label",
				caption = PHASE_LABELS[phase],
				tooltip = PHASE_TOOLTIPS[phase],
				style_mods = { font = "default-small" },
			},
		}
	end

	return {
		tab = {
			name = "manager_delivery_breakdown_tab",
			type = "tab",
			caption = { "cybersyn-gui.delivery-breakdown-tab" },
			ref = { "delivery_breakdown", "tab" },
			handler = delivery_breakdown_tab.handle.on_breakdown_tab_selected,
		},
		content = {
			name = "manager_delivery_breakdown_content_frame",
			type = "flow",
			direction = "vertical",
			ref = { "delivery_breakdown", "content_frame" },
			-- Time range selector
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
					name = "breakdown_interval_buttons",
					type = "flow",
					direction = "horizontal",
					ref = { "delivery_breakdown", "interval_buttons" },
					table.unpack(interval_buttons),
				},
			},
			-- Main content: legend + graph
			{
				name = "breakdown_main_flow",
				type = "flow",
				direction = "horizontal",
				style_mods = {
					horizontal_spacing = 8,
					horizontally_stretchable = true,
					vertically_stretchable = true,
				},
				ref = { "delivery_breakdown", "main_flow" },
				visible = false,
				-- Left sidebar: phase legend
				{
					name = "breakdown_legend_flow",
					type = "flow",
					direction = "vertical",
					style_mods = { width = 120, vertically_stretchable = true },
					ref = { "delivery_breakdown", "legend_flow" },
					{
						type = "label",
						caption = { "cybersyn-gui.phases" },
						style = "caption_label",
					},
					{
						type = "flow",
						direction = "vertical",
						style_mods = { top_margin = 8, vertical_spacing = 4 },
						table.unpack(legend_items),
					},
					-- Stats section
					{
						type = "line",
						direction = "horizontal",
						style_mods = { top_margin = 12, bottom_margin = 8 },
					},
					{
						type = "label",
						caption = { "cybersyn-gui.stats" },
						style = "caption_label",
					},
					{
						name = "breakdown_stats_label",
						type = "label",
						ref = { "delivery_breakdown", "stats_label" },
						caption = "",
						style_mods = { single_line = false, font = "default-small" },
					},
				},
				-- Right: large graph
				{
					name = "breakdown_camera_frame",
					type = "frame",
					style = "deep_frame_in_shallow_frame",
					style_mods = {
						horizontally_stretchable = true,
						vertically_stretchable = true,
						minimal_width = GRAPH_WIDTH,
						minimal_height = GRAPH_HEIGHT,
					},
					ref = { "delivery_breakdown", "camera_frame" },
					{
						name = "breakdown_camera",
						type = "camera",
						position = { 0, 0 },
						surface_index = 1,
						zoom = 1,
						ref = { "delivery_breakdown", "camera" },
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
				name = "breakdown_no_data_label",
				type = "label",
				caption = { "cybersyn-gui.no-breakdown-data" },
				ref = { "delivery_breakdown", "no_data_label" },
				visible = true,
			},
		},
	}
end

---Format seconds into human readable time
---@param seconds number
---@return string
local function format_time(seconds)
	if seconds < 60 then
		return string.format("%.1fs", seconds)
	elseif seconds < 3600 then
		local mins = math.floor(seconds / 60)
		local secs = seconds % 60
		return string.format("%dm %.0fs", mins, secs)
	else
		local hours = math.floor(seconds / 3600)
		local mins = math.floor((seconds % 3600) / 60)
		return string.format("%dh %dm", hours, mins)
	end
end

---Single-pass gather, filter by time range, and calculate stats
---@param data table Analytics data
---@param oldest_tick number Minimum complete_tick to include
---@param search_item string? Optional item filter
---@return table filtered Filtered and sorted deliveries
---@return table stats Aggregated statistics
local function gather_filter_and_stats(data, oldest_tick, search_item)
	local filtered = {}
	local total_wait, total_travel_p, total_loading = 0, 0, 0
	local total_travel_r, total_unloading = 0, 0

	for item_hash, deliveries in pairs(data.completed_deliveries) do
		local include = true
		if search_item then
			local item_name = unhash_signal(item_hash)
			include = (item_name == search_item)
		end

		if include then
			for _, delivery in ipairs(deliveries) do
				if delivery.complete_tick >= oldest_tick then
					filtered[#filtered + 1] = delivery
					total_wait = total_wait + (delivery.wait or 0)
					total_travel_p = total_travel_p + (delivery.travel_to_p or 0)
					total_loading = total_loading + (delivery.loading or 0)
					total_travel_r = total_travel_r + (delivery.travel_to_r or 0)
					total_unloading = total_unloading + (delivery.unloading or 0)
				end
			end
		end
	end

	-- Sort by complete_tick (oldest first for left-to-right display)
	table.sort(filtered, function(a, b)
		return a.complete_tick < b.complete_tick
	end)

	return filtered, {
		total_wait = total_wait,
		total_travel_p = total_travel_p,
		total_loading = total_loading,
		total_travel_r = total_travel_r,
		total_unloading = total_unloading,
	}
end

---@param map_data MapData
---@param player_data PlayerData
function delivery_breakdown_tab.build(map_data, player_data)
	if not analytics.is_enabled() then
		return
	end
	-- Ensure analytics is initialized
	analytics.init(map_data)
	if not map_data.analytics then
		return
	end

	local refs = player_data.refs
	local data = map_data.analytics

	-- Ensure completed_deliveries exists
	if not data.completed_deliveries then
		data.completed_deliveries = {}
	end

	-- Get selected interval
	local interval_index = player_data.breakdown_interval or 1

	-- Update button styles to match current interval
	local interval_buttons = refs.breakdown_interval_buttons
	if interval_buttons then
		for _, button in pairs(interval_buttons.children) do
			if button.tags and button.tags.interval_index then
				button.style = button.tags.interval_index == interval_index and "flib_selected_tool_button" or "tool_button"
			end
		end
	end

	-- Use item filter from manager toolbar (optional - if empty, show all items)
	local search_item = player_data.search_item

	-- Calculate time range based on interval (needed for cache key)
	local interval_defs = analytics.get_interval_defs()
	local interval_def = interval_defs[interval_index]
	local interval_ticks = interval_def.ticks * interval_def.length
	local current_tick = game.tick
	local oldest_tick = current_tick - interval_ticks

	-- Check cache - use cached data if still valid
	local cache_key = string.format("%d:%s", interval_index, search_item or "")
	local cache = player_data.breakdown_cache
	local filtered, stats
	local cache_hit = false

	if cache and cache.key == cache_key and (current_tick - cache.tick) < CACHE_DURATION_TICKS then
		filtered = cache.filtered
		stats = cache.stats
		cache_hit = true
	else
		-- Cache miss - generate fresh data with single-pass function
		filtered, stats = gather_filter_and_stats(data, oldest_tick, search_item)
		player_data.breakdown_cache = {
			tick = current_tick,
			key = cache_key,
			filtered = filtered,
			stats = stats,
		}
	end

	-- Check if there's any data
	local has_data = #filtered > 0 or next(data.completed_deliveries) ~= nil

	-- Update visibility
	if refs.breakdown_no_data_label then
		refs.breakdown_no_data_label.visible = #filtered == 0
	end
	if refs.breakdown_main_flow then
		refs.breakdown_main_flow.visible = has_data
	end

	if #filtered == 0 then
		return
	end

	-- Register chunk for this graph if not already registered
	local player = game.get_player(player_data.player_index)
	if not player then return end

	-- Allocate or reuse chunk for breakdown chart
	if not data.breakdown_interval then
		data.breakdown_interval = {
			name = "breakdown",
			viewer_count = 0,
			guis = {},
			chunk = nil,
			line_ids = {},
		}
	end

	if not player_data.breakdown_registered then
		analytics.interval_register_gui(map_data, data.breakdown_interval, player, refs)
		player_data.breakdown_registered = true
	end

	local chunk = data.breakdown_interval.chunk
	if not chunk then
		return
	end

	-- Update camera position to point at analytics surface
	if refs.breakdown_camera and chunk.coord then
		local cam_x = chunk.coord.x + GRAPH_WIDTH / 2 / 32
		local cam_y = chunk.coord.y + GRAPH_HEIGHT / 2 / 32
		refs.breakdown_camera.position = { cam_x, cam_y }
		refs.breakdown_camera.surface_index = data.surface.index
		refs.breakdown_camera.zoom = 1
	end

	-- Only re-render chart on cache miss (data changed)
	if not cache_hit then
		analytics.render_stacked_bar_chart(map_data, data.breakdown_interval, filtered, PHASE_COLORS, PHASE_ORDER)
	end

	-- Update stats display using cached stats
	if refs.breakdown_stats_label and #filtered > 0 then
		local count = #filtered
		local avg_total = (stats.total_wait + stats.total_travel_p + stats.total_loading +
			stats.total_travel_r + stats.total_unloading) / count

		refs.breakdown_stats_label.caption = string.format(
			"Deliveries: %d\nAvg total: %s\nAvg wait: %s\nAvg load: %s\nAvg unload: %s",
			count,
			format_time(avg_total),
			format_time(stats.total_wait / count),
			format_time(stats.total_loading / count),
			format_time(stats.total_unloading / count)
		)
	end
end

---@param map_data MapData
---@param player_data PlayerData
function delivery_breakdown_tab.cleanup(map_data, player_data)
	if not map_data.analytics then return end
	if not player_data.player_index then return end

	local data = map_data.analytics
	if data.breakdown_interval then
		local player = game.get_player(player_data.player_index)
		if player then
			analytics.interval_unregister_gui(map_data, data.breakdown_interval, player)
		end
	end

	player_data.breakdown_registered = nil
end

delivery_breakdown_tab.handle = {}

--- @param e {player_index: uint}
function delivery_breakdown_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

---@param player LuaPlayer
---@param player_data PlayerData
function delivery_breakdown_tab.handle.on_breakdown_tab_selected(player, player_data)
	player_data.selected_tab = "delivery_breakdown_tab"
end

---@param player LuaPlayer
---@param player_data PlayerData
---@param refs table<string, LuaGuiElement>
---@param e EventData.on_gui_click
function delivery_breakdown_tab.handle.on_breakdown_interval_click(player, player_data, refs, e)
	local element = e.element
	if not element or not element.tags then return end

	local interval_index = element.tags.interval_index
	if not interval_index then return end

	-- Update selected interval
	player_data.breakdown_interval = interval_index

	-- Invalidate cache for immediate refresh with new interval
	player_data.breakdown_cache = nil

	-- Update button styles
	local interval_buttons = refs.breakdown_interval_buttons
	if interval_buttons then
		for _, button in pairs(interval_buttons.children) do
			if button.tags and button.tags.interval_index then
				button.style = button.tags.interval_index == interval_index and "flib_selected_tool_button" or "tool_button"
			end
		end
	end
end

gui.add_handlers(delivery_breakdown_tab.handle, delivery_breakdown_tab.wrapper)

return delivery_breakdown_tab
