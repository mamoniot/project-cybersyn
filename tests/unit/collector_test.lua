-- Characterization tests for scripts/gui/collector.lua, on a synthetic storage with fake entities.

local H = require("harness")
local collector = require("scripts.gui.collector")

local WORKING = defines.entity_status.working
local LOW_POWER = defines.entity_status.low_power
local NO_POWER = defines.entity_status.no_power

local function sig(name, count, type, quality)
	return { signal = { name = name, type = type, quality = quality }, count = count }
end

-- `signals` and `status` stay writable, so a test can change a combinator's inputs between two passes.
local function comb(status, signals, unit_number)
	local c = { valid = true, status = status, signals = signals, unit_number = unit_number }
	function c.get_signals(red, green)
		assert(red == defines.wire_connector_id.circuit_red and green == defines.wire_connector_id.circuit_green)
		return c.signals
	end
	return c
end

local function stop(name, surface)
	return { valid = true, backer_name = name, surface_index = surface or 1 }
end

--- A record without its rows (they point back at the record), for whole-record comparisons.
local function without_rows(st)
	local out = {}
	for k, v in pairs(st) do
		if k ~= "rows" then out[k] = v end
	end
	return out
end

--- The planner's poll over storage.stations: the manager reads only what it keeps. Settings come from mod_settings, as
--- the planner's own copy would; the economy it builds stays apart from storage.economy, whose starved set the tests
--- choose themselves.
local function poll()
	local settings = {
		enable_planner = true, update_rate = 1000, tps = 60, network_mask = 1, locked_slots = 0,
		reserved_fluid_capacity = 0, r_threshold = mod_settings.r_threshold or 2000,
		r_fluid_threshold = mod_settings.r_fluid_threshold or 0, priority = mod_settings.priority or 0,
	}
	local ids = {}
	for id, station in pairs(storage.stations or {}) do
		local stop, comb1, comb2 = station.entity_stop, station.entity_comb1, station.entity_comb2
		if stop.valid and comb1 and comb1.valid and not (comb2 and not comb2.valid) then
			ids[#ids + 1] = id
			station.deliveries = station.deliveries or {}
			station.display_state = station.display_state or 0
			stop.trains_limit = station.trains_limit or 0
		end
	end
	table.sort(ids)
	local map_data = {
		tick_data = {}, active_station_ids = ids, stations = storage.stations, tick_state = STATE_POLL_STATIONS,
		economy = { all_r_stops = {}, all_p_stops = {}, all_names = {} }, total_ticks = 1, trains = {},
		each_refuelers = {}, refuelers = {}, to_comb = {}, available_trains = {}, layouts = {},
	}
	for _ = 1, 100 do
		if map_data.tick_state ~= STATE_POLL_STATIONS then return end
		tick(map_data, settings)
	end
	error("the planner did not finish polling")
end

--- One planner poll, then one whole collector pass.
local function pass()
	poll()
	collector.run_to_completion()
end

local function manager()
	storage.manager = { players = {} }
	storage.economy = { starved = {} }
	collector.init()
end

-- Six stations covering provider, requester, warming up, each-network + stack, missing combinator, secondary.
local function scenario()
	mod_settings = { r_threshold = 2000, r_fluid_threshold = 0, tps = 30 }
	manager()
	-- What the planner's last poll publishes for these stations: each-network station 4 requests coal on both of
	-- its networks.
	storage.economy.starved = { ["signal-A:coal"] = true, ["signal-B:coal"] = true, ["signal-A:copper-ore"] = true }
	storage.stations = {
		[1] = {
			entity_stop = stop("Iron Mine"),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, {
				sig("iron-ore", 500),
				sig("signal-A", 1, "virtual"),
				sig("cybersyn-priority", 5, "virtual"),
				sig("coal", -100),
				sig("water", 2000, "fluid"),
			}),
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
			trains_limit = 2,
			deliveries_total = 3,
			last_delivery_tick = 700,
			priority = 5,
			deliveries = { ["iron-ore"] = -400 },
		},
		[2] = {
			entity_stop = stop("Smelter"),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, {
				sig(REQUEST_THRESHOLD, 500, "virtual"),
				sig("iron-ore", -1000),
				sig("copper-ore", -100),
				sig("coal", -800),
				sig("water", -50, "fluid"),
				sig("stone", 10),
			}),
			entity_comb2 = comb(WORKING, {
				sig("cybersyn-request-threshold", 7, "virtual"),
				sig("iron-ore", -300),
				sig("copper-ore", 20, "item", "rare"),
				sig("copper-ore", 50),
			}),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			deliveries = { ["iron-ore"] = 400 },
			request_start_ticks = { ["iron-ore"] = 50, coal = 20, ["copper-ore"] = 5 },
		},
		[3] = {
			entity_stop = stop("Warming"),
			secondary_inv_combs = {},
			entity_comb1 = comb(LOW_POWER, { sig("stone", -5000) }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			is_warming_up = true,
		},
		[4] = {
			entity_stop = stop("Each", 2),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, {
				sig("stone", -60), sig("coal", -200), sig("signal-A", 1, "virtual"), sig("signal-B", 2, "virtual"),
				sig(REQUEST_THRESHOLD, 2, "virtual"),
			}),
			network_name = NETWORK_EACH,
			network_mask = { ["signal-A"] = 1, ["signal-B"] = 2 },
			is_r = true,
			is_stack = true,
		},
		[5] = {
			entity_stop = stop("No combinator"),
			secondary_inv_combs = {},
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
		},
		[6] = {
			entity_stop = stop("Unpowered"),
			entity_comb1 = comb(NO_POWER, { sig("iron-plate", 999) }),
			secondary_inv_combs = {
				comb(WORKING, { sig("iron-plate", 100), sig("copper-plate", -30), sig(REQUEST_THRESHOLD, 20, "virtual") }),
			},
			network_name = "signal-B",
			network_mask = 1,
			is_p = true,
			is_r = true,
		},
	}
	storage.trains = {
		[10] = {
			entity = { valid = true, front_stock = { surface_index = 1 } },
			status = STATUS_TO_P,
			layout_id = 1,
			depot_id = 100,
			network_name = "signal-A",
			network_mask = 1,
			manifest = { { name = "iron-ore", count = 200 }, { name = "iron-ore", quality = "rare", count = 5 }, { name = "iron-ore", count = 50 } },
			p_station_id = 1,
			r_station_id = 2,
		},
		[11] = { entity = { valid = false }, status = STATUS_D },
		[12] = {
			entity = { valid = true, back_stock = { surface_index = 2 } },
			depot_id = 101,
			network_name = NETWORK_EACH,
			network_mask = { ["signal-A"] = 1 },
			is_available = true,
		},
	}
	storage.depots = {
		[100] = { entity_stop = { valid = true, backer_name = "Depot 1", trains_limit = 1, trains_count = 0 } },
		[101] = { entity_stop = { valid = false }, available_train_id = 12 },
	}
	storage.available_trains = { ["signal-A"] = { [12] = true } }
	storage.active_alerts = { [12] = { "x", 3 }, [10] = { "x", 2, 90 } }
	storage.total_ticks = 100
	storage.tick_state = STATE_POLL_STATIONS
	game.tick = 1000
end

test("empty: the snapshot shape", function()
	assert_eq(collector.empty(), {
		started_tick = 0,
		station_count = 0,
		train_count = 0,
		secondary_count = 0,
		stations = {},
		trains = {},
		trains_version = 0,
		inventory_all = { provided = {}, requested = {}, in_transit = {} },
		starved = {},
		starved_items = {},
		starved_version = 0,
		-- The hour's minimum from stats; the fleet facts, depot groups and provider masks the lint engine reads.
		fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {}, min_available_by_network = {},
			capability = {}, mask_or = {}, in_interrupt_count = {}, group_depots = {} },
		depots = { total = 0, parked = 0 },
		depots_by_name = {},
		provider_masks = {},
		provider_overrides = {},
		-- The active request keys, kept for the Inventory's Dim unrequested.
		request_keys = {},
		alerts = {},
	})
	assert_true(collector.empty() ~= collector.empty())
end)

test("init and reset_log: new snapshot, epoch counts up", function()
	storage.manager = { players = {}, snapshot_build = {} }
	collector.init()
	assert_eq(storage.manager.snapshot, collector.empty())
	assert_nil(storage.manager.snapshot_build)
	assert_eq(storage.manager.collect_log, { epoch = 1, base = 0, ids = {} })
	collector.reset_log()
	assert_eq(storage.manager.collect_log, { epoch = 2, base = 0, ids = {} })
	collector.init()
	assert_eq(storage.manager.collect_log.epoch, 3)
end)

test("log_position: creates a log when missing", function()
	storage.manager = { players = {} }
	assert_eq({ collector.log_position() }, { 1, 0 })
	storage.manager.collect_log = { epoch = 4, base = 10, ids = { 7, 8 } }
	assert_eq({ collector.log_position() }, { 4, 12 })
end)

test("changed_since: epoch and range checks", function()
	storage.manager = { players = {} }
	assert_eq({ collector.changed_since(1, 0) }, { nil, 0, 0 })
	local ids = { 7, 8, 9 }
	storage.manager.collect_log = { epoch = 3, base = 10, ids = ids }
	assert_eq({ collector.changed_since(nil, 10) }, { nil, 0, 0 })
	assert_eq({ collector.changed_since(3, nil) }, { nil, 0, 0 })
	assert_eq({ collector.changed_since(2, 10) }, { nil, 0, 0 })
	assert_eq({ collector.changed_since(3, 9) }, { nil, 0, 0 })
	assert_eq({ collector.changed_since(3, 14) }, { nil, 0, 0 })
	local r, first, last = collector.changed_since(3, 10)
	assert_same(r, ids)
	assert_eq({ first, last }, { 1, 3 })
	assert_eq({ select(2, collector.changed_since(3, 12)) }, { 3, 3 })
	-- Up to date: an empty range.
	assert_eq({ select(2, collector.changed_since(3, 13)) }, { 4, 3 })
end)

test("get: creates an empty snapshot and a new log epoch when missing", function()
	storage.manager = { players = {}, collect_log = { epoch = 5, base = 3, ids = { 1 } } }
	local s = collector.get()
	assert_eq(s, collector.empty())
	assert_same(storage.manager.snapshot, s)
	assert_eq(storage.manager.collect_log, { epoch = 6, base = 0, ids = {} })
	assert_same(collector.get(), s)
	assert_eq(storage.manager.collect_log.epoch, 6)
end)

