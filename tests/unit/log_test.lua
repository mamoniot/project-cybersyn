-- The Log tab's model (scripts/gui/log-model.lua): the two rings merged by seq, adjacent-row collapse, the rows that
-- follow the head, the severity counts under eviction and the window, the unread-error badge, the Summary
-- aggregation, age and message text, chat tags; plus every locale key the Log builds, in every locale.

local H = require("harness")

local diag, model

local function at(tick)
	game.tick = tick
end

local function setup(mode, ring)
	mod_settings.diagnostics = mode or "basic"
	storage.trains = storage.trains or {}
	storage.stations = storage.stations or {}
	diag = H.load("scripts.diag")
	diag.FULL_RING = ring or 16384
	model = H.load("scripts.gui.log-model")
	return diag.apply()
end

--- Writes one event; the kind decides the ring (full-only kinds need full mode).
local function ev(d, kind, sev, fields)
	fields = fields or {}
	return diag.event(d, kind, sev, fields.code or 0, fields.delivery or 0, fields.train or 0, fields.station or 0,
		fields.station2 or 0, fields.item or 0, fields.a or 0, fields.b or 0)
end

local function filter(over)
	local f = model.default_filter()
	for k, v in pairs(over or {}) do f[k] = v end
	return f
end

--- Brute force over diag.events: severities per filter, the reference the incremental counts must equal.
local function oracle_counts(d, cf)
	local c = { 0, 0, 0 }
	local rb, rf = model.rings(d)
	for _, r in ipairs({ rb, rf }) do
		for k = 0, r.count - 1 do
			local i = diag.ring_at(r, k)
			if (not cf.min_tick or r.tick[i] >= cf.min_tick) and model.match(r, i, cf) then
				c[r.sev[i]] = c[r.sev[i]] + 1
			end
		end
	end
	return c
end

