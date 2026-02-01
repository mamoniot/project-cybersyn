local gui = require("__flib__.gui")
local analytics = require("scripts.analytics")

-- Try to load the factorio-charts library for interaction support
local charts_available, charts = pcall(require, "__factorio-charts__.charts")
if not charts_available then
	charts = nil
end

local delivery_breakdown_tab = {}

local CACHE_DURATION_TICKS = 300  -- 5 seconds at 60 UPS
local MAX_BARS = 200  -- Limit bars rendered for performance

local interval_names = {"1m", "10m", "1h", "10h", "50h"}

-- Graph dimensions (pixels) - sized to fill the manager window
local GRAPH_WIDTH = 1100
local GRAPH_HEIGHT = 700

-- Phase colors for stacked bars (Factorio-style colors, brightened for visibility)
local PHASE_COLORS = {
	-- Success phases (follow delivery timeline progression: warm→cool)
	wait = {r = 0.70, g = 0.35, b = 0.35},        -- Muted red
	travel_to_p = {r = 0.80, g = 0.60, b = 0.50}, -- Warm orange-brown
	loading = {r = 0.85, g = 0.75, b = 0.45},     -- Visible gold/yellow
	travel_to_r = {r = 0.45, g = 0.72, b = 0.45}, -- Muted green
	unloading = {r = 0.40, g = 0.65, b = 0.75},   -- Soft teal
	-- Failed dispatch phases (distinct but still Factorio-style)
	fail_no_stock = {r = 0.80, g = 0.40, b = 0.55},    -- Muted pink
	fail_no_train = {r = 0.25, g = 0.68, b = 0.95},    -- Sky blue
	fail_capacity = {r = 0.90, g = 0.30, b = 0.10},    -- Deep orange
	fail_layout = {r = 0.60, g = 0.38, b = 0.72},      -- Soft violet
}

-- Phases that should be drawn with diagonal stripe pattern
local HATCHED_PHASES = {
	fail_no_stock = true,
	fail_no_train = true,
	fail_capacity = true,
	fail_layout = true,
}

local PHASE_ORDER = {"wait", "travel_to_p", "loading", "travel_to_r", "unloading",
	"fail_no_stock", "fail_no_train", "fail_capacity", "fail_layout"}
-- Legend order matches visual top-to-bottom appearance in stacked bars
local LEGEND_ORDER = {"unloading", "travel_to_r", "loading", "travel_to_p", "wait",
	"fail_no_stock", "fail_no_train", "fail_capacity", "fail_layout"}
local PHASE_LABELS = {
	wait = "Matching",
	travel_to_p = "Travel to P",
	loading = "Loading",
	travel_to_r = "Travel to R",
	unloading = "Unloading",
	fail_no_stock = "No Stock (F)",
	fail_no_train = "No Train (F)",
	fail_capacity = "Capacity (F)",
	fail_layout = "Layout (F)",
}

