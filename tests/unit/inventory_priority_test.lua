-- A secondary inventory's priority signal, driven through the real poll and dispatch: the poll reads it into the
-- inventory's own stop, and the dispatcher ranks that stop by it as a provider and as a requester, independently of the
-- priority of the station combinator beside it. Deliveries are recorded, not created, so only the ranking is tested.

local H = require("harness")
local F = require("planner_fixtures")
local sig, station, world, pass, NET = F.sig, F.station, F.world, F.pass, F.NET

local function prio(n)
	return sig(SIGNAL_PRIORITY, n, "virtual")
end

--- Inventory inputs: `signals` with a priority signal of `n` in front, or `signals` alone when n is nil.
local function with_prio(n, signals)
	if n ~= nil then table.insert(signals, 1, prio(n)) end
	return { list = signals }
end

--- One planner pass with the world's trains available: the requester and provider stops of the first delivery the
--- dispatcher created, each as {station id, inventory unit or nil}, or nil when it created none.
local function first_match(map_data)
	local r, p
	F.with_globals({
		Surfaces = { find_surface_connections_masked = function() return {} end },
		create_manifest = function() return {} end,
		create_delivery = function(_, _, _, _, _, _, r_stop, p_stop)
			if not r then r, p = r_stop, p_stop end
		end,
	}, function() pass(map_data) end)
	if not r then return nil end
	return { r = { r.station_id, r.unit }, p = { p.station_id, p.unit } }
end

test("poll: an inventory's priority signal sets its own stop's priority; without one it takes the station combinator's", function()
	H.fresh()
	local st = station(100, { list = { NET, prio(4) } }, {
		[201] = with_prio(9, { sig("iron-plate", 500) }),
		[202] = with_prio(nil, { sig("copper-plate", 500) }),
		[203] = with_prio(-3, { sig("stone", -5000) }),
	})
	local plain = station(300, { list = { NET } }, { [301] = with_prio(nil, { sig("coal", 500) }) })
	pass(world({ st, plain }))
	assert_eq({ st.primary_stop.priority, st.inv_stops[201].priority, st.inv_stops[202].priority, st.inv_stops[203].priority },
		{ 4, 9, 4, -3 }, "the station combinator's stop keeps its own; 202 inherits it; 201 and 203 override it")
	assert_eq({ plain.primary_stop.priority, plain.inv_stops[301].priority }, { 0, 0 },
		"the mod setting when neither carries a signal")
end)

--- Station 100 requests 5000 iron. Station 300, the nearer, provides 9000 from its station combinator at priority
--- `near`; station 500 carries `far` on its station combinator and provides 9000 from an inventory carrying `inv` (nil:
--- no signal of its own). `far_control`: the signals of a station control combinator at 500.
local function provider_chosen(near, far, inv, far_control)
	H.fresh()
	local req = station(100, { list = { NET, sig("iron-plate", -5000) } }, nil, { is_p = false, allows_all_trains = true })
	local near_st = station(300, { list = { NET, prio(near), sig("iron-plate", 9000) } }, nil,
		{ is_r = false, allows_all_trains = true })
	local far_st = station(500, { list = { NET, prio(far) } }, { [501] = with_prio(inv, { sig("iron-plate", 9000) }) },
		{ is_r = false, allows_all_trains = true })
	if far_control then far_st.entity_comb2 = F.comb(502, MODE_SECONDARY_IO, { list = far_control }) end
	local map_data = world({ req, near_st, far_st })
	F.train(map_data, 7)
	local m = first_match(map_data)
	return m and m.p
end

test("provider: an inventory ranks by its own priority, not its station combinator's, against another station", function()
	assert_eq(provider_chosen(3, 0, 5), { 500, 501 }, "5 beats the nearer 3 although its station combinator says 0")
	assert_eq(provider_chosen(3, 9, 1), { 300 }, "1 loses to 3 although its station combinator says 9")
	assert_eq(provider_chosen(3, 9, nil), { 500, 501 }, "without a signal of its own it provides at its station combinator's 9")
	assert_eq(provider_chosen(3, 0, 3), { 300 }, "equal priority: the nearer provider")
end)

--- Station 300 provides 9000 iron. Station 100 requests 5000 from its station combinator at priority `a`; station 500
--- carries `b` on its station combinator and requests 5000 from an inventory carrying `inv` (nil: no signal of its
--- own). `b_control`: the signals of a station control combinator at 500.
local function requester_chosen(a, b, inv, b_control)
	H.fresh()
	local prov = station(300, { list = { NET, sig("iron-plate", 9000) } }, nil, { is_r = false, allows_all_trains = true })
	local a_st = station(100, { list = { NET, prio(a), sig("iron-plate", -5000) } }, nil,
		{ is_p = false, allows_all_trains = true })
	local b_st = station(500, { list = { NET, prio(b) } }, { [501] = with_prio(inv, { sig("iron-plate", -5000) }) },
		{ is_p = false, allows_all_trains = true })
	if b_control then b_st.entity_comb2 = F.comb(502, MODE_SECONDARY_IO, { list = b_control }) end
	local map_data = world({ prov, a_st, b_st })
	F.train(map_data, 7)
	local m = first_match(map_data)
	return m and m.r
end

test("requester: an inventory's request ranks by its own priority, not its station combinator's, against another station", function()
	assert_eq(requester_chosen(3, 0, 5), { 500, 501 }, "5 beats 3 although its station combinator says 0")
	assert_eq(requester_chosen(3, 9, 1), { 100 }, "1 loses to 3 although its station combinator says 9")
	assert_eq(requester_chosen(3, 9, nil), { 500, 501 }, "without a signal of its own it requests at its station combinator's 9")
end)


--- Station 100 carries iron `count` on its station combinator (priority `own`) and on an inventory (priority `inv`),
--- against station 300 in the opposite role; count > 0 makes 100 the provider, < 0 the requester. The two stops share
--- every station-level input (distance, limit, deliveries, last delivery), so only their own priorities can decide.
local function stop_chosen_at_one_station(count, own, inv)
	H.fresh()
	local both = station(100, { list = { NET, prio(own), sig("iron-plate", count) } },
		{ [101] = with_prio(inv, { sig("iron-plate", count) }) }, { allows_all_trains = true })
	local other = station(300, { list = { NET, sig("iron-plate", -2 * count) } }, nil, { allows_all_trains = true })
	local map_data = world({ both, other })
	F.train(map_data, 7)
	local m = first_match(map_data)
	return m and (count > 0 and m.p or m.r)
end

test("provider: at one station, the station combinator and an inventory offering the same item rank by their own priorities", function()
	assert_eq(stop_chosen_at_one_station(9000, 0, 5), { 100, 101 })
	assert_eq(stop_chosen_at_one_station(9000, 5, 0), { 100 })
end)

test("requester: at one station, the station combinator and an inventory asking for the same item rank by their own priorities", function()
	assert_eq(stop_chosen_at_one_station(-5000, 0, 5), { 100, 101 })
	assert_eq(stop_chosen_at_one_station(-5000, 5, 0), { 100 })
end)

test("a station control combinator's priority for an item overrides every stop of its station, an inventory's own included", function()
	local iron = { prio(7), sig("iron-plate", 100) }
	assert_eq(provider_chosen(3, 0, 1, iron), { 500, 501 }, "provider: 7 for iron, not the inventory's 1")
	assert_eq(requester_chosen(3, 0, 1, iron), { 500, 501 }, "requester: 7 for iron, not the inventory's 1")
	assert_eq(provider_chosen(3, 0, 1, { prio(7), sig("copper-plate", 100) }), { 300 }, "only for the items it lists")
end)