test("scan_back merges both rings newest first, stops at the window, continues within a budget", function()
	at(100)
	local d = setup("full", 1024)
	ev(d, DIAG_KIND_SERVED, DIAG_SEV_INFO, { a = 1 })      -- seq 1 basic
	ev(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, { a = 2 })    -- seq 2 full
	at(200)
	ev(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, { a = 3 })    -- seq 3 full
	ev(d, DIAG_KIND_ALERT, DIAG_SEV_ERROR, { a = 4 })      -- seq 4 basic
	ev(d, DIAG_KIND_LEAVE_P, DIAG_SEV_INFO, { a = 5 })     -- seq 5 full
	local cf = model.compile(filter(), 300)
	local seen = {}
	local ended = model.scan_back(d.ring_basic, d.ring_full, d.seq + 1, cf, 100, function(r, i)
		seen[#seen + 1] = r.seq[i]
	end)
	assert_true(ended)
	assert_eq(seen, { 5, 4, 3, 2, 1 })
	-- Budget 2: two rows, then the scan says where to go on.
	seen = {}
	local ended2, below = model.scan_back(d.ring_basic, d.ring_full, d.seq + 1, cf, 2, function(r, i)
		seen[#seen + 1] = r.seq[i]
	end)
	assert_false(ended2)
	assert_eq(seen, { 5, 4 })
	assert_eq(below, 4)
	model.scan_back(d.ring_basic, d.ring_full, below, cf, 100, function(r, i) seen[#seen + 1] = r.seq[i] end)
	assert_eq(seen, { 5, 4, 3, 2, 1 })
	-- The window ends the scan at the first older row.
	cf = model.compile(filter({ window = 1 }), 200 + 36000 - 50)
	seen = {}
	model.scan_back(d.ring_basic, d.ring_full, d.seq + 1, cf, 100, function(r, i) seen[#seen + 1] = r.seq[i] end)
	assert_eq(seen, { 5, 4, 3 })
	-- The forward scan: oldest first, merged, bounded.
	local fwd = {}
	local reached, done = model.scan_fwd(d.ring_basic, d.ring_full, 1, 3, function(r, i) fwd[#fwd + 1] = r.seq[i] end)
	assert_eq({ fwd, reached, done }, { { 2, 3, 4 }, 4, false })
	-- Full off: the full ring is not read.
	local rb, rf = model.rings({ ring_basic = d.ring_basic, ring_full = d.ring_full, full = false })
	assert_same(rb, d.ring_basic)
	assert_nil(rf)
end)

test("collapse: adjacent identical rows become one with a count; the oldest seq is the key", function()
	setup()
	local function e(seq, kind, station, item, code)
		return { seq = seq, tick = seq * 10, kind = kind, sev = 2, code = code or 0, delivery = 0, train = 0,
			station = station, station2 = 0, item = item or 0, a = seq, b = 0 }
	end
	local rows = model.collapse({
		e(9, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_STUCK),
		e(8, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_STUCK),
		e(7, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_STUCK),
		e(6, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_MISSING_TRAIN),   -- another alert code: not identical
		e(5, DIAG_KIND_ALERT, 5, 0, DIAG_ALERT_STUCK),           -- identical to the first, but not adjacent
		e(4, DIAG_KIND_SHORT_LOAD, 5, 2),
		e(3, DIAG_KIND_SHORT_LOAD, 5, 3),                        -- another item
	})
	local shape = {}
	for i, g in ipairs(rows) do shape[i] = { g.seq, g.first, g.n, g.a } end
	assert_eq(shape, { { 9, 7, 3, 9 }, { 6, 6, 1, 6 }, { 5, 5, 1, 5 }, { 4, 4, 1, 4 }, { 3, 3, 1, 3 } })
	assert_eq(#model.collapse({ e(3, 1, 1), e(2, 1, 2), e(1, 1, 3) }, 2), 2)
	assert_eq(model.repeat_caption(1), "")
	assert_eq(model.repeat_caption(3), "×3")
	assert_eq(model.repeat_caption(1200), "×1,200")
	assert_eq(model.repeat_caption(11000), "×11k")
end)

test("collapse: never across severities, nor across the numbers that name a lint finding or an action", function()
	setup()
	local function e(seq, kind, sev, a, b)
		return { seq = seq, tick = seq, kind = kind, sev = sev, code = 0, delivery = 0, train = 0, station = 5,
			station2 = 0, item = 0, a = a, b = b }
	end
	-- Lint rows group by pass, never as identical rows. Written on different ticks outside a
	-- pass (delivery 0), each is a pass of its own.
	local rows = model.collapse({
		e(6, DIAG_KIND_LINT, DIAG_SEV_ERROR, 3, 5),
		e(5, DIAG_KIND_LINT, DIAG_SEV_WARNING, 7, 5),
		e(4, DIAG_KIND_LINT, DIAG_SEV_WARNING, 7, 5),
		e(3, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, 1, 2),
		e(2, DIAG_KIND_STATION_LIMIT, DIAG_SEV_WARNING, 1, 2),
		e(1, DIAG_KIND_STATION_LIMIT, DIAG_SEV_WARNING, 4, 9),
	})
	local shape = {}
	for i, g in ipairs(rows) do shape[i] = { g.seq, g.n, g.sev, g.a } end
	assert_eq(shape, { { 6, 1, DIAG_SEV_ERROR, 3 }, { 5, 1, DIAG_SEV_WARNING, 7 }, { 4, 1, DIAG_SEV_WARNING, 7 },
		{ 3, 1, DIAG_SEV_INFO, 1 }, { 2, 2, DIAG_SEV_WARNING, 1 } })
	local edits = model.collapse({ e(2, DIAG_KIND_SCHEDULE_EDITED, 3, 1, 1), e(1, DIAG_KIND_SCHEDULE_EDITED, 3, 2, 1) })
	assert_eq(#edits, 2)
	local actions = model.collapse({ e(2, DIAG_KIND_MANUAL_ACTION, 3, 1, 10), e(1, DIAG_KIND_MANUAL_ACTION, 3, 1, 11) })
	assert_eq(#actions, 2)
end)

test("rows: a backward fill to the limit, then the head followed; identical new events join the top row", function()
	at(1000)
	local d = setup()
	for s = 1, 6 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = s, a = s }) end
	local cf = model.compile(filter(), 1000)
	local rs = {}
	assert_true(model.update_rows(rs, d, cf, 4, true, 100))
	local function shape()
		local out = {}
		for i, g in ipairs(rs.groups) do out[i] = { g.first, g.n } end
		return out
	end
	assert_eq(shape(), { { 6, 1 }, { 5, 1 }, { 4, 1 }, { 3, 1 } })
	assert_nil(rs.below, "four rows found and a fifth that did not fit: complete")
	-- Nothing new: nothing changes.
	assert_false(model.update_rows(rs, d, cf, 4, true, 100))
	-- Two events identical to the newest row: one row, three events, same key.
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 6, a = 60 })
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 6, a = 61 })
	assert_true(model.update_rows(rs, d, cf, 4, true, 100))
	assert_eq(shape(), { { 6, 3 }, { 5, 1 }, { 4, 1 }, { 3, 1 } })
	assert_eq({ rs.groups[1].seq, rs.groups[1].a }, { 8, 61 })
	-- A different event pushes the bottom row out.
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 9 })
	model.update_rows(rs, d, cf, 4, true, 100)
	assert_eq(shape(), { { 9, 1 }, { 6, 3 }, { 5, 1 }, { 4, 1 } })
	-- Follow off: new events do not move the rows; back on: the rows are read from the head again.
	model.update_rows(rs, d, cf, 4, false, 100)
	local frozen = shape()
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 10 })
	model.update_rows(rs, d, cf, 4, false, 100)
	assert_eq(shape(), frozen)
	assert_eq(rs.anchor, 9)
	-- A filter change while frozen rescans up to the anchor only.
	local errors_too = model.compile(filter({ sev = { true, true, true }, group = 3 }), 1000)
	model.update_rows(rs, d, errors_too, 4, false, 100)
	assert_eq(shape()[1], { 9, 1 })
	model.update_rows(rs, d, cf, 4, true, 100)
	assert_eq(shape(), { { 10, 1 }, { 9, 1 }, { 6, 3 }, { 5, 1 } })
end)

test("rows: while paused, 'n newer' counts only the newer events the filter shows, within the budget", function()
	at(1000)
	local d = setup()
	for s = 1, 4 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = s }) end
	local only_7 = model.compile(filter({}), 1000, nil, 7)
	local rs = {}
	model.update_rows(rs, d, only_7, 4, false, 100)
	assert_eq({ model.newer(rs, d) }, { 0, true })
	-- Five newer events, two of them at station 7, one of those an info hidden by the severity filter of none.
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 7 })
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 8 })
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 7 })
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 9 })
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 9 })
	model.update_rows(rs, d, only_7, 4, false, 100)
	assert_eq({ model.newer(rs, d) }, { 2, true }, "two of the five newer events are this station's")
	-- A budget smaller than the gap: a partial count, completed on the next update.
	for _ = 1, 6 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 7 }) end
	model.update_rows(rs, d, only_7, 4, false, 3)
	local n, complete = model.newer(rs, d)
	assert_eq({ n, complete }, { 5, false })
	model.update_rows(rs, d, only_7, 4, false, 100)
	assert_eq({ model.newer(rs, d) }, { 8, true })
	-- Follow on: no paused count.
	model.update_rows(rs, d, only_7, 4, true, 100)
	assert_eq({ model.newer(rs, d) }, { 0, true })
end)

