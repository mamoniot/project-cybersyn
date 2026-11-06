-- The Stations query pipeline (scripts/gui/stations.lua): the status ladder, sort order with its name/id tiebreak,
-- the status filter and the incremental update from the collector log. Records carry `status` as
-- collector.station_status sets it once per pass, and the query reads it; ties compare name_lower, then id.

local H = require("harness")

local function st(id, name, over)
	local r = {
		id = id,
		name = name,
		name_lower = string.lower(name),
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		comb_ok = true,
		warming_up = false,
		trains_limit = 2,
		deliveries_total = 0,
		provided = {},
		requested = {},
		deliveries = {},
		wait = {},
	}
	for k, v in pairs(over or {}) do r[k] = v end
	return require("inventory_fixtures").rows(r)
end

local function setup()
	local stations_tab = H.load("scripts.gui.stations")
	-- The cases build bare PlayerData literals.
	local query = stations_tab.query
	stations_tab.query = function(pd, ...) return query(H.player_data(pd), ...) end
	local collector = require("scripts.gui.collector")
	mod_settings = { tps = 60 }
	storage.total_ticks = 200000
	storage.manager = { players = {} }
	collector.init()
	local snap = collector.get()
	snap.stations = {
		[1] = st(1, "Alpha", { comb_ok = false }),
		[2] = st(2, "Bravo", { trains_limit = 0 }),
		[3] = st(3, "Charlie", { warming_up = true, requested = { coal = { count = -5, threshold = 1, active = true } } }),
		[4] = st(4, "Delta", { requested = { coal = { count = -5, threshold = 1, active = true } }, longest_wait_start = 100 }),
		[5] = st(5, "Echo", { deliveries_total = 2 }),
		[6] = st(6, "Foxtrot", { trains_limit = 2100000000, deliveries_total = 5 }),
		[7] = st(7, "Golf", { last_delivery_tick = 50000 }),
		[8] = st(8, "Hotel"),
		[9] = st(9, "Hotel", { last_delivery_tick = 50000, requested = { stone = { count = -5, threshold = 1, active = true } }, longest_wait_start = 20 }),
	}
	snap.starved = { ["signal-A:coal"] = true }
	for _, record in pairs(snap.stations) do
		record.status = collector.station_status(record, snap.starved)
	end
	snap.starved_version = 1
	snap.tick = 10
	game.tick = 20
	return stations_tab, collector, snap
end

--- Station ids of the rows in display order (a row per combinator).
local function ids(rows)
	local out = {}
	for i, r in ipairs(rows) do out[i] = r.st.id end
	return out
end

test("query: status ladder and counts", function()
	local stations_tab = setup()
	local pd = { filters = {} }
	local rows, counts, ctx, column, ascending = stations_tab.query(pd)
	assert_eq(column, "name")
	assert_true(ascending)
	assert_eq(ids(rows), { 1, 2, 3, 4, 5, 6, 7, 8, 9 })
	assert_eq(ctx.status, {
		[1] = "no_power", [2] = "disabled", [3] = "warming_up", [4] = "starved", [5] = "saturated",
		[6] = "ok", [7] = "idle", [8] = "ok", [9] = "ok",
	})
	-- The chip counts besides the statuses; failing = no power + disabled (+ throttling + setup).
	assert_eq(counts, { all = 9, no_power = 1, disabled = 1, warming_up = 1, starved = 1, setup = 0, saturated = 1, idle = 1,
		ok = 3, unserved = 0, problems = 0, failing = 2, stuck = 0 })
end)

-- An OK station with an open setup error reads Setup, counted in its own chip and not in OK; an
-- acknowledgement, which writes no change-log entry, turns it back on the next query.
test("query: Setup replaces OK while an error finding is open", function()
	local stations_tab, _, snap = setup()
	snap.stations[8].lint = LINT_BIT[LINT_CAPACITY]
	snap.stations[4].lint = LINT_BIT[LINT_CAPACITY]
	snap.stations[9].lint = LINT_BIT[LINT_LIMIT_ZERO]
	local pd = { filters = {} }
	local _, counts, ctx = stations_tab.query(pd)
	assert_eq(ctx.status[8], "setup")
	assert_eq(ctx.status[4], "starved", "a status that says why stays")
	assert_eq(ctx.status[9], "ok", "a warning does not block")
	assert_eq(counts.setup, 1)
	assert_eq(counts.ok, 2)
	pd.filters.stations_chip = "setup"
	assert_eq(ids((stations_tab.query(pd))), { 8 })
	pd.filters.stations_chip = nil
	storage.acks = { request = {}, station = {}, lint = { [8] = { [LINT_CAPACITY] = { player_index = 1 } } }, lint_version = 1 }
	_, counts, ctx = stations_tab.query(pd)
	assert_eq(ctx.status[8], "ok")
	assert_eq(counts.setup, 0)
	assert_eq(counts.ok, 3)
	storage.acks = nil
end)

