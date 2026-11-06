-- The 2.2.0 entry of scripts/migrations.lua, run through on_config_changed against a storage shaped like a save
-- written by 2.1.2, and the train interrupt refresh every configuration change runs afterwards.

local H = require("harness")
local analytics = package.loaded["scripts.analytics"]

package.loaded["gui.main"] = package.loaded["gui.main"] or {}
dofile(H.mod_root .. "/scripts/migrations.lua")
dofile(H.mod_root .. "/scripts/train-events.lua")

local UPGRADE = { mod_changes = { cybersyn = { old_version = "2.1.2", new_version = "2.2.0" } } }

local function schedule(records, current)
	return {
		current = current,
		get_record_count = function() return #records end,
		get_record = function(pos) return records[pos.schedule_index] end,
	}
end

local function train_entity(id, state, records, current)
	return {
		valid = true,
		id = id,
		state = state,
		get_schedule = function() return schedule(records or {}, current or 1) end,
	}
end

--- A storage with every field a 2.1.2 save carries that the migration reads or drops.
local function storage_212()
	return {
		tick_state = STATE_DISPATCH,
		tick_data = { stale = true },
		recent_external_items = { { name = "iron-plate", tick = 10 } },
		warmup_station_ids = { 7 },
		warmup_station_cycles = { [7] = 1 },
		economy = { all_r_stations = { a = { 7 } }, all_p_stations = { b = { 8 } }, all_names = { "a" } },
		stations = {
			[7] = {
				deliveries = {},
				item_p_counts = { ["iron-plate"] = 100 },
				tick_signals = { [1] = { signal = { name = "iron-plate", type = "item" }, count = 100 } },
				request_start_ticks = { ["iron-plate"] = 12 },
			},
			[8] = { deliveries = {}, request_start_ticks = {} },
		},
		available_trains = { ["signal-A"] = {}, ["signal-B"] = { [1] = true } },
		trains = {
			[1] = { entity = train_entity(1, defines.train_state.wait_station) },
			[2] = { entity = { valid = false } },
		},
		manager = {
			players = {
				[1] = {
					stations_sort = {}, trains_sort = {}, auto_refresh = true, pinned = {},
					recent_panel_dirty = true, disable_top_left_button = false,
					delivery_times_interval = 2, delivery_times_mode = "x", delivery_times_selected = {},
					search_query = "iron", search_network_name = "signal-A", search_network_mask = 3,
					search_surface_idx = 1, search_item = "coal",
					utilization_interval = 3, utilization_selected = { ["signal-A"] = false }, breakdown_interval = 2,
					utilization_cache = { tick = 1 }, breakdown_cache = { tick = 1 }, utilization_registered = true,
					visible = true,
					is_manager_open = false,
				},
			},
		},
	}
end

