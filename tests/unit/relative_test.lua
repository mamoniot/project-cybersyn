-- The pure builders of the relative panels (scripts/gui/relative-text.lua) and the bounded backward scan they read
-- the log with (diag.last_for_step).

local H = require("harness")

local function rt()
	return H.load("scripts.gui.relative-text")
end

local function collector()
	return require("scripts.gui.collector")
end


test("role: provider, requester, both, none; stack mode appended", function()
	local t = rt()
	assert_eq(t.role(true, true, false), { "cybersyn-gui.relative-role-both" })
	assert_eq(t.role(true, false, false), { "cybersyn-gui.relative-role-provider" })
	assert_eq(t.role(false, true, false), { "cybersyn-gui.relative-role-requester" })
	assert_eq(t.role(false, false, false), { "cybersyn-gui.relative-role-none" })
	assert_eq(t.role(false, true, true),
		{ "", { "cybersyn-gui.relative-role-requester" }, " · ", { "cybersyn-gui.relative-stack-mode" } })
end)

test("stacks: whole stacks a threshold fills, rounded up; no stack size reads 0", function()
	local t = rt()
	assert_eq(t.stacks(2000, 100), 20)
	assert_eq(t.stacks(2001, 100), 21)
	assert_eq(t.stacks(2000, 5), 400)
	assert_eq(t.stacks(1, 200), 1)
	assert_eq(t.stacks(0, 50), 0)
	assert_eq(t.stacks(100, nil), 0)
end)

test("effective_threshold: a lower or equal provider threshold replaces the requester's, a higher one does not", function()
	local t = rt()
	local v, o = t.effective_threshold(5000, 2000)
	assert_eq(v, 2000)
	assert_true(o)
	v, o = t.effective_threshold(5000, 8000)
	assert_eq(v, 5000)
	assert_false(o)
	v, o = t.effective_threshold(5000, 5000)
	assert_eq(v, 5000)
	assert_true(o)
	v, o = t.effective_threshold(5000, nil)
	assert_eq(v, 5000)
	assert_false(o)
end)

test("train_mask: one network, NETWORK_EACH by name, other networks nil", function()
	local t = rt()
	assert_eq(t.train_mask({ network_name = "signal-A", network_mask = 3 }, "signal-A"), 3)
	assert_nil(t.train_mask({ network_name = "signal-A", network_mask = 3 }, "signal-B"))
	assert_eq(t.train_mask({ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 4 } }, "signal-B"), 4)
	assert_nil(t.train_mask({ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 4 } }, "signal-A"))
	assert_nil(t.train_mask({ network_name = nil }, "signal-A"))
end)

test("count_train: mask matches and distinct depots; capability per layout over every train on the network", function()
	local t = rt()
	local counts = { ["signal-A"] = t.new_fleet_count(1), ["signal-B"] = t.new_fleet_count(2) }
	local trains = {
		{ network_name = "signal-A", network_mask = 1, depot_id = 10, layout_id = 1, item_slot_capacity = 40, fluid_capacity = 0 },
		{ network_name = "signal-A", network_mask = 3, depot_id = 10, layout_id = 2, item_slot_capacity = 80, fluid_capacity = 0 },
		{ network_name = "signal-A", network_mask = 2, depot_id = 11, layout_id = 1, item_slot_capacity = 40, fluid_capacity = 0 },
		{ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 6 }, depot_id = 12, layout_id = 3, item_slot_capacity = 0, fluid_capacity = 50000 },
		{ network_name = "signal-C", network_mask = 1, depot_id = 13, layout_id = 1, item_slot_capacity = 40 },
	}
	for _, tr in ipairs(trains) do t.count_train(counts, tr) end
	local a, b = counts["signal-A"], counts["signal-B"]
	assert_eq(a.trains, 2, "trains sharing bit 1")
	assert_eq(a.depots, 1, "both in depot 10")
	assert_eq(a.capability[1], { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 3 })
	assert_eq(a.capability[2], { count = 1, item_capacity = 80, fluid_capacity = 0, mask_or = 3 })
	assert_eq(b.trains, 1)
	assert_eq(b.depots, 1)
	assert_eq(b.capability[3].fluid_capacity, 50000)
	assert_eq(a.matched[1], { count = 1, item_capacity = 40, fluid_capacity = 0 }, "layout 1: only the mask-1 train")
	assert_eq(a.matched[2], { count = 1, item_capacity = 80, fluid_capacity = 0 })