test("rows: a row whose events its ring has overwritten leaves; the other ring's older rows fill in", function()
	at(1000)
	local d = setup("full", 1024)
	-- An old basic row of station 7, then four full rows of station 7, then 1,100 full rows elsewhere.
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 7 })
	for _ = 1, 4 do ev(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, { station = 7, train = 3 }) end
	local only_7 = model.compile(filter({}), 1000, nil, 7)
	local rs = {}
	model.update_rows(rs, d, only_7, 4, true, 10000)
	assert_eq(#rs.groups, 2, "the four identical arrivals collapse into one row above the basic row")
	assert_true(rs.groups[1].full == true)
	for k = 1, 1100 do ev(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, { station = 8, train = k }) end
	model.update_rows(rs, d, only_7, 4, true, 10000)
	assert_eq(#rs.groups, 1, "the arrivals left the full ring")
	assert_eq({ rs.groups[1].kind, rs.groups[1].station }, { DIAG_KIND_STATION_LIMIT, 7 })
end)

test("rows: severity toggles, a sparse filter scanned over several updates, the window trims the bottom", function()
	at(0)
	local d = setup()
	ev(d, DIAG_KIND_ALERT, DIAG_SEV_ERROR, { train = 7, code = DIAG_ALERT_STUCK })
	for s = 1, 300 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = s }) end
	local rs = {}
	local cf = model.compile(filter({ train = 7 }), 0)
	model.update_rows(rs, d, cf, 5, true, 100)
	assert_eq(#rs.groups, 0)
	assert_not_nil(rs.below, "budget spent before the match")
	model.update_rows(rs, d, cf, 5, true, 100)
	model.update_rows(rs, d, cf, 5, true, 100)
	model.update_rows(rs, d, cf, 5, true, 100)
	assert_eq(#rs.groups, 1)
	assert_eq(rs.groups[1].train, 7)
	assert_nil(rs.below)
	-- Errors hidden: nothing.
	local rs2 = {}
	model.update_rows(rs2, d, model.compile(filter({ sev = { false, true, true }, train = 7 }), 0), 5, true, 1000)
	assert_eq(#rs2.groups, 0)
	-- Window: rows older than 10 min leave the bottom.
	at(36000 + 10)
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 999 })
	local rs3 = {}
	local w = model.compile(filter({ window = 1 }), 36000 + 10)
	model.update_rows(rs3, d, w, 5, true, 1000)
	assert_eq(#rs3.groups, 1)
	assert_eq(rs3.groups[1].station, 999)
end)

test("counts: equal a brute-force count through eviction, a moving window and a chunked first count", function()
	at(0)
	local d = setup("full", 1024)
	local sevs = { DIAG_SEV_ERROR, DIAG_SEV_WARNING, DIAG_SEV_INFO }
	local n = 0
	local function burst(k, tick_step)
		for _ = 1, k do
			n = n + 1
			at(game.tick + tick_step)
			local kind = (n % 3 == 0) and DIAG_KIND_ARRIVE_P or DIAG_KIND_STATION_LIMIT
			ev(d, kind, sevs[n % 3 + 1], { station = n % 7, train = n % 5 })
		end
	end
	burst(3000, 3)
	local f = filter({ window = 1 })
	local cs = {}
	local cf = model.compile(f, game.tick)
	-- 300-row budget: the first count takes several updates and says so.
	assert_true(model.update_counts(cs, d, cf, 300))
	local guard = 0
	while model.update_counts(cs, d, cf, 300) do guard = guard + 1 end
	assert_true(guard > 1)
	assert_eq(cs.total, oracle_counts(d, cf))
	for round = 1, 6 do
		burst(700, 7)
		cf = model.compile(f, game.tick)
		-- 700 new rows against a 300-row budget: caught up over three calls, each within the budget.
		local calls = 0
		while true do
			calls = calls + 1
			local building, used = model.update_counts(cs, d, cf, 300)
			assert_true(used <= 300)
			if not building then break end
		end
		assert_eq(calls, 3, "round " .. round)
		assert_eq(cs.total, oracle_counts(d, cf), "round " .. round)
	end
	-- Far behind (the Log was not shown for a while): a fresh chunked count, never one long walk.
	burst(model.COUNTS_BEHIND + 10, 1)
	cf = model.compile(f, game.tick)
	local building, used = model.update_counts(cs, d, cf, 300)
	assert_true(building)
	assert_true(used <= 300)
	while model.update_counts(cs, d, cf, 300) do end
	assert_eq(cs.total, oracle_counts(d, cf))
	-- Everything kept, with a station chip: still the brute force.
	local all = model.compile(filter({}), game.tick, nil, 3)
	local cs2 = {}
	while model.update_counts(cs2, d, all, 500) do end
	assert_eq(cs2.total, oracle_counts(d, all))
	burst(1500, 1)
	all = model.compile(filter({}), game.tick, nil, 3)
	while model.update_counts(cs2, d, all, 500) do end
	assert_eq(cs2.total, oracle_counts(d, all))
end)

test("count text: a building count is a lower bound with a plus, except a zero; short form from five digits", function()
	setup()
	assert_eq(model.count_text(0, true), "0")
	assert_eq(model.count_text(0, false), "0")
	assert_eq(model.count_text(21, true), "21+")
	assert_eq(model.count_text(21, false), "21")
	assert_eq(model.count_text(12345, true, true), "12.3k+")
	assert_eq(model.count_text(9999, false, true), model.count_text(9999, false))
end)

test("budget: rows and counts report the rows they examined and never pass the budget they were given", function()
	at(0)
	local d = setup("full", 4096)
	for n = 1, 3000 do ev(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, { train = n % 50 }) end
	-- A train with no events: the rows scan the whole ring, a budget's worth per update.
	local cf = model.compile(filter({ train = 999 }), game.tick)
	local rs, cs = {}, {}
	local updates = 0
	repeat
		updates = updates + 1
		local left = 400
		local _, used = model.update_rows(rs, d, cf, 10, true, left)
		assert_true(used <= left)
		left = left - used
		local _, used2 = model.update_counts(cs, d, cf, left)
		assert_true(used + used2 <= 400, "update " .. updates)
	until rs.below == nil and not cs.build
	assert_true(updates >= 3000 / 400)
	assert_eq(#rs.groups, 0)
	assert_eq(cs.total, { 0, 0, 0 })
end)

test("badge: errors after the last seen seq, counted forward within a budget; seen clears it", function()
	at(0)
	local d = setup()
	for k = 1, 10 do ev(d, DIAG_KIND_ALERT, k % 2 == 0 and DIAG_SEV_ERROR or DIAG_SEV_WARNING) end
	local bs = {}
	assert_eq(model.update_badge(bs, d, nil, 4), 2)
	assert_eq(model.update_badge(bs, d, nil, 100), 5)
	assert_eq(model.update_badge(bs, d, 10, 100), 0)
	ev(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR)
	assert_eq(model.update_badge(bs, d, 10, 100), 1)
	-- A new diagnostics state starts the count again.
	setup("off")
	at(50)
	d = setup("basic")
	ev(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR)
	assert_eq(model.update_badge(bs, d, 10, 100), 1)
end)

test("badge: errors of the first planner cycles after diagnostics start are the base's state, not news", function()
	at(100)
	local d = setup()
	for _ = 1, 6 do ev(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR) end
	at(200)
	ev(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR)
	local bs = {}
	-- While the threshold is unknown (math.huge) nothing counts; once known, the count starts over from it.
	assert_eq(model.update_badge(bs, d, nil, 100, math.huge), 0)
	assert_eq(model.update_badge(bs, d, nil, 100, 150), 1)
	assert_eq(model.update_badge(bs, d, nil, 100, nil), 7, "without a threshold every error counts")
end)

test("badge and Follow off across a diagnostics restart: an old state's seq means nothing in the new one", function()
	at(0)
	local d = setup()
	for _ = 1, 20 do ev(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR) end
	local seen = { state = model.state_id(d), seq = 15 }
	assert_eq(model.seen_seq(seen, d), 15)
	local rs = {}
	local cf = model.compile(filter({ follow = false }), 0)
	model.update_rows(rs, d, cf, 5, false, 100)
	assert_eq(rs.anchor, 20)
	setup("off")
	d = setup("basic")
	local bs = {}
	-- The new state's seq passes the old seen seq: the badge keeps counting every error of the new state.
	for k = 1, 25 do
		ev(d, DIAG_KIND_DISPATCH_FAILED, DIAG_SEV_ERROR)
		assert_eq(model.update_badge(bs, d, model.seen_seq(seen, d), 100), k)
	end
	-- The anchor is taken again in the new state's numbering.
	model.update_rows(rs, d, cf, 5, false, 100)
	assert_eq(rs.anchor, 25)
	assert_eq(rs.anchor_state, model.state_id(d))
end)

test("summary: top stations and items by events in the window with the worst severity", function()
	at(0)
	local d = setup()
	local iron = diag.intern(d, "iron-plate")
	local coal = diag.intern(d, "coal")
	for _ = 1, 3 do ev(d, DIAG_KIND_SHORT_LOAD, DIAG_SEV_WARNING, { station = 11, item = iron }) end
	ev(d, DIAG_KIND_UNSERVED_REASON, DIAG_SEV_ERROR, { station = 12, item = coal })
	ev(d, DIAG_KIND_UNSERVED_REASON, DIAG_SEV_INFO, { station = 12, item = coal })
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 13 })
	for s = 20, 35 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = s }) end
	local ss = {}
	local cf = model.compile(filter(), 0)
	local guard = 0
	while not model.update_summary(ss, d, cf, 5) do guard = guard + 1 end
	assert_true(guard >= 3)
	assert_eq(#ss.top_stations, model.SUMMARY_TOP)
	assert_eq({ ss.top_stations[1].id, ss.top_stations[1].n, ss.top_stations[1].sev }, { 11, 3, DIAG_SEV_WARNING })
	assert_eq({ ss.top_stations[2].id, ss.top_stations[2].n, ss.top_stations[2].sev }, { 12, 2, DIAG_SEV_ERROR })
	-- Ties: worse severity first, then the lower id.
	assert_eq({ ss.top_stations[3].id, ss.top_stations[4].id }, { 13, 20 })
	assert_eq(ss.top_items, { { item = iron, n = 3, sev = DIAG_SEV_WARNING }, { item = coal, n = 2, sev = DIAG_SEV_ERROR } })
	assert_eq(ss.scanned, 22)
	-- The severities apply: errors only.
	local ss2 = {}
	while not model.update_summary(ss2, d, model.compile(filter({ sev = { true, false, false } }), 0), 100) do end
	assert_eq(ss2.top_stations, { { id = 12, n = 1, sev = DIAG_SEV_ERROR } })
end)

