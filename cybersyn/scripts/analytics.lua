--Analytics module for Cybersyn

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

---The Utilization legend's name for a layout: locomotives, cargo and fluid wagons counted ("2L-4C-1F"); "#id"
---when the layout record is gone.
---@param layout int[]? the layout array (0 = locomotive, 1 = cargo wagon, 2 = fluid wagon)
---@param layout_id uint?
---@return string
function analytics.format_layout_name(layout, layout_id)
	if not layout or #layout == 0 then
		return "#" .. tostring(layout_id or "?")
	end
	local locos, cargo, fluid = 0, 0, 0
	for i = 1, #layout do
		local c = layout[i]
		if c == WAGON_LOCO then
			locos = locos + 1
		elseif c == WAGON_CARGO then
			cargo = cargo + 1
		elseif c == WAGON_FLUID then
			fluid = fluid + 1
		end
	end
	local parts = {}
	if locos > 0 then parts[#parts + 1] = locos .. "L" end
	if cargo > 0 then parts[#parts + 1] = cargo .. "C" end
	if fluid > 0 then parts[#parts + 1] = fluid .. "F" end
	return table.concat(parts, "-")
end

-- The Utilization chart's resolutions, one per range button: each interval keeps `length` samples taken `ticks` game
-- ticks apart, so it spans exactly the time its name says (ticks x length), and every `steps` of them are averaged
-- into one sample of the next. analytics.tick runs on its own nth tick (SAMPLE_TICKS = the first interval's `ticks`),
-- not the planner's, so the spans do not depend on the dispatcher rate.
local interval_defs = {
	{name = "1m",    ticks = 6,      steps = 10,  length = 600},
	{name = "10m",   ticks = 60,     steps = 6,   length = 600},
	{name = "1h",    ticks = 360,    steps = 10,  length = 600},
	{name = "10h",   ticks = 3600,   steps = 5,   length = 600},
	{name = "50h",   ticks = 18000,  steps = 5,   length = 600},
	{name = "250h",  ticks = 90000,  steps = 4,   length = 600},
	{name = "1000h", ticks = 360000, steps = nil, length = 600},
}
analytics.UTILIZATION_INTERVALS = interval_defs
analytics.SAMPLE_TICKS = interval_defs[1].ticks

--- The Breakdown tab's range buttons: each covers exactly the span its caption names (key = number + m or h).
analytics.BREAKDOWN_RANGES = {
	{ key = "1m", ticks = 3600 },
	{ key = "10m", ticks = 36000 },
	{ key = "1h", ticks = 216000 },
	{ key = "10h", ticks = 2160000 },
	{ key = "50h", ticks = 10800000 },
}

local SURFACE_NAME = "cybersyn_analytics"

---@return table[] intervals the Utilization chart's interval set, empty
local function new_interval_set()
	return charts.create_time_series(interval_defs)
end

---Drops every chart and chunk the save holds and restarts chunk allocation. Versions with another utilization shape
---created a new surface_data on every tab build, so the stored cursor can point at chunks still in use.
---@param map_data MapData
local function reset_charts(map_data)
	local data = map_data.analytics
	for _, set in pairs({ data.train_utilization, data.fulfillment_times, data.total_delivery_times,
		{ data.breakdown_interval } }) do
		for _, interval in pairs(set) do
			if interval.line_ids then charts.destroy_render_objects(interval.line_ids) end
			analytics.destroy_chart(interval)
		end
	end
	data.surface_data = charts.create_surface(SURFACE_NAME)
	data.breakdown_interval = nil
end

---Brings a save's analytics to the current shape, then creates what is missing (analytics.init).
---@param map_data MapData
function analytics.migrate(map_data)
	local data = map_data.analytics
	if data then
		local series = data.train_utilization
		if not (series and #series == #interval_defs and series[1].name == interval_defs[1].name) then
			reset_charts(map_data)
			data.train_utilization = new_interval_set()
		end
		-- Series and per-item averages no tab reads.
		data.failed_dispatches, data.last_failure_tick = nil, nil
		data.fulfillment_times, data.total_delivery_times = nil, nil
		data.fulfillment_ema, data.total_time_ema, data.delivery_counts, data.delivery_starts = nil, nil, nil, nil
	end
	analytics.init(map_data)
end

---Creates whatever analytics state is missing.
---@param map_data MapData
function analytics.init(map_data)
	local data = map_data.analytics
	if data then
		-- The stored surface_data carries the chunk allocation cursor: a fresh one would place every new chunk at {0,0},
		-- on top of the charts already there.
		local surface_data = data.surface_data
		if not (surface_data and surface_data.surface and surface_data.surface.valid) then
			surface_data = charts.create_surface(SURFACE_NAME)
			data.surface_data = surface_data
		end
		data.surface = surface_data.surface
		data.train_utilization = data.train_utilization or new_interval_set()
		data.delivery_phases = data.delivery_phases or {}
		data.completed_deliveries = data.completed_deliveries or {}
		data.active_failures = data.active_failures or {}
		return
	end

	local surface_data = charts.create_surface(SURFACE_NAME)
	map_data.analytics = {
		surface = surface_data.surface,
		surface_data = surface_data,
		train_utilization = new_interval_set(),
		delivery_phases = {},
		completed_deliveries = {},
		active_failures = {},
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
	return setting and setting.value --[[@as boolean]]
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
---@param options table? Optional {viewport_width, viewport_height}
---@return table chunk
function analytics.interval_register_gui(map_data, interval, player, gui, options)
	interval.guis[player.index] = gui
	interval.viewer_count = interval.viewer_count + 1

	if interval.chunk then
		-- Ensure existing chunk has sufficient tile coverage for the viewport
		if options and (options.viewport_width or options.viewport_height) then
			charts.ensure_tile_coverage(map_data.analytics.surface_data, interval.chunk, options)
		end
		return interval.chunk
	end

	local chunk = charts.allocate_chunk(map_data.analytics.surface_data, options)
	interval.chunk = chunk
	return chunk
end

---Brings a tab's graph frame and camera to gw x gh, registers the player as a viewer of `interval` and aims the camera
---at its chunk.
---@param map_data MapData
---@param interval table
---@param player LuaPlayer
---@param refs table the tab's refs, kept as the player's viewer entry
---@param frame LuaGuiElement?
---@param camera LuaGuiElement?
---@param gw int
---@param gh int
---@param y_bias number the tab's vertical offset, in tiles, tuned by eye
---@return boolean? resized
---@return table? camera_info nil while the interval has no chunk
function analytics.sync_chart_view(map_data, interval, player, refs, frame, camera, gw, gh, y_bias)
	local data = map_data.analytics
	local resized = frame and frame.valid and (frame.style.minimal_width ~= gw or frame.style.minimal_height ~= gh)
	if resized then
		for _, e in ipairs({ frame, camera }) do
			if e and e.valid then
				e.style.width, e.style.height = gw, gh
				e.style.minimal_width, e.style.minimal_height = gw, gh
				e.style.maximal_width, e.style.maximal_height = gw, gh
			end
		end
		if interval.chunk and data.surface_data then
			charts.ensure_tile_coverage(data.surface_data, interval.chunk, { viewport_width = gw, viewport_height = gh })
		end
	end
	-- Keeps the camera off the player's own surface even when no chunk could be allocated.
	if camera and data.surface then camera.surface_index = data.surface.index end
	-- The interval's own viewer table decides, not a per-player flag: a flag outlives a window rebuilt by reset_player
	-- and an interval replaced by analytics.migrate.
	if interval.guis[player.index] then
		interval.guis[player.index] = refs
	else
		analytics.interval_register_gui(map_data, interval, player, refs, { viewport_width = gw, viewport_height = gh })
	end
	local chunk = interval.chunk
	if not (chunk and camera and charts) then return resized, nil end
	-- zoom = scale / density puts one tile on 32 logical px on any display (Windows density 1.0-1.75, Mac 2.0). The
	-- library centres the camera on a 900x700 viewport (it is not told the size); the offsets move it onto the graph's
	-- centre.
	local display_scale = player.display_scale or 1.0
	return resized, charts.setup_camera_widget(camera, data.surface, chunk, {
		widget_width = gw,
		widget_height = gh,
		display_scale = display_scale,
		position_offset = { x = (gw - 900) / 64 - 0.125, y = (gh - 700) / 64 + y_bias },
		zoom_override = display_scale / (player.display_density_scale or 1.0),
	})
end

---Unregister a GUI from viewing an interval
---@param map_data MapData
---@param interval table
---@param player LuaPlayer
function analytics.interval_unregister_gui(map_data, interval, player)
	interval.guis[player.index] = nil
	interval.viewer_count = interval.viewer_count - 1
end

---Draws one Utilization interval as a factorio-charts interactive line graph kept on the interval (interval.chart),
---so the crosshair can find the drawing. `id` must be the same on every peer and across save/load: the hover buttons
---carry it and the library's registry is rebuilt from storage in on_load.
---@param map_data MapData
---@param interval table one interval of map_data.analytics.train_utilization
---@param id string
---@param options table line graph options (selected_series, y_range, label_format, x_axis, camera_zoom, viewport_*)
---@param callbacks table? {format_tooltip, on_cell_hover, on_cell_leave} registered with the state
---@return table? state
function analytics.render_chart(map_data, interval, id, options, callbacks)
	local chunk = interval.chunk
	if not chunk then return nil end
	local opts = { id = id, data = interval.data, index = interval.index, length = interval.length,
		counts = interval.counts, sum = interval.sum, ttl = math.max(interval.ticks * 2, 360) }
	for k, v in pairs(options) do opts[k] = v end
	if type(opts.x_axis) == "table" and not opts.x_axis.ticks_per_point then
		local x_axis = { ticks_per_point = interval.ticks }
		for k, v in pairs(opts.x_axis) do x_axis[k] = v end
		opts.x_axis = x_axis
	end
	local state = interval.chart
	if state and (state.chunk ~= chunk or state.id ~= id) then
		charts.interactive.destroy(state)
		state = nil
	end
	if state then
		charts.interactive.update_line_graph(state, opts)
	else
		state = charts.interactive.create_line_graph(map_data.analytics.surface, chunk, opts)
		interval.chart = state
	end
	charts.interactive.register(state, callbacks)
	return state
end

---Removes an interval's interactive chart (lines, every crosshair and its registry entry).
---@param interval table
function analytics.destroy_chart(interval)
	local state = interval.chart
	if state and charts then charts.interactive.destroy(state) end
	interval.chart = nil
end

---Gives every chart chunk the save holds the factorio-charts 1.3.0 background (black, no lights): chunks allocated
---by an older library keep their lit lab tiles otherwise. Idempotent.
---@param map_data MapData
function analytics.restyle_chunks(map_data)
	local data = map_data.analytics
	local restyle = charts and charts.surface and charts.surface.restyle_chunk
	if not (restyle and data and data.surface_data and data.surface_data.surface and data.surface_data.surface.valid) then
		return
	end
	for _, interval in ipairs(data.train_utilization or {}) do
		if interval.chunk then restyle(data.surface_data, interval.chunk) end
	end
	local breakdown = data.breakdown_interval
	if breakdown and breakdown.chunk then restyle(data.surface_data, breakdown.chunk) end
end

---Record delivery start for time tracking
---@param map_data MapData
---@param train_id uint
---@param item_hash string
---@param fulfillment_time uint?
---@param r_station_id uint? Requester station ID (to clear active failure)
function analytics.record_delivery_start(map_data, train_id, item_hash, fulfillment_time, r_station_id)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end

	local data = map_data.analytics
	local current_tick = game.tick

	if not data.delivery_phases then data.delivery_phases = {} end
	data.delivery_phases[train_id] = {
		item_hash = item_hash,
		request_tick = fulfillment_time and (current_tick - fulfillment_time) or current_tick,
		dispatch_tick = current_tick,
		arrive_p_tick = nil,
		leave_p_tick = nil,
		arrive_r_tick = nil,
	}

	-- Clear any active failure for this item+station since delivery is now in progress
	if r_station_id then
		analytics.clear_active_failure(map_data, r_station_id, item_hash)
	end
end

---Record delivery completion for time tracking
---@param map_data MapData
---@param train_id uint
function analytics.record_delivery_complete(map_data, train_id)
	if not analytics.is_enabled() then return end
	local data = map_data.analytics
	if not data then return end
	local phases = data.delivery_phases and data.delivery_phases[train_id]
	if not phases then return end
	local item_hash = phases.item_hash

	if not data.completed_deliveries then data.completed_deliveries = {} end

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

	while #completed_list > 50 do
		table.remove(completed_list, 1)
	end

	data.delivery_phases[train_id] = nil
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

local FAILURE_WAIT_THRESHOLD = 30  -- Only record failures after 30s of waiting
local FAILURE_STALE_TICKS = 3600   -- Consider failure resolved if not updated for 60 seconds

---Record a failed dispatch attempt - tracks active (ongoing) failures
---@param map_data MapData
---@param r_station_id uint
---@param item_hash string
---@param failure_reason number 0=no provider stock, 1=no train, 2=capacity, 3=layout
---@param wait_so_far number seconds the request has been waiting (cumulative)
---@param p_station_id uint? provider station id if one was found
---@param reason int? REASON_* the diagnostics recorded for this evaluation (nil when a provider-side failure is not
---  classified because diagnostics are off)
function analytics.record_failed_dispatch(map_data, r_station_id, item_hash, failure_reason, wait_so_far, p_station_id, reason)
	if not analytics.is_enabled() then return end
	if not map_data.analytics then return end

	-- Only record if wait time exceeds threshold
	if wait_so_far < FAILURE_WAIT_THRESHOLD then return end

	local data = map_data.analytics
	local current_tick = game.tick

	-- Track active failures (one entry per item+station, grows over time)
	if not data.active_failures then data.active_failures = {} end

	local key = item_hash .. ":" .. r_station_id
	local existing = data.active_failures[key]

	if existing then
		-- Update existing active failure
		existing.last_tick = current_tick
		existing.failure_reason = failure_reason  -- Reason might change
		existing.reason = reason
		existing.p_station_id = p_station_id
		-- Keep original request_start_tick so bar shows full wait time
	else
		-- New active failure - calculate when the request actually started
		-- wait_so_far is in seconds, convert back to ticks to find original request time
		local request_start_tick = current_tick - (wait_so_far * 60)
		data.active_failures[key] = {
			item_hash = item_hash,
			r_station_id = r_station_id,
			request_start_tick = request_start_tick,  -- When the request originally started
			last_tick = current_tick,
			failure_reason = failure_reason,
			reason = reason,
			p_station_id = p_station_id,
		}
	end
end

---Clear an active failure when a delivery succeeds
---@param map_data MapData
---@param r_station_id uint
---@param item_hash string
function analytics.clear_active_failure(map_data, r_station_id, item_hash)
	if not map_data.analytics then return end
	local data = map_data.analytics
	if not data.active_failures then return end

	local key = item_hash .. ":" .. r_station_id
	data.active_failures[key] = nil
end

---Get active failures for display, filtering out stale ones
---@param map_data MapData
---@param oldest_tick number Only used for stale check reference, not filtering (active failures always shown)
---@return table[] Array of active failure info with calculated duration
function analytics.get_active_failures(map_data, oldest_tick)
	if not map_data.analytics then return {} end
	local data = map_data.analytics
	if not data.active_failures then return {} end

	local current_tick = game.tick
	local results = {}
	local stale_keys = {}

	for key, failure in pairs(data.active_failures) do
		-- Check if stale (not updated recently) - consider resolved
		if (current_tick - failure.last_tick) > FAILURE_STALE_TICKS then
			stale_keys[#stale_keys + 1] = key
		else
			-- Active failure - always show regardless of time range filter
			-- Use request_start_tick for full wait duration, fall back to last_tick for old entries
			local start = failure.request_start_tick or failure.start_tick or failure.last_tick
			local duration_seconds = (current_tick - start) / 60
			-- The reason the Unserved chip shows (flap-confirmed) when diagnostics hold this request, so both tabs
			-- name it the same; the per-evaluation reason only without diagnostics.
			local reason = failure.reason
			local d = storage.diag
			local ix = d and d.item_ix[failure.item_hash]
			local by_item = ix and d.unserved[failure.r_station_id]
			local e = by_item and by_item[ix]
			if e then reason = e.reason end
			results[#results + 1] = {
				item_hash = failure.item_hash,
				r_station_id = failure.r_station_id,
				failure_reason = failure.failure_reason,
				reason = reason,
				duration = duration_seconds,
				request_start_tick = start,
				last_tick = failure.last_tick,
			}
		end
	end

	-- Clean up stale entries
	for _, key in ipairs(stale_keys) do
		data.active_failures[key] = nil
	end

	return results
end

-- Scratch counts by layout id, empty between calls, and the series name of each layout id: a sample runs every
-- SAMPLE_TICKS over every train, and only the sample itself is kept (by the chart).
local sample_working, sample_total, layout_keys = {}, {}, {}

---One utilization sample: per train layout (keyed by its id as a string, the chart's series name), the share of its
---trains on a delivery now, in percent.
---@param trains {[uint]: Train}
---@return {[string]: number}
function analytics.utilization_sample(trains)
	local working, total = sample_working, sample_total
	for _, train in pairs(trains) do
		local layout_id = train.layout_id
		if layout_id then
			total[layout_id] = (total[layout_id] or 0) + 1
			if STATUS_ON_DELIVERY[train.status] then
				working[layout_id] = (working[layout_id] or 0) + 1
			end
		end
	end
	local sample = {}
	for layout_id, n in pairs(total) do
		local key = layout_keys[layout_id]
		if not key then
			key = tostring(layout_id)
			layout_keys[layout_id] = key
		end
		sample[key] = (working[layout_id] or 0) / n * 100
		total[layout_id], working[layout_id] = nil, nil
	end
	return sample
end

---Samples train utilization into the chart's time series; called every SAMPLE_TICKS game ticks.
---@param map_data MapData
function analytics.tick(map_data)
	if not analytics.is_enabled() then return end
	-- Turning the setting on mid-game, or a save without samples, must start the chart without waiting for
	-- a tab to open.
	local data = map_data.analytics
	if not (data and data.train_utilization) then analytics.init(map_data) end
	local sample = analytics.utilization_sample(map_data.trains)
	if next(sample) then
		charts.add_datapoint(map_data.analytics.train_utilization, sample)
	end
end

---Render a stacked bar chart for delivery breakdown using the library
---@param map_data MapData
---@param interval table
---@param deliveries table[]
---@param phase_colors table
---@param phase_order string[]
---@param hatched_phases table? Phases to draw with diagonal stripes
---@param overlay_options table? {camera_position, camera_zoom, widget_size, get_tooltip}
---@return table? hit_regions Hit regions for interaction (if no overlay_options)
---@return table? button_configs Button configs with tooltips (if overlay_options provided)
---@return table? metadata the library's graph geometry and axis top (graph_left/right/bottom/height, max_total), with overlay_options
function analytics.render_stacked_bar_chart(map_data, interval, deliveries, phase_colors, phase_order, hatched_phases, viewport_width, viewport_height, overlay_options)
	if not interval.chunk then
		return nil
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
		return nil
	end

	local data = map_data.analytics

	-- If overlay options provided, use the combined render function
	if overlay_options and overlay_options.camera_position and overlay_options.camera_zoom and overlay_options.widget_size then
		local line_ids, button_configs, metadata = charts.render_stacked_bars_with_overlays(data.surface, interval.chunk, {
			deliveries = deliveries,
			phase_colors = phase_colors,
			phase_order = phase_order,
			hatched_phases = hatched_phases,
			bar_icons = overlay_options.bar_icons,
			ttl = 360,
			viewport_width = viewport_width,
			viewport_height = viewport_height,
			camera_position = overlay_options.camera_position,
			camera_zoom = overlay_options.camera_zoom,
			widget_size = overlay_options.widget_size,
			get_tooltip = overlay_options.get_tooltip,
		})

		if line_ids then
			interval.line_ids = line_ids
		end

		return button_configs, metadata
	end

	-- Legacy path: use metadata-returning version for interaction support
	local line_ids, metadata = charts.render_stacked_bars_with_metadata(data.surface, interval.chunk, {
		deliveries = deliveries,
		phase_colors = phase_colors,
		phase_order = phase_order,
		hatched_phases = hatched_phases,
		ttl = 360,
		viewport_width = viewport_width,
		viewport_height = viewport_height,
	})

	if line_ids then
		interval.line_ids = line_ids
	end

	-- Generate hit regions from metadata
	if metadata then
		local hit_regions = charts.create_bar_chart_hit_regions(interval.chunk, metadata)
		return hit_regions
	end

	return nil
end

return analytics