end)

--- A fleet count of one network from {mask, layout_id, items, fluid} trains against the stop's mask.
local function fleet(t, stop_mask, trains)
	local counts = { ["signal-A"] = t.new_fleet_count(stop_mask) }
	for _, x in ipairs(trains) do
		t.count_train(counts, { network_name = "signal-A", network_mask = x[1], depot_id = 1, layout_id = x[2],
			item_slot_capacity = x[3], fluid_capacity = x[4] or 0 })
	end
	return counts["signal-A"]
end

test("eligible: trains counted one by one, never a layout's whole count by its OR-ed mask", function()
	local t = rt()
	-- One layout, four trains with masks 1, 2, 4, 8; the stop's mask is 1.
	local c = fleet(t, 1, { { 1, 7, 40 }, { 2, 7, 40 }, { 4, 7, 40 }, { 8, 7, 40 } })
	assert_eq(c.trains, 1)
	assert_eq(c.capability[7].count, 4)
	local n, items = t.eligible(c, true, {})
	assert_eq(n, 1, "matches the per-train count")
	assert_eq(items, 40)
	-- The largest capacity comes from a matching train only.
	c = fleet(t, 1, { { 1, 3, 20 }, { 2, 3, 80 } })
	n, items = t.eligible(c, true, {})
	assert_eq({ n, items }, { 1, 20 }, "the 80-stack train shares no bit")
	-- Accepted layouts filter the matched trains.
	c = fleet(t, 3, { { 1, 1, 40 }, { 2, 2, 80 }, { 1, 2, 60 } })
	n, items = t.eligible(c, false, { [1] = true })
	assert_eq({ n, items }, { 1, 40 })
	n, items = t.eligible(c, false, { [2] = true })
	assert_eq({ n, items }, { 2, 80 })
	assert_eq({ t.eligible(nil, true, {}) }, { 0, 0, 0 })
end)

test("allow_list: accepted layouts, eligible trains and the layouts no train has", function()
	local t = rt()
	local c = fleet(t, 1, { { 1, 1, 40 }, { 1, 1, 40 }, { 2, 2, 40 }, { 2, 2, 40 }, { 3, 2, 40 } })
	local n, trains, missing = t.allow_list({ [1] = true, [5] = true, [4] = true }, false, c)
	assert_eq(n, 3)
	assert_eq(trains, 2)
	assert_eq(missing, { 4, 5 })
	n, trains, missing = t.allow_list({ [2] = true }, false, c)
	assert_eq(trains, 1, "only layout 2's mask-3 train shares bit 1")
	assert_eq(missing, {})
	n, trains = t.allow_list({}, true, c)
	assert_false(n)
	assert_eq(trains, 3)
	n, trains, missing = t.allow_list({ [1] = true }, false, nil)
	assert_eq(n, 1)
	assert_eq(trains, 0)
	assert_eq(missing, { 1 })
end)

test("schedule_row: the active record marked, stations, rail waypoints, temporary and interrupt records", function()
	local t = rt()
	assert_eq(t.schedule_row(1, { station = "Depot" }, 2), { caption = { "", "    ", "1", ". ", "Depot" }, active = false })
	assert_eq(t.schedule_row(2, { station = "P", temporary = true }, 2), {
		caption = { "", "▶ ", "2", ". ", "P", " ", { "cybersyn-gui.relative-schedule-temporary" } }, active = true })
	assert_eq(t.schedule_row(3, { rail = true, temporary = true }, 2).caption[5], { "cybersyn-gui.relative-schedule-rail" })
	assert_eq(t.schedule_row(4, { station = "X", temporary = true, created_by_interrupt = true }, 1).caption[7],
		{ "cybersyn-gui.relative-schedule-interrupt" })
end)

