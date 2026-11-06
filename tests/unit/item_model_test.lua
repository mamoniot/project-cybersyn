-- The per-item drill-down's pure model (scripts/gui/item-model.lua): the row split between the
-- three tables, the dispatcher-order comparator for requesters and the model builder.

local H = require("harness")

local function model()
	return H.load("scripts.gui.item-model")
end

local PRIORITY = "cybersyn-priority"

local SF = require("inventory_fixtures")
local inventories = require("scripts.gui.collector").inventories

--- m.build over records given their rows as a pass leaves them; a hand-built record takes its key as its id.
local function build(m, snapshot, hash, priority_signal, changed, keep)
	for id, st in pairs(snapshot.stations) do
		if not st.rows then
			st.id = st.id or id
			SF.rows(st)
		end
	end
	return m.build(snapshot, hash, priority_signal, changed, keep, inventories)
end

test("split_rows: a third each, Requesters the remainder; the three add up to n", function()
	local m = model()
	local many = { providers = 100, requesters = 100, trains = 100 }
	assert_eq(m.split_rows(26, many), { providers = 8, requesters = 10, trains = 8 })
	assert_eq(m.split_rows(27, many), { providers = 9, requesters = 9, trains = 9 })
	assert_eq(m.split_rows(28, many), { providers = 9, requesters = 10, trains = 9 })
	assert_eq(m.split_rows(3, many), { providers = 1, requesters = 1, trains = 1 })
	for n = 3, 80 do
		local a = m.split_rows(n, many)
		assert_eq(a.providers + a.requesters + a.trains, n, "sum at " .. n)
		assert_true(a.requesters >= a.providers and a.requesters >= a.trains, "requesters most at " .. n)
		assert_true(a.providers >= math.floor(n / 3) and a.trains >= math.floor(n / 3), "a third each at " .. n)
	end
end)

test("split_rows: rows a short table cannot fill go to Requesters, then Providers, then Trains", function()
	local m = model()
	-- 2 providers, 40 requesters, 0 trains: providers keep 2, trains 1 (the empty line), requesters the rest.
	assert_eq(m.split_rows(26, { providers = 2, requesters = 40, trains = 0 }), { providers = 2, requesters = 23, trains = 1 })
	-- Requesters full, providers take the next share.
	assert_eq(m.split_rows(26, { providers = 30, requesters = 12, trains = 0 }), { providers = 13, requesters = 12, trains = 1 })
	-- Nobody needs the spare rows: each table keeps its third as blank space, the sum stays n.
	assert_eq(m.split_rows(26, { providers = 1, requesters = 2, trains = 0 }), { providers = 8, requesters = 10, trains = 8 })
	-- Trains last.
	assert_eq(m.split_rows(26, { providers = 1, requesters = 1, trains = 50 }), { providers = 1, requesters = 1, trains = 24 })
	for n = 3, 60 do
		for _, c in ipairs({ { 0, 0, 0 }, { 5, 0, 100 }, { 100, 3, 1 }, { 2, 2, 2 }, { 0, 70, 0 } }) do
			local a = m.split_rows(n, { providers = c[1], requesters = c[2], trains = c[3] })
			assert_eq(a.providers + a.requesters + a.trains, n, "sum")
			assert_true(a.providers >= 1 and a.requesters >= 1 and a.trains >= 1, "an empty-state row each")
			-- A table with more entries than its rows always has at least its third.
			for t, k in pairs({ providers = c[1], requesters = c[2], trains = c[3] }) do
				if k > a[t] then assert_true(a[t] >= math.floor(n / 3), t .. " starved at " .. n) end
			end
		end
	end
end)

test("effective_priority: the station's, or the control combinator's when the item has its own threshold", function()
	local m = model()
	assert_eq(m.effective_priority({ priority = 5, thresholds = {}, control2 = { [PRIORITY] = 9 } }, "iron-plate", PRIORITY), 5)
	assert_eq(m.effective_priority({ priority = 5, thresholds = { ["iron-plate"] = 100 }, control2 = { [PRIORITY] = 9 } },
		"iron-plate", PRIORITY), 9)
	assert_eq(m.effective_priority({ priority = 5, thresholds = { ["iron-plate"] = 100 }, control2 = {} }, "iron-plate", PRIORITY), 5)
	assert_eq(m.effective_priority({ thresholds = {}, control2 = {} }, "iron-plate", PRIORITY), 0)
end)