test("station_status: idle needs an old last delivery, tps > 0 and no active request", function()
	local _, collector, snap = setup()
	local golf = snap.stations[7]
	mod_settings.tps = 0
	assert_eq(collector.station_status(golf, snap.starved), "ok")
	mod_settings.tps = 60
	-- 30 minutes at tps 60 is exactly IDLE_TICKS, which is not idle yet.
	golf.last_delivery_tick = 200000 - 108000
	assert_eq(collector.station_status(golf, snap.starved), "ok")
	golf.last_delivery_tick = 200000 - 108001
	assert_eq(collector.station_status(golf, snap.starved), "idle")
	golf.requested = { stone = { count = -5, threshold = 1, active = true } }
	assert_eq(collector.station_status(golf, snap.starved), "ok")
	golf.requested = { stone = { count = -5, threshold = 10, active = false } }
	assert_eq(collector.station_status(golf, snap.starved), "idle")
	golf.deliveries_total = 1
	assert_eq(collector.station_status(golf, snap.starved), "ok")
end)

test("query: descending name keeps the id tiebreak ascending", function()
	local stations_tab = setup()
	local pd = { sort = { stations_tab = { column = "name", ascending = false } }, filters = {} }
	local rows = stations_tab.query(pd)
	assert_eq(ids(rows), { 8, 9, 7, 6, 5, 4, 3, 2, 1 })
end)

test("query: status and wait sort keys", function()
	local stations_tab = setup()
	local pd = { sort = { stations_tab = { column = "station_status", ascending = true } }, filters = {} }
	assert_eq(ids((stations_tab.query(pd))), { 1, 2, 3, 4, 5, 7, 6, 8, 9 })
	stations_tab = setup()
	pd = { sort = { stations_tab = { column = "wait", ascending = true } }, filters = {} }
	-- Ascending wait = latest request start first; stations without a wait last, by name.
	assert_eq(ids((stations_tab.query(pd))), { 4, 9, 1, 2, 3, 5, 6, 7, 8 })
	stations_tab = setup()
	pd = { sort = { stations_tab = { column = "bogus", ascending = true } }, filters = {} }
	local _, _, _, column = stations_tab.query(pd)
	assert_eq(column, "name")
end)