test("event_row: rounded age, kind, and the detail each kind needs", function()
	local t = rt()
	assert_eq(t.event_row({ tick = 0, kind = DIAG_KIND_UNSERVED_REASON, code = REASON_R_LAYOUT, a = 0, b = 0 }, 1250),
		{ "", "20s", "  ", { "cybersyn-diag.kind-unserved-reason" }, " · ", { "cybersyn-diag.chip-r-layout" } })
	assert_eq(t.event_row({ tick = 100, kind = DIAG_KIND_SERVED, code = REASON_R_LAYOUT, a = 60, b = 0 }, 100),
		{ "", "0s", "  ", { "cybersyn-diag.kind-served" } })
	assert_eq(t.event_detail({ kind = DIAG_KIND_SHORT_LOAD, code = 0, a = 2000, b = 1900 }),
		{ "cybersyn-gui.relative-event-cargo", "2,000", "1,900" })
	assert_eq(t.event_detail({ kind = DIAG_KIND_LINT, code = DIAG_LINT_APPEARED, a = LINT_LAYOUT, b = 5 }),
		{ "", { "cybersyn-diag.lint-layout" }, " (", { "cybersyn-diag.lint-appeared" }, ")" })
	assert_eq(t.event_detail({ kind = DIAG_KIND_STATION_LIMIT, code = 0, a = 2, b = 0 }),
		{ "cybersyn-gui.relative-event-limit", "2", "0" })
	assert_nil(t.event_detail({ kind = DIAG_KIND_ALERT, code = 1, a = 0, b = 0 }))
end)

test("s_colour, trains_pair, mask_text", function()
	local t = rt()
	assert_eq(t.s_colour(0), "cyan")
	assert_eq(t.s_colour(1), "green")
	assert_eq(t.s_colour(3), "green")
	assert_eq(t.s_colour(2), "red")
	assert_eq(t.s_colour(nil), "cyan")
	assert_eq(t.trains_pair(1, 2), "1 / 2")
	assert_eq(t.trains_pair(0, 4294967295), "0 / ∞")
	assert_eq(t.mask_text(5), "5 (101)")
	assert_eq(t.mask_text(0), "0 (0)")
	assert_eq(t.mask_text(-1), "-1")
	assert_eq(t.mask_text(65536), "65536")
end)

-- ---------------------------------------------------------------- diag.last_for_step

local diag = H.load("scripts.diag")

local function setup(mode)
	mod_settings.diagnostics = mode or "full"
	storage.trains = storage.trains or {}
	storage.stations = storage.stations or {}
	return diag.apply()
end

local function seqs(rows)
	local out = {}
	for i, ev in ipairs(rows) do out[i] = ev.seq end
	return out
end

--- The reference result of the backward scans: the newest `n` events about one subject, newest first, from an
--- unbounded diag.events.
local function last_for(kind, id, n)
	local rows, out = diag.events({ [kind] = id }, nil, n, math.huge), {}
	for i = #rows, 1, -1 do out[#out + 1] = rows[i] end
	return out
end

--- `n` events about `station` (basic and full rings alternating) among `filler` others each.
local function fill(d, station, n, filler)
	for _ = 1, n do
		for _ = 1, filler do diag.event(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, 0, 0, 1, 999, 0, 0, 0, 0) end
		diag.event(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, 0, 0, 0, station, 0, 0, 1, 2)
		diag.event(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, 0, 0, 2, station, 0, 0, 0, 0)
	end
end

