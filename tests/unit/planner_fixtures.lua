-- Fake stations for driving the real planner (`tick`: poll, then dispatch) under the unit harness.

local F = {}

-- The harness's analytics module is empty, and a failed dispatch is recorded through it.
package.loaded["scripts.analytics"].record_failed_dispatch = function() end

function F.sig(name, count, type)
	return { signal = { name = name, type = type or "item" }, count = count }
end

--- A combinator whose inputs are `inputs.list` (copied on every read: the poll removes control signals in place).
function F.comb(unit, op, inputs)
	local control = { parameters = { operation = op } }
	return {
		valid = true,
		unit_number = unit,
		status = defines.entity_status.working,
		get_signals = function()
			local out = {}
			for i, s in ipairs(inputs.list) do out[i] = { signal = s.signal, count = s.count } end
			return out
		end,
		get_or_create_control_behavior = function() return control end,
	}
end

function F.op(c)
	return c.get_or_create_control_behavior().parameters.operation
end

--- One station on signal-A: the station combinator reads `own`, each inventory combinator `invs[unit]`.
function F.station(id, own, invs, extra)
	local secs = {}
	for unit, inputs in pairs(invs or {}) do secs[unit] = F.comb(unit, MODE_SECONDARY_INVENTORY, inputs) end
	local st = {
		entity_stop = { valid = true, trains_limit = 5, unit_number = id, surface_index = 1, position = { x = id, y = 0 } },
		entity_comb1 = F.comb(id + 1, MODE_PRIMARY_IO, own),
		secondary_inv_combs = secs,
		is_r = true,
		is_p = true,
		network_name = "signal-A",
		network_mask = 1,
		deliveries = {},
		deliveries_total = 0,
		display_state = 0,
		last_delivery_tick = 0,
		request_start_ticks = {},
		accepted_layouts = {},
	}
	for k, v in pairs(extra or {}) do st[k] = v end
	return st
end

function F.world(stations)
	local ids, by_id = {}, {}
	for _, st in ipairs(stations) do
		ids[#ids + 1] = st.entity_stop.unit_number
		by_id[st.entity_stop.unit_number] = st
	end
	return {
		tick_data = {},
		active_station_ids = ids,
		stations = by_id,
		economy = { all_r_stops = {}, all_p_stops = {}, all_names = {} },
		tick_state = STATE_POLL_STATIONS,
		total_ticks = 1,
		trains = {},
		each_refuelers = {},
		refuelers = {},
		to_comb = {},
		available_trains = {},
		layouts = {},
	}
end

F.SETTINGS = {
	enable_planner = true, update_rate = 10, r_threshold = 1000, r_fluid_threshold = 0, priority = 0, locked_slots = 0,
	reserved_fluid_capacity = 0, network_mask = 1, tps = 60,
}

--- Polls every station and dispatches until the planner is back at its init state: one whole planner pass.
function F.pass(map_data)
	map_data.tick_state = STATE_POLL_STATIONS
	map_data.tick_data = {}
	for _ = 1, 20 do
		tick(map_data, F.SETTINGS)
		if map_data.tick_state == STATE_INIT then return end
	end
	error("the planner did not finish a pass")
end

--- Runs `fn` with the named globals replaced, restoring them however it ends.
function F.with_globals(replacements, fn)
	local saved = {}
	for name, value in pairs(replacements) do
		saved[name] = { _G[name] }
		_G[name] = value
	end
	local ok, err = pcall(fn)
	for name, old in pairs(saved) do _G[name] = old[1] end
	assert(ok, err)
end

--- An available train on signal-A standing at (x, 0) on surface 1, at its depot with a base schedule: one 40-slot
--- cargo wagon, no fluid wagon, priority 0.
function F.train(map_data, id, x)
	local stock = { surface_index = 1, position = { x = x or 0, y = 0 } }
	local train = {
		network_name = "signal-A", network_mask = 1, priority = 0, status = STATUS_D, depot_id = 9, depot_surface_id = 1,
		layout_id = 1, item_slot_capacity = 40, fluid_capacity = 0,
		entity = {
			valid = true, manual_mode = false, front_stock = stock,
			get_schedule = function() return { get_record_count = function() return 1 end } end,
		},
	}
	map_data.trains[id] = train
	local available = map_data.available_trains["signal-A"] or {}
	map_data.available_trains["signal-A"] = available
	available[id] = true
	return train
end

F.NET = F.sig("signal-A", 1, "virtual")

return F
