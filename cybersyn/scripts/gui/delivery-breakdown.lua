local gui = require("__flib__.gui")
local analytics = require("scripts.analytics")
local util = require("scripts.gui.util")
local filters = require("scripts.gui.utils.filters")
local logic = require("scripts.gui.tab-logic")
local utext = require("scripts.gui.unserved-text")

-- Try to load the factorio-charts library for interaction support
local charts_available, charts = pcall(require, "__factorio-charts__.charts")
if not charts_available then
	charts = nil
end

local delivery_breakdown_tab = {}

local CACHE_DURATION_TICKS = 300  -- 5 seconds at 60 UPS
local MAX_BARS = 200  -- Limit bars rendered for performance

local RANGES = analytics.BREAKDOWN_RANGES

-- Graph size in logical px before the first layout is known; build() sizes it to the tab (graph_size).
local GRAPH_WIDTH = 1100
local GRAPH_HEIGHT = 700
-- The legend and stats column left of the graph, and the stats table's value column inside it.
local SIDEBAR_WIDTH = 200
local STAT_VALUE_WIDTH = 64
-- Above the graph: the tab subheader 36, the time range row 32, the gaps between them; below it the frame's padding.
local GRAPH_CHROME = 80
local GRAPH_MIN_WIDTH, GRAPH_MIN_HEIGHT = 400, 300
-- factorio-charts draws its bar chart's y-axis first: five gridlines, each a line then its label, at evenly spaced
-- fractions of the axis top, labelled with rounded minutes ("1m" for 73 s). The tab replaces them with gridlines on
-- whole durations (logic.duration_ticks), in the library's colours, line width, label style and position.
local LIBRARY_GRID_LINES = 5
local AXIS_TTL = 360

--- The graph's size for the player's window: the tab's width beside the legend and its height below the time range.
--- @param player_data PlayerData
--- @return int width
--- @return int height
local function graph_size(player_data)
	local layout = player_data.layout
	if not layout then return GRAPH_WIDTH, GRAPH_HEIGHT end
	return math.max(GRAPH_MIN_WIDTH, layout.content_width - SIDEBAR_WIDTH - 8),
		math.max(GRAPH_MIN_HEIGHT, layout.content_height - GRAPH_CHROME)
end
delivery_breakdown_tab.graph_size = graph_size

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
--- @param phase string
--- @return LocalisedString
local function phase_label(phase)
	return { "cybersyn-gui.breakdown-phase-" .. string.gsub(phase, "_", "-") }
end

--- @param phase string
--- @return LocalisedString
local function phase_tooltip(phase)
	return { "cybersyn-gui.breakdown-phase-" .. string.gsub(phase, "_", "-") .. "-tooltip" }
end

--- The item line of a bar's tooltip: the icon, the localised name and the quality, from the hash.
--- @param hash string
--- @return LocalisedString head
local function item_head(hash)
	local sprite, quality, tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return { "", (unhash_signal(hash)) } end
	if quality then return { "", tooltip, " · ", prototypes.quality[quality].localised_name } end
	return tooltip
end