test("release_if_unused: keeps data while any window is open; drops it otherwise", function()
	collector.release_if_unused()
	assert_nil(storage.manager)
	manager()
	local snap = storage.manager.snapshot
	snap.tick = 5
	storage.manager.players = { [1] = { cache = {}, is_manager_open = false }, [2] = { cache = {}, is_manager_open = true } }
	collector.release_if_unused()
	assert_same(storage.manager.snapshot, snap)
	storage.manager.players[2].is_manager_open = false
	storage.manager.snapshot_build = {}
	collector.release_if_unused()
	assert_true(storage.manager.snapshot ~= snap)
	assert_eq(storage.manager.snapshot, collector.empty())
	assert_nil(storage.manager.snapshot_build)
	assert_eq(storage.manager.collect_log.epoch, 2)
	-- Already empty: nothing to release, the epoch stays.
	collector.release_if_unused()
	assert_eq(storage.manager.collect_log.epoch, 2)
end)

test("wanted and tick: an open manager collects unless it is paused with data shown", function()
	scenario()
	storage.manager.players = { [1] = { cache = {}, is_manager_open = true, paused = true }, [2] = { cache = {}, is_manager_open = false } }
	-- Paused before its first data (reopened paused): it still needs one pass.
	assert_true(collector.wanted())
	storage.manager.players[1].rendered_snapshot_tick = 10
	assert_false(collector.wanted())
	assert_false(collector.tick())
	assert_nil(storage.manager.snapshot_build)
	storage.manager.players[1].paused = false
	assert_true(collector.wanted())
	assert_true(collector.tick())
	assert_not_nil(storage.manager.snapshot_build)
	storage.manager = nil
	assert_false(collector.tick())
end)

