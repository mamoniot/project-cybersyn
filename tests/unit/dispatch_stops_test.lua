-- Dispatch per stop: a secondary inventory combinator is matched with its own thresholds, reservation and networks,
-- not its station's. Driven through the real poll and dispatch, create_manifest, create_delivery and tick_init.

local H = require("harness")
local F = require("planner_fixtures")
local sig, station, world, pass, NET = F.sig, F.station, F.world, F.pass, F.NET

local with_globals = F.with_globals

local ANY_ROUTE = { Surfaces = { find_surface_connections_masked = function() return {} end } }

--- One pass with a requester whose inventory asks for 900 iron plates at `inv_threshold`, against a provider holding
--- 500. Returns whether the provider was locked as below the threshold (display bit 4), the train check being
--- reached otherwise.
local function provider_locked(inv_threshold, station_threshold)
	H.fresh()
	local own = { list = { NET } }
	if station_threshold then own.list[2] = sig(REQUEST_THRESHOLD, station_threshold, "virtual") end
	local inv = { list = { sig(REQUEST_THRESHOLD, inv_threshold, "virtual"), sig("iron-plate", -900) } }
	local req = station(100, own, { [201] = inv }, { is_p = false })
	local prov = station(300, { list = { NET, sig("iron-plate", 500) } }, nil, { is_r = false })
	local map_data = world({ req, prov })
	with_globals(ANY_ROUTE, function() pass(map_data) end)
	return bit32.band(prov.display_state, 4) > 0
end

test("an inventory's request threshold sets the provider minimum, below and above the station's", function()
	assert_false(provider_locked(100), "inventory 100, station 1000: a provider with 500 qualifies")
	assert_true(provider_locked(800, 100), "inventory 800, station 100: a provider with 500 is below it")
	assert_false(provider_locked(400, 100), "both below the stock")
end)

--- create_manifest for a requester stop asking for iron and water with its own thresholds, from a provider stop with
--- plenty of both, on a train of one 40-slot cargo wagon and one 25000 fluid wagon.
local function manifest_for(p_stop_reserved, p_station_reserved)
	mod_settings = {}
	local requests = { sig("iron-plate", -500), sig("water", -50000, "fluid") }
	local map_data = {
		stations = {
			[1] = { deliveries = {}, r_threshold = 2000, r_fluid_threshold = 60000 },
			[2] = { locked_slots = 0, reserved_fluid_capacity = p_station_reserved },
		},
		trains = {
			[7] = {
				item_slot_capacity = 40,
				fluid_capacity = 25000,
				entity = { valid = true, cargo_wagons = { {} }, fluid_wagons = { {} } },
			},
		},
	}
	local r_stop = { station_id = 1, tick_signals = requests, r_threshold = 100, r_fluid_threshold = 1000,
		requested = { ["iron-plate"] = 100, water = 1000 } }
	local p_stop = { station_id = 2, item_p_counts = { ["iron-plate"] = 500, water = 100000 },
		reserved_fluid_capacity = p_stop_reserved }
	local out = {}
	for _, item in ipairs(create_manifest(map_data, r_stop, p_stop, 7, "iron-plate")) do out[item.name] = item.count end
	return out
end

test("create_manifest: the requester stop's thresholds and the provider stop's fluid reservation apply", function()
	assert_eq(manifest_for(1000, 0), { ["iron-plate"] = 500, water = 24000 },
		"stop thresholds below the station's admit both; the stop reserves 1000 of the wagon")
	assert_eq(manifest_for(nil, 5000), { ["iron-plate"] = 500, water = 20000 },
		"a stop without its own reservation uses the station's")
end)

test("an inventory whose stock is covered by pending pickups offers nothing, like a station combinator", function()
	H.fresh()
	local prov = station(300, { list = { NET } }, { [301] = { list = { sig("iron-plate", 500) } } }, { is_r = false })
	prov.deliveries["iron-plate"] = -500
	local req = station(100, { list = { NET, sig("iron-plate", -5000) } }, nil, { is_p = false })
	local map_data = world({ req, prov })
	with_globals(ANY_ROUTE, function() pass(map_data) end)
	assert_nil(map_data.economy.all_p_stops["signal-A:iron-plate"])
	assert_eq(bit32.band(prov.display_state, 4), 0, "no provider-low lamp for a provider with nothing to give")
end)