test("last_for_step: equals an unbounded scan once done, with at most the budget examined per call", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 6, 500)
	local want = seqs(last_for("station", 7, 10))
	assert_eq(#want, 10)
	local c = diag.scan_cursor("station", 7, 10)
	local calls = 0
	repeat
		diag.last_for_step(c, 300)
		calls = calls + 1
		assert_true(c.examined <= 300, "examined " .. c.examined)
	until c.done or calls > 100
	assert_true(c.done)
	assert_eq(seqs(c.rows), want)
	assert_true(calls > 5, "the scan was spread over calls: " .. calls)
end)

test("last_for_step: rows written since the last call come first, without a rescan", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 12, 3)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	assert_true(c.done)
	fill(d, 7, 1, 20)
	diag.last_for_step(c)
	assert_eq(c.examined, 22, "only the new rows")
	assert_eq(seqs(c.rows), seqs(last_for("station", 7, 10)))
end)

test("last_for_step: fewer matches than n is done at the end of the log; a new state starts over", function()
	game.tick = 10
	local d = setup("basic")
	fill(d, 7, 2, 5)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	assert_true(c.done)
	assert_eq(#c.rows, 2, "basic keeps only the limit rows")
	setup("off")
	assert_eq(diag.last_for_step(c), {})
	d = setup("basic")
	fill(d, 7, 1, 0)
	assert_eq(#diag.last_for_step(c), 1)
	-- Off and on again within one tick, the new state already past the old one's seq: still a new state.
	diag.last_for_step(c)
	setup("off")
	d = setup("basic")
	fill(d, 9, 3, 0)
	fill(d, 7, 1, 0)
	assert_eq(seqs(diag.last_for_step(c)), { d.seq })
end)

test("last_for_step: more new rows than the budget start over from the newest", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 3, 0)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	fill(d, 9, 2, 400)
	fill(d, 7, 1, 0)
	diag.last_for_step(c, 100)
	assert_eq(c.rows[1].seq, d.seq)
	repeat diag.last_for_step(c, 100) until c.done
	assert_eq(seqs(c.rows), seqs(last_for("station", 7, 10)))
end)

-- ---------------------------------------------------------------- inventory rows

-- Records in the collector's inventory-row contract, built by hand: each source carries its own lists, priority and
-- network, and the fixtures fill st.rows from them.

local F = require("inventory_fixtures")

local function fluid(name, order)
	prototypes.fluid[name] = prototypes.fluid[name]
		or { name = name, order = order, localised_name = { "fluid-name." .. name }, valid = true }
end

local function source(kind, index, priority, mask, provided, requested, ignored)
	return { kind = kind, index = index, unit = 100 + index, ok = true, priority = priority or 0,
		network_name = "signal-A", mask = mask, network_mask = mask,
		provided = provided or {}, requested = requested or {}, ignored = ignored or {} }
end

--- [naphthalene-oil] Provider: Provide only, the station combinator on A1, Inventory 1 on A3, Inventory 2 on
--- A4 whose -866 liquid fuel the switch keeps from being advertised.
local function naphthalene()
	fluid("naphthalene-oil", "z[a]")
	fluid("liquid-fuel", "z[b]")
	local s0 = source("station", 0, 0, 1, { ["naphthalene-oil"] = 199134 })
	local s1 = source("inventory", 1, 0, 3, { ["liquid-fuel"] = 99134 })
	local s2 = source("inventory", 2, 0, 4, {}, {}, { ["liquid-fuel"] = -866 })
	return F.rows({
		id = 7, name = "[fluid=naphthalene-oil] Provider", is_p = true, is_r = false, is_stack = false,
		network_name = "signal-A", network_mask = 1, comb_ok = true, priority = 0,
		provided = { ["naphthalene-oil"] = 199134, ["liquid-fuel"] = 99134 }, requested = {}, wait = {}, deliveries = {},
		ignored = { ["liquid-fuel"] = -866 },
		sources = { s0, s1, s2 },
	})
end

--- A plain requester: Request only, the station combinator on A3, several requests below threshold, and a provide the
--- switch drops.
local function plain()
	local requested = {
		["iron-plate"] = { count = -1900, threshold = 2000, active = false },
		["copper-plate"] = { count = -1600, threshold = 2000, active = false },
		["coal"] = { count = -2500, threshold = 2000, active = true },
	}
	local provided, ignored = {}, { stone = 52 }
	return F.rows({
		id = 9, name = "Circuit Requestor", is_p = false, is_r = true, is_stack = false,
		network_name = "signal-A", network_mask = 3, comb_ok = true, priority = 1,
		provided = provided, requested = requested, ignored = ignored, wait = {}, deliveries = {},
		sources = { source("station", 0, 1, 3, provided, requested, ignored) },
	})
end

local function rows_of(st)
	return collector().inventories(st)
end

test("rows: network, head and one line of text per row, as the stop panel heads its blocks", function()
	local t = rt()
	local rows = rows_of(naphthalene())
	assert_eq(t.row_network(rows[2]), "[virtual-signal=signal-A]3")
	assert_eq(t.row_head(rows[2]), { "", { "cybersyn-gui.source-inventory", 1 }, " · ", { "cybersyn-gui.section-priority", "0" } })
	assert_eq(t.row_text(rows[1]), { "", { "", { "cybersyn-gui.source-station" }, " · ", { "cybersyn-gui.section-priority", "0" } },
		" · ", "[virtual-signal=signal-A]1" })
	local sig = t.row_sig(rows[2])
	rows[2].priority = 9
	assert_true(t.row_sig(rows[2]) ~= sig, "the priority is in the text, so in the sig")
	local each = { kind = "station", index = 0, priority = 0, network_name = NETWORK_EACH,
		networks = { ["signal-B"] = 2, ["signal-A"] = 1 } }
	assert_eq(t.row_network(each), "[virtual-signal=signal-A]1 [virtual-signal=signal-B]2")
	assert_eq(t.row_network({ kind = "inventory", index = 1, network_name = "signal-A" }), "", "unread: no mask")
	assert_eq(t.row_text({ kind = "inventory", index = 1, priority = 2, network_name = "signal-A" }),
		{ "", { "cybersyn-gui.source-inventory", 1 }, " · ", { "cybersyn-gui.section-priority", "2" } })
end)

test("rows: inventories, the distinct networks and their mask union", function()
	local t = rt()
	local n, p = naphthalene(), plain()
	assert_true(t.has_inventories(n))
	assert_false(t.has_inventories(p))
	assert_eq(t.row_networks(n), { { name = "signal-A", mask = 1 }, { name = "signal-A", mask = 3 }, { name = "signal-A", mask = 4 } })
	assert_eq(t.rows_union(n), { ["signal-A"] = 7 })
	n.sources[3].mask = 3
	F.rows(n)
	assert_eq(#t.row_networks(n), 2, "two inventories on one mask are one network")
	assert_eq(#t.advertised_rows(n), 3, "and still two blocks")
end)

test("rows: the switch's reason for what a row does not advertise", function()
	local t = rt()
	assert_eq(t.ignored_reason(naphthalene()), { "cybersyn-gui.section-provide-only" })
	assert_eq(t.ignored_reason(plain()), { "cybersyn-gui.section-request-only" })
	assert_eq(t.ignored_reason({ is_p = true, is_r = true }), { "cybersyn-gui.section-switch" })
end)

test("rows_content: same values sign alike whatever the fill order; ignored, starved and priority change it", function()
	local t = rt()
	local a, b = naphthalene(), naphthalene()
	b.sources[1].provided = {}
	b.sources[1].provided["naphthalene-oil"] = 199134
	assert_eq(t.rows_content(a), t.rows_content(b))
	b.sources[3].ignored["liquid-fuel"] = -900
	assert_true(t.rows_content(a) ~= t.rows_content(b), "ignored count")
	local p = plain()
	local base = t.rows_content(p)
	rows_of(p)[1].starved = { coal = true }
	assert_true(base ~= t.rows_content(p), "starved")
	rows_of(p)[1].starved = nil
	rows_of(p)[1].priority = 4
	assert_true(base ~= t.rows_content(p), "priority")
end)

-- ---------------------------------------------------------------- stop panel blocks

local function relative_mod()
	commands = commands or { add_command = function() end, remove_command = function() end, commands = {}, game_commands = {} }
	return H.load("scripts.gui.relative")
end

--- Captions of a def tree, depth first, LocalisedStrings flattened to their keys and plain parts.
local function captions(defs)
	local out = {}
	local function flat(ls)
		if type(ls) ~= "table" then return tostring(ls) end
		local parts = {}
		for i, v in ipairs(ls) do
			if not (i == 1 and v == "") then parts[#parts + 1] = flat(v) end
		end
		return table.concat(parts, "")
	end
	local function walk(d)
		if d.caption then out[#out + 1] = flat(d.caption) end
		if d.type == "sprite-button" then out[#out + 1] = "slot:" .. d.tags.id .. ":" .. string.gsub(d.style, "^ltnm_small_slot_button_", "") end
		for _, c in ipairs(d) do walk(c) end
		for _, c in ipairs(d.children or {}) do
			if d.type ~= "sprite-button" then walk(c) end
		end
	end
	for _, d in ipairs(defs) do walk(d) end
	return out
end

test("stop panel: the naphthalene provider gets one block per combinator, Inventory 2 with its unadvertised fuel", function()
	local r = relative_mod()
	local c = captions(r.slots_defs(naphthalene()))
	assert_eq(c[1], "cybersyn-gui.section-advertised")
	local text = table.concat(c, "\n")
	-- Block heads in order: the station combinator on A1, Inventory 1 on A3, Inventory 2 on A4, each with its letter.
	local i1 = text:find("[color=0.4,0.9,1]S[/color] cybersyn-gui.source-station · cybersyn-gui.section-priority0\n[virtual-signal=signal-A]1\n", 1, true)
	local i3 = text:find("[color=0.4,0.9,1]I[/color] cybersyn-gui.source-inventory1 · cybersyn-gui.section-priority0\n[virtual-signal=signal-A]3\n", 1, true)
	local i4 = text:find("[color=0.4,0.9,1]I[/color] cybersyn-gui.source-inventory2 · cybersyn-gui.section-priority0\n[virtual-signal=signal-A]4\n", 1, true)
	assert_true(i1 and i3 and i4 and i1 < i3 and i3 < i4, text)
	assert_nil(text:find("bits", 1, true), "no bits labels")
	assert_true(text:find("slot:naphthalene-oil:green", i1, true) < i3, "naphthalene oil provided by the station combinator")
	assert_true(text:find("slot:liquid-fuel:green", i3, true) < i4, "liquid fuel provided by Inventory 1")
	assert_nil(text:find("slot:liquid-fuel", i4, true), "never a slot in Inventory 2")
	local tail = text:sub(i4)
	assert_true(tail:find("cybersyn-gui.section-not-advertised [fluid=liquid-fuel", 1, true) and tail:find("]-866 (cybersyn-gui.section-provide-only)", 1, true) ~= nil, tail)
	local lines = 0
	for _, d in ipairs(r.slots_defs(naphthalene())) do
		if d.type == "line" then lines = lines + 1 end
	end
	assert_eq(lines, 2, "a separator between three blocks")
end)

test("stop panel: an unserved request names the inventory that asks for it, a plain station its network", function()
	local r = relative_mod()
	local n = naphthalene()
	local req = { count = -866, threshold = 100, active = true }
	n.sources[3].requested = { ["liquid-fuel"] = req }
	-- The station's sum is larger: the line gives the request of the inventory it names.
	n.requested = { ["liquid-fuel"] = { count = -2866, threshold = 100, active = true } }
	F.rows(n)
	local e = { first_tick = 0, reason = REASON_NO_PROVIDER, a = 0, b = 0, n = 1 }
	local tip = r.unserved_texts({ st = n, name = n.name, network_name = "signal-A" }, { hash = "liquid-fuel", e = e }, 60, 0)
	local why = serpent.line(tip[4], { comment = false })
	local all = serpent.line(tip, { comment = false })
	assert_true(all:find('"866"', 1, true) ~= nil and all:find("2866", 1, true) == nil
		and all:find("2,866", 1, true) == nil, all)
	assert_true(why:find('{"cybersyn-gui.source-inventory", 2}', 1, true) ~= nil, why)
	assert_true(why:find("[virtual-signal=signal-A]4", 1, true) ~= nil, why)
	local p = plain()
	tip = r.unserved_texts({ st = p, name = p.name, network_name = "signal-A" }, { hash = "coal", e = e }, 60, 0)
	why = serpent.line(tip[4], { comment = false })
	assert_nil(why:find("source-inventory", 1, true), why)
end)

test("stop panel: two inventories on one mask are two blocks", function()
	local r = relative_mod()
	local n = naphthalene()
	n.sources[3].mask = 3
	F.rows(n)
	local text = table.concat(captions(r.slots_defs(n)), "\n")
	local _, count = text:gsub("%[virtual%-signal=signal%-A%]3\n", "")
	assert_eq(count, 2, text)
end)

test("stop panel: a plain requester is a single block with Provided, Requested, the threshold note and its dropped provide", function()
	local r = relative_mod()
	local c = captions(r.slots_defs(plain()))
	local text = table.concat(c, "\n")
	assert_eq(c[1], "cybersyn-gui.section-advertised")
	assert_true(text:find("S[/color] cybersyn-gui.source-station · cybersyn-gui.section-priority1\n[virtual-signal=signal-A]3\n", 1, true) ~= nil, text)
	assert_true(text:find("cybersyn-gui.section-provided\ncybersyn-gui.section-none\ncybersyn-gui.section-requested\n", 1, true) ~= nil, text)
	assert_true(text:find("slot:coal:red", 1, true) ~= nil)
	assert_true(text:find("slot:iron-plate:orange", 1, true) ~= nil)
	assert_true(text:find("slot:copper-plate:orange", 1, true) ~= nil)
	assert_true(text:find("cybersyn-gui.section-below-threshold", 1, true) ~= nil)
	assert_true(text:find("cybersyn-gui.section-not-advertised [item=stone", 1, true) and text:find("]52 (cybersyn-gui.section-request-only)", 1, true) ~= nil, text)
	for _, d in ipairs(r.slots_defs(plain())) do assert_true(d.type ~= "line", "one block, no separator") end
	local none = plain()
	none.network_name = nil
	assert_eq(captions(r.slots_defs(none)), { "cybersyn-gui.relative-no-items" })
end)

test("stop panel: a starved request in a row says so in its tooltip", function()
	local r = relative_mod()
	local p = plain()
	rows_of(p)[1].starved = { coal = true }
	local found = false
	local function walk(d)
		if d.type == "sprite-button" and d.tags.id == "coal" then
			found = serpent.line(d.tooltip):find("cybersyn-gui.section-starved", 1, true) ~= nil
		end
		for _, c in ipairs(d) do walk(c) end
	end
	for _, d in ipairs(r.slots_defs(p)) do walk(d) end
	assert_true(found)
end)

test("stop panel: every Advertised slot's tooltip ends with the click and shift-click hint", function()
	local r = relative_mod()
	local p = plain()
	local slots, hinted = 0, 0
	local function walk(d)
		if d.type == "sprite-button" and d.tags and d.tags.kind == "item" then
			slots = slots + 1
			assert_eq(d.tags.station, p.id, "a stop panel slot carries its station")
			local tip = d.tooltip
			if tip[#tip][1] == "cybersyn-gui.relative-slot-hint" and tip[#tip - 1] == "\n" then hinted = hinted + 1 end
			assert_true(d.elem_tooltip ~= nil, "the item's own tooltip stays")
		end
		for _, c in ipairs(d) do walk(c) end
	end
	for _, d in ipairs(r.slots_defs(p)) do walk(d) end
	assert_true(slots > 0)
	assert_eq(hinted, slots)
end)

test("stop panel: red S and red I on the heads, from the combinators' display", function()
	local r = relative_mod()
	local n = naphthalene()
	local text = table.concat(captions(r.slots_defs(n, { s = "green", inv_failed = { [102] = true } })), "\n")
	assert_true(text:find("[color=0.3,1,0.3]S[/color] cybersyn-gui.source-station", 1, true) ~= nil, text)
	assert_true(text:find("[color=0.4,0.9,1]I[/color] cybersyn-gui.source-inventory1", 1, true) ~= nil, text)
	assert_true(text:find("[color=1,0.35,0.35]I[/color] cybersyn-gui.source-inventory2", 1, true) ~= nil, text)
	-- Without the live display, the collector's row.failed decides the I.
	n.sources[2].failed = true
	F.rows(n)
	text = table.concat(captions(r.slots_defs(n)), "\n")
	assert_true(text:find("[color=1,0.35,0.35]I[/color] cybersyn-gui.source-inventory1", 1, true) ~= nil, text)
	local tips = {}
	local function walk(d)
		if d.type == "label" and d.style == "bold_label" then tips[#tips + 1] = d.tooltip end
		for _, c in ipairs(d) do walk(c) end
	end
	for _, d in ipairs(r.slots_defs(n, { s = "red" })) do walk(d) end
	assert_eq(tips, { { "cybersyn-gui.relative-s-red" }, { "cybersyn-gui.relative-i-cyan" }, { "cybersyn-gui.relative-i-cyan" } })
end)

test("stop panel: the blocks are rebuilt only when the record or a letter changed", function()
	local r = relative_mod()
	local body = H.element({ name = "body" })
	body.slots = body.add({ type = "flow", name = "slots" })
	local state = { sigs = {}, rebuilds = 0 }
	local st = naphthalene()
	st.read_tick = 10
	local m = { st = st, source = "snapshot" }
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 1)
	assert_true(#body.slots.children > 0)
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 1, "same pass, nothing rebuilt")
	st.read_tick = 20
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 1, "refilled with the same values")
	st.sources[3].ignored["liquid-fuel"] = -900
	st.read_tick = 30
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 2, "an unadvertised count moved")
	m.display_state = 2
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 3, "the S turned red")
	storage.stations = { [7] = { inv_failed = { [101] = true } } }
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 4, "Inventory 1's I turned red")
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 4)
	storage.stations = nil
end)

test("stop panel: a working station combinator without input names its inventories as paused for that reason", function()
	local r = relative_mod()
	local t = rt()
	local n = naphthalene()
	n.comb_ok = true
	n.sources[3].read = false
	assert_eq(#t.paused_inventories(n), 1)
	assert_eq(#t.advertised_rows(n), 2)
	local text = table.concat(captions(r.slots_defs(n)), "\n")
	assert_true(text:find("cybersyn-gui.section-paused-no-signals", 1, true) ~= nil, text)
	assert_nil(text:find("source-inventory2 ·", 1, true), "no block for the paused inventory")
	n.comb_ok = false
	local off = table.concat(captions(r.slots_defs(n)), "\n")
	assert_true(off:find("cybersyn-gui.section-paused-no-signals", 1, true) == nil, off)
	assert_true(t.rows_content(n) ~= t.rows_content(naphthalene()))
end)

test("stop panel: a station combinator that is off names its inventories as paused", function()
	local r = relative_mod()
	local t = rt()
	local n = naphthalene()
	n.comb_ok = false
	n.sources[2].read, n.sources[3].read = false, false
	assert_eq(#t.paused_inventories(n), 2)
	local text = table.concat(captions(r.slots_defs(n)), "\n")
	assert_true(text:find("cybersyn-gui.section-paused", 1, true) ~= nil, text)
	assert_nil(text:find("cybersyn-gui.section-paused-no-signals", 1, true), text)
	assert_true(t.rows_content(n) ~= t.rows_content(naphthalene()))
end)