test("full pass: provider record", function()
	scenario()
	pass()
	local snap = collector.get()
	local source = { kind = "station", index = 0, ok = true, priority = 5, network_mask = 1, network_name = "signal-A",
		mask = 1, provided = { ["iron-ore"] = 500, water = 2000 }, requested = {}, ignored = { coal = -100 } }
	assert_eq(without_rows(snap.stations[1]), {
		id = 1,
		name = "Iron Mine",
		name_lower = "iron mine",
		-- No tiebreak string (sorts compare name_lower, then id); the parsed name and status.
		name_parts = { text = "Iron Mine" },
		status = "saturated",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		is_p = true,
		is_r = false,
		is_stack = false,
		comb_ok = true,
		warming_up = false,
		trains_limit = 2,
		deliveries_total = 3,
		last_delivery_tick = 700,
		priority = 5,
		provided = { ["iron-ore"] = 500, water = 2000 },
		requested = {},
		deliveries = { ["iron-ore"] = -400 },
		control = { ["cybersyn-priority"] = 5 },
		control2 = {},
		thresholds = {},
		wait = {},
		secondary = false,
		secondary_count = 0,
		-- When the record was read, and the lint bitmask (0 before the first lint pass).
		read_tick = 1000,
		lint = 0,
		-- No unserved request at a train limit names the station.
		throttling = false,
		-- A Provide only station does not advertise its coal request; one source.
		ignored = { coal = -100 },
		sources = { source },
	})
	local st = snap.stations[1]
	-- The station combinator is the only row, on the record's own lists.
	assert_eq(#st.rows, 1)
	assert_same(collector.inventories(st), st.rows)
	local row = st.rows[1]
	assert_same(row.st, st)
	assert_same(row.src, st.sources[1])
	assert_same(row.provided, st.provided)
	assert_same(row.requested, st.requested)
	assert_same(row.ignored, st.ignored)
	assert_eq({ row.index, row.kind, row.priority, row.network_name, row.mask, row.read, row.ok },
		{ 0, "station", 5, "signal-A", 1, true, true })
	assert_eq(row.label, { "cybersyn-gui.source-station" })
	-- Copied, not shared, so the planner's later writes do not leak into the snapshot.
	assert_true(snap.stations[1].deliveries ~= storage.stations[1].deliveries)
end)

test("full pass: requester record with thresholds, control combinator and waits", function()
	scenario()
	pass()
	local st = collector.get().stations[2]
	assert_eq(st.requested, {
		["iron-ore"] = { count = -1000, threshold = 300, active = true, mask = 1 },
		["copper-ore"] = { count = -100, threshold = 50, active = true, mask = 1 },
		coal = { count = -800, threshold = 500, active = true, mask = 1 },
		-- No fluid threshold anywhere: the item threshold applies to fluids.
		water = { count = -50, threshold = 500, active = false, mask = 1 },
	})
	assert_eq(st.provided, {})
	assert_eq(st.control, { [REQUEST_THRESHOLD] = 500 })
	assert_eq(st.control2, { [REQUEST_THRESHOLD] = 7 })
	assert_eq(st.thresholds, { ["iron-ore"] = 300, ["copper-ore|rare"] = 20, ["copper-ore"] = 50 })
	assert_true(st.comb2_ok)
	assert_eq(st.wait, { ["iron-ore"] = 50, coal = 20, ["copper-ore"] = 5 })
	assert_eq(st.longest_wait_start, 5)
	assert_eq(st.trains_limit, 0)
	assert_eq(st.deliveries_total, 0)
	assert_nil(st.last_delivery_tick)
end)

test("full pass: warming up, each-network stack station, skipped and secondary stations", function()
	scenario()
	pass()
	local snap = collector.get()
	local warm = snap.stations[3]
	assert_true(warm.warming_up)
	assert_true(warm.comb_ok)
	-- The planner keeps nothing for a warming-up station, so neither does the manager.
	assert_eq(warm.requested, {})
	local each = snap.stations[4]
	assert_eq(each.surface_index, 2)
	assert_eq(each.requested, {
		stone = { count = -60, threshold = 100, active = false },
		coal = { count = -200, threshold = 100, active = true },
	})
	assert_eq(each.control, { ["signal-A"] = 1, ["signal-B"] = 2, [REQUEST_THRESHOLD] = 2 })
	assert_eq(each.network_mask, { ["signal-A"] = 1, ["signal-B"] = 2 })
	assert_true(each.network_mask ~= storage.stations[4].network_mask)
	assert_nil(snap.stations[5])
	-- The planner reads secondaries only while the station combinator works.
	local sec = snap.stations[6]
	assert_false(sec.comb_ok)
	assert_false(sec.secondary)
	assert_eq(sec.secondary_count, 0)
	assert_eq(sec.provided, {})
	assert_eq(sec.requested, {})
	assert_eq(sec.control, {})
	assert_eq(sec.sources[2], { kind = "inventory", index = 1, ok = true, priority = 0, read = false,
		network_name = "signal-B", provided = {}, requested = {}, ignored = {} })
	assert_eq(#sec.rows, 2)
	assert_false(sec.rows[2].read)
	assert_nil(sec.rows[2].mask, "an unread inventory registers under no mask")
	assert_eq(snap.station_count, 5)
	assert_eq(snap.secondary_count, 0)
	assert_eq(snap.tick, 1000)
	assert_eq(snap.started_tick, 1000)
end)

test("full pass: inventory_all sums active requests and incoming deliveries only", function()
	scenario()
	pass()
	local inv = collector.get().inventory_all
	assert_eq(inv.provided, {
		["iron-ore"] = { count = 500, stations = 1 },
		water = { count = 2000, stations = 1 },
	})
	assert_eq(inv.requested, {
		["iron-ore"] = { count = -1000, stations = 1, earliest_wait_start = 50 },
		["copper-ore"] = { count = -100, stations = 1, earliest_wait_start = 5 },
		coal = { count = -1000, stations = 2, earliest_wait_start = 20 },
	})
	assert_eq(inv.in_transit, { ["iron-ore"] = { count = 400, stations = 1 } })
end)

test("full pass: the starved set is the one the planner published, whatever its phase", function()
	scenario()
	storage.tick_state = STATE_DISPATCH
	-- The economy the planner is consuming plays no part.
	storage.economy.all_r_stops = { ["signal-A:stone"] = {} }
	storage.economy.all_p_stops = {}
	pass()
	local snap = collector.get()
	assert_same(snap.starved, storage.economy.starved)
	assert_eq(snap.starved_items, { coal = true, ["copper-ore"] = true })
	assert_eq(snap.starved_version, 1)
end)

test("full pass: request keys stay with the snapshot next to the provider masks", function()
	scenario()
	pass()
	local snap = collector.get()
	for key in pairs(snap.starved) do
		assert_true(snap.request_keys[key], key .. " is a request key")
		assert_nil(snap.provider_masks[key], key .. " has no provider")
	end
	local first = snap.request_keys
	pass()
	assert_eq(collector.get().request_keys, first, "the same keys after another pass")
end)

test("throttling: an unacknowledged R_AT_LIMIT names the requester, P_AT_LIMIT the provider", function()
	scenario()
	storage.diag = {
		unserved = {
			[2] = { [1] = { reason = REASON_R_AT_LIMIT, first_tick = 10 } },
			[3] = { [2] = { reason = REASON_P_AT_LIMIT, p_station_id = 1, first_tick = 10 } },
			[4] = { [1] = { reason = REASON_R_AT_LIMIT, first_tick = 10 } },
			[6] = { [2] = { reason = REASON_NO_PROVIDER, first_tick = 10 } },
		},
		item_hash = { "iron-ore", "stone" },
		item_ix = { ["iron-ore"] = 1, stone = 2 },
	}
	storage.acks = { request = { [4] = { ["iron-ore"] = { until_tick = 5000 } } }, station = {}, lint = {} }
	pass()
	local snap = collector.get()
	assert_true(snap.stations[1].throttling, "provider of a P_AT_LIMIT")
	assert_true(snap.stations[2].throttling, "requester of an R_AT_LIMIT")
	assert_false(snap.stations[3].throttling, "a requester waiting on a full provider is not itself at its limit")
	assert_false(snap.stations[4].throttling, "acknowledged")
	assert_false(snap.stations[6].throttling, "another reason")
	game.tick = 6000
	pass()
	assert_true(collector.get().stations[4].throttling, "the acknowledgement expired")
	storage.diag = nil
	storage.acks = nil
end)

test("full pass: trains, fleet, depots and alerts", function()
	scenario()
	pass()
	local snap = collector.get()
	assert_eq(H.keys(snap.trains), { 10, 12 })
	assert_eq(snap.trains[10], {
		id = 10,
		status = STATUS_TO_P,
		layout_id = 1,
		depot_id = 100,
		depot_name = "Depot 1",
		network_name = "signal-A",
		network_mask = 1,
		p_station_id = 1,
		r_station_id = 2,
		manifest = {
			{ name = "iron-ore", count = 200, hash = "iron-ore" },
			{ name = "iron-ore", quality = "rare", count = 5, hash = "iron-ore|rare" },
			{ name = "iron-ore", count = 50, hash = "iron-ore" },
		},
		manifest_hashes = { ["iron-ore"] = 250, ["iron-ore|rare"] = 5 },
		surface_index = 1,
		is_available = false,
		disable_bypass = false,
		-- The stub entity has no state, signal or path, so only the cached flag shows.
		in_interrupt = false,
		in_group = false,
		-- Never seen refuelling: tracked from when refuelling was first recorded (the train has no seen_tick).
		refuel_from = 1000,
	})
	local t12 = snap.trains[12]
	assert_eq(t12.depot_name, "")
	assert_eq(t12.surface_index, 2)
	assert_true(t12.is_available)
	assert_nil(t12.status)
	assert_eq(t12.manifest, {})
	assert_eq(snap.train_count, 2)
	assert_eq(snap.fleet, {
		total = 2,
		by_status = { [STATUS_TO_P] = 1, [STATUS_D] = 1 },
		available_by_network = { ["signal-A"] = 1 },
		by_layout = { [1] = 1 },
		min_available_by_network = {},
		-- Per network and layout (train 12 has no layout yet: 0), and the OR of the masks.
		capability = { ["signal-A"] = {
			[1] = { count = 1, item_capacity = 0, fluid_capacity = 0, mask_or = 1 },
			[0] = { count = 1, item_capacity = 0, fluid_capacity = 0, mask_or = 1 },
		} },
		mask_or = { ["signal-A"] = 1 },
		in_interrupt_count = {},
		group_depots = {},
	})
	assert_eq(snap.depots, { total = 2, parked = 1 })
	-- Depot 101's stop is invalid; train 12's depot has no name, so only Depot 1 forms a group.
	assert_eq(snap.depots_by_name, { ["Depot 1"] = { ids = { 100 }, limit = 1, count = 0, parked = 0, inbound = 0,
		trains_bound = 1, compositions = { [1] = 1 }, same_depot_bypass = 1 } })
	-- tps 30 = 2 ticks per main tick: alert raised 10 main ticks ago.
	assert_eq(snap.alerts, { { train_id = 10, kind = 2, since_tick = 980 }, { train_id = 12, kind = 3, since_tick = 1000 } })
end)

test("alerts: tps 0 means one tick per main tick", function()
	scenario()
	mod_settings.tps = 0
	pass()
	assert_eq(collector.get().alerts[1].since_tick, 990)
end)

test("delivery_age: the planner's nth, ceil(60 / tps), per planner tick; nil at tps 0", function()
	storage.total_ticks = 110
	mod_settings.tps = 7
	assert_eq(collector.delivery_age({ last_delivery_tick = 100 }), 90)
	mod_settings.tps = 0
	assert_nil(collector.delivery_age({ last_delivery_tick = 100 }))
end)

test("passes: change log, removed stations, stable starved set", function()
	scenario()
	pass()
	local log = storage.manager.collect_log
	assert_eq(log, { epoch = 1, base = 0, ids = { 1, 2, 3, 4, 6 } })
	assert_eq({ collector.log_position() }, { 1, 5 })
	local starved = collector.get().starved
	-- The next cycle publishes an equal set in a new table: the snapshot keeps its own.
	storage.economy.starved = { ["signal-A:coal"] = true, ["signal-B:coal"] = true, ["signal-A:copper-ore"] = true }
	game.tick = 1100
	pass()
	log = storage.manager.collect_log
	assert_eq(log, { epoch = 1, base = 5, ids = { 1, 2, 3, 4, 6 } })
	assert_eq({ select(2, collector.changed_since(1, 5)) }, { 1, 5 })
	assert_nil(collector.changed_since(1, 0))
	local snap = collector.get()
	assert_same(snap.starved, starved)
	assert_eq(snap.starved_version, 1)
	assert_eq(snap.tick, 1100)
	storage.stations[3] = nil
	pass()
	snap = collector.get()
	assert_eq(storage.manager.collect_log.ids, { 1, 2, 4, 6, 3 })
	assert_nil(snap.stations[3])
	assert_eq(snap.station_count, 4)
	assert_eq(snap.starved_version, 1)
	storage.stations[2] = nil
	storage.economy.starved = { ["signal-A:coal"] = true, ["signal-B:coal"] = true }
	pass()
	snap = collector.get()
	assert_eq(snap.starved, { ["signal-A:coal"] = true, ["signal-B:coal"] = true })
	assert_eq(snap.starved_items, { coal = true })
	assert_eq(snap.starved_version, 2)
end)

test("empty starved sets compare equal, so the version stays 0", function()
	mod_settings = {}
	manager()
	storage.stations, storage.trains, storage.depots = {}, {}, {}
	pass()
	local snap = collector.get()
	assert_eq(snap.tick, 0)
	assert_eq(snap.starved_version, 0)
	assert_eq(snap.station_count, 0)
end)

test("step: unbudgeted steps list, then summarise trains, then collect a batch", function()
	scenario()
	assert_false(collector.step())
	local b = storage.manager.snapshot_build
	assert_eq(b.ids, { 1, 2, 3, 4, 5, 6 })
	assert_eq(b.i, 0)
	assert_true(b.trains_pending)
	assert_eq(collector.get().train_count, 0)
	assert_false(collector.step())
	assert_nil(b.trains_pending)
	assert_eq(collector.get().train_count, 2)
	-- Six stations fit in the minimum batch of 25.
	assert_true(collector.step())
	assert_nil(storage.manager.snapshot_build)
	assert_same(storage.manager.snapshot, b)
	assert_nil(b.ids)
	assert_nil(b.seen)
	assert_nil(b.r_keys)
end)

test("step: a budget covers listing and trains in the same call", function()
	scenario()
	assert_false(collector.step(2))
	local b = storage.manager.snapshot_build
	assert_eq(b.i, 2)
	assert_eq(H.keys(collector.get().stations), { 1, 2 })
	assert_false(collector.step(3))
	assert_eq(b.i, 5)
	assert_true(collector.step(3))
	assert_eq(collector.get().station_count, 5)
end)

test("step: stations removed mid-pass are skipped", function()
	scenario()
	collector.step(1)
	storage.stations[2] = nil
	pass()
	assert_eq(collector.get().station_count, 4)
	assert_nil(collector.get().stations[2])
end)

test("batch size: ceil(n / 20) clamped to 25..200", function()
	mod_settings = {}
	manager()
	storage.trains, storage.depots = {}, {}
	storage.stations = {}
	for i = 1, 1000 do
		storage.stations[i] = { entity_stop = stop("S" .. i), entity_comb1 = comb(WORKING, {}), network_name = "signal-A", network_mask = 1, secondary_inv_combs = {} }
	end
	collector.step()
	collector.step()
	collector.step()
	assert_eq(storage.manager.snapshot_build.i, 50)
	for i = 101, 1000 do storage.stations[i] = nil end
	storage.manager.snapshot_build = nil
	collector.step()
	collector.step()
	collector.step()
	assert_eq(storage.manager.snapshot_build.i, 25)
	for i = 101, 5000 do
		storage.stations[i] = { entity_stop = stop("S" .. i), entity_comb1 = comb(WORKING, {}), network_name = "signal-A", network_mask = 1, secondary_inv_combs = {} }
	end
	storage.manager.snapshot_build = nil
	collector.step()
	collector.step()
	collector.step()
	assert_eq(storage.manager.snapshot_build.i, 200)
end)

-- Opening never collects synchronously; a missing or stale snapshot gets a boosted pass instead.
test("ensure_fresh: never collected or older than 600 ticks boosts the next passes, nothing synchronous", function()
	scenario()
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	collector.ensure_fresh()
	assert_nil(collector.get().tick)
	assert_eq(storage.manager.collect_boost, 1000)
	assert_nil(storage.manager.collect_quiet)
	assert_eq(collector.collecting(), 0)
	-- Not on the open's own tick, which carried its first render.
	assert_false(collector.boost_tick())
	assert_nil(storage.manager.snapshot_build)
	-- The first boosted step lists the stations and summarises the trains, with no stations on top.
	assert_false(collector.boost_tick(true))
	assert_nil(collector.get().tick)
	assert_eq(collector.collecting(), 0)
	-- Six stations fit the next boosted step (2 x the minimum batch).
	assert_true(collector.boost_tick(true))
	assert_eq(collector.get().tick, 1000)
	assert_nil(storage.manager.collect_boost)
	assert_nil(collector.collecting())
	game.tick = 1600
	collector.ensure_fresh()
	assert_nil(storage.manager.collect_boost)
	game.tick = 1601
	collector.ensure_fresh()
	-- A complete snapshot is refreshed quietly: no placeholders, no note.
	assert_eq(storage.manager.collect_boost, 1601)
	assert_true(storage.manager.collect_quiet)
	assert_nil(collector.collecting())
	assert_eq(collector.get().tick, 1000)
	-- A pass in progress that started long ago is dropped; a recent one is kept and boosted.
	storage.manager.snapshot_build = { started_tick = 1000, stale = true }
	collector.ensure_fresh()
	assert_nil(storage.manager.snapshot_build)
	collector.step()
	local b = storage.manager.snapshot_build
	collector.ensure_fresh()
	assert_same(storage.manager.snapshot_build, b)
end)

test("collecting: progress of the boosted pass", function()
	scenario()
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	for id = 7, 106 do
		storage.stations[id] = { entity_stop = stop("S" .. id), entity_comb1 = comb(WORKING, {}), network_name = "signal-A", network_mask = 1, secondary_inv_combs = {} }
	end
	collector.ensure_fresh()
	-- 106 stations: default batch 25, boosted 100, after a first step that only lists them and the trains.
	assert_false(collector.step(nil, 4))
	assert_eq(collector.collecting(), 0)
	assert_false(collector.step(nil, 4))
	assert_eq(collector.collecting(), 100 / 106)
	assert_true(collector.boost_tick(true))
	assert_eq(collector.get().tick, 1000)
	assert_nil(collector.collecting())
end)

-- The opening boost steps on every tick from its own handler; the manager update leaves it alone.
test("boost_tick: a no-op without a boost or a wanted window; one step per call; completion owes renders", function()
	scenario()
	assert_false(collector.boost_tick())
	assert_nil(storage.manager.snapshot_build)
	storage.manager.collect_boost = 999
	assert_false(collector.boost_tick())
	assert_nil(storage.manager.snapshot_build, "no window wants data")
	storage.manager.players[1] = { cache = {}, is_manager_open = true, paused = true, rendered_snapshot_tick = 5 }
	assert_false(collector.boost_tick())
	assert_nil(storage.manager.snapshot_build, "paused with data shown")
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	-- The manager update neither steps nor runs the lint job while the boost runs.
	assert_false(collector.tick())
	assert_nil(storage.manager.snapshot_build)
	storage.manager.collect_boost = 1000
	assert_false(collector.boost_tick(), "the open's tick")
	assert_nil(storage.manager.snapshot_build)
	game.tick = 1001
	assert_false(collector.boost_tick())
	local b = storage.manager.snapshot_build
	assert_not_nil(b)
	assert_eq(b.i, 0)
	assert_false(collector.tick())
	assert_eq(b.i, 0)
	assert_nil(storage.manager.settle)
	game.tick = 1002
	assert_true(collector.boost_tick())
	assert_eq(collector.get().tick, 1002)
	assert_true(collector.get().boosted)
	assert_eq(storage.manager.settle, 4)
	assert_nil(storage.manager.collect_boost)
	assert_nil(storage.manager.collect_quiet)
	-- Nor while the renders after it are owed: they run on those ticks.
	assert_false(collector.tick())
	assert_nil(storage.manager.snapshot_build)
	-- Without a boost the manager update collects at 1x again.
	storage.manager.settle = nil
	assert_true(collector.tick())
	assert_not_nil(storage.manager.snapshot_build)
end)

test("collecting_note: only once a cold boost has run NOTE_TICKS, never for a quiet one", function()
	scenario()
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	collector.ensure_fresh()
	assert_eq(collector.collecting(), 0)
	assert_nil(collector.collecting_note())
	game.tick = 1000 + collector.NOTE_TICKS - 1
	assert_nil(collector.collecting_note())
	game.tick = 1000 + collector.NOTE_TICKS
	assert_eq(collector.collecting_note(), 0)
	storage.manager.collect_boost = 1000
	storage.manager.collect_quiet = true
	assert_nil(collector.collecting())
	assert_nil(collector.collecting_note())
end)

test("on_last_close: keeps the snapshot KEEP_TICKS, release_due frees it at the deadline, a reopen cancels it", function()
	scenario()
	assert_eq(collector.KEEP_TICKS, 7200)
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	pass()
	local snap = collector.get()
	snap.boosted = true
	local log = storage.manager.collect_log
	local parts = storage.manager.name_parts
	assert_not_nil(parts)
	storage.manager.lint = { job = {}, occupancy_since = { 1 }, phantom_since = { 1 } }
	-- Still open: nothing happens.
	collector.on_last_close()
	assert_nil(storage.manager.release_at)
	storage.manager.players[1].is_manager_open = false
	storage.manager.snapshot_build = { started_tick = 990 }
	storage.manager.collect_boost = 990
	storage.manager.collect_quiet = true
	storage.manager.settle = 2
	collector.on_last_close()
	assert_same(collector.get(), snap)
	assert_nil(snap.boosted, "a kept snapshot never defers a first build")
	assert_same(storage.manager.collect_log, log)
	assert_same(storage.manager.name_parts, parts)
	assert_nil(storage.manager.snapshot_build)
	assert_nil(storage.manager.collect_boost)
	assert_nil(storage.manager.collect_quiet)
	assert_nil(storage.manager.settle)
	assert_nil(storage.manager.lint.job)
	assert_eq(storage.manager.lint.occupancy_since, {})
	storage.manager.lint = nil
	assert_eq(storage.manager.release_at, 1000 + 7200)
	-- Kept but not live: a panel reads the stop itself.
	assert_nil(collector.live())
	game.tick = 1000 + 7199
	collector.release_due()
	assert_same(collector.get(), snap)
	game.tick = 1000 + 7200
	collector.release_due()
	assert_eq(collector.get(), collector.empty())
	assert_nil(storage.manager.release_at)
	assert_nil(storage.manager.name_parts)
	assert_nil(storage.manager.collect_spare)
	assert_true(storage.manager.collect_log.epoch > log.epoch)
	-- Reopened inside the grace period: the deadline goes, the kept rows are refreshed quietly.
	pass()
	snap = collector.get()
	collector.on_last_close()
	assert_eq(storage.manager.release_at, 8200 + 7200)
	game.tick = 8200 + 700
	storage.manager.players[1].is_manager_open = true
	collector.ensure_fresh()
	assert_nil(storage.manager.release_at)
	assert_true(storage.manager.collect_quiet)
	assert_same(collector.live(), snap)
	-- release_due with a window open only forgets a stale deadline.
	storage.manager.release_at = 1
	collector.release_due()
	assert_nil(storage.manager.release_at)
	assert_same(collector.get(), snap)
end)

test("on_last_close: nothing collected yet releases at once", function()
	scenario()
	-- A cold pass that never completed: nothing worth keeping.
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	collector.ensure_fresh()
	collector.boost_tick(true)
	storage.manager.players[1].is_manager_open = false
	collector.on_last_close()
	assert_nil(storage.manager.snapshot_build)
	assert_nil(storage.manager.collect_boost)
	assert_nil(storage.manager.release_at)
	-- A cold open closed on its own tick, before the first step: the boost goes too, so the handler is idle and the
	-- next open starts its own boost (and note delay).
	storage.manager.players[1].is_manager_open = true
	collector.ensure_fresh()
	assert_eq(storage.manager.collect_boost, game.tick)
	storage.manager.settle = 1
	storage.manager.players[1].is_manager_open = false
	collector.on_last_close()
	assert_nil(storage.manager.collect_boost)
	assert_nil(storage.manager.collect_quiet)
	assert_nil(storage.manager.settle)
end)

test("kept Stations query caches: a closed player's goes when another window reopens, every one on init", function()
	scenario()
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	storage.manager.players[2] = { cache = {}, is_manager_open = false }
	pass()
	storage.manager.players[1].is_manager_open = false
	collector.on_last_close()
	storage.manager.players[1].cache.stations = { kept = 1 }
	storage.manager.players[2].cache.stations = { kept = 2 }
	-- Player 1 reopens inside the grace: its own cache stays, the other closed player's goes.
	storage.manager.players[1].is_manager_open = true
	collector.ensure_fresh()
	assert_eq(storage.manager.players[1].cache.stations, { kept = 1 })
	assert_nil(storage.manager.players[2].cache.stations)
	-- A later open with nothing kept leaves caches alone.
	storage.manager.players[2].cache.stations = { kept = 2 }
	collector.ensure_fresh()
	assert_eq(storage.manager.players[2].cache.stations, { kept = 2 })
	storage.manager.settle_tick = 5
	collector.init()
	assert_nil(storage.manager.players[1].cache.stations)
	assert_nil(storage.manager.players[2].cache.stations)
	assert_nil(storage.manager.settle_tick)
end)

test("live: the snapshot only while a window keeps it current", function()
	scenario()
	assert_nil(collector.live())
	pass()
	assert_nil(collector.live(), "no window")
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	assert_same(collector.live(), collector.get())
	storage.manager.players[1] = { cache = {}, is_manager_open = true, paused = true, rendered_snapshot_tick = 1000 }
	assert_nil(collector.live(), "paused: frozen, not current")
	storage.manager.players[1] = { cache = {}, is_manager_open = true }
	storage.manager.snapshot = collector.empty()
	assert_nil(collector.live(), "never collected")
end)

test("aggregate: provided, active requests and incoming deliveries over the accepted stations", function()
	local snapshot = collector.empty()
	snapshot.stations = {
		[1] = {
			provided = { coal = 10 },
			requested = { stone = { count = -5, active = true }, water = { count = -1, active = false } },
			deliveries = { coal = -3, stone = 4 },
			wait = { stone = 30 },
			surface_index = 1,
		},
		[2] = {
			provided = { coal = 5 },
			requested = { stone = { count = -7, active = true } },
			deliveries = { stone = 6 },
			wait = { stone = 20 },
			surface_index = 2,
		},
		[3] = {
			provided = {},
			requested = { stone = { count = -1, active = true } },
			deliveries = {},
			wait = {},
			surface_index = 1,
		},
	}
	assert_eq(collector.aggregate(snapshot, function() return true end), {
		provided = { coal = { count = 15, stations = 2 } },
		requested = { stone = { count = -13, stations = 3, earliest_wait_start = 20 } },
		in_transit = { stone = { count = 10, stations = 2 } },
	})
	assert_eq(collector.aggregate(snapshot, function(st) return st.surface_index == 1 end), {
		provided = { coal = { count = 10, stations = 1 } },
		requested = { stone = { count = -6, stations = 2, earliest_wait_start = 30 } },
		in_transit = { stone = { count = 4, stations = 1 } },
	})
	assert_eq(collector.aggregate(snapshot, function() return false end), { provided = {}, requested = {}, in_transit = {} })
end)

test("thresholds: a request exactly at its threshold is active", function()
	mod_settings = { r_threshold = 500 }
	manager()
	storage.trains, storage.depots = {}, {}
	storage.stations = {
		[1] = {
			entity_stop = stop("R"),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, {
				sig("coal", -500), sig("stone", -499), sig("water", -40, "fluid"), sig(REQUEST_FLUID_THRESHOLD, 40, "virtual"),
			}),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
		},
	}
	pass()
	assert_eq(collector.get().stations[1].requested, {
		coal = { count = -500, threshold = 500, active = true, mask = 1 },
		stone = { count = -499, threshold = 500, active = false, mask = 1 },
		water = { count = -40, threshold = 40, active = true, mask = 1 },
	})
end)

test("alerts: tps 25 rounds ticks per main tick up", function()
	scenario()
	mod_settings.tps = 25
	pass()
	-- ceil(60 / 25) = 3 ticks per main tick, 10 main ticks ago.
	assert_eq(collector.get().alerts[1].since_tick, 970)
end)

-- A pass refills the previous record's subtables in place; every changed input must replace the old value.
test("second pass: changed inputs replace every field of the previous record", function()
	scenario()
	pass()
	local s1, s2, s3 = storage.stations[1], storage.stations[2], storage.stations[3]
	s1.entity_comb1.status = NO_POWER
	s2.entity_comb1.signals = {
		sig("signal-A", 3, "virtual"),
		sig(REQUEST_THRESHOLD, 500, "virtual"),
		sig("iron-ore", -1000),
		sig("copper-ore", -100),
		sig("stone", -700),
		sig("water", -50, "fluid"),
	}
	s2.entity_comb2.signals = { sig(REQUEST_THRESHOLD, 9, "virtual"), sig("stone", -200) }
	s2.deliveries = { stone = 200 }
	s2.request_start_ticks = { stone = 900, ["iron-ore"] = 60 }
	s3.is_warming_up = nil
	storage.economy.starved = { ["signal-A:iron-ore"] = true, ["signal-A:stone"] = true, ["signal-A:coal"] = true,
		["signal-B:coal"] = true }
	game.tick = 1100
	pass()
	local snap = collector.get()

	assert_eq(without_rows(snap.stations[1]), {
		id = 1,
		name = "Iron Mine",
		name_lower = "iron mine",
		name_parts = { text = "Iron Mine" },
		status = "no_power",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		is_p = true,
		is_r = false,
		is_stack = false,
		comb_ok = false,
		warming_up = false,
		trains_limit = 2,
		deliveries_total = 3,
		last_delivery_tick = 700,
		-- With its station combinator off, the planner falls back to the priority setting.
		priority = 0,
		provided = {},
		requested = {},
		deliveries = { ["iron-ore"] = -400 },
		control = {},
		control2 = {},
		thresholds = {},
		wait = {},
		secondary = false,
		secondary_count = 0,
		-- When the record was read, and the lint bitmask (0 before the first lint pass).
		read_tick = 1100,
		lint = 0,
		-- No unserved request at a train limit names the station.
		throttling = false,
		ignored = {},
		sources = { { kind = "station", index = 0, ok = false, priority = 0, network_mask = 1, network_name = "signal-A",
			mask = 1, provided = {}, requested = {}, ignored = {} } },
	})
	local smelter_requested = {
		["iron-ore"] = { count = -1000, threshold = 500, active = true, mask = 3 },
		["copper-ore"] = { count = -100, threshold = 500, active = false, mask = 3 },
		stone = { count = -700, threshold = 200, active = true, mask = 3 },
		water = { count = -50, threshold = 500, active = false, mask = 3 },
	}
	-- Nobody provides either on signal-A.
	local smelter_source = { kind = "station", index = 0, ok = true, priority = 0, network_mask = 3, network_name = "signal-A",
		mask = 3, provided = {}, requested = smelter_requested, ignored = {}, starved = { ["iron-ore"] = true, stone = true } }
	assert_eq(without_rows(snap.stations[2]), {
		id = 2,
		name = "Smelter",
		name_lower = "smelter",
		name_parts = { text = "Smelter" },
		status = "disabled",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 3,
		is_p = false,
		is_r = true,
		is_stack = false,
		comb_ok = true,
		comb2_ok = true,
		warming_up = false,
		trains_limit = 0,
		deliveries_total = 0,
		priority = 0,
		provided = {},
		requested = {
			["iron-ore"] = { count = -1000, threshold = 500, active = true, mask = 3 },
			["copper-ore"] = { count = -100, threshold = 500, active = false, mask = 3 },
			stone = { count = -700, threshold = 200, active = true, mask = 3 },
			water = { count = -50, threshold = 500, active = false, mask = 3 },
		},
		deliveries = { stone = 200 },
		control = { [REQUEST_THRESHOLD] = 500 },
		control2 = { [REQUEST_THRESHOLD] = 9 },
		thresholds = { stone = 200 },
		wait = { stone = 900, ["iron-ore"] = 60 },
		longest_wait_start = 60,
		secondary = false,
		secondary_count = 0,
		-- When the record was read, and the lint bitmask (0 before the first lint pass).
		read_tick = 1100,
		lint = 0,
		-- No unserved request at a train limit names the station.
		throttling = false,
		ignored = {},
		sources = { smelter_source },
	})
	assert_eq(snap.stations[3].warming_up, false)
	assert_eq(snap.stations[3].requested, { stone = { count = -5000, threshold = 2000, active = true, mask = 1 } })

	-- The refilled record still owns its tables: later planner writes must not show through.
	local rec = snap.stations[2]
	assert_true(rec.deliveries ~= s2.deliveries)
	assert_true(rec.wait ~= s2.request_start_ticks)
	assert_true(rec.thresholds ~= s2.item_thresholds)
	s2.deliveries.stone = 999
	s2.request_start_ticks.stone = 1
	assert_eq(rec.deliveries, { stone = 200 })
	assert_eq(rec.wait.stone, 900)

	assert_eq(snap.inventory_all, {
		provided = {},
		requested = {
			["iron-ore"] = { count = -1000, stations = 1, earliest_wait_start = 60 },
			stone = { count = -5700, stations = 2, earliest_wait_start = 900 },
			-- The poll starts the wait of a request it registers for the first time.
			coal = { count = -200, stations = 1, earliest_wait_start = 1000 },
		},
		in_transit = { stone = { count = 200, stations = 1 } },
	})
	assert_eq(snap.starved, {
		["signal-A:iron-ore"] = true,
		["signal-A:stone"] = true,
		["signal-A:coal"] = true,
		["signal-B:coal"] = true,
	})
	assert_eq(snap.starved_items, { ["iron-ore"] = true, stone = true, coal = true })
	assert_eq(snap.starved_version, 2)
	assert_eq(snap.station_count, 5)
	assert_eq(storage.manager.collect_log, { epoch = 1, base = 5, ids = { 1, 2, 3, 4, 6 } })
end)

-- Primary and secondary combinators contributing to the same hashes, each-network secondaries, a stack station with
-- a control combinator and two requesters of one item with different wait starts.
local function merge_scenario()
	mod_settings = { r_threshold = 2000, r_fluid_threshold = 0, tps = 30 }
	manager()
	storage.stations = {
		[1] = {
			entity_stop = stop("Merge"),
			entity_comb1 = comb(WORKING, {
				sig("iron-ore", -80), sig("copper-ore", 40), sig("signal-A", 1, "virtual"), sig(REQUEST_THRESHOLD, 100, "virtual"),
			}),
			secondary_inv_combs = {
				[11] = comb(WORKING, {
					sig("iron-ore", -50),
					sig("copper-ore", 60),
					sig("water", -15, "fluid"),
					sig(REQUEST_THRESHOLD, 40, "virtual"),
					sig(REQUEST_FLUID_THRESHOLD, 10, "virtual"),
					sig(SIGNAL_PRIORITY, 2, "virtual"),
					sig("signal-B", 1, "virtual"),
				}, 11),
				[12] = comb(WORKING, { sig("iron-ore", -30), sig("copper-ore", 5) }, 12),
			},
			network_name = NETWORK_EACH,
			network_mask = { ["signal-A"] = 1 },
			is_p = true,
			is_r = true,
		},
		[2] = {
			entity_stop = stop("Stack"),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, { sig("stone", -150) }),
			entity_comb2 = comb(WORKING, {
				sig("stone", -3),
				sig("iron-plate", 2),
				sig("water", -7, "fluid"),
				sig(REQUEST_THRESHOLD, 4, "virtual"),
			}),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			is_stack = true,
		},
		[3] = {
			entity_stop = stop("Unpowered control"),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, { sig("coal", -10), sig(REQUEST_THRESHOLD, 5, "virtual") }),
			entity_comb2 = comb(NO_POWER, { sig("stone", -3), sig(REQUEST_THRESHOLD, 4, "virtual") }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			request_start_ticks = { coal = 10 },
		},
		[4] = {
			entity_stop = stop("Coal 2"),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, { sig("coal", -20), sig(REQUEST_THRESHOLD, 5, "virtual") }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			request_start_ticks = { coal = 30 },
		},
	}
	storage.trains, storage.depots = {}, {}
	storage.tick_state = STATE_POLL_STATIONS
	game.tick = 1000
