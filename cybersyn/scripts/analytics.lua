--Analytics module for Cybersyn
--Graph rendering technique inspired by factorio-timeseries by Kirk McDonald
--https://mods.factorio.com/mod/timeseries (MIT License)

local analytics = {}

-- Try to load the factorio-charts library (optional dependency)
local charts_available, charts = pcall(require, "__factorio-charts__.charts")
if not charts_available then
	charts = nil
end

-- Debug logging - set to true to enable verbose logging
local DEBUG = false

local function debug_log(msg)
	if DEBUG then
		local full_msg = "[Cybersyn Analytics] " .. msg
		log(full_msg)
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
local interval_defs = {
	{name = "5s",    ticks = 1,      steps = 6,   length = 300},
	{name = "1m",    ticks = 6,      steps = 10,  length = 600},
	{name = "10m",   ticks = 60,     steps = 6,   length = 600},
	{name = "1h",    ticks = 360,    steps = 10,  length = 600},
	{name = "10h",   ticks = 3600,   steps = 5,   length = 600},
	{name = "50h",   ticks = 18000,  steps = 5,   length = 600},
	{name = "250h",  ticks = 90000,  steps = 4,   length = 600},
	{name = "1000h", ticks = 360000, steps = nil, length = 600},
}

local interval_map = {
	["5s"] = 1, ["1m"] = 2, ["10m"] = 3, ["1h"] = 4,
	["10h"] = 5, ["50h"] = 6, ["250h"] = 7, ["1000h"] = 8,
}

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
			line_ids = {},
		}
	end
	return intervals
end

---Initialize analytics data structure
---@param map_data MapData
function analytics.init(map_data)
	-- Create the chart surface using the library
	local surface_data = charts.create_surface(SURFACE_NAME)

	if map_data.analytics then
		-- Already initialized, update surface reference
		map_data.analytics.surface = surface_data.surface
		map_data.analytics.surface_data = surface_data
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
		surface = surface_data.surface,
		surface_data = surface_data,
		train_utilization = new_interval_set(),
		fulfillment_times = new_interval_set(),
		total_delivery_times = new_interval_set(),
		delivery_starts = {},
		fulfillment_ema = {},
		total_time_ema = {},
		delivery_counts = {},
		delivery_phases = {},
		completed_deliveries = {},
		breakdown_interval = nil,
	}
	debug_log("Analytics initialized, surface index: " .. surface_data.surface.index)
end

---Check if analytics is enabled (requires both setting AND factorio-charts library)
---@return boolean
function analytics.is_enabled()
	if not charts then
		return false
	end
	local setting = settings.global["cybersyn-enable-analytics"]
	return setting and setting.value
end

---Check if the charts library is available
---@return boolean
function analytics.is_library_available()
	return charts ~= nil
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

	local chunk = charts.allocate_chunk(map_data.analytics.surface_data)
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
			for k, v in pairs(consolidated) do
				consolidated[k] = v / steps
			end
			value = consolidated
		else
			break
		end
	end
end

---Render a graph to its chunk using the library
---@param map_data MapData
---@param intervals table[]
---@param interval_index number
---@param selected_series table?
---@param fixed_range table?
---@param label_format string?
function analytics.render_graph(map_data, intervals, interval_index, selected_series, fixed_range, label_format)
	local interval = intervals[interval_index]
	if not interval.chunk then
		debug_log("render_graph: no chunk for interval " .. interval_index)
		return
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

	local data = map_data.analytics
	local ttl = math.max(interval.ticks * 2, 360)

	-- Use the library to render
	local ordered_sums, line_ids = charts.render_line_graph(data.surface, interval.chunk, {
		data = interval.data,
		index = interval.index,
		length = interval.length,
		counts = interval.counts,
		sum = interval.sum,
		y_range = fixed_range,
		label_format = label_format or "percent",
		selected_series = selected_series,
		ttl = ttl,
	})

	if line_ids then
		interval.line_ids = line_ids
	end

	return ordered_sums