local function with_stubs(fn)
	local saved = { retrigger_train_calculation, analytics.migrate, analytics.is_library_available, analytics.is_enabled }
	local inits = {}
	retrigger_train_calculation = function() end
	analytics.migrate = function(map_data) inits[#inits + 1] = map_data end
	analytics.is_library_available = function() return false end
	analytics.is_enabled = function() return false end
	local ok, err = pcall(fn, inits)
	retrigger_train_calculation, analytics.migrate, analytics.is_library_available, analytics.is_enabled =
		saved[1], saved[2], saved[3], saved[4]
	if not ok then error(err, 0) end
end

test("2.1.2 -> 2.2.0 creates the new fields and drops the unread ones", function()
	with_stubs(function()
		game.tick = 4000
		storage = storage_212()
		on_config_changed(UPGRADE)

		assert_eq(storage.tick_state, STATE_INIT, "on_config_changed restarts the planner")
		assert_nil(storage.recent_external_items)
		assert_nil(storage.warmup_station_ids)
		assert_eq(storage.warmup_station_cycles, { [7] = 1 })
		assert_eq(storage.economy, { all_r_stops = {}, all_p_stops = {}, all_names = {}, starved = {} })
		assert_eq(storage.available_trains, { ["signal-B"] = { [1] = true } }, "empty network tables dropped")

		for id, station in pairs(storage.stations) do
			assert_eq(station.secondary_inv_combs, {}, "station " .. id)
			assert_nil(station.tick_signals, "station " .. id)
			assert_nil(station.item_p_counts, "station " .. id)
			assert_eq(station.request_start_ticks, {}, "station " .. id)
			assert_nil(station.created_tick, "unknown, not backfilled")
		end

		local t = storage.trains[1]
		assert_eq(t.last_state, defines.train_state.wait_station)
		assert_eq(t.state_tick, 4000)
		assert_nil(storage.trains[2].last_state, "invalid train left alone")

		assert_eq(storage.manager.players[1], {
			is_manager_open = false,
			cache = {},
			tabs = {
				utilization_tab = { interval = 3, selected = { ["signal-A"] = false } },
				delivery_breakdown_tab = { interval = 2 },
			},
		}, "choices move under pd.tabs, the 2.1.2 caches go")
	end)
end)

test("2.2.0 keeps inventory combinators a station already has", function()
	with_stubs(function()
		storage = storage_212()
		local comb = { valid = true, unit_number = 99 }
		storage.stations[7].secondary_inv_combs = { [99] = comb }
		on_config_changed(UPGRADE)
		assert_same(storage.stations[7].secondary_inv_combs[99], comb)
	end)
end)

test("2.2.0 is idempotent", function()
	with_stubs(function()
		game.tick = 4000
		storage = storage_212()
		on_config_changed(UPGRADE)
		local once = H.copy(storage)
		on_config_changed(UPGRADE)
		assert_eq(storage, once)
	end)
end)

test("2.2.0 does not run once a save is on 2.2.0", function()
	with_stubs(function()
		storage = storage_212()
		on_config_changed({ mod_changes = { cybersyn = { old_version = "2.2.0", new_version = "2.2.1" } } })
		assert_not_nil(storage.recent_external_items)
		assert_eq(storage.stations[7].request_start_ticks, { ["iron-plate"] = 12 })
	end)
end)

test("a configuration change reshapes analytics only when the charts library is loaded", function()
	with_stubs(function(inits)
		storage = storage_212()
		storage.analytics = { train_utilization = {} }
		analytics.is_library_available = function() return false end
		on_config_changed(UPGRADE)
		assert_eq(#inits, 0)

		storage = storage_212()
		storage.analytics = { train_utilization = {} }
		analytics.is_library_available = function() return true end
		on_config_changed(UPGRADE)
		assert_eq(#inits, 1)
		assert_same(inits[1], storage)

		storage = storage_212()
		on_config_changed(UPGRADE)
		assert_eq(#inits, 1, "no analytics table, nothing to reshape")
	end)
end)

test("refresh_train_interrupts recomputes the flag from the live schedule", function()
	local normal = { created_by_interrupt = false }
	local inserted = { created_by_interrupt = true }
	storage.trains = {
		[1] = { entity = train_entity(1, 0, { normal, inserted }, 2), in_interrupt = false },
		[2] = { entity = train_entity(2, 0, { normal, inserted }, 1), in_interrupt = false },
		[3] = { entity = train_entity(3, 0, {}), in_interrupt = true },
		[4] = { entity = { valid = false }, in_interrupt = true },
		[5] = { entity = train_entity(5, 0, { normal, normal }, 2), in_interrupt = true },
	}
	refresh_train_interrupts(storage)
	assert_true(storage.trains[1].in_interrupt)
	assert_true(storage.trains[2].in_interrupt, "an interrupt record counts while current still points elsewhere")
	assert_false(storage.trains[3].in_interrupt, "an empty schedule is no interrupt")
	assert_true(storage.trains[4].in_interrupt, "an invalid train is left for its removal handler")
	assert_false(storage.trains[5].in_interrupt, "no interrupt record")
end)

test("sanitize_economy_names carries renamed items and qualities into deliveries, stats and acks", function()
	local ack = { tick = 5 }
	storage = {
		stations = { [7] = { deliveries = { coal = 5, ["iron-plate|rare"] = 3, stone = 1 } } },
		trains = {},
		stats = {
			minute = { [1] = { items = { coal = 2, water = 4 } } },
			hour = { [1] = { items = { ["iron-plate|rare"] = 6 } } },
			trip_ema = { coal = { avg = 60, n = 2 } },
		},
		acks = { request = { [7] = { ["iron-plate|rare"] = ack, stone = { tick = 1 } }, [8] = { stone = { tick = 2 } } }, n = 3 },
	}
	sanitize_economy_names({ migrations = { item = { coal = "coke", stone = "" }, quality = { rare = "epic" } } })
	assert_eq(storage.stations[7].deliveries, { coke = 5, ["iron-plate|epic"] = 3 })
	assert_eq(storage.stats.minute[1].items, { coke = 2, water = 4 })
	assert_eq(storage.stats.hour[1].items, { ["iron-plate|epic"] = 6 })
	assert_eq(storage.stats.trip_ema, { coke = { avg = 60, n = 2 } })
	assert_eq(storage.acks.request[7], { ["iron-plate|epic"] = ack })
	assert_nil(storage.acks.request[8])
	assert_eq(storage.acks.n, 1)
end)