test("requester_group: in the order the poll and the dispatcher test them", function()
	local m = model()
	local active = { active = true }
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 0, trains_limit = 2, deliveries = {} }, active, "x"), m.QUEUED)
	assert_eq(m.requester_group({ warming_up = true, deliveries_total = 0, trains_limit = 2 }, active, "x"), m.NOT_POLLED)
	assert_eq(m.requester_group({ status = "no_power", deliveries_total = 0, trains_limit = 2 }, active, "x"), m.NOT_POLLED)
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 0, trains_limit = 2 }, { active = false }, "x"),
		m.BELOW_THRESHOLD)
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 2, trains_limit = 2, deliveries = { x = -5 } }, active, "x"),
		m.AT_LIMIT)
	-- A switched-off stop (train limit 0) is its own group, not "at train limit".
	assert_eq(m.requester_group({ status = "disabled", deliveries_total = 0, trains_limit = 0 }, active, "x"), m.DISABLED)
	assert_true(m.AT_LIMIT < m.DISABLED and m.DISABLED < m.PROVIDING, "listed right after the busy stops")
	assert_eq(m.GROUP_KEYS[m.DISABLED], "disabled")
	assert_eq(m.GROUP_KEYS[m.NOT_REQUESTING], "not-requesting")
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 1, trains_limit = 2, deliveries = { x = -5 } }, active, "x"),
		m.PROVIDING)
	assert_eq(m.requester_group({ status = "ok", deliveries_total = 1, trains_limit = 2, deliveries = { x = 5 } }, active, "x"),
		m.QUEUED)
end)