test("summary top: the short insertion list equals a full sort", function()
	setup()
	local map, list = {}, {}
	local x = 7
	for id = 1, 500 do
		x = (x * 1103515245 + 12345) % 2147483648
		local n, sev = x % 13, 1 + x % 3
		map[id] = { n, sev }
		list[#list + 1] = { id = id, n = n, sev = sev }
	end
	table.sort(list, function(a, b)
		if a.n ~= b.n then return a.n > b.n end
		if a.sev ~= b.sev then return a.sev < b.sev end
		return a.id < b.id
	end)
	local want = {}
	for i = 1, model.SUMMARY_TOP do want[i] = list[i] end
	assert_eq(model.top(map, "id"), want)
	assert_eq(model.top({ [4] = { 1, 2 } }, "id"), { { id = 4, n = 1, sev = 2 } })
end)

test("compile and export_filter: groups take their alerts by code; train field and chip combine", function()
	setup()
	local cf = model.compile(filter({ group = 1 }), 100)
	assert_true(cf.kinds[DIAG_KIND_SERVED])
	assert_true(cf.alerts[DIAG_ALERT_MISSING_TRAIN])
	assert_nil(cf.alerts[DIAG_ALERT_STUCK])
	local ex = model.export_filter(model.compile(filter({ sev = { true, false, true }, train = 4 }), 100))
	assert_eq({ ex.sevs, ex.train, ex.min_tick }, { { [1] = true, [3] = true }, 4, nil })
	ex = model.export_filter(model.compile(filter({ window = 2 }), 300000, 3, 9))
	assert_eq({ ex.station, ex.min_tick, ex.item, ex.sevs }, { 9, 300000 - 216000, 3, nil })
	-- Every kind is in exactly one group, except alerts, which belong to a group by their code.
	local seen = {}
	for _, g in ipairs(model.GROUPS) do
		for _, k in ipairs(g.kinds) do
			assert_nil(seen[k], "kind " .. k .. " in two groups")
			seen[k] = true
		end
	end
	assert_nil(seen[DIAG_KIND_ALERT])
	seen[DIAG_KIND_ALERT] = true
	for k = 1, #DIAG_KIND_NAMES do assert_true(seen[k] == true, "kind " .. DIAG_KIND_NAMES[k] .. " in no group") end
	-- The trains group takes train alerts only; every kind can still be picked on its own.
	local trains = model.compile(filter({ group = 4 }), 100)
	assert_eq(model.GROUPS[4].name, "trains")
	assert_nil(trains.kinds[DIAG_KIND_ALERT])
	assert_true(trains.alerts[DIAG_ALERT_STUCK])
	assert_nil(trains.alerts[DIAG_ALERT_MISSING_TRAIN])
	local items = {}
	for _, it in ipairs(model.KIND_ITEMS) do
		if it.kind then items[it.kind] = (items[it.kind] or 0) + 1 end
	end
	for k = 1, #DIAG_KIND_NAMES do assert_eq(items[k], 1, "drop-down item " .. DIAG_KIND_NAMES[k]) end
	local codes = {}
	for _, g in ipairs(model.GROUPS) do
		for _, c in ipairs(g.alerts or {}) do codes[c] = (codes[c] or 0) + 1 end
	end
	for c = 1, #DIAG_ALERT_NAMES do assert_eq(codes[c], 1, "alert " .. DIAG_ALERT_NAMES[c]) end
end)

test("age: two units in the column, the absolute tick in the tooltip, the range for a collapsed row", function()
	setup()
	local one, four = { tick = 60, first_tick = 60, n = 1 }, { tick = 120, first_tick = 60, n = 4 }
	assert_eq(model.age_caption(7260, one), "2m 00s")
	assert_eq(model.age_caption(60, one), "0s")
	assert_eq(model.age_caption(60 + 59 * 60, one), "59s")
	assert_eq(model.age_caption(60 + 3 * 86400 * 60, one), "3d 00h")
	assert_eq(model.age_tooltip(one), { "cybersyn-gui.log-age-tooltip", "60", "1s" })
	assert_eq(model.age_caption(216000 + 120, four), "1h 00m")
	assert_eq(model.age_tooltip(four),
		{ "cybersyn-gui.log-age-range-tooltip", "60", "120", "1s", "2s", "4" })
end)

test("message: cargo reads loaded 18k of 24k, edits name the player, acknowledgements their expiry", function()
	setup()
	local ctx = {
		player = function(i) return ({ "Daniel", "Ozzy" })[i] end,
		stock = function(reason, a, b) return a .. "/" .. b end,
		chip = function(reason) return { "chip", reason } end,
	}
	local function g(kind, fields)
		local out = { kind = kind, code = 0, a = 0, b = 0, station2 = 0, tick = 600, seq = 1, n = 1 }
		for k, v in pairs(fields or {}) do out[k] = v end
		return out
	end
	assert_eq(model.message(g(DIAG_KIND_SHORT_LOAD, { a = 24000, b = 18000 }), ctx),
		{ "cybersyn-diag.msg-short-load", "18k", "24k" })
	assert_eq(model.message(g(DIAG_KIND_RESIDUAL_CARGO, { a = 400, b = 30 }), ctx),
		{ "cybersyn-diag.msg-residual-cargo", "30", "400" })
	assert_eq(model.message(g(DIAG_KIND_SCHEDULE_EDITED, { a = 2, b = 1 }), ctx),
		{ "cybersyn-diag.msg-schedule-edited", "Ozzy" })
	assert_eq(model.message(g(DIAG_KIND_SCHEDULE_EDITED, { a = 1, b = 5 }), ctx),
		{ "cybersyn-diag.msg-schedule-edited-group", "Daniel", "5" })
	assert_eq(model.message(g(DIAG_KIND_ACKNOWLEDGED, { code = DIAG_ACK_REQUEST, station2 = 1, a = 600 + 3600 }), ctx),
		{ "cybersyn-diag.msg-acknowledged", { "cybersyn-diag.ack-kind-request" }, "Daniel", "1m 0s" })
	assert_eq(model.message(g(DIAG_KIND_ACKNOWLEDGED, { code = DIAG_ACK_LINT, station2 = 2, a = 0 }), ctx),
		{ "cybersyn-diag.msg-acknowledged-reason", { "cybersyn-diag.ack-kind-lint" }, "Ozzy" })
	assert_eq(model.message(g(DIAG_KIND_UNSERVED_REASON, { code = REASON_P_BELOW_THRESHOLD, a = 5, b = 9 }), ctx),
		{ "cybersyn-diag.msg-unserved-reason", { "chip", REASON_P_BELOW_THRESHOLD }, "5/9" })
	assert_eq(model.message(g(DIAG_KIND_ALERT, { code = DIAG_ALERT_STUCK }), ctx),
		{ "cybersyn-diag.msg-alert", { "cybersyn-diag.alert-stuck" } })
	assert_eq(model.message(g(DIAG_KIND_TRAIN_STATE, { code = defines.train_state.wait_signal, a = 1200 }), ctx),
		{ "cybersyn-diag.msg-train-state-wait-signal", "20s" })
	assert_eq(model.message(g(DIAG_KIND_MANUAL_ACTION, { a = ACTION_FIX_PRIORITIES, station2 = 0 }), ctx),
		{ "cybersyn-diag.msg-manual-action", { "cybersyn-diag.action-fix-priorities" }, { "cybersyn-diag.log-server" } })
	assert_eq(model.message(g(DIAG_KIND_LINT, { code = DIAG_LINT_CLEARED, a = LINT_CAPACITY }), ctx),
		{ "cybersyn-diag.msg-lint-cleared", { "cybersyn-diag.lint-capacity" } })
	-- The plural is chosen on a plain number: "8,646" would print the raw __plural_for_parameter__ token.
	assert_eq(model.message(g(DIAG_KIND_SERVED, { code = REASON_P_BELOW_THRESHOLD, a = 600, b = 8646 }), ctx),
		{ "cybersyn-diag.msg-served", "10s", "8,646", { "chip", REASON_P_BELOW_THRESHOLD }, "8646" })
end)

test("locale: a plural parameter is never one the code fills with a grouped number", function()
	-- Keys whose shown number is format.number's: the plural reads a later, plain parameter.
	local plain = {
		["msg-served"] = 4, ["log-summary-count-tooltip"] = 2, ["log-summary-status"] = 3, ["log-paused"] = 2,
		["log-badge-tooltip"] = 2, ["log-lint-errors"] = 2, ["log-lint-warnings"] = 2, ["log-lint-infos"] = 2,
		["log-header"] = 3,
	}
	for _, lang in ipairs(H.LOCALES) do
		for line in H.locale_text(lang):gmatch("[^\n]+") do
			local key = line:match("^([%w%-]+)=")
			if key and plain[key] then
				local n = tonumber(line:match("__plural_for_parameter__(%d+)__"))
				assert_eq(n, plain[key], lang .. " " .. key)
			end
		end
	end
end)

test("chat tags: train by front stock unit number, stop by unit number, item, gps", function()
	setup()
	assert_eq(model.chat_tags(812, 4410, { x = 10.5, y = -3.5, surface = "nauvis" }, "iron-plate|rare"),
		"[train=812] [train-stop=4410] [item=iron-plate,quality=rare] [gps=10,-4,nauvis]")
	assert_eq(model.chat_tags(nil, nil, nil, "water"), "[fluid=water]")
	assert_eq(model.chat_tags(nil, 7, nil, nil), "[train-stop=7]")
end)

--- Every [section] key inside a LocalisedString.
local function collect_keys(ls, out)
	if type(ls) ~= "table" then return end
	local k = ls[1]
	if type(k) == "string" and k ~= "" then out[k] = true end
	for i = 2, #ls do collect_keys(ls[i], out) end
end

test("locale: every key the Log builds resolves in every locale", function()
	setup()
	local used = {}
	local ctx = {
		player = function() return "p" end,
		stock = function(reason) return reason == REASON_NO_PROVIDER and "–" or "1/2" end,
		chip = function() return "chip" end,
	}
	for kind = 1, #DIAG_KIND_NAMES do
		used["cybersyn-diag.kind-" .. DIAG_KIND_KEYS[kind]] = true
		local variants = {
			{}, { a = 1 }, { b = 1 }, { b = 3 }, { code = 1 }, { code = REASON_NO_PROVIDER },
			{ code = DIAG_LINT_CLEARED, a = 1 }, { code = DIAG_LINT_APPEARED, a = 1 },
			{ b = DIAG_ACK_END_MANUAL }, { b = DIAG_ACK_END_EXPIRED }, { a = 1, code = DIAG_ACK_STATION },
		}
		for _, v in ipairs(variants) do
			local g = { kind = kind, code = v.code or 0, a = v.a or 0, b = v.b or 0, station2 = 1, tick = 0, n = 1 }
			collect_keys(model.message(g, ctx), used)
		end
	end
	for code = 1, #DIAG_ALERT_NAMES do
		collect_keys(model.message({ kind = DIAG_KIND_ALERT, code = code, a = 0, b = 0, station2 = 0, tick = 0 }, ctx), used)
	end
	for code = 1, #DIAG_DISPATCH_NAMES do
		collect_keys(model.message({ kind = DIAG_KIND_DISPATCH_FAILED, code = code, a = 0, b = 0, tick = 0 }, ctx), used)
	end
	for code = 1, #DIAG_FAIL_NAMES do
		collect_keys(model.message({ kind = DIAG_KIND_DELIVERY_FAILED, code = code, a = 0, b = 0, tick = 0 }, ctx), used)
	end
	for _, state in pairs(defines.train_state) do
		collect_keys(model.message({ kind = DIAG_KIND_TRAIN_STATE, code = state, a = 0, b = 0, tick = 0 }, ctx), used)
	end
	for _, b in ipairs({ 1, 2, 3, 4 }) do
		collect_keys(model.message({ kind = DIAG_KIND_UNACKNOWLEDGED, code = 1, a = 0, b = b, station2 = 1, tick = 0 }, ctx),
			used)
	end
	collect_keys(model.message({ kind = DIAG_KIND_LINT, code = 1, a = 1, b = 0, tick = 0, n = 4, pass = 1,
		lint = { 1, 1, 1, 1 } }, ctx), used)
	for _, g in ipairs(model.GROUPS) do used["cybersyn-gui.log-group-" .. g.name] = true end
	for _, k in ipairs({ "error", "warning", "info" }) do used["cybersyn-diag.sev-" .. k] = true end
	-- The GUI's own keys: every "cybersyn-gui.log-..." and "cybersyn-diag...." literal in log.lua.
	local src = io.open(H.mod_root .. "/scripts/gui/log.lua"):read("*a")
	for key in string.gmatch(src, '"(cybersyn%-gui%.[%w%-]+)"') do
		if not string.match(key, "%-$") then used[key] = true end
	end
	for _, mode in ipairs({ "basic", "full-reach" }) do used["cybersyn-gui.log-mode-" .. mode] = true end
	for key in string.gmatch(src, '"(cybersyn%-diag%.[%w%-]+)"') do
		if not string.match(key, "%-$") then used[key] = true end
	end
	for _, loc in ipairs(H.LOCALES) do
		local cfg = H.locale(loc)
		local sections = { ["cybersyn-gui"] = cfg["cybersyn-gui"], ["cybersyn-diag"] = cfg["cybersyn-diag"] }
		local missing = {}
		for key in pairs(used) do
			local section, name = string.match(key, "^([^.]+)%.(.+)$")
			if sections[section] and not sections[section][name] then missing[#missing + 1] = loc .. ": " .. key end
		end
		table.sort(missing)
		assert_eq(missing, {}, loc)
	end
end)

test("dispatch tooltip: why/fix for every code, recorded state or not, in every locale; fix lines take no numbers", function()
	setup()
	assert_eq(#DIAG_DISPATCH_SEVERITY, #DIAG_DISPATCH_NAMES, "severity parallel to the names")
	local used, fixes = {}, {}
	local states, state_name = { 0 }, {}
	for name, st in pairs(defines.train_state) do
		states[#states + 1] = st + 1
		state_name[st + 1] = name
	end
	for code = 1, #DIAG_DISPATCH_NAMES do
		for _, a in ipairs(states) do
			local g = { kind = DIAG_KIND_DISPATCH_FAILED, code = code, a = a, b = 0, train = 15, tick = 0, n = 1 }
			local tip = model.dispatch_tooltip(g)
			assert_true(type(tip) == "table", "code " .. code .. " a " .. a)
			local why, fix = tip[2], tip[4]
			assert_eq({ why[1], why[2][1], why[2][2], fix[1], fix[2][1] }, { "cybersyn-gui.unserved-why",
				"cybersyn-diag.dispatch-why-" .. string.gsub(DIAG_DISPATCH_NAMES[code], "_", "-"), "15",
				"cybersyn-gui.unserved-fix", "cybersyn-diag.dispatch-fix-" .. string.gsub(DIAG_DISPATCH_NAMES[code], "_", "-") })
			if a == 0 then
				assert_eq(why[2][3], { "cybersyn-diag.dispatch-state-unknown" })
			else
				assert_eq(why[2][3][1], "cybersyn-diag.train-state-" .. string.gsub(state_name[a], "_", "-"))
			end
			collect_keys(tip, used)
			fixes[fix[2][1]] = true
		end
	end
	assert_eq(model.dispatch_tooltip({ kind = DIAG_KIND_DISPATCH_FAILED, code = 99, a = 0, b = 0, train = 1 }), nil)
	assert_eq(model.dispatch_tooltip({ kind = DIAG_KIND_SERVED, code = 1, a = 0, b = 0, train = 1 }), nil)
	for _, loc in ipairs(H.LOCALES) do
		local cfg = H.locale(loc)
		local sections = { ["cybersyn-gui"] = cfg["cybersyn-gui"], ["cybersyn-diag"] = cfg["cybersyn-diag"] }
		local missing, numbered = {}, {}
		for key in pairs(used) do
			local section, name = string.match(key, "^([^.]+)%.(.+)$")
			local v = sections[section] and sections[section][name]
			if not v then missing[#missing + 1] = loc .. ": " .. key end
			if v and fixes[key] and string.find(v, "__", 1, true) then numbered[#numbered + 1] = loc .. ": " .. key end
		end
		table.sort(missing)
		table.sort(numbered)
		assert_eq(missing, {}, loc)
		assert_eq(numbered, {}, loc .. " fix lines")
	end
end)

test("lint passes: one row per pass whatever lies between its rows, counts by severity, cleared apart", function()
	at(1000)
	local d = setup()
	local P = 501
	local function lint(sev, code, station, a, pass)
		return ev(d, DIAG_KIND_LINT, sev, { code = code, delivery = pass or P, station = station, b = station, a = a })
	end
	lint(DIAG_SEV_ERROR, DIAG_LINT_APPEARED, 1, 3)                        -- seq 1
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 9, a = 1 })  -- seq 2, between the pass's rows
	lint(DIAG_SEV_WARNING, DIAG_LINT_APPEARED, 2, 5)                      -- seq 3
	lint(DIAG_SEV_INFO, DIAG_LINT_CLEARED, 1, 7)                          -- seq 4
	local rs = { groups = {} }
	local cf = model.compile(filter(), 1000)
	model.update_rows(rs, d, cf, model.PAGE, true, 100)
	local g = rs.groups[1]
	assert_eq(#rs.groups, 2, "the pass and the station row")
	assert_eq({ g.pass, g.n, g.lint, g.seqs, g.seq, g.first, g.sev, g.station }, { P, 3, { 1, 1, 0, 1 }, { 4, 3, 1 }, 4, 1,
		DIAG_SEV_ERROR, 0 })
	assert_eq(rs.groups[2].kind, DIAG_KIND_STATION_LIMIT)
	-- Following: the pass's next row joins it and moves it back to the top over a newer event.
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 8, a = 2 })  -- seq 5
	model.update_rows(rs, d, cf, model.PAGE, true, 100)
	assert_eq(rs.groups[1].kind, DIAG_KIND_STATION_LIMIT)
	lint(DIAG_SEV_ERROR, DIAG_LINT_APPEARED, 3, 3)                        -- seq 6
	model.update_rows(rs, d, cf, model.PAGE, true, 100)
	assert_eq({ #rs.groups, rs.groups[1].pass, rs.groups[1].n, rs.groups[1].lint }, { 3, P, 4, { 2, 1, 0, 1 } })
	-- Another pass is another row; a row written outside a pass groups by its tick.
	lint(DIAG_SEV_ERROR, DIAG_LINT_APPEARED, 4, 3, 777)
	at(1001)
	lint(DIAG_SEV_WARNING, DIAG_LINT_APPEARED, 4, 3, 0)
	lint(DIAG_SEV_WARNING, DIAG_LINT_APPEARED, 5, 3, 0)
	model.update_rows(rs, d, cf, model.PAGE, true, 100)
	assert_eq({ rs.groups[1].pass, rs.groups[1].n, rs.groups[2].pass, rs.groups[2].n }, { -1001, 2, 777, 1 })
	-- The same rows from a backward scan (a fresh filter) give the same rows.
	local fresh = { groups = {} }
	model.update_rows(fresh, d, model.compile(filter({ window = 3 }), 1001), model.PAGE, true, 100)
	local function shape(groups)
		local out = {}
		for i, x in ipairs(groups) do out[i] = (x.pass or "-") .. ":" .. x.n .. ":" .. x.seq .. ":" .. x.first end
		return table.concat(out, ",")
	end
	assert_eq(shape(fresh.groups), shape(rs.groups))
	-- Only errors: the pass shows its errors only.
	local errs = { groups = {} }
	model.update_rows(errs, d, model.compile(filter({ sev = { true, false, false } }), 1001), model.PAGE, true, 100)
	assert_eq({ errs.groups[2].pass, errs.groups[2].n, errs.groups[2].lint }, { P, 2, { 2, 0, 0, 0 } })
end)

test("lint passes: the caption counts the pass; a pass of one row reads as that finding", function()
	setup()
	local ctx = { player = function() return "p" end,
		stock = function() return "1/2" end, chip = function() return "chip" end }
	local g = { kind = DIAG_KIND_LINT, code = DIAG_LINT_APPEARED, a = 3, b = 0, tick = 0, n = 3, pass = 1,
		lint = { 25, 6, 0, 2 } }
	local m = model.message(g, ctx)
	assert_eq(m[1], "cybersyn-gui.log-lint-pass")
	assert_eq(m[3], "▸")
	assert_eq(model.message(g, ctx, true)[3], "▾")
	assert_eq(m[2], { "", { "cybersyn-gui.log-lint-errors", "25", "25" }, ", ",
		{ "cybersyn-gui.log-lint-warnings", "6", "6" }, ", ", { "cybersyn-gui.log-lint-cleared", "2", "2" } })
	g.n = 1
	assert_eq(model.message(g, ctx)[1], "cybersyn-diag.msg-lint-appeared")
end)

test("display: an expanded pass lists its rows below it, newest first, within the page", function()
	local pass = { first = 10, seq = 14, n = 3, pass = 7, seqs = { 14, 12, 10 } }
	local other = { first = 9, seq = 9, n = 1 }
	local function lookup(seq)
		if seq == 12 then return nil end
		return { seq = seq, first = seq, n = 1 }
	end
	local rows = model.display({ pass, other }, nil, lookup, 200)
	assert_eq({ #rows, rows[1].key, rows[1].x, rows[2].key }, { 2, 10, nil, 9 })
	rows = model.display({ pass, other }, { [7] = true }, lookup, 200)
	local keys = {}
	for i, r in ipairs(rows) do keys[i] = r.key .. (r.child and "c" or "") .. (r.x and "x" or "") end
	assert_eq(keys, { "10x", "14.5c", "10.5c", "9" }, "a row its ring dropped is left out")
	assert_eq(#model.display({ pass, other }, { [7] = true }, lookup, 2), 2)
	-- A pass of one row has nothing to expand.
	assert_eq(#model.display({ { first = 1, seq = 1, n = 1, pass = 3, seqs = { 1 } } }, { [3] = true }, lookup, 9), 1)
end)

test("rows: held (pointer over the rows, window paused), Follow takes nothing in at the top; release catches up", function()
	at(1000)
	local d = setup()
	for s = 1, 3 do ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = s, a = s }) end
	local rs = { groups = {} }
	local cf = model.compile(filter(), 1000)
	model.update_rows(rs, d, cf, model.PAGE, true, 100)
	assert_eq(#rs.groups, 3)
	ev(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, { station = 7, a = 7 })
	assert_false(model.update_rows(rs, d, cf, model.PAGE, true, 100, true))
	assert_eq({ #rs.groups, rs.groups[1].a }, { 3, 3 })
	assert_true(model.update_rows(rs, d, cf, model.PAGE, true, 100, false))
	assert_eq({ #rs.groups, rs.groups[1].a }, { 4, 7 })
	assert_eq(model.PAGE, 200)
end)

test("badge: unread errors, capped at 99+", function()
	assert_eq({ model.badge_caption(0), model.badge_caption(7), model.badge_caption(99), model.badge_caption(100),
		model.badge_caption(4321) }, { "", "7", "99", "99+", "99+" })
end)

test("names: lead · text · tail; when the cell is short the lead icons go before the tail's", function()
	local name_cell = require("scripts.gui.name-cell")
	local parts = { lead = { "item/a", "item/b", "item/c" }, tail = { "item/x", "item/y" }, text = "Requestor for" }
	-- 5 icons × 22 px + 120 px of text + 4 fit 234 px.
	assert_eq({ name_cell.fit_counts(parts, 300) }, { 3, 2 })
	assert_eq({ name_cell.fit_counts(parts, 234) }, { 3, 2 })
	assert_eq({ name_cell.fit_counts(parts, 233) }, { 2, 2 })
	assert_eq({ name_cell.fit_counts(parts, 168) }, { 0, 2 })
	assert_eq({ name_cell.fit_counts(parts, 140) }, { 0, 0 })
	assert_eq({ name_cell.fit_counts({ lead = { "a", "b", "c", "d" } }, 1000) }, { 3, 0 }, "at most POOL_ICONS a side")
	assert_eq({ name_cell.fit_counts(nil, 300) }, { 0, 0 })
end)
