-- The same combinator inputs through the planner's poll and the manager's collector: what each one registers,
-- shows and ships, and where the two agree. Covers the station combinator, the control combinator, inventory
-- combinators, NETWORK_EACH masks, network signals, stack and fluid thresholds, priority and threshold overrides,
-- locked slots, the P/R switches, in-flight deliveries and the rule that inventories count only while the station
-- combinator has input.

local H = require("harness")
local F = require("planner_fixtures")
local collector = require("scripts.gui.collector")
local sig, station, world = F.sig, F.station, F.world

local V = "virtual"
local NET = "signal-A"
local RARE_ORE = hash_item("copper-ore", "rare")

local function poll(map_data)
	map_data.tick_state = STATE_POLL_STATIONS
	map_data.tick_data = {}
	for _ = 1, 20 do
		tick(map_data, F.SETTINGS)
		if map_data.tick_state ~= STATE_POLL_STATIONS then return end
	end
	error("the planner did not finish polling")
end

local function quiet(comb)
	-- A working combinator with nothing on its input wires reads as nil.
	comb.get_signals = function() return nil end
	return comb
end

local function control_comb(unit, list)
	return F.comb(unit, MODE_SECONDARY_IO, { list = list })
end

local function stations()
	local primary = station(100, { list = {
		sig(NET, 3, V), sig(SIGNAL_PRIORITY, 7, V), sig(REQUEST_THRESHOLD, -200, V), sig(REQUEST_FLUID_THRESHOLD, 5000, V),
		sig(LOCKED_SLOTS, 2, V), sig(RESERVED_FLUID_CAPACITY, 100, V), sig("signal-B", 9, V),
		sig("iron-plate", 900), sig("coal", -300), sig("stone", -150), sig("water", -6000, "fluid"),
		{ signal = { name = "copper-ore", type = "item", quality = "rare" }, count = -400 },
		sig("iron-gear-wheel", -5, "recipe"),
	} })
	local delivering = station(110, { list = {
		sig(NET, 1, V), sig(REQUEST_THRESHOLD, 200, V), sig("coal", -300), sig("iron-plate", 100),
	} }, nil, { deliveries = { coal = 200, ["iron-plate"] = -100 } })
	local warming = station(120, { list = { sig(NET, 1, V), sig("coal", -5000) } }, nil, { is_warming_up = true })
	local stack = station(200, { list = {
		sig(NET, 1, V), sig("iron-ore", -60), sig("coal", -40), sig("copper-ore", 10),
	} }, nil, { is_stack = true })
	stack.entity_comb2 = control_comb(202, {
		sig(SIGNAL_PRIORITY, 4, V), sig("signal-B", 2, V), sig("iron-ore", -1), sig("copper-ore", 3),
	})
	local inv = station(300, { list = { sig(NET, 1, V), sig("coal", 100) } }, {
		[351] = { list = {
			sig(SIGNAL_PRIORITY, 2, V), sig(REQUEST_THRESHOLD, 50, V), sig(LOCKED_SLOTS, 9, V),
			sig(RESERVED_FLUID_CAPACITY, 7, V), sig(NET, 5, V),
			sig("iron-plate", -60), sig("stone", -10), sig("copper-plate", 70),
		} },
		[352] = { list = { sig("iron-ore", -2000), sig("stone", 5) } },
	})
	local each = station(400, { list = { sig(NET, 1, V), sig("signal-B", 2, V), sig("coal", -5000), sig("stone", 3000) } },
		{ [451] = { list = {
			sig("signal-C", 4, V), sig(SIGNAL_PRIORITY, 1, V), sig(LOCKED_SLOTS, 3, V), sig("iron-plate", -2000),
		} } },
		{ network_name = NETWORK_EACH, network_mask = {} })
	local p_only = station(500, { list = { sig(NET, 1, V), sig("coal", -5000), sig("iron-plate", 500) } }, nil,
		{ is_r = false })
	local r_only = station(510, { list = { sig(NET, 1, V), sig("iron-plate", 500), sig("coal", -5000) } }, nil,
		{ is_p = false })
	local idle = station(600, { list = {} }, { [651] = { list = { sig("iron-plate", -5000) } } })
	quiet(idle.entity_comb1)
	idle.entity_comb2 = control_comb(602, { sig(SIGNAL_PRIORITY, 4, V), sig("iron-plate", 3) })
	local provider = station(900, { list = {
		sig(NET, 1, V), sig("coal", 50000), sig("stone", 50000), sig("iron-plate", 50000), sig("iron-ore", 50000),
		sig("water", 100000, "fluid"),
	} }, nil, { is_r = false })
	return { primary, delivering, warming, stack, inv, each, p_only, r_only, idle, provider }