--- tick_dispatch's own selection, restated as a loop: the requester it picks first from a list, then the next once that
--- one is removed (it evaluates and removes requesters in that order within a call).
local function dispatcher_picks(list)
	local left, order = {}, {}
	for i, r in ipairs(list) do left[i] = r end
	while #left > 0 do
		local best_i, best_prior, best_ts = nil, -math.huge, math.huge
		for i, r in ipairs(left) do
			if not (r.priority < best_prior) and not (r.priority == best_prior and r.last_served > best_ts) then
				best_i, best_prior, best_ts = i, r.priority, r.last_served
			end
		end
		order[#order + 1] = left[best_i].id
		table.remove(left, best_i)
	end
	return order
end

test("dispatch_before: priority descending, then the oldest last delivery, as the dispatcher picks", function()
	local m = model()
	local rows = {
		{ id = 1, group = 0, priority = 0, last_served = 500 },
		{ id = 2, group = 0, priority = 10, last_served = 900 },
		{ id = 3, group = 0, priority = 0, last_served = 100 },
		{ id = 4, group = 0, priority = 10, last_served = 200 },
		{ id = 5, group = 0, priority = -3, last_served = 0 },
	}
	local sorted = {}
	for i, r in ipairs(rows) do sorted[i] = r end
	table.sort(sorted, m.dispatch_before)
	local ids = {}
	for i, r in ipairs(sorted) do ids[i] = r.id end
	assert_eq(ids, { 4, 2, 3, 1, 5 })
	-- With distinct keys the comparator and the dispatcher's own loop agree on the whole order.
	assert_eq(ids, dispatcher_picks(rows))
end)

test("dispatch_before: groups after the queue, a full tie by station id", function()
	local m = model()
	local a = { id = 7, group = 0, priority = 0, last_served = 0 }
	local b = { id = 3, group = 0, priority = 0, last_served = 0 }
	local skipped = { id = 1, group = m.AT_LIMIT, priority = 99, last_served = 0 }
	assert_true(m.dispatch_before(b, a))
	assert_false(m.dispatch_before(a, b))
	assert_true(m.dispatch_before(a, skipped), "queued before a skipped request whatever its priority")
	assert_false(m.dispatch_before(a, a))
end)

--- A model row without its inventory row (a table of the record) and key, for comparing whole rows.
local function plain_row(r)
	local out = {}
	for k, v in pairs(r) do
		if k ~= "row" and k ~= "key" and k ~= "index" then out[k] = v end
	end
	return out
end

local function station(t)
	t.provided = t.provided or {}
	t.requested = t.requested or {}
	t.deliveries = t.deliveries or {}
	t.thresholds = t.thresholds or {}
	t.control2 = t.control2 or {}
	t.wait = t.wait or {}
	t.status = t.status or "ok"
	t.trains_limit = t.trains_limit or 5
	t.deliveries_total = t.deliveries_total or 0
	return t
end

test("build: providers by stock, requesters in dispatch order, trains by amount, totals from inventory_all", function()
	local m = model()
	local H_ = "iron-plate"
	local snapshot = {
		tick = 1234,
		stations = {
			[10] = station({ provided = { [H_] = 500 }, deliveries = { [H_] = -200 }, thresholds = { [H_] = 400 } }),
			[11] = station({ provided = { [H_] = 900, ["copper-plate"] = 1 } }),
			[20] = station({ requested = { [H_] = { count = -3000, threshold = 1000, active = true } }, priority = 0,
				last_delivery_tick = 50, wait = { [H_] = 77 }, deliveries = { [H_] = 400 }, network_name = "signal-A" }),
			[21] = station({ requested = { [H_] = { count = -2000, threshold = 1000, active = true } }, priority = 10,
				last_delivery_tick = 900 }),
			[22] = station({ requested = { [H_] = { count = -100, threshold = 1000, active = false } }, priority = 50 }),
			[23] = station({ requested = { [H_] = { count = -2000, threshold = 1000, active = true } }, priority = 0,
				last_delivery_tick = 10, thresholds = { [H_] = 1000 }, control2 = { [PRIORITY] = 20 } }),
			[30] = station({ requested = { ["copper-plate"] = { count = -1, threshold = 1, active = true } } }),
		},
		trains = {
			[1] = { status = 3, manifest_hashes = { [H_] = 2000 }, r_station_id = 20, p_station_id = 11 },
			[2] = { status = 3, manifest_hashes = { [H_] = 4000 }, r_station_id = 21, p_station_id = 10 },
			[3] = { status = 0, manifest_hashes = {} },
		},
		inventory_all = {
			provided = { [H_] = { count = 1400, stations = 2 } },
			requested = { [H_] = { count = -7000, stations = 3 } },
			in_transit = { [H_] = { count = 400, stations = 1 } },
		},
	}
	local r = build(m, snapshot, H_, PRIORITY)
	assert_eq(r.tick, 1234)
	assert_eq(r.totals, { provided = 1400, provided_stations = 2, requested = 7000, requested_stations = 3,
		in_transit = 400, in_transit_stations = 1 })
	assert_eq(#r.providers, 2)
	assert_eq(plain_row(r.providers[1]), { id = 11, stock = 900, priority = 0, out = 0, status = "ok" })
	assert_eq(plain_row(r.providers[2]), { id = 10, stock = 500, threshold = 400, priority = 0, out = 200,
		status = "ok" })
	-- A record without inventory rows is one station row of its own lists.
	assert_eq(r.providers[1].key, "11@0")
	assert_eq(r.providers[1].index, 0)
	assert_nil(r.providers[1].multi)
	local ids = {}
	for i, x in ipairs(r.requesters) do ids[i] = x.id end
	-- 23 has the item's own threshold, so the control combinator's priority 20 counts; 22 is below threshold.
	assert_eq(ids, { 23, 21, 20, 22 })
	assert_eq(r.queued, 3)
	assert_eq(r.requesters[1].priority, 20)
	assert_eq(plain_row(r.requesters[3]), { id = 20, requested = 3000, threshold = 1000, wait_start = 77, incoming = 400,
		priority = 0, last_served = 50, group = m.QUEUED, network = "signal-A", position = 3 })
	assert_eq(r.requesters[4].group, m.BELOW_THRESHOLD)
	assert_eq(r.requesters[4].position, nil)
	assert_eq(#r.trains, 2)
	assert_eq(r.trains[1], { id = 2, status = 3, amount = 4000, to = 21, from = 10 })
	assert_eq(r.trains[2].id, 1)
end)

test("build: the collector's per-item index, and stations whose only link to the item is a delivery", function()
	local m = model()
	local H_ = "iron-plate"
	local function station(f)
		local st = { provided = {}, requested = {}, deliveries = {}, status = "ok", deliveries_total = 0, trains_limit = 5 }
		for k, v in pairs(f) do st[k] = v end
		return st
	end
	local snapshot = {
		tick = 1,
		stations = {
			[10] = station({ provided = { [H_] = 500 } }),
			-- a pickup under way, nothing provided any more
			[11] = station({ deliveries = { [H_] = -300 } }),
			-- a delivery on its way in, no request any more
			[12] = station({ deliveries = { [H_] = 200 } }),
			-- switched off: train limit 0
			[13] = station({ requested = { [H_] = { count = -900, threshold = 100, active = true } }, trains_limit = 0 }),
			-- in the index but not in the records (removed since the pass): skipped
			[99] = nil,
			-- not in the index: never looked at
			[50] = station({ provided = { [H_] = 7 } }),
		},
		trains = {},
		inventory_all = { provided = {}, requested = {}, in_transit = {} },
		item_stations = { [H_] = { 10, 11, 12, 13, 99 } },
	}
	local r = build(m, snapshot, H_, PRIORITY)
	local pids, rids = {}, {}
	for i, x in ipairs(r.providers) do pids[i] = x.id .. ":" .. x.stock .. ":" .. x.out end
	for i, x in ipairs(r.requesters) do rids[i] = x.id .. ":" .. x.group end
	assert_eq(pids, { "10:500:0", "11:0:300" }, "the outgoing delivery joins Providers with stock 0")
	table.sort(rids)
	assert_eq(rids, { "12:" .. m.NOT_REQUESTING, "13:" .. m.DISABLED }, "the incoming one joins Requesters")
	-- A record the running pass refilled (the change log) joins, once, though the index does not name it.
	r = build(m, snapshot, H_, PRIORITY, { 50, 10, 50 })
	pids = {}
	for i, x in ipairs(r.providers) do pids[i] = x.id .. ":" .. x.stock end
	assert_eq(pids, { "10:500", "50:7", "11:0" }, "the changed station joins the index's")
	-- Without the index every record is looked at.
	snapshot.item_stations = nil
	r = build(m, snapshot, H_, PRIORITY)
	assert_eq(#r.providers, 3)
end)

test("build: an item nobody handles gives empty tables and zero totals", function()
	local m = model()
	local r = build(m, { stations = {}, trains = {}, inventory_all = { provided = {}, requested = {}, in_transit = {} } },
		"steel-plate", PRIORITY)
	assert_eq(#r.providers + #r.requesters + #r.trains, 0)
	assert_eq(r.totals.provided + r.totals.requested + r.totals.in_transit, 0)
	assert_eq(r.queued, 0)
end)

-- The manager's filters as item.lua's get_cache passes them: the item filter and the station search are dropped, every
-- inventory row and train goes through utils/filters' own predicates (place filters and the station chip).
local function place_keep(u, f)
	f.mask = f.mask or -1
	return {
		row = function(row) return u.row_passes(row, f, true) end,
		train = function(tr) return u.train_passes(tr, f, true) end,
	}
end

local function filter_snapshot()
	local H_ = "iron-plate"
	local function st(net, mask, surface, t)
		t.network_name, t.network_mask, t.surface_index, t.name_lower = net, mask, surface, "s"
		return station(t)
	end
	return H_, {
		tick = 5,
		stations = {
			-- signal-A ID 1 on surface 1
			[10] = st("signal-A", 1, 1, { provided = { [H_] = 500 } }),
			[20] = st("signal-A", 1, 1, { requested = { [H_] = { count = -300, threshold = 1, active = true } },
				deliveries = { [H_] = 40 } }),
			-- signal-B ID 2 on surface 1
			[11] = st("signal-B", 2, 1, { provided = { [H_] = 900 } }),
			[21] = st("signal-B", 2, 1, { requested = { [H_] = { count = -700, threshold = 1, active = true } } }),
			-- signal-A ID 2 on surface 2
			[12] = st("signal-A", 2, 2, { provided = { [H_] = 60 } }),
			[22] = st("signal-A", 2, 2, { requested = { [H_] = { count = -5, threshold = 1, active = false } } }),
		},
		trains = {
			[1] = { status = 3, manifest_hashes = { [H_] = 40 }, network_name = "signal-A", network_mask = 1, surface_index = 1 },
			[2] = { status = 3, manifest_hashes = { [H_] = 80 }, network_name = "signal-B", network_mask = 2, surface_index = 1 },
			[3] = { status = 3, manifest_hashes = { [H_] = 10 }, network_name = "signal-A", network_mask = 2, surface_index = 2 },
		},
		inventory_all = {
			provided = { [H_] = { count = 1460, stations = 3 } },
			requested = { [H_] = { count = -1000, stations = 2 } },
			in_transit = { [H_] = { count = 40, stations = 1 } },
		},
	}
end

local function ids_of(rows)
	local out = {}
	for i, r in ipairs(rows) do out[i] = r.id end
	table.sort(out)
	return out
end

test("build with place filters: a network keeps that network's rows, totals summed from them", function()
	local m, u = model(), H.load("scripts.gui.utils.filters")
	local H_, snapshot = filter_snapshot()
	local r = build(m, snapshot, H_, PRIORITY, nil, place_keep(u, { network = "signal-B", mask = -1 }))
	assert_true(r.filtered)
	assert_eq(ids_of(r.providers), { 11 })
	assert_eq(ids_of(r.requesters), { 21 })
	assert_eq(ids_of(r.trains), { 2 })
	assert_eq(r.totals, { provided = 900, provided_stations = 1, requested = 700, requested_stations = 1,
		in_transit = 0, in_transit_stations = 0 })
end)

test("build with place filters: a network ID and a surface each drop the right rows and totals", function()
	local m, u = model(), H.load("scripts.gui.utils.filters")
	local H_, snapshot = filter_snapshot()
	local r = build(m, snapshot, H_, PRIORITY, nil, place_keep(u, { mask = 1 }))
	assert_eq(ids_of(r.providers), { 10 })
	assert_eq(ids_of(r.requesters), { 20 })
	assert_eq(ids_of(r.trains), { 1 })
	assert_eq(r.totals, { provided = 500, provided_stations = 1, requested = 300, requested_stations = 1,
		in_transit = 40, in_transit_stations = 1 })
	r = build(m, snapshot, H_, PRIORITY, nil, place_keep(u, { mask = -1, surface = 2 }))
	assert_eq(ids_of(r.providers), { 12 })
	assert_eq(ids_of(r.requesters), { 22 }, "below threshold: listed, not in the requested total")
	assert_eq(ids_of(r.trains), { 3 })
	assert_eq(r.totals, { provided = 60, provided_stations = 1, requested = 0, requested_stations = 0,
		in_transit = 0, in_transit_stations = 0 })
end)

test("build without place filters: every row, totals from inventory_all", function()
	local m = model()
	local H_, snapshot = filter_snapshot()
	local r = build(m, snapshot, H_, PRIORITY)
	assert_false(r.filtered)
	assert_eq(ids_of(r.providers), { 10, 11, 12 })
	assert_eq(ids_of(r.requesters), { 20, 21, 22 })
	assert_eq(ids_of(r.trains), { 1, 2, 3 })
	assert_eq(r.totals, { provided = 1460, provided_stations = 3, requested = 1000, requested_stations = 2,
		in_transit = 40, in_transit_stations = 1 })
end)

test("locale: every key the drill-down builds from parts, in every locale with the en fallback", function()
	local keys = {}
	for _, t in ipairs({ "providers", "requesters", "trains" }) do
		keys["item-" .. t] = true
		keys["item-empty-" .. t] = true
	end
	for _, c in ipairs({ "station", "stock", "threshold", "out", "status", "priority", "requested", "wait", "why",
		"incoming", "train", "train-status", "amount", "to" }) do
		keys["item-col-" .. c] = true
	end
	for _, g in ipairs({ "at-limit", "providing", "below-threshold", "not-polled" }) do
		keys["item-group-" .. g] = true
		keys["item-group-" .. g .. "-tooltip"] = true
	end
	for _, p in ipairs({ 10, 60, 1440 }) do keys["item-period-" .. p] = true end
	for _, k in ipairs({ "item-provided", "item-in-transit", "item-requested", "item-click-hint" }) do keys[k] = true end
	for _, loc in ipairs(H.LOCALES) do
		local text = H.locale_text(loc)
		for k in pairs(keys) do
			assert_true(text:find("\n" .. k .. "=", 1, true) ~= nil, loc .. " lacks " .. k)
		end
		assert_true(text:find("\nitem%-requesters=[^\n]*approximate") ~= nil, loc .. ": the Requesters caption says approximate")
	end
end)

-- One row per inventory (combinator) of a station, from collector.inventories.

local function rows_snapshot(list)
	local stations = {}
	for _, st in ipairs(list) do stations[st.id] = st end
	return { tick = 1, stations = stations, trains = {}, inventory_all = { provided = {}, requested = {}, in_transit = {} } }
end

local function keys_of(rows)
	local out = {}
	for i, r in ipairs(rows) do out[i] = r.key end
	return out
end

test("build rows: the naphthalene plant's liquid fuel row is its Inventory 1 row", function()
	local m = model()
	local snapshot = rows_snapshot({ SF.naphtha(100) })
	local r = build(m, snapshot, SF.LIQUID_FUEL, PRIORITY)
	assert_eq(keys_of(r.providers), { "100@1002" })
	assert_eq(r.providers[1].stock, 99134)
	assert_eq(r.providers[1].row.kind, "inventory")
	assert_eq(r.providers[1].index, 1)
	assert_true(r.providers[1].multi, "a station with several rows names the row's inventory")
	-- Inventory 2's -866 is not advertised on a Provide only station: no requester row.
	assert_eq(#r.requesters, 0)
	local oil = build(m, snapshot, SF.NAPHTHA_OIL, PRIORITY)
	assert_eq(keys_of(oil.providers), { "100@1001" })
	assert_eq(oil.providers[1].stock, 199134)
	assert_eq(oil.providers[1].row.kind, "station")
end)

test("build rows: provided by one inventory and requested by another, the station is in both tables", function()
	local m = model()
	local st = SF.coal_both(200)
	st.deliveries = { [SF.COAL] = 700 }
	st.priority = 4
	local r = build(m, rows_snapshot({ st }), SF.COAL, PRIORITY)
	assert_eq(keys_of(r.providers), { "200@2001" })
	assert_eq(keys_of(r.requesters), { "200@2002" })
	local req = r.requesters[1]
	assert_eq(req.requested, 2000)
	assert_eq(req.threshold, 1000)
	assert_eq(req.incoming, 700)
	-- The requesting inventory's own 3, not the station's 4: tick_dispatch ranks every stop by its own priority.
	assert_eq(req.priority, 3)
	assert_eq(req.group, m.QUEUED)
	assert_eq(req.position, 1)
	assert_eq(r.providers[1].out, 0)
end)

test("build rows: two inventories providing one item give two rows; a delivery goes on the first only", function()
	local m = model()
	local st = SF.naphtha(100)
	-- Inventory 2 on A4 now advertises liquid fuel too.
	st.rows[3].provided[SF.LIQUID_FUEL] = 5000
	st.deliveries = { [SF.LIQUID_FUEL] = -1200 }
	local r = build(m, rows_snapshot({ st }), SF.LIQUID_FUEL, PRIORITY)
	assert_eq(keys_of(r.providers), { "100@1002", "100@1003" })
	assert_eq(r.providers[1].out, 1200)
	assert_eq(r.providers[2].out, 0)
end)

test("build rows: a plain station keeps one row with no inventory tag", function()
	local m = model()
	local plain = SF.plain(7, "Plain", 1, { [SF.COAL] = 40 })
	local r = build(m, rows_snapshot({ plain }), SF.COAL, PRIORITY)
	assert_eq(keys_of(r.providers), { "7@9007" })
	assert_nil(r.providers[1].multi)
end)

test("build rows with filters: a network ID keeps the rows on it, totals count those, a station once", function()
	local m, u = model(), H.load("scripts.gui.utils.filters")
	local st = SF.coal_both(200)
	-- The station combinator is on A1, so a station-wide filter would have dropped the whole station.
	local r = build(m, rows_snapshot({ st }), SF.COAL, PRIORITY, nil, place_keep(u, { mask = 2 }))
	assert_eq(keys_of(r.providers), {})
	assert_eq(keys_of(r.requesters), { "200@2002" })
	assert_eq(r.totals.provided, 0)
	assert_eq(r.totals.requested, 2000)
	assert_eq(r.totals.requested_stations, 1)
	r = build(m, rows_snapshot({ st }), SF.COAL, PRIORITY, nil, place_keep(u, { mask = 1 }))
	assert_eq(keys_of(r.providers), { "200@2001" })
	assert_eq(keys_of(r.requesters), {})
	assert_eq(r.totals.provided, 5000)
	assert_eq(r.totals.provided_stations, 1)
	-- Two rows providing it: the stock is the sum, the station counts once.
	local nap = SF.naphtha(100)
	nap.rows[3].provided[SF.LIQUID_FUEL] = 5000
	r = build(m, rows_snapshot({ nap }), SF.LIQUID_FUEL, PRIORITY, nil, place_keep(u, { network = "signal-A" }))
	assert_eq(r.totals.provided, 99134 + 5000)
	assert_eq(r.totals.provided_stations, 1)
end)

test("build rows: the station chip keeps that station's rows and the trains to or from it", function()
	local m, u = model(), H.load("scripts.gui.utils.filters")
	local a, b = SF.coal_both(200), SF.plain(7, "Plain", 1, { [SF.COAL] = 40 })
	local snapshot = rows_snapshot({ a, b })
	snapshot.trains = {
		[1] = { status = 3, manifest_hashes = { [SF.COAL] = 10 }, p_station_id = 7, r_station_id = 200, surface_index = 1,
			network_name = "signal-A", network_mask = 1 },
		[2] = { status = 3, manifest_hashes = { [SF.COAL] = 20 }, p_station_id = 7, r_station_id = 8, surface_index = 1,
			network_name = "signal-A", network_mask = 1 },
	}
	local r = build(m, snapshot, SF.COAL, PRIORITY, nil, place_keep(u, { station = 200 }))
	assert_true(r.filtered)
	assert_eq(keys_of(r.providers), { "200@2001" })
	assert_eq(keys_of(r.requesters), { "200@2002" })
	assert_eq(#r.trains, 1)
	assert_eq(r.trains[1].id, 1)
	assert_eq(r.totals.provided, 5000)
	assert_eq(r.totals.provided_stations, 1)
	r = build(m, snapshot, SF.COAL, PRIORITY, nil, place_keep(u, { station = 7 }))
	assert_eq(keys_of(r.providers), { "7@9007" })
	assert_eq(#r.requesters, 0)
	assert_eq(#r.trains, 2)
end)

test("build rows: rows of one station sort by inventory index after the station id", function()
	local m = model()
	local st = SF.naphtha(100)
	st.rows[3].provided[SF.LIQUID_FUEL] = 99134
	local r = build(m, rows_snapshot({ st }), SF.LIQUID_FUEL, PRIORITY)
	assert_eq(keys_of(r.providers), { "100@1002", "100@1003" })
	-- A lower unit number whose text sorts after the other's: the index decides, not the key's text.
	st.rows[2].key = "100@999"
	r = build(m, rows_snapshot({ st }), SF.LIQUID_FUEL, PRIORITY)
	assert_eq(keys_of(r.providers), { "100@999", "100@1003" })
end)

test("row_priority: an inventory's own priority, the item override on every row", function()
	local m = model()
	local st = { priority = 2, thresholds = { coal = 10 }, control2 = { [PRIORITY] = 6 } }
	assert_eq(m.row_priority(st, { index = 0, priority = 2 }, "coal", PRIORITY), 6, "the item override")
	assert_eq(m.row_priority(st, { index = 0, priority = 2 }, "iron-ore", PRIORITY), 2)
	assert_eq(m.row_priority(st, { index = 1, priority = 9 }, "coal", PRIORITY), 6,
		"tick_dispatch's override replaces p_stop.priority on an inventory's stop too")
	assert_eq(m.row_priority(st, { index = 1, priority = 9 }, "iron-ore", PRIORITY), 9, "the inventory's own stop")
end)

test("build rows: an inventory requests and provides at its own priority; the item override replaces it on both", function()
	local m = model()
	local st = SF.coal_both(200)
	st.priority = 1
	st.rows[1].priority = 1
	st.rows[2].priority = 9
	local r = build(m, rows_snapshot({ st }), SF.COAL, PRIORITY)
	assert_eq(r.requesters[1].priority, 9, "the requesting inventory's own priority")
	assert_eq(r.providers[1].priority, 1)
	st.thresholds = { [SF.COAL] = 10 }
	st.control2 = { [PRIORITY] = 7 }
	r = build(m, rows_snapshot({ st }), SF.COAL, PRIORITY)
	assert_eq(r.requesters[1].priority, 7, "the control combinator's item override")
	assert_eq(r.providers[1].priority, 7)
end)

test("dispatch_before: on a full tie inside one station the inventories go before the station combinator", function()
	local m = model()
	local function row(index) return { group = m.QUEUED, priority = 0, last_served = 0, id = 5, index = index } end
	local sorted = { row(0), row(2), row(1) }
	table.sort(sorted, m.dispatch_before)
	assert_eq({ sorted[1].index, sorted[2].index, sorted[3].index }, { 1, 2, 0 },
		"the poll registers the inventory stops first and the dispatcher keeps the first on a tie")
	assert_false(m.dispatch_before(row(0), row(0)))
end)