---Compute statistics (min, max, avg, median, stddev) for each phase
---@param filtered table[] Array of delivery data
---@return table phase_stats Table mapping phase name to stats
local function compute_phase_stats(filtered)
	-- Collect durations per phase
	local phase_durations = {}
	for _, phase in ipairs(PHASE_ORDER) do
		phase_durations[phase] = {}
	end

	for _, delivery in ipairs(filtered) do
		for _, phase in ipairs(PHASE_ORDER) do
			local duration = delivery[phase]
			if duration and duration > 0 then
				phase_durations[phase][#phase_durations[phase] + 1] = duration
			end
		end
	end

	-- Compute stats for each phase
	local phase_stats = {}
	for phase, durations in pairs(phase_durations) do
		local count = #durations
		if count > 0 then
			-- Sort for median
			table.sort(durations)

			-- Min/Max
			local min_val = durations[1]
			local max_val = durations[count]

			-- Average
			local sum = 0
			for _, d in ipairs(durations) do sum = sum + d end
			local avg = sum / count

			-- Median
			local median
			if count % 2 == 0 then
				median = (durations[count/2] + durations[count/2 + 1]) / 2
			else
				median = durations[math.ceil(count/2)]
			end

			-- Standard deviation
			local variance_sum = 0
			for _, d in ipairs(durations) do
				variance_sum = variance_sum + (d - avg)^2
			end
			local stddev = math.sqrt(variance_sum / count)

			phase_stats[phase] = {
				min = min_val,
				max = max_val,
				avg = avg,
				median = median,
				stddev = stddev,
				count = count,
			}
		end
	end

	return phase_stats
end

--- The short name of the reason the dispatcher recorded for a stuck request, the same caption as the Unserved chip
--- and the Log, or "unknown" when none was recorded (a provider-side failure with diagnostics off).
--- @param reason int?
--- @return LocalisedString
local function failure_label(reason)
	if not (reason and REASON_KEYS[reason]) then return { "cybersyn-gui.unserved-unknown-reason" } end
	return utext.chip_caption(reason)
end

--- The reason's full name, for the tooltip under the short caption.
--- @param reason int?
--- @return LocalisedString?
local function failure_name(reason)
	local key = reason and REASON_KEYS[reason]
	return key and { "cybersyn-diag.reason-" .. key } or nil
end

---Generate tooltip text for a bar segment
---@param bar_idx number Bar index
---@param phase string Phase name
---@param duration number Duration in seconds
---@param delivery table Delivery data
---@param phase_stats table? Optional phase statistics
---@return LocalisedString tooltip Formatted tooltip text
local function get_segment_tooltip(bar_idx, phase, duration, delivery, phase_stats)
	local fmt_time = charts and charts.format_time_detailed or function(d) return string.format("%.1fs", d) end
	-- Show item icon and name when available (most useful when no item filter is set)
	local head = delivery.item_hash and item_head(delivery.item_hash) or nil
	-- A stuck request's bar is labelled with the reason the dispatcher recorded for it.
	local label
	if HATCHED_PHASES[phase] then
		local full = failure_name(delivery.reason)
		label = { "", failure_label(delivery.reason), full and { "", " · ", full } or "" }
	else
		label = phase_label(phase)
	end
	-- Nested, so no level holds more than the engine's 20 parameters.
	local body = { "", label, "\n", { "cybersyn-gui.breakdown-duration", fmt_time(duration) } }
	local stats = phase_stats and phase_stats[phase]
	if stats then
		body = { "", body, "\n\n", { "cybersyn-gui.breakdown-phase-stats", fmt_time(stats.min), fmt_time(stats.max),
			fmt_time(stats.avg), fmt_time(stats.median), fmt_time(stats.stddev) } }
	end
	if head then return { "", head, "\n\n", body } end
	return body
end

---Overlay button options for charts library
---@param width int
---@param height int
local function overlay_button_options(width, height)
	return { button_style = "cybersyn_chart_overlay_button", widget_width = width, widget_height = height }
end
local OVERLAY_BUTTON_OPTIONS = overlay_button_options(GRAPH_WIDTH, GRAPH_HEIGHT)

--- Replaces the library's y-axis (its first LIBRARY_GRID_LINES line/label pairs in interval.line_ids) with gridlines
--- on whole durations. Leaves the chart as drawn when the objects are not laid out as factorio-charts draws them.
--- @param interval table
--- @param surface LuaSurface
--- @param chunk table
--- @param meta table? the library's metadata: graph_left/right/bottom/height and max_total
local function replace_axis(interval, surface, chunk, meta)
	local ids = interval.line_ids
	if not (meta and meta.max_total and meta.max_total > 0 and ids and #ids >= 2 * LIBRARY_GRID_LINES and chunk.coord) then
		return
	end
	for i = 1, 2 * LIBRARY_GRID_LINES do
		local o = ids[i]
		if not (o and o.valid and o.type == (i % 2 == 1 and "line" or "text")) then return end
	end
	local line_color, line_width, text_color = ids[1].color, ids[1].width, ids[2].color
	for i = 1, 2 * LIBRARY_GRID_LINES do ids[i].destroy() end
	local kept = {}
	for i = 2 * LIBRARY_GRID_LINES + 1, #ids do kept[#kept + 1] = ids[i] end
	local pos = chunk.coord
	local ticks = logic.duration_ticks(meta.max_total)
	for _, t in ipairs(ticks) do
		local y = pos.y + meta.graph_bottom - (t.value / meta.max_total) * meta.graph_height
		kept[#kept + 1] = rendering.draw_line({ surface = surface, color = line_color, width = line_width,
			from = { pos.x + meta.graph_left, y }, to = { pos.x + meta.graph_right, y }, time_to_live = AXIS_TTL })
		kept[#kept + 1] = charts.style.draw_label({ text = t.label, surface = surface,
			target = { pos.x + meta.graph_left - 0.2, y }, color = text_color,
			alignment = "right", vertical_alignment = "middle", time_to_live = AXIS_TTL })
	end
	interval.line_ids = kept