end

---Record delivery start for time tracking
---@param map_data MapData
---@param train_id uint
---@param item_hash string
---@param fulfillment_time uint?
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

	if not data.total_time_ema then data.total_time_ema = {} end
	if not data.fulfillment_ema then data.fulfillment_ema = {} end
	if not data.delivery_counts then data.delivery_counts = {} end

	local item_hash = start_info.item_hash
	local total_time = (game.tick - start_info.dispatch_tick) / 60
	local fulfill_time_sec = start_info.fulfillment_time and (start_info.fulfillment_time / 60) or nil

	data.delivery_counts[item_hash] = (data.delivery_counts[item_hash] or 0) + 1

	local old_total_ema = data.total_time_ema[item_hash]
	if old_total_ema then
		data.total_time_ema[item_hash] = EMA_ALPHA * total_time + (1 - EMA_ALPHA) * old_total_ema
	else
		data.total_time_ema[item_hash] = total_time
	end

	if fulfill_time_sec then
		local old_fulfill_ema = data.fulfillment_ema[item_hash]
		if old_fulfill_ema then
			data.fulfillment_ema[item_hash] = EMA_ALPHA * fulfill_time_sec + (1 - EMA_ALPHA) * old_fulfill_ema
		else
			data.fulfillment_ema[item_hash] = fulfill_time_sec
		end
	end

	data.delivery_starts[train_id] = nil

	if not data.delivery_phases then data.delivery_phases = {} end
	if not data.completed_deliveries then data.completed_deliveries = {} end

	local phases = data.delivery_phases[train_id]
	if phases then
		local current_tick = game.tick
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

		if not data.completed_deliveries[item_hash] then
			data.completed_deliveries[item_hash] = {}
		end
		local completed_list = data.completed_deliveries[item_hash]
		table.insert(completed_list, completed)

		while #completed_list > 100 do
			table.remove(completed_list, 1)
		end

		data.delivery_phases[train_id] = nil
	end
end

---Record train arriving at provider
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

---Record train leaving provider
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

---Record train arriving at requester
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

local WORKING_STATUSES = {
	[1] = true, [2] = true, [3] = true, [4] = true,
}

---Called each tick to sample analytics data
---@param map_data MapData
function analytics.tick(map_data)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end

	local data = map_data.analytics

	local working_counts = {}
	local total_counts = {}

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

	local utilization_value = {}
	for layout_id, total in pairs(total_counts) do
		local working = working_counts[layout_id] or 0
		local utilization = (working / total) * 100
		utilization_value[layout_id] = utilization
	end

	if next(utilization_value) then
		add_datapoint(data.train_utilization, utilization_value)
	end

	if data.fulfillment_ema and next(data.fulfillment_ema) then
		local fulfillment_value = {}
		for item_hash, ema in pairs(data.fulfillment_ema) do
			fulfillment_value[item_hash] = ema
		end
		add_datapoint(data.fulfillment_times, fulfillment_value)
	end

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

---Get colors from library
---@return table[]
function analytics.get_colors()
	return charts.get_series_colors()
end

---Get viewport dimensions from library
---@return number, number
function analytics.get_viewport_size()
	return 900, 700  -- Default values
end

---Get max lines from library
---@return number
function analytics.get_max_lines()
	return charts.get_max_series()
end

---Render a stacked bar chart for delivery breakdown using the library
---@param map_data MapData
---@param interval table
---@param deliveries table[]
---@param phase_colors table
---@param phase_order string[]
function analytics.render_stacked_bar_chart(map_data, interval, deliveries, phase_colors, phase_order)
	if not interval.chunk then
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

	local data = map_data.analytics
	local line_ids = charts.render_stacked_bars(data.surface, interval.chunk, {
		deliveries = deliveries,
		phase_colors = phase_colors,
		phase_order = phase_order,
		ttl = 360,
	})

	if line_ids then
		interval.line_ids = line_ids
	end
end

return analytics