local PHASE_TOOLTIPS = {
	wait = "Time from request until a provider and train are matched",
	travel_to_p = "Train traveling to provider station",
	loading = "Loading cargo at provider station",
	travel_to_r = "Train traveling to requester station",
	unloading = "Unloading cargo at requester station",
	fail_no_stock = "Failed: No provider had sufficient stock",
	fail_no_train = "Failed: No train available on network",
	fail_capacity = "Failed: Train capacity insufficient",
	fail_layout = "Failed: Train layout mismatch",
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

	-- Build phase legend items (in visual top-to-bottom order)
	local legend_items = {}
	for i, phase in ipairs(LEGEND_ORDER) do
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
				-- Right: large graph with hover overlay
				{
					name = "breakdown_camera_frame",
					type = "frame",
					style = "deep_frame_in_shallow_frame",
					style_mods = {
						-- Fixed size - lock with both min and max to prevent stretching
						width = GRAPH_WIDTH,
						height = GRAPH_HEIGHT,
						minimal_width = GRAPH_WIDTH,
						minimal_height = GRAPH_HEIGHT,
						maximal_width = GRAPH_WIDTH,
						maximal_height = GRAPH_HEIGHT,
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
							width = GRAPH_WIDTH,
							height = GRAPH_HEIGHT,
							minimal_width = GRAPH_WIDTH,
							minimal_height = GRAPH_HEIGHT,
							maximal_width = GRAPH_WIDTH,
							maximal_height = GRAPH_HEIGHT,
						},
						-- Overlay buttons will be added dynamically as camera children
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

-- Use charts.format_time_detailed() from factorio-charts library

---Single-pass gather, filter by time range, and calculate stats
---@param map_data MapData Map data containing analytics
---@param data table Analytics data
---@param oldest_tick number Minimum complete_tick to include
---@param search_item string? Optional item filter
---@return table filtered Filtered and sorted deliveries
---@return table stats Aggregated statistics
local function gather_filter_and_stats(map_data, data, oldest_tick, search_item)
	local filtered = {}
	local total_wait, total_travel_p, total_loading = 0, 0, 0
	local total_travel_r, total_unloading = 0, 0
	-- Track MAX duration per failure type (not sum) so time progresses at real-time rate
	local max_fail_no_stock, max_fail_no_train = 0, 0
	local max_fail_capacity, max_fail_layout = 0, 0
	-- Track counts per failure type
	local count_fail_no_stock, count_fail_no_train = 0, 0
	local count_fail_capacity, count_fail_layout = 0, 0
	local fail_count = 0
	local delivery_count = 0

	for item_hash, deliveries in pairs(data.completed_deliveries) do
		local include = true
		if search_item then
			local item_name = unhash_signal(item_hash)
			include = (item_name == search_item)
		end

		if include then
			for _, delivery in ipairs(deliveries) do
				if delivery.complete_tick >= oldest_tick then
					-- Add item_hash to delivery for tooltip display
					delivery.item_hash = item_hash
					filtered[#filtered + 1] = delivery
					delivery_count = delivery_count + 1
					total_wait = total_wait + (delivery.wait or 0)
					total_travel_p = total_travel_p + (delivery.travel_to_p or 0)
					total_loading = total_loading + (delivery.loading or 0)
					total_travel_r = total_travel_r + (delivery.travel_to_r or 0)
					total_unloading = total_unloading + (delivery.unloading or 0)
				end
			end
		end
	end

	-- Gather active failures - each stuck request becomes its own bar
	-- When the request is satisfied, this bar disappears and a completed delivery bar appears
	local active_failures = analytics.get_active_failures(map_data, oldest_tick)
	for _, failure in ipairs(active_failures) do
		local include = true
		if search_item then
			local item_name = unhash_signal(failure.item_hash)
			include = (item_name == search_item)
		end

		if include then
			fail_count = fail_count + 1
			local duration = failure.duration or 0

			-- Track stats for display (max duration per type)
			if failure.failure_reason == FAILURE_REASON_NO_PROVIDER_STOCK then
				count_fail_no_stock = count_fail_no_stock + 1
				if duration > max_fail_no_stock then
					max_fail_no_stock = duration
				end
			elseif failure.failure_reason == FAILURE_REASON_NO_TRAIN_AVAILABLE then
				count_fail_no_train = count_fail_no_train + 1
				if duration > max_fail_no_train then
					max_fail_no_train = duration
				end
			elseif failure.failure_reason == FAILURE_REASON_TRAIN_CAPACITY then
				count_fail_capacity = count_fail_capacity + 1
				if duration > max_fail_capacity then
					max_fail_capacity = duration
				end
			else
				count_fail_layout = count_fail_layout + 1
				if duration > max_fail_layout then
					max_fail_layout = duration
				end
			end

			-- Add individual bar for this stuck request
			local bar = { complete_tick = failure.last_tick }
			if failure.failure_reason == FAILURE_REASON_NO_PROVIDER_STOCK then
				bar.fail_no_stock = duration
			elseif failure.failure_reason == FAILURE_REASON_NO_TRAIN_AVAILABLE then
				bar.fail_no_train = duration
			elseif failure.failure_reason == FAILURE_REASON_TRAIN_CAPACITY then
				bar.fail_capacity = duration
			else
				bar.fail_layout = duration
			end
			filtered[#filtered + 1] = bar
		end
	end

	-- Sort by complete_tick/failed_tick (oldest first for left-to-right display)
	table.sort(filtered, function(a, b)
		return a.complete_tick < b.complete_tick
	end)

	-- Limit to most recent bars for performance (keep rightmost/newest)
	if #filtered > MAX_BARS then
		local trimmed = {}
		local start_idx = #filtered - MAX_BARS + 1
		for i = start_idx, #filtered do
			trimmed[#trimmed + 1] = filtered[i]
		end
		filtered = trimmed
	end

	return filtered, {
		delivery_count = delivery_count,
		total_wait = total_wait,
		total_travel_p = total_travel_p,
		total_loading = total_loading,
		total_travel_r = total_travel_r,
		total_unloading = total_unloading,
		max_fail_no_stock = max_fail_no_stock,
		max_fail_no_train = max_fail_no_train,
		max_fail_capacity = max_fail_capacity,
		max_fail_layout = max_fail_layout,
		count_fail_no_stock = count_fail_no_stock,
		count_fail_no_train = count_fail_no_train,
		count_fail_capacity = count_fail_capacity,
		count_fail_layout = count_fail_layout,
		fail_count = fail_count,
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
		filtered, stats = gather_filter_and_stats(map_data, data, oldest_tick, search_item)
		player_data.breakdown_cache = {
			tick = current_tick,
			key = cache_key,
			filtered = filtered,
			stats = stats,
		}
	end

	-- Check if there's any data
	local has_data = #filtered > 0 or next(data.completed_deliveries) ~= nil or
		(data.active_failures and next(data.active_failures) ~= nil)

	-- Update visibility
	if refs.breakdown_no_data_label then
		refs.breakdown_no_data_label.visible = #filtered == 0
	end
	if refs.breakdown_main_flow then
		refs.breakdown_main_flow.visible = has_data
	end

	-- Register chunk for this graph if not already registered
	local player = game.get_player(player_data.player_index)
	if not player then return end

	-- Always ensure camera points at the correct surface (prevents showing wrong surface if chunk allocation fails)
	if refs.breakdown_camera and data.surface then
		refs.breakdown_camera.surface_index = data.surface.index
	end

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
		analytics.interval_register_gui(map_data, data.breakdown_interval, player, refs, {
			viewport_width = GRAPH_WIDTH,
			viewport_height = GRAPH_HEIGHT,
		})
		player_data.breakdown_registered = true
	end

	local chunk = data.breakdown_interval.chunk
	if not chunk then
		return
	end

	-- Set up camera widget (must happen before early return so camera points at correct surface)
	local display_scale = player.display_scale or 1.0
	local display_density = player.display_density_scale or 1.0
	-- Resolution-independent zoom formula: zoom = scale / density
	-- Works across Windows (density 1.0-1.75) and Mac (density 2.0)
	local zoom = display_scale / display_density
	local xoffset = 3.0
	local yoffset = -1.0
	local camera_info = nil
	if refs.breakdown_camera and chunk.coord and charts then
		camera_info = charts.setup_camera_widget(refs.breakdown_camera, data.surface, chunk, {
			widget_width = GRAPH_WIDTH,
			widget_height = GRAPH_HEIGHT,
			display_scale = display_scale,
			position_offset = {x = xoffset, y = yoffset},
			zoom_override = zoom,
		})
	end

	-- Early return if no data to render (camera is already set up above)
	if #filtered == 0 then
		return
	end

	-- Only re-render chart on cache miss (data changed)
	if not cache_hit and camera_info then
		analytics.render_stacked_bar_chart(
			map_data, data.breakdown_interval, filtered,
			PHASE_COLORS, PHASE_ORDER, HATCHED_PHASES,
			GRAPH_WIDTH, GRAPH_HEIGHT
		)
	end

	-- Update stats display using cached stats
	if refs.breakdown_stats_label then
		local delivery_count = stats.delivery_count or 0
		local fail_count = stats.fail_count or 0
		local lines = {}

		if delivery_count > 0 then
			local avg_total = (stats.total_wait + stats.total_travel_p + stats.total_loading +
				stats.total_travel_r + stats.total_unloading) / delivery_count
			lines[#lines + 1] = string.format("Deliveries: %d", delivery_count)
			lines[#lines + 1] = string.format("Avg total: %s", charts.format_time_detailed(avg_total))
			lines[#lines + 1] = string.format("Avg wait: %s", charts.format_time_detailed(stats.total_wait / delivery_count))
			lines[#lines + 1] = string.format("Avg load: %s", charts.format_time_detailed(stats.total_loading / delivery_count))
			lines[#lines + 1] = string.format("Avg unload: %s", charts.format_time_detailed(stats.total_unloading / delivery_count))
		end

		if fail_count > 0 then
			if delivery_count > 0 then
				lines[#lines + 1] = ""  -- Blank line separator
			end
			lines[#lines + 1] = string.format("Stuck: %d", fail_count)
			if stats.count_fail_no_stock > 0 then
				lines[#lines + 1] = string.format("  No stock: %s (%d)", charts.format_time_detailed(stats.max_fail_no_stock), stats.count_fail_no_stock)
			end
			if stats.count_fail_no_train > 0 then
				lines[#lines + 1] = string.format("  No train: %s (%d)", charts.format_time_detailed(stats.max_fail_no_train), stats.count_fail_no_train)
			end
			if stats.count_fail_capacity > 0 then
				lines[#lines + 1] = string.format("  Capacity: %s (%d)", charts.format_time_detailed(stats.max_fail_capacity), stats.count_fail_capacity)
			end
			if stats.count_fail_layout > 0 then
				lines[#lines + 1] = string.format("  Layout: %s (%d)", charts.format_time_detailed(stats.max_fail_layout), stats.count_fail_layout)
			end
		end

		refs.breakdown_stats_label.caption = table.concat(lines, "\n")
	end
end

---@param map_data MapData
---@param player_data PlayerData
function delivery_breakdown_tab.cleanup(map_data, player_data)
	if not map_data.analytics then return end
	if not player_data.player_index then return end

	local data = map_data.analytics

	-- Destroy chart render objects immediately to prevent overlap when switching tabs
	if data.breakdown_interval and data.breakdown_interval.line_ids and charts then
		charts.destroy_render_objects(data.breakdown_interval.line_ids)
		data.breakdown_interval.line_ids = {}
	end

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