end

function delivery_breakdown_tab.create()
	local interval_buttons = {}
	for i, range in ipairs(RANGES) do
		interval_buttons[i] = {
			type = "button",
			caption = { "cybersyn-gui.breakdown-range-" .. range.key },
			tooltip = { "cybersyn-gui.breakdown-range-tooltip-" .. range.key },
			style = i == 1 and "flib_selected_tool_button" or "tool_button",
			tags = { interval_name = range.key, interval_index = i },
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
					width = 24,
					height = 18,
					bar_width = 18,
					color = PHASE_COLORS[phase],
				},
			},
			{
				type = "label",
				caption = phase_label(phase),
				tooltip = phase_tooltip(phase),
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
					style_mods = { width = SIDEBAR_WIDTH, vertically_stretchable = true },
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
					-- Label / value rows, the values on one right edge (stats_rows).
					{
						name = "breakdown_stats_table",
						type = "table",
						column_count = 2,
						style_mods = { horizontal_spacing = 0, vertical_spacing = 2, top_margin = 4 },
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
				visible = false,
			},
		},
	}
end

-- Use charts.format_time_detailed() from factorio-charts library

---Single-pass gather, filter by time range, and calculate stats
---@param map_data MapData Map data containing analytics
---@param data table Analytics data
---@param oldest_tick number Minimum complete_tick to include
---@param search_item string? the item filter's hash
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
	local fail_by_reason, fail_reasons = {}, {}

	for item_hash, deliveries in pairs(data.completed_deliveries) do
		if not search_item or item_hash == search_item then
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

	-- Gather active failures only when an item filter is set
	-- Without a filter, showing failures for all items would be noisy and confusing
	if search_item then
		local active_failures = analytics.get_active_failures(map_data, oldest_tick)
		for _, failure in ipairs(active_failures) do
			if failure.item_hash == search_item then
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
				local reason = failure.reason or -1
				local by = fail_by_reason[reason]
				if not by then
					by = { reason = failure.reason, count = 0, max = 0 }
					fail_by_reason[reason] = by
					fail_reasons[#fail_reasons + 1] = by
				end
				by.count = by.count + 1
				if duration > by.max then by.max = duration end

				local bar = { complete_tick = failure.last_tick, reason = failure.reason }
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
		fail_reasons = fail_reasons,
	}
end

