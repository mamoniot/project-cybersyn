--Analytics module for Cybersyn
--Graph rendering technique inspired by factorio-timeseries by Kirk McDonald
--https://mods.factorio.com/mod/timeseries (MIT License)

local analytics = {}

-- Debug logging - set to true to enable verbose logging
local DEBUG = false

local function debug_log(msg)
	if DEBUG then
		local full_msg = "[Cybersyn Analytics] " .. msg
		log(full_msg)
		-- Also print to in-game console
		if game then
			game.print(full_msg)
		end
	end
end

---Format a layout into a human-readable description
---@param layout table? The layout array (0=loco, 1=cargo, 2=fluid)
---@param layout_id number? Optional layout_id for fallback display
---@return string
function analytics.format_layout_name(layout, layout_id)
	if not layout then
		if layout_id then
			return "Layout #" .. layout_id
		end
		return "Unknown"
	end

	local locos = 0
	local cargo = 0
	local fluid = 0
	for i = 1, #layout do
		if layout[i] == 0 then
			locos = locos + 1
		elseif layout[i] == 1 then
			cargo = cargo + 1
		elseif layout[i] == 2 then
			fluid = fluid + 1
		end
	end

	local parts = {}
	if locos > 0 then
		parts[#parts + 1] = locos .. "L"
	end
	if cargo > 0 then
		parts[#parts + 1] = cargo .. "C"
	end
	if fluid > 0 then
		parts[#parts + 1] = fluid .. "F"
	end

	if #parts == 0 then
		return "No wagons"
	end
	return table.concat(parts, "-")
end

-- Interval definitions for time series data
-- ticks = game ticks per datapoint at 60 UPS
-- steps = datapoints consolidated into next interval
-- length = buffer capacity
local interval_defs = {
	{name = "5s",    ticks = 1,      steps = 6,   length = 300},   -- 5 sec
	{name = "1m",    ticks = 6,      steps = 10,  length = 600},   -- 1 min
	{name = "10m",   ticks = 60,     steps = 6,   length = 600},   -- 10 min
	{name = "1h",    ticks = 360,    steps = 10,  length = 600},   -- 1 hour
	{name = "10h",   ticks = 3600,   steps = 5,   length = 600},   -- 10 hours
	{name = "50h",   ticks = 18000,  steps = 5,   length = 600},   -- 50 hours
	{name = "250h",  ticks = 90000,  steps = 4,   length = 600},   -- 250 hours
	{name = "1000h", ticks = 360000, steps = nil, length = 600},   -- 1000 hours (no cascade)
}

local interval_map = {
	["5s"] = 1,
	["1m"] = 2,
	["10m"] = 3,
	["1h"] = 4,
	["10h"] = 5,
	["50h"] = 6,
	["250h"] = 7,
	["1000h"] = 8,
}

-- Maximum brightness colors (all values at or near 1.0)
local colors = {
	{r = 1.0,  g = 1.0,  b = 0.0},   -- Yellow
	{r = 0.0,  g = 1.0,  b = 1.0},   -- Cyan
	{r = 1.0,  g = 1.0,  b = 1.0},   -- White
	{r = 1.0,  g = 0.0,  b = 0.0},   -- Red
	{r = 0.0,  g = 1.0,  b = 0.0},   -- Green
	{r = 1.0,  g = 0.5,  b = 0.0},   -- Orange
	{r = 1.0,  g = 0.0,  b = 1.0},   -- Magenta
	{r = 0.5,  g = 0.5,  b = 1.0},   -- Light blue
	{r = 1.0,  g = 0.5,  b = 0.5},   -- Light red
	{r = 0.5,  g = 1.0,  b = 0.5},   -- Light green
	{r = 1.0,  g = 1.0,  b = 0.5},   -- Light yellow
	{r = 1.0,  g = 0.5,  b = 1.0},   -- Pink
}

-- Grid line color (subtle)
local grid_color = {r = 0.3, g = 0.3, b = 0.3, a = 0.4}

local MAX_LINES = #colors

local VIEWPORT_WIDTH = 900
local VIEWPORT_HEIGHT = 700

local SURFACE_NAME = "cybersyn_analytics"

---Create a new interval set (8 intervals for one graph)
---@return table[] intervals
local function new_interval_set()
	local intervals = {}
	for i, def in ipairs(interval_defs) do
		intervals[i] = {
			name = def.name,
			data = {},
			index = 0,
			sum = {},
			counts = {},
			ticks = def.ticks,
			steps = def.steps,
			length = def.length,
			viewer_count = 0,
			guis = {},
			chunk = nil,
			last_rendered_tick = nil,
			line_ids = {},  -- Track rendered line IDs for cleanup
		}
	end
	return intervals
end

---Initialize analytics data structure
---Configure surface settings
---@param surface LuaSurface
local function configure_surface_brightness(surface)
	surface.daytime = 0.5
	surface.freeze_daytime = true
end

---@param map_data MapData
function analytics.init(map_data)
	-- Create or get the analytics surface
	local surface = game.get_surface(SURFACE_NAME)
	if not surface then
		surface = game.create_surface(SURFACE_NAME, {width = 2, height = 2})
	end
	-- Always apply brightness settings (fixes existing saves)
	configure_surface_brightness(surface)

	if map_data.analytics then
		-- Already initialized, just update surface reference in case it was recreated
		map_data.analytics.surface = surface
		-- Ensure fields exist for backwards compatibility
		if not map_data.analytics.fulfillment_ema then
			map_data.analytics.fulfillment_ema = {}
		end
		if not map_data.analytics.total_time_ema then
			map_data.analytics.total_time_ema = {}
		end
		if not map_data.analytics.delivery_counts then
			map_data.analytics.delivery_counts = {}
		end
		if not map_data.analytics.delivery_phases then
			map_data.analytics.delivery_phases = {}
		end
		if not map_data.analytics.completed_deliveries then
			map_data.analytics.completed_deliveries = {}
		end
		return
	end

	map_data.analytics = {
		surface = surface,
		train_utilization = new_interval_set(),
		fulfillment_times = new_interval_set(),
		total_delivery_times = new_interval_set(),
		delivery_starts = {},          -- {[train_id]: {item_hash, dispatch_tick, fulfillment_time}}
		-- EMA tracking for smooth delivery time graphs
		fulfillment_ema = {},          -- {[item_hash]: number} Current EMA of fulfillment time in seconds
		total_time_ema = {},           -- {[item_hash]: number} Current EMA of total delivery time in seconds
		-- Delivery count tracking
		delivery_counts = {},          -- {[item_hash]: number} Total delivery count per item
		-- Detailed phase tracking for stacked bar chart
		delivery_phases = {},          -- {[train_id]: {item_hash, request_tick, dispatch_tick, arrive_p_tick, leave_p_tick, arrive_r_tick}}
		completed_deliveries = {},     -- {[item_hash]: array of {complete_tick, wait, travel_to_p, loading, travel_to_r, unloading}}
		-- Stacked bar chart interval
		breakdown_interval = nil,      -- Current interval for breakdown chart
		chunk_freelist = {},
		next_chunk_x = 0,
		next_chunk_y = 0,
	}
	debug_log("Analytics initialized, surface index: " .. surface.index)
end

---Check if analytics is enabled
---@return boolean
function analytics.is_enabled()
	local setting = settings.global["cybersyn-enable-analytics"]
	return setting and setting.value
end

---Allocate a chunk for graph rendering
---@param map_data MapData
---@return table chunk {render_entity, coord}
local function get_chunk(map_data)
	local data = map_data.analytics
	local chunk_coord

	local length = #data.chunk_freelist
	if length > 0 then
		chunk_coord = data.chunk_freelist[length]
		data.chunk_freelist[length] = nil
	else
		chunk_coord = {
			x = data.next_chunk_x * 32,
			y = data.next_chunk_y * 32
		}
		-- Diagonal chunk allocation pattern
		if data.next_chunk_x == 0 then
			data.next_chunk_x = data.next_chunk_y + 1
			data.next_chunk_y = 0
		else
			data.next_chunk_x = data.next_chunk_x - 1
			data.next_chunk_y = data.next_chunk_y + 1
		end

		-- Create dark tiles for graph background
		local tiles = {}
		local i = 1
		for x = chunk_coord.x, chunk_coord.x + 31 do
			for y = chunk_coord.y, chunk_coord.y + 31 do
				tiles[i] = {name = "lab-dark-1", position = {x = x, y = y}}
				i = i + 1
			end
		end
		data.surface.set_tiles(tiles)
	end

	-- Create anchor entity for line offsets
	local render_entity = data.surface.create_entity{
		name = "pipe",
		position = chunk_coord,
		force = "neutral",
	}

	-- Add multiple bright lights to illuminate the graph area
	local light_ids = {}
	for lx = 0, 2 do
		for ly = 0, 2 do
			local light_id = rendering.draw_light{
				sprite = "utility/light_medium",
				scale = 50,
				intensity = 10,  -- Very high intensity
				minimum_darkness = 0,
				target = {chunk_coord.x + 5 + lx * 10, chunk_coord.y + 3 + ly * 7},
				surface = data.surface,
			}
			table.insert(light_ids, light_id)
		end
	end

	return {render_entity = render_entity, coord = chunk_coord, light_ids = light_ids}
end

---Free a chunk back to the pool
---@param map_data MapData
---@param chunk table
local function free_chunk(map_data, chunk)
	local data = map_data.analytics
	if chunk.render_entity and chunk.render_entity.valid then
		chunk.render_entity.destroy()
	end
	if chunk.light_ids then
		for _, light_id in ipairs(chunk.light_ids) do
			if light_id.valid then
				light_id.destroy()
			end
		end
	end
	table.insert(data.chunk_freelist, chunk.coord)
end

---Register a GUI as viewing an interval
---@param map_data MapData
---@param interval table
---@param player LuaPlayer
---@param gui table
---@return table chunk
function analytics.interval_register_gui(map_data, interval, player, gui)
	interval.guis[player.index] = gui
	interval.viewer_count = interval.viewer_count + 1

	if interval.chunk then
		return interval.chunk
	end

	local chunk = get_chunk(map_data)
	interval.chunk = chunk
	return chunk
end

---Unregister a GUI from viewing an interval
---@param map_data MapData
---@param interval table
---@param player LuaPlayer
function analytics.interval_unregister_gui(map_data, interval, player)
	interval.guis[player.index] = nil
	interval.viewer_count = interval.viewer_count - 1
	-- Don't free the chunk - keep it so lines can expire naturally via TTL
	-- and so we can reuse the same chunk when this interval is viewed again.
	-- This prevents old lines from appearing when switching intervals
	-- (since each interval has its own dedicated chunk coordinates).
end

---Add a datapoint to an interval set (with cascading aggregation)
---@param intervals table[]
---@param value table {[series_name]: number}
local function add_datapoint(intervals, value)
	for interval_index, interval in ipairs(intervals) do
		local index = interval.index
		local steps = interval.steps

		-- Remove oldest value from sum and counts
		local old_data = interval.data[index + 1]
		if old_data then
			for k, v in pairs(old_data) do
				interval.counts[k] = interval.counts[k] - 1
				if interval.counts[k] == 0 then
					interval.sum[k] = nil
					interval.counts[k] = nil
				else
					interval.sum[k] = interval.sum[k] - v
				end
			end
		end

		-- Insert new value
		interval.data[index + 1] = value

		-- Update sum and counts
		for k, v in pairs(value) do
			interval.sum[k] = (interval.sum[k] or 0) + v
			interval.counts[k] = (interval.counts[k] or 0) + 1
		end

		-- Advance index
		interval.index = (index + 1) % interval.length

		-- Cascade to next interval if needed
		if steps and interval.index % steps == 0 then
			-- Compute consolidated value
			local start_idx = (interval.index - steps) % interval.length
			local consolidated = {}
			for i = 1, steps do
				local datum = interval.data[start_idx + i]
				if datum then
					for k, v in pairs(datum) do
						consolidated[k] = (consolidated[k] or 0) + v
					end
				end
			end
			-- Average the values
			for k, v in pairs(consolidated) do
				consolidated[k] = v / steps
			end
			value = consolidated
		else
			break
		end
	end
end

---Format seconds into human readable time for Y-axis labels
---@param seconds number
---@return string
local function format_time_label(seconds)
	if seconds < 60 then
		return string.format("%.0fs", seconds)
	elseif seconds < 3600 then
		return string.format("%.0fm", seconds / 60)
	else
		return string.format("%.1fh", seconds / 3600)
	end
end

---Render a graph to its chunk
---@param map_data MapData
---@param intervals table[]
---@param interval_index number
---@param selected_series table? Optional filter of series names to show (nil or empty = show all, false = hide)
---@param fixed_range table? Optional {min, max} to fix the y-axis range (e.g., {0, 100} for utilization)
---@param label_format string? Optional format: "percent" (default) or "time"
function analytics.render_graph(map_data, intervals, interval_index, selected_series, fixed_range, label_format)
	local interval = intervals[interval_index]
	if not interval.chunk then
		debug_log("render_graph: no chunk for interval " .. interval_index)
		return
	end

	local data = map_data.analytics
	local surface = data.surface
	local entity = interval.chunk.render_entity
	if not entity or not entity.valid then
		debug_log("render_graph: invalid entity for interval " .. interval_index)
		return
	end

	-- TTL ensures lines eventually expire even if cleanup fails
	-- Minimum 360 ticks (6 seconds) to support 5-second GUI caching
	local ttl = math.max(interval.ticks * 2, 360)

	-- Collect and sort series by sum
	-- Empty table or nil means show all; otherwise only hide if explicitly set to false
	local show_all = not selected_series or not next(selected_series)
	local ordered_sums = {}
	local datasets = 0
	for name, count in pairs(interval.counts) do
		if show_all or selected_series[name] ~= false then
			datasets = datasets + 1
			ordered_sums[datasets] = {name = name, sum = interval.sum[name] or 0}
		end
	end

	if datasets == 0 then
		return
	end

	table.sort(ordered_sums, function(a, b)
		if a.sum ~= b.sum then
			return a.sum > b.sum
		end
		return a.name < b.name
	end)

	local to_draw = math.min(datasets, MAX_LINES)

	-- Compute Y-axis range from actual data
	local min_y = math.huge
	local max_y = -math.huge
	local has_data = false
	for i = 1, interval.length do
		local datum = interval.data[i]
		if datum then
			for j = 1, to_draw do
				local name = ordered_sums[j].name
				local val = datum[name]
				if val then
					has_data = true
					if val < min_y then min_y = val end
					if val > max_y then max_y = val end
				end
			end
		end
	end

	if not has_data then
		return
	end

	-- Use fixed range if provided (e.g., {0, 100} for utilization graphs)
	if fixed_range then
		min_y = fixed_range[1]
		max_y = fixed_range[2]
	else
		-- Auto-scale with some padding
		if min_y == max_y then
			min_y = min_y - 1
			max_y = max_y + 1
		end
	end

	-- Avoid re-render on same tick
	if interval.last_rendered_tick == game.tick then return end
	interval.last_rendered_tick = game.tick

	-- Destroy old lines before drawing new ones
	if interval.line_ids then
		for _, render_obj in ipairs(interval.line_ids) do
			if render_obj.valid then
				render_obj.destroy()
			end
		end
	end
	interval.line_ids = {}

	-- Calculate graph coordinates
	-- Camera shows a region centered at chunk center
	-- Camera viewport: 900x700 pixels = 28.125x21.875 tiles at zoom=1
	-- Lines are drawn with offsets from entity at chunk.coord

	local graph_left = 0.6                          -- Left edge in tiles (after Y labels)
	local graph_right = VIEWPORT_WIDTH / 32 - 1.5   -- Right edge in tiles (more margin)
	local graph_top = 1                             -- Top margin in tiles
	local graph_bottom = VIEWPORT_HEIGHT / 32 - 1   -- Bottom edge in tiles

	local graph_width = graph_right - graph_left
	local graph_height = graph_bottom - graph_top

	local y_range = max_y - min_y
	if y_range == 0 then y_range = 1 end

	-- dx: horizontal tiles per datapoint
	local dx = graph_width / (interval.length - 1)
	-- dy: vertical tiles per data unit
	local dy = graph_height / y_range

	-- Get entity position for absolute coordinate calculation
	local entity_pos = entity.position

	-- Draw horizontal grid lines with Y-axis labels
	local num_grid_lines = 5
	local label_color = {r = 0.8, g = 0.8, b = 0.8}
	for i = 0, num_grid_lines - 1 do
		local grid_value = min_y + (y_range * i / (num_grid_lines - 1))
		local grid_y = graph_bottom - ((grid_value - min_y) * dy)

		-- Draw grid line
		local id = rendering.draw_line{
			surface = surface,
			color = grid_color,
			width = 1,
			from = {entity_pos.x + graph_left, entity_pos.y + grid_y},
			to = {entity_pos.x + graph_right, entity_pos.y + grid_y},
			time_to_live = ttl,
		}
		interval.line_ids[#interval.line_ids + 1] = id

		-- Draw Y-axis label (positioned at left margin)
		local label_text
		if label_format == "time" then
			label_text = format_time_label(grid_value)
		else
			label_text = string.format("%.0f%%", grid_value)
		end
		local text_id = rendering.draw_text{
			text = label_text,
			surface = surface,
			target = {entity_pos.x + 0.5, entity_pos.y + grid_y},
			color = label_color,
			scale = 1.0,
			alignment = "right",
			vertical_alignment = "middle",
			time_to_live = ttl,
		}
		interval.line_ids[#interval.line_ids + 1] = text_id
	end

	-- Draw lines for each series
	local prev = {}
	local x = graph_left

	-- Get first datapoint (oldest) - only set prev if there's actual data
	local first = interval.data[interval.index + 1]
	if first then
		for j = 1, to_draw do
			local name = ordered_sums[j].name
			local n = first[name]
			if n then
				-- Map data value to y coordinate: higher values = smaller y (top)
				local y = graph_bottom - ((n - min_y) * dy)
				prev[name] = {x, y}
			end
		end
	end

	-- Iterate through data in chronological order
	local ranges = {
		{start = interval.index + 2, stop = interval.length},
		{start = 1, stop = interval.index},
	}

	local lines_drawn = 0
	for _, range in ipairs(ranges) do
		for i = range.start, range.stop do
			x = x + dx
			local datum = interval.data[i]
			local next_points = {}

			for j = to_draw, 1, -1 do
				local name = ordered_sums[j].name
				local point = prev[name]
				local n = datum and datum[name]

				if n then
					-- Map data value to y coordinate: higher values = smaller y (top)
					local y = graph_bottom - ((n - min_y) * dy)
					local to = {x, y}
					next_points[name] = to

					if point then
						-- Use absolute positions instead of entity offsets
						local from_pos = {entity_pos.x + point[1], entity_pos.y + point[2]}
						local to_pos = {entity_pos.x + to[1], entity_pos.y + to[2]}

						local id = rendering.draw_line{
							surface = surface,
							color = colors[j],
							width = 1,
							from = from_pos,
							to = to_pos,
							time_to_live = ttl,
						}
						interval.line_ids[#interval.line_ids + 1] = id
						lines_drawn = lines_drawn + 1
					end
				else
					-- No data for this point, clear previous so we don't draw a line to the next point
					next_points[name] = nil
				end
			end
			prev = next_points
		end
	end

	return ordered_sums
end

---Record delivery start for time tracking
---@param map_data MapData
---@param train_id uint
---@param item_hash string
---@param fulfillment_time uint? Fulfillment time in ticks (from request to dispatch)
function analytics.record_delivery_start(map_data, train_id, item_hash, fulfillment_time)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end

	local data = map_data.analytics
	local current_tick = game.tick

	data.delivery_starts[train_id] = {
		item_hash = item_hash,
		dispatch_tick = current_tick,
		fulfillment_time = fulfillment_time,
	}

	-- Also start phase tracking for stacked bar chart
	if not data.delivery_phases then data.delivery_phases = {} end
	data.delivery_phases[train_id] = {
		item_hash = item_hash,
		request_tick = fulfillment_time and (current_tick - fulfillment_time) or current_tick,
		dispatch_tick = current_tick,
		arrive_p_tick = nil,
		leave_p_tick = nil,
		arrive_r_tick = nil,
	}
end

-- EMA smoothing factor (0.1 = slow/smooth, 0.5 = fast/responsive)
local EMA_ALPHA = 0.2

---Record delivery completion for time tracking
---@param map_data MapData
---@param train_id uint
function analytics.record_delivery_complete(map_data, train_id)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end

	local data = map_data.analytics
	local start_info = data.delivery_starts[train_id]
	if not start_info then return end

	-- Ensure tables exist (backwards compatibility)
	if not data.total_time_ema then data.total_time_ema = {} end
	if not data.fulfillment_ema then data.fulfillment_ema = {} end
	if not data.delivery_counts then data.delivery_counts = {} end

	local item_hash = start_info.item_hash
	local total_time = (game.tick - start_info.dispatch_tick) / 60 -- Convert to seconds
	local fulfill_time_sec = start_info.fulfillment_time and (start_info.fulfillment_time / 60) or nil

	-- Increment delivery count
	data.delivery_counts[item_hash] = (data.delivery_counts[item_hash] or 0) + 1

	-- Update total delivery time EMA
	local old_total_ema = data.total_time_ema[item_hash]
	if old_total_ema then
		data.total_time_ema[item_hash] = EMA_ALPHA * total_time + (1 - EMA_ALPHA) * old_total_ema
	else
		data.total_time_ema[item_hash] = total_time
	end

	-- Update fulfillment time EMA if available (captured at dispatch time)
	if fulfill_time_sec then
		local old_fulfill_ema = data.fulfillment_ema[item_hash]
		if old_fulfill_ema then
			data.fulfillment_ema[item_hash] = EMA_ALPHA * fulfill_time_sec + (1 - EMA_ALPHA) * old_fulfill_ema
		else
			data.fulfillment_ema[item_hash] = fulfill_time_sec
		end
	end

	-- Clear the start record
	data.delivery_starts[train_id] = nil

	-- Finalize phase tracking for stacked bar chart
	if not data.delivery_phases then data.delivery_phases = {} end
	if not data.completed_deliveries then data.completed_deliveries = {} end

	local phases = data.delivery_phases[train_id]
	if phases then
		local current_tick = game.tick
		-- Calculate phase durations in seconds
		local completed = {
			complete_tick = current_tick,
			wait = phases.dispatch_tick and phases.request_tick and
				((phases.dispatch_tick - phases.request_tick) / 60) or 0,
			travel_to_p = phases.arrive_p_tick and phases.dispatch_tick and
				((phases.arrive_p_tick - phases.dispatch_tick) / 60) or 0,
			loading = phases.leave_p_tick and phases.arrive_p_tick and
				((phases.leave_p_tick - phases.arrive_p_tick) / 60) or 0,
			travel_to_r = phases.arrive_r_tick and phases.leave_p_tick and
				((phases.arrive_r_tick - phases.leave_p_tick) / 60) or 0,
			unloading = phases.arrive_r_tick and
				((current_tick - phases.arrive_r_tick) / 60) or 0,
		}

		-- Store completed delivery
		if not data.completed_deliveries[item_hash] then
			data.completed_deliveries[item_hash] = {}
		end
		local completed_list = data.completed_deliveries[item_hash]
		table.insert(completed_list, completed)

		-- Keep only most recent deliveries (100 per item)
		while #completed_list > 100 do
			table.remove(completed_list, 1)
		end

		-- Clear phase tracking
		data.delivery_phases[train_id] = nil
	end
end

-- Max completed deliveries to keep per item for breakdown chart
local MAX_COMPLETED_DELIVERIES = 100

---Record train arriving at provider (STATUS_TO_P -> STATUS_P)
---@param map_data MapData
---@param train_id uint
function analytics.record_phase_arrive_provider(map_data, train_id)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end
	local data = map_data.analytics
	if not data.delivery_phases then return end

	local phases = data.delivery_phases[train_id]
	if phases then
		phases.arrive_p_tick = game.tick
	end
end

---Record train leaving provider (STATUS_P -> STATUS_TO_R)
---@param map_data MapData
---@param train_id uint
function analytics.record_phase_leave_provider(map_data, train_id)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end
	local data = map_data.analytics
	if not data.delivery_phases then return end

	local phases = data.delivery_phases[train_id]
	if phases then
		phases.leave_p_tick = game.tick
	end
end

---Record train arriving at requester (STATUS_TO_R -> STATUS_R)
---@param map_data MapData
---@param train_id uint
function analytics.record_phase_arrive_requester(map_data, train_id)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end
	local data = map_data.analytics
	if not data.delivery_phases then return end

	local phases = data.delivery_phases[train_id]
	if phases then
		phases.arrive_r_tick = game.tick
	end
end

-- Working statuses: train is productive
-- STATUS_TO_P (1), STATUS_P (2), STATUS_TO_R (3), STATUS_R (4)
local WORKING_STATUSES = {
	[1] = true,  -- STATUS_TO_P
	[2] = true,  -- STATUS_P
	[3] = true,  -- STATUS_TO_R
	[4] = true,  -- STATUS_R
}

---Called each tick to sample analytics data
---@param map_data MapData
function analytics.tick(map_data)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end

	local data = map_data.analytics

	-- Count trains per layout: working vs total
	local working_counts = {}  -- {[layout_id]: count}
	local total_counts = {}    -- {[layout_id]: count}

	for train_id, train in pairs(map_data.trains) do
		local layout_id = train.layout_id
		if layout_id then
			local key = tostring(layout_id)
			total_counts[key] = (total_counts[key] or 0) + 1
			if WORKING_STATUSES[train.status] then
				working_counts[key] = (working_counts[key] or 0) + 1
			end
		end
	end

	-- Calculate utilization percentage per layout
	local utilization_value = {}
	for layout_id, total in pairs(total_counts) do
		local working = working_counts[layout_id] or 0
		local utilization = (working / total) * 100
		utilization_value[layout_id] = utilization
	end

	if next(utilization_value) then
		add_datapoint(data.train_utilization, utilization_value)
	end

	-- Sample current delivery time EMAs (creates smooth continuous lines)
	-- Fulfillment times (request → delivery)
	if data.fulfillment_ema and next(data.fulfillment_ema) then
		local fulfillment_value = {}
		for item_hash, ema in pairs(data.fulfillment_ema) do
			fulfillment_value[item_hash] = ema
		end
		add_datapoint(data.fulfillment_times, fulfillment_value)
	end

	-- Total delivery times (dispatch → completion)
	if data.total_time_ema and next(data.total_time_ema) then
		local total_value = {}
		for item_hash, ema in pairs(data.total_time_ema) do
			total_value[item_hash] = ema
		end
		add_datapoint(data.total_delivery_times, total_value)
	end
end

---Get interval definitions
---@return table[]
function analytics.get_interval_defs()
	return interval_defs
end

---Get interval by name
---@param name string
---@return number
function analytics.get_interval_index(name)
	return interval_map[name] or 1
end

---Get colors
---@return table[]
function analytics.get_colors()
	return colors
end

---Get viewport dimensions
---@return number, number
function analytics.get_viewport_size()
	return VIEWPORT_WIDTH, VIEWPORT_HEIGHT
end

---Get max lines
---@return number
function analytics.get_max_lines()
	return MAX_LINES
end

---Format seconds into human readable time for Y-axis labels (bar chart)
---@param seconds number
---@return string
local function format_bar_time_label(seconds)
	if seconds < 60 then
		return string.format("%.0fs", seconds)
	elseif seconds < 3600 then
		return string.format("%.0fm", seconds / 60)
	else
		return string.format("%.1fh", seconds / 3600)
	end
end

---Render a stacked bar chart for delivery breakdown
---@param map_data MapData
---@param interval table The interval object with chunk info
---@param deliveries table[] Array of delivery data with phase durations
---@param phase_colors table {[phase_name]: color}
---@param phase_order string[] Order of phases from bottom to top
function analytics.render_stacked_bar_chart(map_data, interval, deliveries, phase_colors, phase_order)
	if not interval.chunk then
		return
	end

	local data = map_data.analytics
	local surface = data.surface
	local entity = interval.chunk.render_entity
	if not entity or not entity.valid then
		return
	end

	-- Destroy old renders
	if interval.line_ids then
		for _, render_obj in ipairs(interval.line_ids) do
			if render_obj.valid then
				render_obj.destroy()
			end
		end
	end
	interval.line_ids = {}

	if #deliveries == 0 then
		return
	end

	local ttl = 360  -- 6 seconds (longer than 5s cache duration)

	-- Graph coordinates
	local graph_left = 1.5
	local graph_right = VIEWPORT_WIDTH / 32 - 1
	local graph_top = 1
	local graph_bottom = VIEWPORT_HEIGHT / 32 - 2.25

	local graph_width = graph_right - graph_left
	local graph_height = graph_bottom - graph_top

	local entity_pos = entity.position

	-- Calculate max total time for Y-axis scaling
	local max_total = 0
	for _, delivery in ipairs(deliveries) do
		local total = 0
		for _, phase in ipairs(phase_order) do
			total = total + (delivery[phase] or 0)
		end
		if total > max_total then
			max_total = total
		end
	end

	if max_total == 0 then
		max_total = 1
	end

	-- Add 10% padding to max
	max_total = max_total * 1.1

	-- Bar dimensions
	local num_bars = #deliveries
	local bar_spacing = 0.1  -- tiles between bars
	local total_spacing = bar_spacing * (num_bars + 1)
	local bar_width = (graph_width - total_spacing) / num_bars
	-- Cap bar width for readability
	if bar_width > 1.5 then
		bar_width = 1.5
	end

	-- Recalculate spacing with capped bar width
	local total_bar_width = bar_width * num_bars
	local remaining_space = graph_width - total_bar_width
	bar_spacing = remaining_space / (num_bars + 1)

	-- Draw Y-axis grid lines and labels
	local num_grid_lines = 5
	local label_color = {r = 0.8, g = 0.8, b = 0.8}
	for i = 0, num_grid_lines - 1 do
		local grid_value = (max_total * i / (num_grid_lines - 1))
		local grid_y = graph_bottom - (grid_value / max_total) * graph_height

		-- Grid line
		local id = rendering.draw_line{
			surface = surface,
			color = grid_color,
			width = 1,
			from = {entity_pos.x + graph_left, entity_pos.y + grid_y},
			to = {entity_pos.x + graph_right, entity_pos.y + grid_y},
			time_to_live = ttl,
		}
		interval.line_ids[#interval.line_ids + 1] = id

		-- Y-axis label
		local text_id = rendering.draw_text{
			text = format_bar_time_label(grid_value),
			surface = surface,
			target = {entity_pos.x + graph_left - 0.2, entity_pos.y + grid_y},
			color = label_color,
			scale = 0.8,
			alignment = "right",
			vertical_alignment = "middle",
			time_to_live = ttl,
		}
		interval.line_ids[#interval.line_ids + 1] = text_id
	end

	-- Draw stacked bars
	for bar_idx, delivery in ipairs(deliveries) do
		local bar_x = graph_left + bar_spacing + (bar_idx - 1) * (bar_width + bar_spacing)
		local bar_bottom = graph_bottom
		local cumulative_height = 0

		-- Draw each phase segment from bottom to top
		for _, phase in ipairs(phase_order) do
			local phase_duration = delivery[phase] or 0
			if phase_duration > 0 then
				local segment_height = (phase_duration / max_total) * graph_height

				local left_top = {
					entity_pos.x + bar_x,
					entity_pos.y + bar_bottom - cumulative_height - segment_height
				}
				local right_bottom = {
					entity_pos.x + bar_x + bar_width,
					entity_pos.y + bar_bottom - cumulative_height
				}

				local id = rendering.draw_rectangle{
					surface = surface,
					color = phase_colors[phase],
					filled = true,
					left_top = left_top,
					right_bottom = right_bottom,
					time_to_live = ttl,
				}
				interval.line_ids[#interval.line_ids + 1] = id

				cumulative_height = cumulative_height + segment_height
			end
		end
	end
end

return analytics