end

test("merge: primary and secondaries sum counts, keep the lowest threshold and OR the active flags", function()
	merge_scenario()
	pass()
	local st = collector.get().stations[1]
	assert_eq(st.provided, { ["copper-ore"] = 105 })
	assert_eq(st.requested, {
		-- -80 below 100 (primary), -50 above 40 (first secondary), -30 below 100 (second secondary).
		["iron-ore"] = { count = -160, threshold = 40, active = true },
		-- The secondary's own fluid threshold applies to its fluid requests.
		water = { count = -15, threshold = 10, active = true },
	})
	assert_eq(st.control, { ["signal-A"] = 1, [REQUEST_THRESHOLD] = 100 })
	assert_true(st.comb_ok)
	assert_nil(st.comb2_ok)
	assert_true(st.secondary)
	assert_eq(st.secondary_count, 2)
	assert_eq(collector.get().secondary_count, 1)
end)

test("merge: each-network secondaries key on their own network signals, not on settings signals", function()
	merge_scenario()
	pass()
	local snap = collector.get()
	-- The primary's iron-ore request is below threshold, so only the secondary's signal-B request is keyed; its
	-- priority signal is a setting, not a network.
	assert_eq(snap.request_keys, {
		["signal-B:iron-ore"] = true,
		["signal-B:water"] = true,
		["signal-A:stone"] = true,
		["signal-A:coal"] = true,
	})
end)