--- The Stats rows beside the graph: {label, value} pairs (a stuck reason's label is indented under "Stuck").
--- @param stats table gather_filter_and_stats
--- @return {[1]: LocalisedString, [2]: string, indent: boolean?}[]
local function stats_rows(stats)
	local rows = {}
	local delivery_count = stats.delivery_count or 0
	local fail_count = stats.fail_count or 0
	local t = charts and charts.format_time_detailed or function(d) return string.format("%.1fs", d) end
	if delivery_count > 0 then
		local avg_total = (stats.total_wait + stats.total_travel_p + stats.total_loading +
			stats.total_travel_r + stats.total_unloading) / delivery_count
		rows[#rows + 1] = { { "cybersyn-gui.breakdown-stat-deliveries" }, tostring(delivery_count) }
		rows[#rows + 1] = { { "cybersyn-gui.breakdown-stat-total" }, t(avg_total) }
		rows[#rows + 1] = { { "cybersyn-gui.breakdown-stat-matching" }, t(stats.total_wait / delivery_count) }
		rows[#rows + 1] = { { "cybersyn-gui.breakdown-stat-travel-to-p" }, t(stats.total_travel_p / delivery_count) }
		rows[#rows + 1] = { { "cybersyn-gui.breakdown-stat-loading" }, t(stats.total_loading / delivery_count) }
		rows[#rows + 1] = { { "cybersyn-gui.breakdown-stat-travel-to-r" }, t(stats.total_travel_r / delivery_count) }
		rows[#rows + 1] = { { "cybersyn-gui.breakdown-stat-unloading" }, t(stats.total_unloading / delivery_count) }
	end
	if fail_count > 0 then
		rows[#rows + 1] = { { "cybersyn-gui.breakdown-stuck" }, tostring(fail_count) }
		-- One row per reason code the dispatcher recorded, longest-waiting first.
		local reasons = stats.fail_reasons or {}
		table.sort(reasons, function(a, b)
			if a.max ~= b.max then return a.max > b.max end
			return (a.reason or -1) < (b.reason or -1)
		end)
		for _, by in ipairs(reasons) do
			rows[#rows + 1] = { failure_label(by.reason), string.format("%s (%d)", t(by.max), by.count), indent = true }
		end
	end
	return rows
end
delivery_breakdown_tab.stats_rows = stats_rows

--- Writes the Stats rows into their table when the stats they come from changed (a new cache entry).
--- @param tbl LuaGuiElement?
--- @param stats table? gather_filter_and_stats, nil for none
--- @param player_data PlayerData
local function write_stats(tbl, stats, player_data)
	if not (tbl and tbl.valid) then return end
	if stats and player_data.cache.breakdown_stats_of == stats and #tbl.children > 0 then return end
	if not stats and player_data.cache.breakdown_stats_of == false then return end
	player_data.cache.breakdown_stats_of = stats or false
	local rows = stats and stats_rows(stats) or {}
	tbl.clear()
	for _, r in ipairs(rows) do
		-- A long reason caption is cut at the sidebar's width; its tooltip keeps it whole.
		local label = tbl.add({ type = "label", caption = r[1], tooltip = r[1],
			style = r.indent and "cybersyn_subheader_note" or nil })
		label.style.font = "default-small"
		label.style.width = SIDEBAR_WIDTH - STAT_VALUE_WIDTH
		if r.indent then label.style.left_padding = 8 end
		local value = tbl.add({ type = "label", caption = r[2], style = "cybersyn_cell_value" })
		value.style.font = "default-small"
		value.style.width = STAT_VALUE_WIDTH
	end
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
	local interval_index = player_data.tabs.delivery_breakdown_tab.interval or 1
	if not RANGES[interval_index] then interval_index = 1 end

	-- Update button styles to match current interval
	local interval_buttons = refs.breakdown_interval_buttons
	if interval_buttons then
		for _, button in pairs(interval_buttons.children) do
			if button.tags and button.tags.interval_index then
				button.style = button.tags.interval_index == interval_index and "flib_selected_tool_button" or "tool_button"
			end
		end
	end

	-- Use item filter from manager toolbar (optional - shows all items when not set)
	local search_item = filters.get(player_data, "delivery_breakdown_tab").item

	-- Calculate time range based on interval (needed for cache key)
	local interval_ticks = RANGES[interval_index].ticks
	local current_tick = game.tick
	local oldest_tick = current_tick - interval_ticks

	-- The graph fills the tab: its size follows the window's layout.
	local gw, gh = graph_size(player_data)
	local overlay_button_opts = overlay_button_options(gw, gh)

	-- Check cache - use cached data if still valid
	local cache_key = string.format("%d:%s:%dx%d", interval_index, search_item or "", gw, gh)
	local cache = player_data.cache.breakdown
	local filtered, stats
	local cache_hit = false

	if cache and cache.key == cache_key and (current_tick - cache.tick) < CACHE_DURATION_TICKS then
		filtered = cache.filtered
		stats = cache.stats
		cache_hit = true
	else
		-- Cache miss - generate fresh data with single-pass function
		filtered, stats = gather_filter_and_stats(map_data, data, oldest_tick, search_item)
		player_data.cache.breakdown = {
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

	-- The constant y term, tuned by eye (-1.0 at 1100x700), moves the camera a tile up as the axis labels sit low.
	local _, camera_info = analytics.sync_chart_view(map_data, data.breakdown_interval, player, refs,
		refs.breakdown_camera_frame, refs.breakdown_camera, gw, gh, -1.0)
	local chunk = data.breakdown_interval.chunk
	if not chunk then return end

	-- Early return if no data to render (camera is already set up above)
	if #filtered == 0 then
		-- Clear overlay buttons when no data
		charts.create_overlay_buttons(refs.breakdown_camera, {}, overlay_button_opts)
		-- The stats of another range must not stay beside an empty one.
		write_stats(refs.breakdown_stats_table, nil, player_data)
		return
	end

	-- Only re-render chart on cache miss (data changed)
	if not cache_hit and camera_info then
		-- Compute phase statistics for tooltips
		local phase_stats = compute_phase_stats(filtered)

		-- Build bar_icons array when no item filter is set so users can identify items
		local bar_icons = nil
		if not search_item then
			bar_icons = {}
			for i, delivery in ipairs(filtered) do
				if delivery.item_hash then
					bar_icons[i] = util.item_sprite_and_tooltip(delivery.item_hash)
				end
			end
		end

		-- Build overlay options for tooltip generation
		-- Use zoom=1 for button position calculation - GUI margins don't scale with camera zoom
		local overlay_options = {
			camera_position = camera_info.position,
			camera_zoom = 1.0,  -- Always calculate positions for zoom=1
			widget_size = {width = gw, height = gh},
			get_tooltip = function(bar_idx, phase, duration, delivery)
				return get_segment_tooltip(bar_idx, phase, duration, delivery, phase_stats)
			end,
			bar_icons = bar_icons,
		}

		local button_configs, meta = analytics.render_stacked_bar_chart(
			map_data, data.breakdown_interval, filtered,
			PHASE_COLORS, PHASE_ORDER, HATCHED_PHASES,
			gw, gh, overlay_options
		)
		replace_axis(data.breakdown_interval, data.surface, chunk, meta)

		-- Create overlay buttons for tooltips
		charts.create_overlay_buttons(refs.breakdown_camera, button_configs or {}, overlay_button_opts)
	end

	write_stats(refs.breakdown_stats_table, stats, player_data)
end

---@param map_data MapData
---@param player_data PlayerData
function delivery_breakdown_tab.cleanup(map_data, player_data)
	if not map_data.analytics then return end
	if not player_data.player_index then return end

	local data = map_data.analytics
	local refs = player_data.refs

	-- Clear overlay buttons
	if refs and refs.breakdown_camera then
		charts.create_overlay_buttons(refs.breakdown_camera, {}, OVERLAY_BUTTON_OPTIONS)
	end

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

	player_data.cache.breakdown_stats_of = nil
end

delivery_breakdown_tab.handle = {}

delivery_breakdown_tab.wrapper = util.wrapper

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
	player_data.tabs.delivery_breakdown_tab.interval = interval_index

	-- Invalidate cache for immediate refresh with new interval
	player_data.cache.breakdown = nil

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
