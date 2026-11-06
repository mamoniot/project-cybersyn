-- The Inventory grids count every inventory row (combinator) of a station on its own network, so a
-- secondary inventory's items land under its own network ID and the network filter keeps only the rows on it; a
-- station's kept rows are summed per item and the station counts once; the station chip keeps one station's rows.

local H = require("harness")
local SF = require("inventory_fixtures")

local function aggregate()
	local collector = require("scripts.gui.collector")
	SF.stub_collector(collector)
	return H.load("scripts.gui.inventory")._aggregate
end

local function snapshot(list)
	local stations = {}
	for _, st in ipairs(list) do stations[st.id] = st end
	return { stations = stations }
end

local function filters(network, mask, station)
	return { network = network, mask = mask or -1, station = station }
end

local function count(bucket, hash)
	return bucket[hash] and bucket[hash].count or nil
end

test("inventory rows: the naphthalene plant's liquid fuel counts on A3, not on the station combinator's A1", function()
	local agg = aggregate()
	local snap = snapshot({ SF.naphtha(100) })
	local inv = agg(snap, filters())
	assert_eq(count(inv.provided, SF.NAPHTHA_OIL), 199134)
	assert_eq(count(inv.provided, SF.LIQUID_FUEL), 99134)
	assert_eq(inv.provided[SF.LIQUID_FUEL].stations, 1)
	-- Inventory 2's ignored -866 is never a request.
	assert_nil(inv.requested[SF.LIQUID_FUEL])
	-- Bit 2 is only in Inventory 1's A3.
	inv = agg(snap, filters("signal-A", 2))
	assert_eq(count(inv.provided, SF.LIQUID_FUEL), 99134)
	assert_nil(inv.provided[SF.NAPHTHA_OIL])
	-- Bit 3 is only Inventory 2's A4, which advertises nothing.
	inv = agg(snap, filters("signal-A", 4))
	assert_nil(inv.provided[SF.LIQUID_FUEL])
	assert_nil(inv.provided[SF.NAPHTHA_OIL])
	-- Another network: nothing.
	inv = agg(snap, filters("signal-B"))
	assert_nil(next(inv.provided))
end)

test("inventory rows: provided on A1 and requested on A2, each counts under its own network ID", function()
	local agg = aggregate()
	local st = SF.coal_both(200)
	st.wait = { [SF.COAL] = 50 }
	local snap = snapshot({ st })
	local inv, _, has_wait = agg(snap, filters())
	assert_eq(count(inv.provided, SF.COAL), 5000)
	assert_eq(count(inv.requested, SF.COAL), -2000)
	assert_eq(inv.requested[SF.COAL].earliest_wait_start, 50)
	assert_true(has_wait)
	inv = agg(snap, filters(nil, 2))
	assert_nil(inv.provided[SF.COAL])
	assert_eq(count(inv.requested, SF.COAL), -2000)
	-- Nothing provides coal on the request's network now, so all of it is short.
	assert_eq(inv.deficit[SF.COAL], 2000)
	inv = agg(snap, filters("signal-A", 1))
	assert_eq(count(inv.provided, SF.COAL), 5000)
	assert_nil(inv.requested[SF.COAL])
end)

test("inventory rows: two rows providing one item sum, the station counts once; deliveries once per station", function()
	local agg = aggregate()
	local st = SF.naphtha(100)
	st.rows[3].provided[SF.LIQUID_FUEL] = 5000
	st.deliveries = { [SF.LIQUID_FUEL] = 300 }
	local inv, top = agg(snapshot({ st }), filters())
	assert_eq(count(inv.provided, SF.LIQUID_FUEL), 99134 + 5000)
	assert_eq(inv.provided[SF.LIQUID_FUEL].stations, 1)
	assert_eq(#top.provided[SF.LIQUID_FUEL], 3, "one top-list entry for the station")
	assert_eq(top.provided[SF.LIQUID_FUEL][1], 99134 + 5000)
	assert_eq(count(inv.in_transit, SF.LIQUID_FUEL), 300)
	-- Only Inventory 2's mask: only its stock.
	inv = agg(snapshot({ st }), filters("signal-A", 4))
	assert_eq(count(inv.provided, SF.LIQUID_FUEL), 5000)
	assert_eq(count(inv.in_transit, SF.LIQUID_FUEL), 300, "the station's delivery counts with any kept row")
end)

test("inventory rows: an each-network row counts its stock once, on each of its networks for the deficit", function()
	local agg = aggregate()
	local st = SF.plain(9, "Each", 1, { [SF.COAL] = 700 })
	local row = st.rows[1]
	row.network_name, row.mask, row.networks = NETWORK_EACH, nil, { ["signal-A"] = 1, ["signal-B"] = 1 }
	local req = SF.plain(10, "Wants", 1, {}, { [SF.COAL] = { count = -500, threshold = 1, active = true } })
	req.rows[1].network_name = "signal-B"
	local inv = agg(snapshot({ st, req }), filters())
	assert_eq(count(inv.provided, SF.COAL), 700)
	assert_eq(inv.provided[SF.COAL].stations, 1)
	assert_nil(inv.deficit[SF.COAL], "B's request is covered by the each-network stock")
	inv = agg(snapshot({ st }), filters("signal-B"))
	assert_eq(count(inv.provided, SF.COAL), 700)
end)

test("inventory rows: an incoming delivery offsets the request on the requesting row's network", function()
	local agg = aggregate()
	local st = SF.coal_both(200)
	st.rows[2].network_name = "signal-B"
	st.deliveries = { [SF.COAL] = 1500 }
	local inv = agg(snapshot({ st }), filters())
	assert_eq(count(inv.in_transit, SF.COAL), 1500)
	-- B requests 2000 with 1500 on the way and no stock on B; A's 5000 is on another network.
	assert_eq(inv.deficit[SF.COAL], 500)
end)

test("inventory rows: the station chip keeps that station's rows only", function()
	local agg = aggregate()
	local a = SF.coal_both(200)
	local b = SF.plain(7, "Plain", 1, { [SF.COAL] = 40 })
	local snap = snapshot({ a, b })
	local inv = agg(snap, filters(nil, nil, 7))
	assert_eq(count(inv.provided, SF.COAL), 40)
	assert_nil(inv.requested[SF.COAL])
	inv = agg(snap, filters(nil, nil, 200))
	assert_eq(count(inv.provided, SF.COAL), 5000)
	assert_eq(count(inv.requested, SF.COAL), -2000)
	-- With a network ID as well: that station's rows on it.
	inv = agg(snap, filters(nil, 2, 200))
	assert_nil(inv.provided[SF.COAL])
	assert_eq(count(inv.requested, SF.COAL), -2000)
	inv = agg(snap, filters())
	assert_eq(count(inv.provided, SF.COAL), 5040)
	assert_eq(inv.provided[SF.COAL].stations, 2)
end)

test("inventory rows: a plain station is counted as before", function()
	local agg = aggregate()
	local plain = SF.plain(7, "Plain", 1, { [SF.COAL] = 40 }, { [SF.COAL .. "x"] = { count = -5, threshold = 1, active = true } })
	local inv = agg(snapshot({ plain }), filters("signal-A", 1))
	assert_eq(count(inv.provided, SF.COAL), 40)
	assert_eq(count(inv.requested, SF.COAL .. "x"), -5)
	inv = agg(snapshot({ plain }), filters("signal-A", 2))
	assert_nil(next(inv.provided))
end)