end

--- One planner poll and one whole collector pass over the same stations.
local function run(skip)
	H.fresh()
	local list = {}
	for _, st in ipairs(stations()) do
		st.entity_stop.backer_name = "Stop " .. st.entity_stop.unit_number
		if not (skip and skip[st.entity_stop.unit_number]) then list[#list + 1] = st end
	end
	local map_data = world(list)
	map_data.trains[1] = {
		entity = { valid = true, cargo_wagons = { {} }, fluid_wagons = { {} } },
		item_slot_capacity = 40,
		fluid_capacity = 50000,
	}
	poll(map_data)

	mod_settings = F.SETTINGS
	storage.manager = { players = {} }
	collector.init()
	storage.stations, storage.trains, storage.depots = map_data.stations, {}, {}
	storage.economy = map_data.economy
	storage.tick_state = STATE_DISPATCH
	collector.run_to_completion()
	return map_data, collector.get()
end

local function sorted_keys(t)
	local out = {}
	for k in pairs(t or {}) do out[#out + 1] = k end
	table.sort(out)
	return out
end

--- "network:item" keys a station's stops registered in `stops_by_key`, each with the stop's unit (0: the station
--- combinator's stop).
local function registered(stops_by_key, id)
	local out = {}
	for key, stops in pairs(stops_by_key) do
		for _, stop in ipairs(stops) do
			if stop.station_id == id then out[#out + 1] = key .. "@" .. (stop.unit or 0) end
		end
	end
	table.sort(out)
	return out
end

local function stop_of(map_data, id, unit)
	for _, stops in pairs(map_data.economy.all_r_stops) do
		for _, stop in ipairs(stops) do
			if stop.station_id == id and stop.unit == unit then return stop end
		end
	end
	for _, stops in pairs(map_data.economy.all_p_stops) do
		for _, stop in ipairs(stops) do
			if stop.station_id == id and stop.unit == unit then return stop end
		end
	end
end

local function manifest(map_data, r_stop, p_stop)
	local out = {}
	for _, item in ipairs(create_manifest(map_data, r_stop, p_stop, 1)) do
		out[item.name .. (item.quality and (":" .. item.quality) or "")] = item.count
	end
	return out
end

--- A collector source as plain values: requests as "count/threshold/active".
local function source(src)
	local r = {}
	for hash, req in pairs(src.requested) do
		r[hash] = req.count .. "/" .. req.threshold .. "/" .. tostring(req.active)
	end
	return {
		unit = src.unit, priority = src.priority, net = src.network_name, mask = src.mask, networks = src.networks,
		p = src.provided, r = r, i = src.ignored, ok = src.ok, read = src.read,
	}
end

local function sources(st)
	local out = {}
	for i, src in ipairs(st.sources) do out[i] = source(src) end
	return out
end

test("classify: station combinator settings, network signal, filtering and request thresholds", function()
	local map_data, snap = run()
	local s = map_data.stations[100]
	assert_eq({ s.priority, s.r_threshold, s.r_fluid_threshold, s.locked_slots, s.reserved_fluid_capacity,
		s.network_mask }, { 7, 200, 5000, 2, 100, 3 })
	assert_eq(registered(map_data.economy.all_r_stops, 100),
		{ "signal-A:coal@0", "signal-A:" .. RARE_ORE .. "@0", "signal-A:water@0" })
	assert_eq(registered(map_data.economy.all_p_stops, 100), { "signal-A:iron-plate@0" })
	assert_eq(s.primary_stop.item_p_counts, { ["iron-plate"] = 900 })
	assert_eq(manifest(map_data, s.primary_stop, map_data.stations[900].primary_stop), { coal = 300, water = 6000 })

	local st = snap.stations[100]
	assert_eq(st.control, { ["cybersyn-priority"] = 7, ["cybersyn-request-threshold"] = -200,
		["cybersyn-fluid-request-threshold"] = 5000, ["cybersyn-locked-slots"] = 2,
		["cybersyn-reserved-fluid-capacity"] = 100, ["signal-B"] = 9 })
	assert_eq(sources(st), { {
		unit = 101, priority = 7, net = NET, mask = 3, networks = nil, ok = true,
		p = { ["iron-plate"] = 900 },
		r = { coal = "-300/200/true", stone = "-150/200/false", water = "-6000/5000/true",
			[RARE_ORE] = "-400/200/true" },
		i = {},
	} })
end)

test("classify: control combinator overrides, item priority and stack thresholds", function()
	local map_data, snap = run()
	local s = map_data.stations[200]
	assert_eq(s.item_priority, 4)
	assert_eq(s.item_thresholds, { ["iron-ore"] = 1, ["copper-ore"] = 3 })
	assert_eq(registered(map_data.economy.all_r_stops, 200), { "signal-A:iron-ore@0" })
	assert_eq(registered(map_data.economy.all_p_stops, 200), { "signal-A:copper-ore@0" })

	local st = snap.stations[200]
	assert_eq(st.control2, { ["cybersyn-priority"] = 4, ["signal-B"] = 2 })
	assert_eq(st.thresholds, { ["iron-ore"] = 50, ["copper-ore"] = 150 })
	assert_eq(sources(st)[1].r, { ["iron-ore"] = "-60/50/true", coal = "-40/50000/false" })
	assert_eq(sources(st)[1].p, { ["copper-ore"] = 10 })
	assert_eq(snap.provider_overrides["signal-A:copper-ore"], 150)
end)

test("classify: inventory combinators take their own settings and network signal, never locked slots", function()
	local map_data, snap = run()
	local s = map_data.stations[300]
	assert_eq(s.locked_slots, 0)
	local i1, i2 = stop_of(map_data, 300, 351), stop_of(map_data, 300, 352)
	assert_eq({ i1.priority, i1.r_threshold, i1.reserved_fluid_capacity, i1.network_mask }, { 2, 50, 7, 5 })
	assert_eq({ i2.priority, i2.r_threshold, i2.network_mask }, { 0, 1000, 1 })
	assert_eq(registered(map_data.economy.all_r_stops, 300), { "signal-A:iron-ore@352", "signal-A:iron-plate@351" })
	assert_eq(registered(map_data.economy.all_p_stops, 300),
		{ "signal-A:coal@0", "signal-A:copper-plate@351", "signal-A:stone@352" })
	-- An inventory's below-threshold request rides along in a manifest; the station combinator's does not.
	assert_eq(manifest(map_data, i1, map_data.stations[900].primary_stop), { ["iron-plate"] = 60, stone = 10 })

	assert_eq(sources(snap.stations[300]), {
		{ unit = 301, priority = 0, net = NET, mask = 1, ok = true, p = { coal = 100 }, r = {}, i = {} },
		{ unit = 351, priority = 2, net = NET, mask = 5, ok = true, read = true, p = { ["copper-plate"] = 70 },
			r = { ["iron-plate"] = "-60/50/true", stone = "-10/50/false" }, i = {} },
		{ unit = 352, priority = 0, net = NET, mask = 1, ok = true, read = true, p = { stone = 5 },
			r = { ["iron-ore"] = "-2000/1000/true" }, i = {} },
	})
end)

test("classify: NETWORK_EACH stations and inventories register on every network signal they carry", function()
	local map_data, snap = run()
	assert_eq(map_data.stations[400].network_mask, { [NET] = 1, ["signal-B"] = 2 })
	assert_eq(stop_of(map_data, 400, 451).network_mask, { ["signal-C"] = 4 })
	assert_eq(registered(map_data.economy.all_r_stops, 400),
		{ "signal-A:coal@0", "signal-B:coal@0", "signal-C:iron-plate@451" })
	assert_eq(registered(map_data.economy.all_p_stops, 400), { "signal-A:stone@0", "signal-B:stone@0" })

	local src = sources(snap.stations[400])
	assert_eq(src[1].networks, { [NET] = 1, ["signal-B"] = 2 })
	assert_eq(src[2].networks, { ["signal-C"] = 4 })
	assert_eq(src[2].priority, 1)
	assert_eq(src[2].r, { ["iron-plate"] = "-2000/1000/true" })
end)

test("classify: the P/R switches decide provide versus request by sign; the rest is ignored", function()
	local map_data, snap = run()
	assert_eq(registered(map_data.economy.all_r_stops, 500), {})
	assert_eq(registered(map_data.economy.all_p_stops, 500), { "signal-A:iron-plate@0" })
	assert_eq(registered(map_data.economy.all_r_stops, 510), { "signal-A:coal@0" })
	assert_eq(registered(map_data.economy.all_p_stops, 510), {})
	assert_eq(snap.stations[500].ignored, { coal = -5000 })
	assert_eq(snap.stations[500].provided, { ["iron-plate"] = 500 })
	assert_eq(snap.stations[510].ignored, { ["iron-plate"] = 500 })
	assert_eq(sorted_keys(snap.stations[510].requested), { "coal" })
end)

test("classify: inventories count only while the station combinator has input", function()
	local map_data, snap = run()
	assert_eq(registered(map_data.economy.all_r_stops, 600), {})
	assert_nil(map_data.stations[600].primary_stop)
	local src = sources(snap.stations[600])
	assert_eq(#src, 2)
	assert_eq({ src[2].read, src[2].ok, src[2].r }, { false, true, {} })
	-- The control combinator too: the poll did not read its overrides.
	assert_eq(snap.stations[600].control2, {})
	assert_eq(snap.stations[600].thresholds, {})
end)

test("classify: in-flight deliveries and warming up: the manager shows what the planner registered", function()
	local _, snap = run()
	-- 300 requested with 200 on the way leaves 100, below the 200 threshold; 100 provided with 100 leaving is 0. The
	-- stock still shows as provided, but neither key is registered.
	assert_eq(sources(snap.stations[110])[1].r, { coal = "-300/200/false" })
	assert_eq(sources(snap.stations[110])[1].p, { ["iron-plate"] = 100 })
	local _, alone = run({ [100] = true, [200] = true, [300] = true, [400] = true, [500] = true, [510] = true,
		[600] = true, [900] = true })
	assert_eq(alone.request_keys, {})
	assert_eq(alone.provider_masks, {})
	-- The planner skips a warming-up station and keeps nothing for it.
	assert_eq(sources(snap.stations[120])[1].r, {})
end)

test("classify: the manager's request keys and provider keys are the planner's registrations", function()
	local map_data, snap = run()
	assert_eq(sorted_keys(snap.request_keys), sorted_keys(map_data.economy.all_r_stops))
	assert_eq(sorted_keys(snap.provider_masks), sorted_keys(map_data.economy.all_p_stops))
	assert_same(snap.starved, map_data.economy.starved)
end)