test("control combinator: stack stations multiply item thresholds, an unpowered one reads nothing", function()
	merge_scenario()
	pass()
	local snap = collector.get()
	local stack = snap.stations[2]
	assert_true(stack.comb2_ok)
	assert_eq(stack.thresholds, { stone = 150, ["iron-plate"] = 200, water = 7 })
	assert_eq(stack.control2, { [REQUEST_THRESHOLD] = 4 })
	-- The control combinator's 3 stacks of stone override the station's threshold.
	assert_eq(stack.requested, { stone = { count = -150, threshold = 150, active = true, mask = 1 } })
	local unpowered = snap.stations[3]
	assert_false(unpowered.comb2_ok)
	assert_eq(unpowered.thresholds, {})
	assert_eq(unpowered.control2, {})
	assert_eq(unpowered.requested, { coal = { count = -10, threshold = 5, active = true, mask = 1 } })
end)

test("merge: inventory_all keeps the earliest wait start across requesters", function()
	merge_scenario()
	pass()
	assert_eq(collector.get().inventory_all, {
		provided = { ["copper-ore"] = { count = 105, stations = 1 } },
		-- The poll starts the wait of a request it registers for the first time.
		requested = {
			["iron-ore"] = { count = -160, stations = 1, earliest_wait_start = 1000 },
			water = { count = -15, stations = 1, earliest_wait_start = 1000 },
			stone = { count = -150, stations = 1, earliest_wait_start = 1000 },
			coal = { count = -30, stations = 2, earliest_wait_start = 10 },
		},
		in_transit = {},
	})
end)