test("signal-each: an inventory's locked-slots signal is not one of its networks", function()
	H.fresh()
	local inv = { list = { sig("signal-B", 1, "virtual"), sig(LOCKED_SLOTS, 2, "virtual"), sig("iron-plate", -5000) } }
	local req = station(100, { list = {} }, { [201] = inv }, { is_p = false, network_name = NETWORK_EACH })
	local map_data = world({ req })
	pass(map_data)
	local keys = {}
	for key in pairs(map_data.economy.all_r_stops) do keys[#keys + 1] = key end
	assert_eq(keys, { "signal-B:iron-plate" })
end)

test("create_delivery: a multi-item delivery takes its items off the inventory's own networks", function()
	H.fresh()
	local function each_station()
		return {
			entity_stop = { valid = true }, network_name = NETWORK_EACH, network_mask = { ["signal-A"] = 1 },
			deliveries = {}, deliveries_total = 0, display_state = 0, request_start_ticks = {},
		}
	end
	local r_station, p_station = each_station(), each_station()
	local r_stop = { station_id = 1, network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 1 } }
	local p_stop = { station_id = 2, network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 1 } }
	local economy = { all_r_stops = {}, all_p_stops = {} }
	for _, key in ipairs({ "signal-A:copper-plate", "signal-B:copper-plate", "signal-B:iron-plate" }) do
		economy.all_r_stops[key] = { r_stop }
		economy.all_p_stops[key] = { p_stop }
	end
	local map_data = {
		economy = economy,
		stations = { [1] = r_station, [2] = p_station },
		trains = { [7] = { entity = { valid = true }, depot_id = 9, status = STATUS_D } },
		depots = { [9] = { entity_stop = { valid = true } } },
		total_ticks = 1,
	}
	local manifest = { { type = "item", name = "iron-plate", count = 100 }, { type = "item", name = "copper-plate", count = 50 } }
	local stats = package.loaded["scripts.stats"]
	local analytics = package.loaded["scripts.analytics"]
	local record_dispatch = stats.record_dispatch
	stats.record_dispatch = function() end
	analytics.record_delivery_start = function() end
	local noop = function() end
	with_globals({
		remove_available_train = function() return true end,
		set_manifest_schedule = function() return true end,
		set_comb2 = noop, update_display = noop, color_train_by_stop = noop, interface_raise_train_status_changed = noop,
	}, function()
		create_delivery(map_data, 1, 2, 7, manifest, {}, r_stop, p_stop)
	end)
	stats.record_dispatch = record_dispatch
	analytics.record_delivery_start = nil
	assert_eq({ economy.all_p_stops["signal-B:copper-plate"], economy.all_r_stops["signal-B:copper-plate"] }, { nil, nil },
		"the second item is withdrawn on the network the inventory was listed under")
	assert_eq({ p_station.deliveries, r_station.deliveries },
		{ { ["iron-plate"] = -100, ["copper-plate"] = -50 }, { ["iron-plate"] = 100, ["copper-plate"] = 50 } })
end)

--- Loads the remote interface for `fn`, then drops every global it defined.
local function with_remote_interface(fn)
	local before = {}
	for k in pairs(_G) do before[k] = true end
	dofile(H.mod_root .. "/scripts/remote-interface.lua")
	local ok, err = pcall(fn)
	for k in pairs(_G) do
		if not before[k] then _G[k] = nil end
	end
	remote.interfaces["cybersyn"] = nil
	assert(ok, err)
end

test("remote create_manifest: takes station ids and builds from each station combinator's latest poll", function()
	H.fresh()
	local req = station(100, { list = { NET, sig("iron-plate", -3000) } }, nil, { is_p = false })
	local prov = station(300, { list = { NET, sig("iron-plate", 9000) } }, nil, { is_r = false })
	local map_data = world({ req, prov })
	with_globals(ANY_ROUTE, function() pass(map_data) end)
	map_data.trains[7] = {
		is_available = true, item_slot_capacity = 40, fluid_capacity = 0,
		entity = { valid = true, cargo_wagons = { {} }, fluid_wagons = {} },
	}
	storage = map_data
	with_remote_interface(function()
		local manifest = remote.call("cybersyn", "create_manifest", 100, 300, 7)
		assert_eq(#manifest, 1)
		assert_eq({ manifest[1].name, manifest[1].count }, { "iron-plate", 3000 })
		req.primary_stop = nil
		local ok, err = pcall(remote.call, "cybersyn", "create_manifest", 100, 300, 7)
		assert_false(ok)
		assert_true(tostring(err):find("not polled", 1, true) ~= nil, tostring(err))
	end)
end)

test("tick_init: a station built while warm-ups finish keeps its own warm-up", function()
	H.fresh()
	local st = station(100, { list = {} })
	st.is_warming_up = true
	st.entity_stop.connected_rail = {}
	local map_data = world({ st })
	map_data.active_station_ids = {}
	map_data.warmup_station_cycles = { [100] = 1 }
	map_data.total_ticks = 10000
	with_globals({
		-- A handler of the events finishing a warm-up raises builds another station.
		combinator_update = function()
			map_data.stations[500] = station(500, { list = {} }, nil, { is_warming_up = true })
			map_data.warmup_station_cycles[500] = 0
		end,
		interface_raise_tick_init = function() end,
	}, function()
		tick_init(map_data, { warmup_time = 1, tps = 60 })
	end)
	assert_eq({ map_data.active_station_ids, st.is_warming_up, map_data.warmup_station_cycles }, { { 100 }, nil, { [500] = 0 } })
end)

test("a network's last stale available train takes its table with it", function()
	H.fresh()
	local req = station(100, { list = { NET, sig("iron-plate", -3000) } }, nil, { is_p = false })
	local prov = station(300, { list = { NET, sig("iron-plate", 9000) } }, nil, { is_r = false })
	local map_data = world({ req, prov })
	map_data.available_trains["signal-A"] = { [99] = true }
	with_globals(ANY_ROUTE, function() pass(map_data) end)
	assert_nil(map_data.available_trains["signal-A"])
end)

test("on_failed_delivery takes the delivery off a station whose control combinator is gone", function()
	H.fresh()
	local r = station(100, { list = { NET } }, nil, { is_p = false, deliveries = { ["iron-plate"] = 100 },
		deliveries_total = 1, display_state = 1, entity_comb2 = { valid = false } })
	local map_data = world({ r })
	map_data.to_output = {}
	local train = { status = STATUS_TO_R, r_station_id = 100, p_station_id = 300,
		manifest = { { type = "item", name = "iron-plate", count = 100 } } }
	with_globals({ interface_raise_train_failed_delivery = function() end }, function()
		on_failed_delivery(map_data, 7, train, nil)
	end)
	assert_eq({ r.deliveries, r.deliveries_total, r.display_state }, { {}, 0, 0 })
end)