test("query: status filter applies after counting; an unknown chip reads as All without a write", function()
	local stations_tab = setup()
	local pd = { filters = { stations_chip = "ok" } }
	local rows, counts = stations_tab.query(pd)
	assert_eq(ids(rows), { 6, 8, 9 })
	assert_eq(counts.all, 9)
	pd.filters.stations_chip = "gone"
	rows = stations_tab.query(pd)
	assert_eq(pd.filters.stations_chip, "gone")
	assert_eq(#rows, 9)
end)

test("query: global filters narrow the set and the counts", function()
	local stations_tab = setup()
	local pd = { filters = { query = "hotel", terms = { "hotel" } } }
	local rows, counts = stations_tab.query(pd)
	assert_eq(ids(rows), { 8, 9 })
	assert_eq(counts, { all = 2, no_power = 0, disabled = 0, warming_up = 0, starved = 0, setup = 0, saturated = 0, idle = 0,
		ok = 2, unserved = 0, problems = 0, failing = 0, stuck = 0 })
	pd = { filters = { item = "coal" } }
	stations_tab = setup()
	rows = stations_tab.query(pd)
	assert_eq(ids(rows), { 3, 4 })
end)

-- The collector refills records in place, so a renamed station keeps its record table.
test("query: a refilled record is merged into the kept order once its pass has completed", function()
	local stations_tab, collector, snap = setup()
	local pd = { filters = {} }
	stations_tab.query(pd)
	assert_eq(pd.cache.stations.sort_kind, "full")
	snap.stations[8].name, snap.stations[8].name_lower = "Aardvark", "aardvark"
	local log = storage.manager.collect_log
	log.ids[#log.ids + 1] = 8
	-- The pass that replaced the record completed on this very tick: the re-sort waits one update.
	snap.tick = 20
	local rows, _, ctx = stations_tab.query(pd)
	assert_eq(ids(rows), { 1, 2, 3, 4, 5, 6, 7, 8, 9 })
	assert_eq(rows[8].st.name, "Aardvark")
	assert_eq(ctx.status[8], "ok")
	game.tick = 21
	rows = stations_tab.query(pd)
	assert_eq(ids(rows), { 8, 1, 2, 3, 4, 5, 6, 7, 9 })
	assert_eq(pd.cache.stations.sort_kind, "merged")
	assert_eq({ collector.log_position() }, { pd.cache.stations.epoch, pd.cache.stations.pos })
end)

test("query: statuses the collector changed and logged update the cached counts", function()
	local stations_tab, _, snap = setup()
	local pd = { filters = {} }
	stations_tab.query(pd)
	snap.stations[4].status = "ok"
	snap.stations[9].status = "starved"
	local log = storage.manager.collect_log
	log.ids[#log.ids + 1] = 4
	log.ids[#log.ids + 1] = 9
	local rows, counts, ctx = stations_tab.query(pd)
	assert_eq(ctx.status[4], "ok")
	assert_eq(ctx.status[9], "starved")
	assert_eq(counts.starved, 1)
	assert_eq(counts.ok, 3)
	assert_eq(#rows, 9)
end)

test("query: the status is read from the record, never recomputed", function()
	local stations_tab, _, snap = setup()
	snap.stations[8].status = "saturated"
	local _, counts, ctx = stations_tab.query({ filters = {} })
	assert_eq(ctx.status[8], "saturated")
	assert_eq(counts.saturated, 2)
end)

test("query: removed station leaves rows and counts", function()
	local stations_tab, _, snap = setup()
	local pd = { filters = {} }
	stations_tab.query(pd)
	snap.stations[5] = nil
	local log = storage.manager.collect_log
	log.ids[#log.ids + 1] = 5
	local rows, counts = stations_tab.query(pd)
	assert_eq(counts.all, 8)
	assert_eq(counts.saturated, 0)
	assert_eq(ids(rows), { 1, 2, 3, 4, 6, 7, 8, 9 })
end)

-- The classification includes the chip flags, so the first build takes three updates (classify, sort, rows).
test("query: the first build after a boosted pass is spread over the three updates after the one that completed it", function()
	local stations_tab, _, snap = setup()
	local pd = { player_index = 1, filters = {} }
	snap.boosted = true
	snap.tick = 20
	local rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 0)
	assert_eq(counts, {})
	assert_true(ctx.pending)
	assert_nil(pd.cache.stations)
	-- Next update: classified into the cache, not sorted yet, rows still pending.
	game.tick = 21
	rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 0)
	assert_true(ctx.pending)
	assert_nil(pd.cache.stations.order)
	assert_eq(pd.cache.stations.counts.all, 9)
	-- The one after: sorted, rows still pending.
	game.tick = 22
	rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 0)
	assert_true(ctx.pending)
	assert_eq(#pd.cache.stations.order, 9)
	game.tick = 23
	rows, counts, ctx = stations_tab.query(pd)
	assert_eq(#rows, 9)
	assert_eq(counts.all, 9)
	assert_nil(ctx.pending)
	-- Only the first build waits: a cache in hand keeps showing rows on the completing update.
	snap.tick = 21
	rows = stations_tab.query(pd)
	assert_eq(#rows, 9)
end)

test("query: a pass completed by run_to_completion or the regular step shows rows at once", function()
	local stations_tab, _, snap = setup()
	snap.tick = 20
	local rows = stations_tab.query({ player_index = 1, filters = {} })
	assert_eq(#rows, 9)
end)

-- The chips besides the statuses. Each chip's count is what it shows when toggled.
test("chips: unserved, problems, stuck and failing count what they show", function()
	local stations_tab, collector, snap = setup()
	snap.stations[5].unserved = { count = 2, worst_reason = 1, oldest_first_tick = 1 }
	snap.stations[6].lint = 8
	snap.stations[7].throttling = true
	snap.stations[8].lint = 1
	snap.stations[8].unserved = { count = 1, worst_reason = 1, oldest_first_tick = 1 }
	snap.trains = { [70] = { id = 70, p_station_id = 4, r_station_id = 9 }, [71] = { id = 71, p_station_id = 3 } }
	snap.alerts = { { train_id = 70, kind = 1 }, { train_id = 71, kind = 2 } }
	local pd = { filters = {} }
	local _, counts = stations_tab.query(pd)
	assert_eq({ counts.unserved, counts.problems, counts.stuck, counts.failing }, { 2, 2, 2, 5 })
	-- The Problems view sorts worst first: capacity (8) before the check behind bit 8 (6).
	local want = { unserved = { 5, 8 }, problems = { 8, 6 }, stuck = { 4, 9 }, failing = { 1, 2, 6, 7, 8 } }
	for chip, list in pairs(want) do
		pd.filters.stations_chip = nil
		stations_tab.set_chip(pd, chip)
		local rows, c = stations_tab.query(pd)
		assert_eq(ids(rows), list, chip)
		assert_eq(#rows, c[chip], chip .. " count == rows")
	end
	-- Toggling the active chip again shows all; a status chip replaces a flag chip.
	pd = { filters = {} }
	stations_tab.set_chip(pd, "failing")
	assert_eq(pd.filters.stations_chip, "failing")
	stations_tab.set_chip(pd, "failing")
	assert_nil(pd.filters.stations_chip)
	stations_tab.set_chip(pd, "problems")
	stations_tab.set_chip(pd, "ok")
	assert_eq(pd.filters.stations_chip, "ok")
	-- The surface filter narrows every chip count.
	snap.stations[8].surface_index = 2
	local _, narrowed = stations_tab.query({ filters = { surface = 1 } })
	assert_eq({ narrowed.unserved, narrowed.problems }, { 1, 1 })
end)

-- The Overview's Misconfigured line counts stations with an error nobody acknowledged; the Problems view
-- it jumps to lists those first, so a station whose findings are all acknowledged moves behind the open ones as soon
-- as the acknowledgement changes (storage.acks.lint_version), without waiting for a collector pass.
test("problems view: acknowledged stations sort after the open ones, at once", function()
	local stations_tab, _, snap = setup()
	snap.stations[6].lint = 8
	snap.stations[8].lint = 1
	local pd = { filters = {} }
	stations_tab.set_chip(pd, "problems")
	assert_eq(ids((stations_tab.query(pd))), { 8, 6 })
	storage.acks = { request = {}, station = {}, lint = { [8] = { [1] = { player_index = 1 } } }, lint_version = 1 }
	local rows, counts = stations_tab.query(pd)
	assert_eq(ids(rows), { 6, 8 }, "the fully acknowledged station goes last")
	assert_eq(counts.problems, 2, "the chip still counts every station with a finding")
	storage.acks.lint[8] = nil
	storage.acks.lint_version = 2
	assert_eq(ids((stations_tab.query(pd))), { 8, 6 }, "ending the acknowledgement puts it back")
	storage.acks = nil
end)

test("chips: a refilled record moves between chip counts with the change log", function()
	local stations_tab, collector, snap = setup()
	local pd = { filters = {} }
	local _, counts = stations_tab.query(pd)
	assert_eq(counts.problems, 0)
	snap.stations[3].lint = 4
	local manager = storage.manager
	manager.collect_log = manager.collect_log or { epoch = 1, base = 0, ids = {} }
	local log = manager.collect_log
	log.ids[#log.ids + 1] = 3
	local _, after = stations_tab.query(pd)
	assert_eq(after.problems, 1)
	assert_eq(after.failing, 3)
end)

-- Names sort by the value of their digit runs, ties keep the id order.
test("query: natural name order (stn-1 < stn-2 < stn-10), both directions", function()
	local stations_tab, _, snap = setup()
	snap.stations = {
		[1] = st(1, "stn-10"),
		[2] = st(2, "stn-2"),
		[3] = st(3, "stn-1"),
		[4] = st(4, "stn-02"),
		[5] = st(5, "Alpha"),
	}
	for _, record in pairs(snap.stations) do record.status = "ok" end
	assert_eq(ids((stations_tab.query({ filters = {} }))), { 5, 3, 2, 4, 1 })
	local pd = { sort = { stations_tab = { column = "name", ascending = false } }, filters = {} }
	assert_eq(ids((stations_tab.query(pd))), { 1, 2, 4, 3, 5 })
	-- Another column's ties fall back to the natural order too.
	pd = { sort = { stations_tab = { column = "station_status", ascending = true } }, filters = {} }
	assert_eq(ids((stations_tab.query(pd))), { 5, 3, 2, 4, 1 })
end)

-- The Problems chip opens its view sorted worst first; leaving it drops that sort.
test("problems chip: worst severity then check order; the sort comes and goes with the chip", function()
	local stations_tab, _, snap = setup()
	snap.stations[2].lint = LINT_BIT[LINT_NEVER_REFUELLED]
	snap.stations[4].lint = LINT_BIT[LINT_LIMIT_ZERO]
	snap.stations[6].lint = LINT_BIT[LINT_LIMIT_ZERO] + LINT_BIT[LINT_LAYOUT]
	snap.stations[8].lint = LINT_BIT[LINT_CAPACITY]
	local pd = { filters = {} }
	stations_tab.set_chip(pd, "problems")
	local rows, counts, _, column, ascending = stations_tab.query(pd)
	assert_eq({ column, ascending }, { "problems", true })
	assert_eq(counts.problems, 4)
	-- Errors (capacity 1, layout 2) before the warning (limit_zero) before the info (never_refuelled).
	assert_eq(ids(rows), { 8, 6, 4, 2 })
	stations_tab.set_chip(pd, "problems")
	local _, _, _, column2 = stations_tab.query(pd)
	assert_eq(column2, "name")
	-- Provided / requested stands in for Problems outside the view, and the other way round.
	pd = { sort = { stations_tab = { column = "provided_requested", ascending = true } }, tabs = { stations_tab = { problems_view = true } },
		filters = { stations_chip = "problems" } }
	local _, _, _, column3 = stations_tab.query(pd)
	assert_eq(column3, "problems")
end)

-- "Last dispatch" reads never until the first dispatch, and sorts with the stations without one.
test("last dispatch: never while last_delivery_tick is still the build tick; sorts last", function()
	local stations_tab, _, snap = setup()
	storage.stations = {
		[5] = { last_delivery_tick = 1000, created_tick = 1000 },
		[7] = { last_delivery_tick = 50000, created_tick = 1000 },
		[9] = { last_delivery_tick = 50000 },
	}
	for _, id in ipairs({ 1, 2, 3, 4, 5, 6, 8 }) do snap.stations[id].last_delivery_tick = nil end
	snap.stations[5].last_delivery_tick = 1000
	assert_true(stations_tab.never_dispatched(snap.stations[5]))
	assert_false(stations_tab.never_dispatched(snap.stations[7]))
	assert_false(stations_tab.never_dispatched(snap.stations[9]))
	local pd = { sort = { stations_tab = { column = "last_delivery", ascending = true } }, filters = {} }
	local order = ids((stations_tab.query(pd)))
	assert_eq({ order[1], order[2] }, { 7, 9 })
	assert_eq(order[#order], 8)
	storage.stations = {}
end)

-- Zero-count chips hide (All and the toggled one stay), the rest wrap in order, never abbreviated.
test("chip_lines: hide zero counts, wrap onto the second line in order, keep the toggled chip", function()
	local stations_tab = setup()
	local counts = { all = 30, no_power = 0, disabled = 2, warming_up = 0, starved = 3, saturated = 0, idle = 0, ok = 25,
		unserved = 4, problems = 6, stuck = 0, failing = 8 }
	local l1, l2 = stations_tab.chip_lines(counts, "all", 2000, 2000)
	assert_eq(l1, { "all", "disabled", "starved", "ok", "unserved", "problems", "failing" })
	assert_eq(l2, {})
	-- The toggled chip shows at zero; `always` keeps a chip whose count is not known yet.
	l1 = stations_tab.chip_lines(counts, "idle", 2000, 2000, { stuck = true })
	assert_eq(l1, { "all", "disabled", "starved", "idle", "ok", "unserved", "problems", "stuck", "failing" })
	-- Narrow: what does not fit goes to the second line, keeping the order; nothing is dropped while it fits there.
	l1, l2 = stations_tab.chip_lines(counts, "all", 200, 1000)
	assert_eq(l1, { "all", "disabled" })
	assert_eq(l2, { "starved", "ok", "unserved", "problems", "failing" })
	-- Once a chip went to the second line, the later ones follow it even if they would fit the first.
	l1, l2 = stations_tab.chip_lines({ all = 1, no_power = 1, ok = 1 }, "all", 160, 1000)
	assert_eq(l1, { "all" })
	assert_eq(l2, { "no_power", "ok" })
end)

-- ---------------------------------------------------------------- inventory rows

local F = require("inventory_fixtures")

local function fluid(name, order)
	prototypes.fluid[name] = prototypes.fluid[name]
		or { name = name, order = order, localised_name = { "fluid-name." .. name }, valid = true }
end

--- The naphthalene plant (F.naphtha: station combinator on A1, Inventory 1 on A3, Inventory 2 on A4) and the coal hub
--- (F.coal_both: A1 provides coal, Inventory 1 on A2 at priority 3 requests it) beside the nine plain stations.
local function setup_rows()
	local stations_tab, collector, snap = setup()
	fluid(F.NAPHTHA_OIL, "z[a]")
	fluid(F.LIQUID_FUEL, "z[b]")
	snap.stations[20] = F.naphtha(20)
	snap.stations[21] = F.coal_both(21)
	for _, id in ipairs({ 20, 21 }) do
		local r = snap.stations[id]
		r.comb_ok, r.warming_up, r.name_lower = true, false, string.lower(r.name)
	end
	return stations_tab, collector, snap
end

--- "id@index" of each row in display order.
local function row_ids(rows)
	local out = {}
	for i, r in ipairs(rows) do out[i] = r.st.id .. "@" .. r.index end
	return out
end

local function slot_ids(defs)
	local out = {}
	for i, d in ipairs(defs) do out[i] = d.tags.overflow and d.caption or d.tags.id end
	return out
end

test("query: a station lists one row per combinator; a name sort keeps them together in index order", function()
	local stations_tab = setup_rows()
	local pd = { filters = {} }
	local rows, counts, ctx = stations_tab.query(pd)
	assert_eq(row_ids(rows), { "1@0", "2@0", "3@0", "21@0", "21@1", "4@0", "5@0", "6@0", "7@0", "8@0", "9@0", "20@0",
		"20@1", "20@2" })
	assert_eq(counts.all, 11, "the counts are stations")
	assert_eq(ctx.stations, 11)
	assert_eq(rows[5].key, "21@2002")
	pd = { sort = { stations_tab = { column = "name", ascending = false } }, filters = {} }
	stations_tab = setup_rows()
	assert_eq(row_ids((stations_tab.query(pd))), { "20@0", "20@1", "20@2", "8@0", "9@0", "7@0", "6@0", "5@0", "4@0",
		"21@0", "21@1", "3@0", "2@0", "1@0" }, "descending keeps the station's own rows ascending")
end)

test("query: rows sort on their own network, provided / requested and priority", function()
	local stations_tab = setup_rows()
	local pd = { sort = { stations_tab = { column = "network", ascending = true } }, filters = {} }
	local rows = stations_tab.query(pd)
	assert_eq(row_ids(rows), { "1@0", "2@0", "3@0", "21@0", "4@0", "5@0", "6@0", "7@0", "8@0", "9@0", "20@0",
		"21@1", "20@1", "20@2" }, "mask 1 by name, then masks 2, 3, 4")
	stations_tab = setup_rows()
	pd = { sort = { stations_tab = { column = "priority", ascending = false } }, filters = {} }
	assert_eq(row_ids((stations_tab.query(pd)))[1], "21@1", "Inventory 1 of the coal hub at priority 3")
	stations_tab = setup_rows()
	pd = { sort = { stations_tab = { column = "provided_requested", ascending = false } }, filters = {} }
	rows = stations_tab.query(pd)
	local first = {}
	for i = 1, 6 do first[i] = rows[i].st.id .. "@" .. rows[i].index end
	assert_eq(first, { "3@0", "21@0", "21@1", "4@0", "9@0", "20@0" }, "one item each, by name")
	assert_eq(row_ids(rows)[#rows], "20@2", "Inventory 2 advertises nothing")
end)

test("query: the network filter lists the rows on that mask; the counts stay stations", function()
	local stations_tab = setup_rows()
	local pd = { filters = { network = "signal-A", mask = 4 } }
	local rows, counts = stations_tab.query(pd)
	assert_eq(row_ids(rows), { "20@2" })
	assert_eq(counts.all, 1)
	stations_tab = setup_rows()
	pd = { filters = { network = "signal-A", mask = 2 } }
	rows, counts = stations_tab.query(pd)
	assert_eq(row_ids(rows), { "21@1", "20@1" }, "mask 3 holds bit 2 too")
	assert_eq(counts.all, 2)
	stations_tab = setup_rows()
	rows = stations_tab.query({ filters = { item = F.COAL } })
	assert_eq(row_ids(rows), { "3@0", "21@0", "21@1", "4@0" }, "the coal hub provides it on one row and requests it on the other")
	stations_tab = setup_rows()
	rows = stations_tab.query({ filters = { station = 20 } })
	assert_eq(row_ids(rows), { "20@0", "20@1", "20@2" }, "the station chip lists every row of its station")
end)

test("query: a refilled station that gained an inventory gets its row merged in", function()
	local stations_tab, collector, snap = setup_rows()
	local pd = { filters = {} }
	stations_tab.query(pd)
	local hub = snap.stations[21]
	local i2 = { kind = "inventory", index = 2, unit = 2003, ok = true, priority = 0, network_name = "signal-A", mask = 1,
		provided = { stone = 10 }, requested = {}, ignored = {}, read = true }
	hub.sources[3] = i2
	F.rows(hub)
	local log = storage.manager.collect_log
	log.ids[#log.ids + 1] = 21
	snap.tick = 20
	game.tick = 21
	local rows = stations_tab.query(pd)
	assert_eq(row_ids(rows), { "1@0", "2@0", "3@0", "21@0", "21@1", "21@2", "4@0", "5@0", "6@0", "7@0", "8@0", "9@0",
		"20@0", "20@1", "20@2" })
	assert_eq(pd.cache.stations.sort_kind, "merged")
end)

test("query: the Problems view lists a station once, on its station combinator's row", function()
	local stations_tab, _, snap = setup_rows()
	snap.stations[20].lint = 8
	local pd = { filters = {} }
	stations_tab.set_chip(pd, "problems")
	assert_eq(row_ids((stations_tab.query(pd))), { "20@0" })
end)

test("query: under a filter that drops the station combinator's row, the Problems view lists the first kept row", function()
	local stations_tab, _, snap = setup_rows()
	snap.stations[20].lint = 8
	snap.stations[21].lint = 8
	local pd = { filters = { network = "signal-A", mask = 2 } }
	stations_tab.set_chip(pd, "problems")
	local rows, counts = stations_tab.query(pd)
	assert_eq(counts.problems, 2)
	assert_eq(row_ids(rows), { "21@1", "20@1" }, "Inventory 1 of each: mask 3 and mask 2 hold bit 2")
	stations_tab, _, snap = setup_rows()
	snap.stations[20].lint = 8
	pd = { filters = { item = F.LIQUID_FUEL } }
	stations_tab.set_chip(pd, "problems")
	rows, counts = stations_tab.query(pd)
	assert_eq(counts.problems, 1)
	assert_eq(row_ids(rows), { "20@1" }, "only Inventory 1 provides liquid fuel")
end)

test("network cell: each row shows its own network and mask, no badge", function()
	local stations_tab, collector = setup_rows()
	local rows = collector.inventories(F.naphtha(20))
	local masks = {}
	for i, row in ipairs(rows) do
		local cell = stations_tab.network_cell(row)
		masks[i] = cell.caption
		assert_eq(cell.sprite, "virtual-signal/signal-A")
	end
	assert_eq(masks, { "1", "3", "4" })
	assert_eq(stations_tab.network_cell(rows[2]).sig, "signal-A=3")
	local unread = F.naphtha(20)
	unread.sources[3].mask, unread.sources[3].read = nil, false
	unread.comb_ok = true
	F.rows(unread)
	local cell = stations_tab.network_cell(collector.inventories(unread)[3])
	assert_eq(cell.caption, "–")
	assert_eq(cell.tooltip[1], "cybersyn-gui.section-paused-no-signals")
	-- Read, but its own input is empty or the combinator is off: the station combinator is not to blame.
	local empty = F.naphtha(20)
	empty.sources[3].mask, empty.sources[3].read, empty.sources[3].ok = nil, true, true
	F.rows(empty)
	cell = stations_tab.network_cell(collector.inventories(empty)[3])
	assert_eq(cell.caption, "–")
	assert_eq(cell.tooltip[1], "cybersyn-gui.stations-inventory-empty-tooltip")
	local off = F.naphtha(20)
	off.sources[3].mask, off.sources[3].read, off.sources[3].ok = nil, true, false
	F.rows(off)
	local off_cell = stations_tab.network_cell(collector.inventories(off)[3])
	assert_eq(off_cell.tooltip[1], "cybersyn-gui.stations-inventory-off-tooltip")
	assert_true(off_cell.sig ~= cell.sig, "the reason is part of the sig")
end)

test("network cell: an inventory on a NETWORK_EACH station that advertises on no network reads –, not ×0", function()
	local stations_tab = setup_rows()
	local row = { st = { comb_ok = false }, kind = "inventory", index = 1, label = "Inventory 1",
		network_name = NETWORK_EACH, src = { read = false, ok = true } }
	local cell = stations_tab.network_cell(row)
	assert_eq(cell.caption, "–")
	assert_eq(cell.sprite, "virtual-signal/" .. NETWORK_EACH)
	assert_eq(cell.tooltip[1], "cybersyn-gui.section-paused")
	assert_nil(stations_tab.sort_keys.network(row), "it sorts with the unread rows, last")
end)

test("network cell: a NETWORK_EACH combinator reads ×N with one tooltip line per network", function()
	local stations_tab = setup_rows()
	local row = { st = {}, index = 0, network_name = NETWORK_EACH, networks = { ["signal-B"] = 2, ["signal-A"] = 1 } }
	local cell = stations_tab.network_cell(row)
	assert_eq(cell.caption, { "cybersyn-gui.network-each-count", 2 })
	assert_eq(cell.sig, NETWORK_EACH .. "|signal-A=1,signal-B=2")
	assert_eq(#cell.tooltip, 3)
end)

test("strip: each row shows its own provides and requests, ungrouped; deliveries sit on the station row", function()
	local stations_tab, collector = setup_rows()
	local n = F.naphtha(20)
	n.deliveries = { [F.NAPHTHA_OIL] = -2000 }
	local rows = collector.inventories(n)
	assert_eq(slot_ids(stations_tab.pr_slots(rows[1], nil, 12)), { F.NAPHTHA_OIL })
	assert_eq(slot_ids(stations_tab.pr_slots(rows[2], nil, 12)), { F.LIQUID_FUEL })
	assert_eq(slot_ids(stations_tab.pr_slots(rows[3], nil, 12)), {}, "Inventory 2 holds its fuel back")
	assert_eq(stations_tab.slot_key(stations_tab.pr_slots(rows[2], nil, 12)[1]), F.LIQUID_FUEL)
	assert_eq(#stations_tab.dl_slots(rows[1], nil, 4), 1)
	assert_eq(#stations_tab.dl_slots(rows[2], nil, 4), 0)
	local sigs = stations_tab.slot_sigs(rows[2], nil, 0)
	assert_eq(sigs.dl, "")
	assert_true(sigs.pr ~= stations_tab.slot_sigs(rows[1], nil, 0).pr)
	local hub = collector.inventories(F.coal_both(21))
	assert_eq(slot_ids(stations_tab.pr_slots(hub[1], nil, 12)), { F.COAL })
	assert_eq(slot_ids(stations_tab.pr_slots(hub[2], nil, 12)), { F.COAL })
end)

test("sort keys and wait: the row's own items, mask, priority and longest active request", function()
	local stations_tab, collector = setup_rows()
	local k = stations_tab.sort_keys
	local rows = collector.inventories(F.naphtha(20))
	assert_eq({ k.provided_requested(rows[1]), k.provided_requested(rows[2]), k.provided_requested(rows[3]) }, { 1, 1, 0 })
	assert_eq(k.network(rows[3]), string.format("%s\0%010.0f", "signal-A", 4 + 2147483648))
	local hub = F.coal_both(21)
	hub.wait = { [F.COAL] = 500 }
	hub.longest_wait_start = 500
	local hr = collector.inventories(hub)
	assert_eq({ k.priority(hr[1]), k.priority(hr[2]) }, { 0, 3 })
	assert_nil(stations_tab.row_wait_start(hr[1]), "the station combinator requests nothing")
	assert_eq(stations_tab.row_wait_start(hr[2]), 500)
	local p = F.plain(30, "Plain", 1, {}, { [F.COAL] = { count = -5, threshold = 1, active = true } })
	p.longest_wait_start = 77
	assert_eq(stations_tab.row_wait_start(collector.inventories(p)[1]), 77, "a plain station's row is the station")
end)

test("priority cell: the row's own priority; * only on the station combinator's row", function()
	local stations_tab, collector = setup_rows()
	local hub = F.coal_both(21)
	hub.control2 = { [SIGNAL_PRIORITY] = 7 }
	hub.thresholds = { [F.COAL] = 100 }
	local rows = collector.inventories(hub)
	local c0, c1 = stations_tab.priority_cell(rows[1]), stations_tab.priority_cell(rows[2])
	assert_eq({ c0.caption, c1.caption }, { "0*", "3" })
	assert_true(serpent.line(c0.tooltip):find('"cybersyn-gui.stations-priority-item", "7", "1"', 1, true) ~= nil)
	assert_eq(#c1.tooltip, 2, "an inventory row has no item line: the control combinator's override is the station's")
	assert_eq(#c0.tooltip, 3)
	local legacy = st(30, "No sources", { priority = 3 })
	assert_eq(stations_tab.priority_cell(collector.inventories(legacy)[1]).caption, "3")
end)

test("marker: an inventory row names its combinator, links it and says when its request failed", function()
	local stations_tab, collector = setup_rows()
	local n = F.naphtha(20)
	local rows = collector.inventories(n)
	assert_nil(stations_tab.marker(rows[1]), "the station combinator's row has none")
	local m = stations_tab.marker(rows[2])
	assert_eq(m.unit, 1002)
	assert_eq(m.def.tags.kind, "entity")
	assert_eq(m.def.tags.id, 1002)
	-- Muted in the list, full colour on hover.
	assert_eq(m.def.sprite, "cybersyn-combinator-muted")
	assert_eq(m.def.hovered_sprite, "item/" .. COMBINATOR_NAME)
	assert_eq(m.tooltip[2], { "cybersyn-gui.stations-inventory-marker", "1", "0",
		{ "cybersyn-gui.stations-inventory-network", "[virtual-signal=signal-A]", "3" } })
	assert_nil(serpent.line(m.tooltip):find("relative-i-red", 1, true))
	n.sources[2].failed = true
	F.rows(n)
	local failed = stations_tab.marker(collector.inventories(n)[2])
	assert_true(serpent.line(failed.tooltip):find("relative-i-red", 1, true) ~= nil)
	assert_true(failed.sig ~= m.sig)
	local empty = F.naphtha(20)
	empty.sources[3].mask, empty.sources[3].read, empty.sources[3].ok = nil, true, true
	F.rows(empty)
	local e = stations_tab.marker(collector.inventories(empty)[3])
	assert_eq(e.tooltip[2][4], { "cybersyn-gui.stations-inventory-empty" }, "read, with an empty input: not 'not read'")
	local paused = F.naphtha(20)
	paused.sources[3].mask, paused.sources[3].read = nil, false
	F.rows(paused)
	local pz = stations_tab.marker(collector.inventories(paused)[3])
	assert_eq(pz.tooltip[2][4], { "cybersyn-gui.stations-inventory-unread" })
	assert_true(pz.sig ~= e.sig)
end)

test("network filter: a station shows under every bit any of its rows advertises on", function()
	local u = H.load("scripts.gui.utils.filters")
	local n = F.naphtha(20)
	local f = { mask = 4, network = "signal-A" }
	assert_true(u.station_passes(n, f), "bit 3 comes from Inventory 2")
	f.mask = 2
	assert_true(u.station_passes(n, f), "bit 2 from Inventory 1's mask 3")
	f.mask = 8
	assert_false(u.station_passes(n, f))
	f.network = "signal-B"
	f.mask = -1
	assert_false(u.station_passes(n, f))
	assert_true(u.station_passes(n, { mask = 4 }), "mask only")
	assert_true(u.row_passes(n.rows[3], { mask = 4 }))
	assert_false(u.row_passes(n.rows[1], { mask = 4 }), "the station combinator's row is on bit 1 only")
	assert_false(u.station_passes(n, { mask = 4, station = 21 }), "the station chip names another station")
	assert_true(u.station_passes(n, { mask = 4, station = 20 }))
	local p = st(21, "Circuit Requestor", { network_mask = 3 })
	assert_false(u.station_passes(p, { mask = 4, network = "signal-A" }), "a record without rows reads its own mask")
end)

test("column widths: no column goes negative and the row fits, at every content width and view", function()
	local stations_tab = H.load("scripts.gui.stations")
	local metrics = require("scripts.gui.metrics")
	local sizing = require("scripts.gui.sizing")
	local fixed = { "station_status", "network", "priority", "deliveries", "last_delivery" }
	-- From the narrowest window sizing.compute gives a screen of at least MIN_WIDTH logical px to the widest.
	for cw = sizing.MIN_WIDTH - sizing.OUTER_WIDTH, sizing.MAX_WIDTH - sizing.OUTER_WIDTH do
		for _, problems in ipairs({ false, true }) do
			for _, hide_wait in ipairs({ false, true }) do
				for _, control in ipairs({ false, true }) do
					local w = stations_tab.column_widths(cw, problems, hide_wait, control)
					local where = cw .. (problems and " problems" or "") .. (hide_wait and " no-wait" or "")
						.. (control and " control" or "")
					local sum, n = w.name + (problems and w.problems or w.provided_requested), 2
					for _, k in ipairs(fixed) do sum, n = sum + w[k], n + 1 end
					if not hide_wait then sum, n = sum + w.wait, n + 1 end
					if w.show_control then sum, n = sum + w.control, n + 1 end
					for k, v in pairs(w) do
						if type(v) == "number" then assert_true(v >= 0, where .. ": " .. k .. " = " .. v) end
					end
					assert_true(sum + (n - 1) * metrics.LIST_SPACING + 2 * metrics.LIST_ROW_PADDING + 16 <= cw, where .. " overflows")
					assert_eq(w.show_control, control and not problems, where)
				end
			end
		end
	end
end)

test("column widths: the Problems view keeps the name at its minimum on the narrowest window", function()
	local w = H.load("scripts.gui.stations").column_widths(912, true, false, false)
	assert_eq(w.name, 160)
	assert_true(w.problems > 0)
end)

test("control column: Auto shows it where it fits beside a full name; the toggle's choice wins", function()
	local stations_tab = H.load("scripts.gui.stations")
	local function pd(cw, choice)
		return { layout = { content_width = cw }, tabs = { stations_tab = { control = choice } } }
	end
	assert_true(stations_tab.control_shown(pd(1392)))
	assert_true(stations_tab.control_shown(pd(1104)))
	assert_false(stations_tab.control_shown(pd(912)), "1080p at UI scale 1.5")
	assert_true(stations_tab.control_shown(pd(912, true)))
	assert_false(stations_tab.control_shown(pd(1392, false)))
end)