test("longest_wait_start: the earliest start over active requests, whatever the hash order", function()
	mod_settings = { r_threshold = 10 }
	manager()
	storage.trains, storage.depots = {}, {}
	local function requester(name, waits)
		return {
			entity_stop = stop(name),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, { sig("coal", -100), sig("stone", -100), sig("iron-ore", -5) }),
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
			request_start_ticks = waits,
		}
	end
	-- Both records build `requested` from the same signals in the same order, so they iterate it in the same order
	-- and one of them has its earliest start last.
	storage.stations = {
		[1] = requester("A", { coal = 10, stone = 20, ["iron-ore"] = 1 }),
		[2] = requester("B", { coal = 20, stone = 10, ["iron-ore"] = 1 }),
	}
	pass()
	local snap = collector.get()
	-- iron-ore is below the threshold, so its earlier start does not count.
	assert_eq(snap.stations[1].longest_wait_start, 10)
	assert_eq(snap.stations[2].longest_wait_start, 10)
end)

-- ---------------------------------------------------------------- in-place refill, status, names

test("refill: unchanged inputs keep the record and every subtable, and allocate no new request tables", function()
	scenario()
	pass()
	local snap = collector.get()
	local before = {}
	for id, st in pairs(snap.stations) do
		before[id] = {
			st = st, provided = st.provided, requested = st.requested, deliveries = st.deliveries, control = st.control,
			control2 = st.control2, thresholds = st.thresholds, wait = st.wait, mask = st.network_mask,
			parts = st.name_parts, reqs = H.copy(st.requested),
		}
		before[id].req_tables = {}
		for hash, req in pairs(st.requested) do before[id].req_tables[hash] = req end
	end
	local trains = snap.trains
	local train10, manifest10 = trains[10], trains[10].manifest
	game.tick = 1100
	pass()
	snap = collector.get()
	assert_same(snap.trains, trains)
	assert_same(snap.trains[10], train10)
	assert_same(snap.trains[10].manifest, manifest10)
	for id, b in pairs(before) do
		local st = snap.stations[id]
		assert_same(st, b.st, "record " .. id)
		for _, field in ipairs({ "provided", "requested", "deliveries", "control", "control2", "thresholds", "wait" }) do
			assert_same(st[field], b[field], field .. " of " .. id)
		end
		assert_same(st.network_mask, b.mask, "mask of " .. id)
		assert_same(st.name_parts, b.parts, "name_parts of " .. id)
		assert_eq(st.requested, b.reqs)
		for hash, req in pairs(st.requested) do assert_same(req, b.req_tables[hash]) end
	end
end)

test("refill: removed entries go, new ones arrive, and a changed manifest or mask is copied again", function()
	scenario()
	pass()
	local snap = collector.get()
	local smelter = snap.stations[2]
	local requested = smelter.requested
	local each_mask = snap.stations[4].network_mask
	local s2 = storage.stations[2]
	s2.entity_comb1.signals = { sig(REQUEST_THRESHOLD, 500, "virtual"), sig("iron-ore", -1000), sig("gravel", -900) }
	s2.deliveries = { gravel = 50 }
	storage.stations[4].entity_comb1.signals = {
		sig("stone", -60), sig("coal", -200), sig("signal-A", 1, "virtual"), sig("signal-B", 4, "virtual"),
		sig(REQUEST_THRESHOLD, 2, "virtual"),
	}
	storage.trains[10].manifest = { { name = "coal", count = 1 } }
	local old_manifest = snap.trains[10].manifest
	game.tick = 1100
	pass()
	snap = collector.get()
	assert_same(snap.stations[2], smelter)
	assert_same(smelter.requested, requested)
	assert_eq(smelter.requested, {
		["iron-ore"] = { count = -1000, threshold = 300, active = true, mask = 1 },
		gravel = { count = -900, threshold = 500, active = true, mask = 1 },
	})
	assert_eq(smelter.deliveries, { gravel = 50 })
	assert_eq(smelter.thresholds, { ["iron-ore"] = 300, ["copper-ore|rare"] = 20, ["copper-ore"] = 50 })
	assert_eq(snap.stations[4].network_mask, { ["signal-A"] = 1, ["signal-B"] = 4 })
	assert_true(snap.stations[4].network_mask ~= each_mask)
	assert_true(snap.stations[4].network_mask ~= storage.stations[4].network_mask)
	assert_true(snap.trains[10].manifest ~= old_manifest)
	assert_eq(snap.trains[10].manifest_hashes, { coal = 1 })
	storage.trains[12] = nil
	pass()
	assert_nil(collector.get().trains[12])
	assert_eq(collector.get().train_count, 1)
end)

test("name_parts: parsed on first sight and again only after a rename", function()
	scenario()
	storage.stations[1].entity_stop.backer_name = "[item=iron-ore] Iron Mine [virtual-signal=signal-P]"
	pass()
	local st = collector.get().stations[1]
	assert_eq(st.name_parts, { lead = { "item/iron-ore" }, text = "Iron Mine", tail = { "virtual-signal/signal-P" } })
	assert_eq(st.name_lower, "[item=iron-ore] iron mine [virtual-signal=signal-p]")
	local parts = st.name_parts
	pass()
	assert_same(st.name_parts, parts)
	storage.stations[1].entity_stop.backer_name = "Iron Mine 2"
	pass()
	assert_eq(st.name, "Iron Mine 2")
	assert_eq(st.name_lower, "iron mine 2")
	assert_eq(st.name_parts.text, "Iron Mine 2")
end)

test("name_parts: one shared table per distinct name, dropped with the snapshot", function()
	scenario()
	storage.stations[2].entity_stop.backer_name = storage.stations[1].entity_stop.backer_name
	pass()
	local snap = collector.get()
	assert_same(snap.stations[1].name_parts, snap.stations[2].name_parts)
	assert_same(storage.manager.name_parts[snap.stations[1].name], snap.stations[1].name_parts)
	storage.manager.players = {}
	collector.release_if_unused()
	assert_nil(storage.manager.name_parts)
end)

local function ladder_station(over)
	local st = {
		comb_ok = true, trains_limit = 2, warming_up = false, deliveries_total = 0, network_name = "signal-A",
		network_mask = 1, requested = {}, last_delivery_tick = nil,
	}
	for k, v in pairs(over or {}) do st[k] = v end
	return st
end

test("station_status: the ladder, first match wins", function()
	mod_settings = { tps = 60 }
	storage.total_ticks = 200000
	local starved = { ["signal-A:coal"] = true }
	local coal = { coal = { count = -5, threshold = 1, active = true } }
	local s = collector.station_status
	assert_eq(collector.STATUSES, { "no_power", "disabled", "warming_up", "starved", "saturated", "idle", "ok" })
	-- Each rung beats every rung below it.
	assert_eq(s(ladder_station({ comb_ok = false, trains_limit = 0, warming_up = true, requested = coal }), starved), "no_power")
	assert_eq(s(ladder_station({ trains_limit = 0, warming_up = true, requested = coal }), starved), "disabled")
	assert_eq(s(ladder_station({ warming_up = true, requested = coal, deliveries_total = 5 }), starved), "warming_up")
	assert_eq(s(ladder_station({ requested = coal, deliveries_total = 5 }), starved), "starved")
	assert_eq(s(ladder_station({ deliveries_total = 2 }), starved), "saturated")
	assert_eq(s(ladder_station({ last_delivery_tick = 1 }), starved), "idle")
	assert_eq(s(ladder_station(), starved), "ok")
end)

test("station_status: saturated means deliveries at a finite limit, nothing else", function()
	mod_settings = { tps = 60 }
	storage.total_ticks = 0
	local s = collector.station_status
	assert_eq(s(ladder_station({ trains_limit = 3, deliveries_total = 3 }), {}), "saturated")
	assert_eq(s(ladder_station({ trains_limit = 3, deliveries_total = 4 }), {}), "saturated")
	assert_eq(s(ladder_station({ trains_limit = 3, deliveries_total = 2 }), {}), "ok")
	-- Not saturated: a switched-off stop is disabled, and the no-limit value is not a limit reached.
	assert_eq(s(ladder_station({ trains_limit = 0, deliveries_total = 1 }), {}), "disabled")
	assert_eq(s(ladder_station({ trains_limit = 4294967295, deliveries_total = 9 }), {}), "ok")
	assert_eq(s(ladder_station({ trains_limit = collector.UNLIMITED - 1, deliveries_total = collector.UNLIMITED }), {}), "saturated")
end)

test("station_status: starved needs an active request without a provider on one of its networks", function()
	mod_settings = { tps = 60 }
	storage.total_ticks = 0
	local s = collector.station_status
	local inactive = { coal = { count = -5, threshold = 10, active = false } }
	local active = { coal = { count = -5, threshold = 1, active = true } }
	assert_eq(s(ladder_station({ requested = inactive }), { ["signal-A:coal"] = true }), "ok")
	assert_eq(s(ladder_station({ requested = active }), { ["signal-B:coal"] = true }), "ok")
	assert_eq(s(ladder_station({ network_name = false, requested = active }), { ["signal-A:coal"] = true }), "ok")
	local each = { network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 1, ["signal-C"] = 2 }, requested = active }
	assert_eq(s(ladder_station(each), { ["signal-C:coal"] = true }), "starved")
	assert_eq(s(ladder_station(each), { ["signal-A:coal"] = true }), "ok")
	assert_eq(collector.starved_hashes(ladder_station(each), { ["signal-C:coal"] = true }), { "coal" })
	assert_false(collector.starved_hashes(ladder_station(each), {}))
end)

test("status: set once per pass, and a changed starved set reclassifies and logs the affected stations", function()
	scenario()
	pass()
	local snap = collector.get()
	local status = {}
	for id, st in pairs(snap.stations) do status[id] = st.status end
	-- No train limit set reads as 0, i.e. disabled.
	assert_eq(status, { [1] = "saturated", [2] = "disabled", [3] = "disabled", [4] = "disabled", [6] = "no_power" })
	-- Smelter requests coal on signal-A, which nobody provides.
	storage.stations[2].trains_limit = 3
	storage.stations[4].trains_limit = 3
	game.tick = 1100
	pass()
	assert_eq(collector.get().stations[2].status, "starved")
	-- Providers of coal and copper ore on signal-A appear: the finish of that pass sees the new set and reclassifies.
	storage.stations[1].entity_comb1.signals = { sig("coal", 5000), sig("iron-ore", 500), sig("copper-ore", 500) }
	storage.economy.starved = { ["signal-B:coal"] = true }
	game.tick = 1200
	pass()
	snap = collector.get()
	assert_eq(snap.stations[2].status, "ok")
	-- Each still lacks coal on signal-B.
	assert_eq(snap.stations[4].status, "starved")
	local log = storage.manager.collect_log.ids
	assert_eq(log[#log], 2)
end)

test("fleet: train groups count the depot names of their Cybersyn trains", function()
	scenario()
	storage.trains[10].entity.group = "G"
	storage.trains[12].entity.group = "G"
	storage.trains[12].depot_id = 100
	storage.trains[13] = { entity = { valid = true, group = "H", front_stock = { surface_index = 1 } }, depot_id = 100,
		network_name = "signal-A", network_mask = 1, status = STATUS_D }
	storage.depots[101].entity_stop = { valid = true, backer_name = "Depot 2", trains_limit = 1, trains_count = 0 }
	storage.trains[13].depot_id = 101
	pass()
	local snap = collector.get()
	assert_eq(snap.fleet.group_depots, { G = 1, H = 1 })
	assert_eq({ snap.trains[10].in_group, snap.trains[10].group, snap.trains[13].group }, { true, "G", "H" })
	storage.trains[13].entity.group = "G"
	pass()
	assert_eq(collector.get().fleet.group_depots, { G = 2 })
end)

test("fleet: a Cybersyn train whose depot has no name does not count as another depot name", function()
	scenario()
	storage.trains[10].entity.group = "G"
	storage.trains[12].entity.group = "G"
	pass()
	local snap = collector.get()
	assert_eq(snap.trains[12].depot_name, "")
	assert_eq(snap.fleet.group_depots, { G = 1 })
end)

test("provider keys: the providers' masks OR-ed and their lowest item threshold per network:item", function()
	scenario()
	storage.stations[1].entity_comb2 = comb(WORKING, { sig("iron-ore", 300), sig("water", 1500, "fluid") })
	storage.stations[5].entity_comb1 = comb(WORKING, { sig("iron-ore", 900), sig("signal-A", 2, "virtual") })
	storage.stations[5].entity_comb2 = comb(WORKING, { sig("iron-ore", 200) })
	pass()
	local snap = collector.get()
	assert_eq(snap.provider_masks["signal-A:iron-ore"], 3)
	assert_eq(snap.provider_overrides, { ["signal-A:iron-ore"] = 200, ["signal-A:water"] = 1500 })
	-- In stack mode an item threshold counts stacks; fluids keep their units.
	storage.stations[5].is_stack = true
	storage.stations[5].entity_comb2.signals = { sig("iron-ore", 2) }
	pass()
	assert_eq(collector.get().provider_overrides["signal-A:iron-ore"], 2 * get_stack_size(nil, "iron-ore"))
end)

test("secondary combinator on one network: its own mask for what it provides and requests", function()
	scenario()
	-- Station 6 (signal-B, mask 1): its secondary carries signal-B = 2, as the planner reads it for that combinator.
	storage.stations[6].entity_comb1 = comb(WORKING, { sig("iron-plate", 999) })
	storage.stations[6].secondary_inv_combs = {
		[61] = comb(WORKING, { sig("coal", 100), sig("copper-plate", -30), sig("signal-B", 2, "virtual"),
			sig(REQUEST_THRESHOLD, 20, "virtual") }, 61),
	}
	pass()
	local snap = collector.get()
	assert_eq(snap.provider_masks["signal-B:coal"], 2)
	assert_eq(snap.provider_masks["signal-B:iron-plate"], 1)
	assert_eq(snap.stations[6].requested["copper-plate"].mask, 2)
end)

test("economy_starved: this stop's active requests in the published set, whatever the planner's phase", function()
	local collector = H.load("scripts.gui.collector")
	local st = { requested = { a = { active = true }, b = { active = true }, c = { active = false } } }
	local nets = { { name = "signal-A" } }
	storage.economy = { starved = { ["signal-A:a"] = true, ["signal-A:c"] = true, ["signal-B:b"] = true } }
	storage.tick_state = STATE_INIT
	assert_eq(collector.economy_starved(st, nets), { ["signal-A:a"] = true })
	storage.tick_state = STATE_DISPATCH
	assert_eq(collector.economy_starved(st, nets), { ["signal-A:a"] = true })
	storage.economy, storage.tick_state = nil, nil
end)

-- What each station advertises per network name + mask, on the patterns of a large real base.
local function inventories_scenario()
	mod_settings = { r_threshold = 2000, r_fluid_threshold = 0, tps = 30, priority = 0 }
	manager()
	-- Station 16 provides sulfur and coke on signal-A only.
	storage.economy.starved = { ["signal-A:coal"] = true, ["signal-A:stone"] = true, ["signal-A:copper-plate"] = true,
		["signal-B:sulfur"] = true }
	storage.stations = {
		-- (a) one network, no secondaries.
		[11] = {
			entity_stop = stop("Plain"),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, { sig("iron-plate", 100), sig("coal", -5000), sig("signal-A", 1, "virtual") }, 110),
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
			is_r = true,
			trains_limit = 1,
		},
		-- (b) the naphthalene pattern: Provide only, three masks; listed by position, not by unit number.
		[12] = {
			entity_stop = stop("Naphthalene"),
			entity_comb1 = comb(WORKING, {
				sig("naphthalene-oil", 5000, "fluid"), sig("signal-A", 1, "virtual"), sig(SIGNAL_PRIORITY, 1, "virtual"),
			}, 120),
			secondary_inv_combs = {
				[502] = comb(WORKING, { sig("liquid-fuel", -866, "fluid"), sig("signal-A", 4, "virtual") }, 502),
				[501] = comb(WORKING, { sig("liquid-fuel", 2000, "fluid"), sig("signal-A", 3, "virtual") }, 501),
			},
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
		},
		-- (c) Request only with a secondary carrying positives.
		[13] = {
			entity_stop = stop("Requester"),
			entity_comb1 = comb(WORKING, { sig("stone", -3000) }, 130),
			secondary_inv_combs = {
				[601] = comb(WORKING, { sig("iron-plate", 400), sig("copper-plate", -2500), sig("signal-A", 2, "virtual"),
					sig(SIGNAL_PRIORITY, 7, "virtual") }, 601),
			},
			network_name = "signal-A",
			network_mask = 1,
			is_r = true,
		},
		-- (d) a secondary without a network signal shares the station combinator's mask.
		[14] = {
			entity_stop = stop("Merged"),
			entity_comb1 = comb(WORKING, { sig("iron-ore", 100) }, 140),
			secondary_inv_combs = { [701] = comb(WORKING, { sig("iron-ore", 50), sig("wood", 10) }, 701) },
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
		},
		-- (e) NETWORK_EACH: the secondary requests on a network the station combinator does not name.
		[15] = {
			entity_stop = stop("Each"),
			entity_comb1 = comb(WORKING, { sig("coke", -3000), sig("signal-A", 1, "virtual") }, 150),
			secondary_inv_combs = {
				[801] = comb(WORKING, { sig("sulfur", -3000), sig("signal-B", 2, "virtual"), sig(REQUEST_THRESHOLD, 5, "virtual") }, 801),
			},
			network_name = NETWORK_EACH,
			network_mask = { ["signal-A"] = 1 },
			is_r = true,
			trains_limit = 1,
		},
		-- Provides sulfur and coke on signal-A only.
		[16] = {
			entity_stop = stop("Sulfur"),
			secondary_inv_combs = {},
			entity_comb1 = comb(WORKING, { sig("sulfur", 9000), sig("coke", 9000) }, 160),
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
		},
		-- (f) a removed secondary still listed next to a live one.
		[17] = {
			entity_stop = stop("Stale"),
			entity_comb1 = comb(WORKING, { sig("brick", 10) }, 170),
			secondary_inv_combs = { [1] = { valid = false }, [901] = comb(LOW_POWER, { sig("brick", 5) }, 901) },
			network_name = "signal-A",
			network_mask = 1,
			is_p = true,
		},
	}
	storage.trains, storage.depots = {}, {}
	storage.tick_state = STATE_POLL_STATIONS
	game.tick = 1000
end

--- The row of `st` as plain fields (no back references), for comparisons.
local function row_fields(row)
	return { key = row.key, index = row.index, unit = row.unit, kind = row.kind, priority = row.priority, ok = row.ok,
		read = row.read, network_name = row.network_name, mask = row.mask, networks = row.networks,
		provided = row.provided, requested = row.requested, ignored = row.ignored, starved = row.starved }
end

local function rows_of(st)
	local out = {}
	for i, row in ipairs(collector.inventories(st)) do
		assert_same(row.st, st, "row " .. i .. " st")
		assert_same(row.src, st.sources[i], "row " .. i .. " src")
		assert_eq(row.label, collector.source_label(st.sources[i]), "row " .. i .. " label")
		out[i] = row_fields(row)
	end
	return out
end

test("inventories (a): one network, no secondaries: one row on the record's own lists", function()
	inventories_scenario()
	pass()
	local st = collector.get().stations[11]
	assert_same(collector.inventories(st), st.rows)
	local coal = { count = -5000, threshold = 2000, active = true, mask = 1 }
	assert_eq(rows_of(st), { {
		key = "11@110", index = 0, unit = 110, kind = "station", priority = 0, ok = true, read = true,
		network_name = "signal-A", mask = 1, provided = { ["iron-plate"] = 100 }, requested = { coal = coal }, ignored = {},
		-- Coal is provided nowhere.
		starved = { coal = true },
	} })
	assert_same(st.rows[1].provided, st.provided)
	assert_same(st.rows[1].requested, st.requested)
	assert_same(st.rows[1].ignored, st.ignored)
	assert_same(st.rows[1].starved, st.sources[1].starved)
	assert_eq(collector.row_key(st, st.sources[1]), "11@110")
	assert_eq(st.status, "starved")
end)

test("inventories (b): naphthalene: one row per combinator in unit order, each with its own mask; totals are sums", function()
	inventories_scenario()
	pass()
	local st = collector.get().stations[12]
	assert_eq(rows_of(st), {
		{ key = "12@120", index = 0, unit = 120, kind = "station", priority = 1, ok = true, read = true,
			network_name = "signal-A", mask = 1, provided = { ["naphthalene-oil"] = 5000 }, requested = {}, ignored = {} },
		{ key = "12@501", index = 1, unit = 501, kind = "inventory", priority = 1, ok = true, read = true,
			network_name = "signal-A", mask = 3, provided = { ["liquid-fuel"] = 2000 }, requested = {}, ignored = {} },
		{ key = "12@502", index = 2, unit = 502, kind = "inventory", priority = 1, ok = true, read = true,
			network_name = "signal-A", mask = 4, provided = {}, requested = {}, ignored = { ["liquid-fuel"] = -866 } },
	})
	assert_true(st.rows[1].provided ~= st.provided, "with an inventory read the station combinator has lists of its own")
	assert_eq(st.provided, { ["naphthalene-oil"] = 5000, ["liquid-fuel"] = 2000 })
	assert_eq(st.requested, {})
	assert_eq(st.ignored, { ["liquid-fuel"] = -866 })
	assert_eq(st.secondary_count, 2)
	assert_eq(collector.get().provider_masks["signal-A:liquid-fuel"], 3)
	assert_eq({ st.sources[2].network_mask, st.sources[3].network_mask }, { 3, 4 })
end)

test("inventories (c): a Request only station ignores its secondary's positives; starved per row", function()
	inventories_scenario()
	pass()
	local st = collector.get().stations[13]
	local rows = rows_of(st)
	assert_eq(rows[1].requested, { stone = { count = -3000, threshold = 2000, active = true, mask = 1 } })
	assert_eq(rows[2], { key = "13@601", index = 1, unit = 601, kind = "inventory", priority = 7, ok = true, read = true,
		network_name = "signal-A", mask = 2, provided = {}, ignored = { ["iron-plate"] = 400 },
		requested = { ["copper-plate"] = { count = -2500, threshold = 2000, active = true, mask = 2 } },
		starved = { ["copper-plate"] = true } })
	assert_eq(rows[1].starved, { stone = true })
	assert_eq(rows[1].priority, 0, "the station combinator keeps the station's priority")
	local hashes = collector.starved_hashes(st, collector.get().starved)
	table.sort(hashes)
	assert_eq(hashes, { "copper-plate", "stone" })
end)

test("inventories (d): two combinators on one mask stay two rows; the station total is their sum", function()
	inventories_scenario()
	pass()
	local st = collector.get().stations[14]
	local rows = rows_of(st)
	assert_eq(#rows, 2)
	assert_eq({ rows[1].mask, rows[2].mask }, { 1, 1 })
	assert_eq(rows[1].provided, { ["iron-ore"] = 100 })
	assert_eq(rows[2].provided, { ["iron-ore"] = 50, wood = 10 })
	assert_eq(st.provided, { ["iron-ore"] = 150, wood = 10 })
	assert_true(st.rows[1].provided ~= st.provided)
end)

test("inventories (e): NETWORK_EACH: each row carries its own networks and its own starved check", function()
	inventories_scenario()
	pass()
	local snap = collector.get()
	local st = snap.stations[15]
	local rows = rows_of(st)
	assert_eq({ rows[1].network_name, rows[1].mask, rows[1].networks }, { NETWORK_EACH, nil, { ["signal-A"] = 1 } })
	assert_same(st.rows[1].networks, st.network_mask)
	assert_eq({ rows[2].network_name, rows[2].mask, rows[2].networks }, { NETWORK_EACH, nil, { ["signal-B"] = 2 } })
	assert_same(st.rows[2].networks, st.sources[2].network_mask)
	assert_eq(rows[1].requested, { coke = { count = -3000, threshold = 2000, active = true } })
	assert_eq(rows[2].requested, { sulfur = { count = -3000, threshold = 5, active = true } })
	-- Station 16 provides sulfur on signal-A only: the secondary's signal-B request is starved, coke on signal-A is not.
	assert_true(snap.starved["signal-B:sulfur"])
	assert_nil(rows[1].starved)
	assert_eq(rows[2].starved, { sulfur = true })
	assert_eq(st.status, "starved")
	assert_eq(collector.starved_hashes(st, snap.starved), { "sulfur" })
end)

test("inventories (f): an invalid secondary is skipped, the live one keeps index 1", function()
	inventories_scenario()
	pass()
	local st = collector.get().stations[17]
	local rows = rows_of(st)
	assert_eq(#rows, 2)
	assert_eq({ rows[2].key, rows[2].index, rows[2].mask, rows[2].provided }, { "17@901", 1, 1, { brick = 5 } })
	assert_eq(st.provided, { brick = 15 })
	assert_eq(st.secondary_count, 1)
end)

test("inventories: a NETWORK_EACH station naming no network; an unpowered inventory is still a row", function()
	inventories_scenario()
	storage.stations[15].entity_comb1.signals = { sig("coke", -3000) }
	storage.stations[15].secondary_inv_combs[801].status = NO_POWER
	pass()
	local st = collector.get().stations[15]
	local rows = rows_of(st)
	assert_eq(#rows, 2)
	assert_eq(rows[1].networks, {})
	assert_false(rows[2].ok)
	assert_nil(rows[2].networks)
	assert_eq(rows[2].provided, {})
	assert_eq(rows[2].requested, {})
	assert_nil(st.sources[2].network_mask)
end)

test("inventories: a working station combinator without input leaves its inventories unread, empty rows", function()
	inventories_scenario()
	-- get_signals returns nil for a combinator with nothing on its input wires.
	storage.stations[12].entity_comb1.signals = nil
	pass()
	local st = collector.get().stations[12]
	assert_true(st.comb_ok)
	local rows = rows_of(st)
	assert_eq(#rows, 3)
	for i = 2, 3 do
		assert_true(rows[i].ok)
		assert_false(rows[i].read)
		assert_eq({ rows[i].network_name, rows[i].mask }, { "signal-A", nil })
		assert_eq({ rows[i].provided, rows[i].requested, rows[i].ignored }, { {}, {}, {} })
		assert_nil(st.sources[i].network_mask)
	end
	assert_same(st.rows[1].provided, st.provided)
	assert_eq(st.provided, {})
	assert_eq(st.requested, {})
	assert_false(st.secondary)
end)

test("inventories: refills keep every table; a secondary appearing or going switches the station row's lists", function()
	inventories_scenario()
	pass()
	local snap = collector.get()
	local plain, naph = snap.stations[11], snap.stations[12]
	local function tables()
		return {
			plain.rows, plain.rows[1], plain.sources, plain.sources[1], plain.ignored, naph.rows, naph.rows[1],
			naph.rows[2], naph.rows[3], naph.rows[1].provided, naph.rows[2].provided, naph.rows[3].ignored,
			naph.rows[3].label, naph.sources, naph.sources[3],
		}
	end
	local keep = tables()
	game.tick = 1100
	pass()
	snap = collector.get()
	plain, naph = snap.stations[11], snap.stations[12]
	local again = tables()
	for i = 1, #keep do assert_same(again[i], keep[i], "table " .. i) end

	-- A secondary added to the plain station gives the station combinator lists of its own.
	local plain_station = storage.stations[11]
	plain_station.secondary_inv_combs = { [111] = comb(WORKING, { sig("iron-plate", 5) }, 111) }
	pass()
	plain = collector.get().stations[11]
	assert_eq(#plain.rows, 2)
	assert_true(plain.rows[1].provided ~= plain.provided)
	assert_eq(plain.rows[1].provided, { ["iron-plate"] = 100 })
	assert_eq(plain.rows[2].provided, { ["iron-plate"] = 5 })
	assert_eq(plain.provided, { ["iron-plate"] = 105 })
	assert_eq(plain.rows[2].key, "11@111")
	-- And removed again, it shares them once more.
	plain_station.secondary_inv_combs = {}
	pass()
	plain = collector.get().stations[11]
	assert_eq(#plain.rows, 1)
	assert_same(plain.rows[1].provided, plain.provided)
	assert_same(plain.rows[1].requested, plain.requested)
	assert_eq(plain.provided, { ["iron-plate"] = 100 })

	-- The naphthalene station's mask-4 inventory moves to mask 3: still its own row.
	storage.stations[12].secondary_inv_combs[502].signals = { sig("liquid-fuel", -866, "fluid"), sig("signal-A", 3, "virtual") }
	pass()
	naph = collector.get().stations[12]
	assert_eq(#naph.rows, 3)
	assert_eq({ naph.rows[2].mask, naph.rows[3].mask }, { 3, 3 })
	assert_eq(naph.rows[3].ignored, { ["liquid-fuel"] = -866 })
end)

test("inventories: read_station fills the same rows for a stop read live", function()
	inventories_scenario()
	poll()
	local st = collector.read_station(12)
	assert_eq(#st.rows, 3)
	assert_eq(st.rows[3].ignored, { ["liquid-fuel"] = -866 })
	local rows = st.rows
	assert_same(collector.read_station(12, st), st)
	assert_same(st.rows, rows)
	assert_eq(#st.rows, 3)
end)

test("economy_starved: a row's own network counts, whatever networks the caller names", function()
	local coal, sulfur = { active = true }, { active = true }
	local st = {
		requested = { coal = coal },
		rows = {
			{ network_name = "signal-A", mask = 1, requested = { coal = coal } },
			{ network_name = NETWORK_EACH, networks = { ["signal-B"] = 2 }, requested = { sulfur = sulfur } },
		},
	}
	storage.economy = { starved = { ["signal-A:coal"] = true, ["signal-B:sulfur"] = true } }
	assert_eq(collector.economy_starved(st, { { name = "signal-A" } }), { ["signal-A:coal"] = true, ["signal-B:sulfur"] = true })
	assert_eq(collector.economy_starved(st), { ["signal-A:coal"] = true, ["signal-B:sulfur"] = true })
	storage.economy = nil
end)

test("mask labels: the value", function()
	assert_eq(collector.mask_label(3), "3")
	assert_eq(collector.mask_label(0), "0")
end)

test("source_label on hand-built records", function()
	assert_eq(collector.source_label({ kind = "station", index = 0 }), { "cybersyn-gui.source-station" })
	assert_eq(collector.source_label({ kind = "inventory", index = 2 }), { "cybersyn-gui.source-inventory", 2 })
end)
