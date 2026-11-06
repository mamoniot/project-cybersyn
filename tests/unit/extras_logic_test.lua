-- The pure rules of the extras (scripts/gui/extras-logic.lua).

local H = require("harness")

local function logic()
	return H.load("scripts.gui.extras-logic")
end

local function points(list)
	local xs, ys = {}, {}
	for i, p in ipairs(list) do xs[i], ys[i] = p[1], p[2] end
	return xs, ys, #list
end

test("sample_runs: a straight run becomes one segment", function()
	local l = logic()
	local list = {}
	for i = 0, 50 do list[#list + 1] = { i * 2, 10 } end
	local vx, vy, runs = l.sample_runs(points(list))
	assert_eq(vx, { 0, 100 })
	assert_eq(vy, { 10, 10 })
	assert_eq(runs, 1)
end)

test("sample_runs: an L turn keeps its corner, duplicates are dropped", function()
	local l = logic()
	local vx, vy, runs = l.sample_runs(points({ { 0, 0 }, { 2, 0 }, { 2, 0 }, { 4, 0 }, { 4, 2 }, { 4, 4 } }))
	assert_eq(vx, { 0, 4, 4 })
	assert_eq(vy, { 0, 0, 4 })
	assert_eq(runs, 2)
end)

test("sample_runs: a reversal is not collinear", function()
	local l = logic()
	local vx = l.sample_runs(points({ { 0, 0 }, { 4, 0 }, { 2, 0 } }))
	assert_eq(vx, { 0, 4, 2 })
end)

test("sample_runs: a zig-zag longer than the cap is thinned to at most the cap, ends kept", function()
	local l = logic()
	local list = {}
	for i = 0, 999 do list[#list + 1] = { i, i % 2 } end
	local xs, ys, n = points(list)
	local vx, vy, runs = l.sample_runs(xs, ys, n)
	assert_eq(runs, 999)
	assert_eq(#vx - 1, l.TRACE_SEGMENTS, "the whole budget is used")
	assert_eq({ vx[1], vy[1] }, { 0, 0 })
	assert_eq({ vx[#vx], vy[#vy] }, { 999, 1 })
	local vx2, vy2 = l.sample_runs(xs, ys, n, 10)
	assert_eq(#vx2 - 1, 10)
	assert_eq({ vx2[11], vy2[11] }, { 999, 1 })
	local seen = {}
	for i = 2, #vx2 do
		assert_true(vx2[i] > vx2[i - 1], "vertices stay in path order")
		seen[#seen + 1] = vx2[i] - vx2[i - 1]
	end
	for _, gap in ipairs(seen) do assert_true(gap >= 99 and gap <= 101, "evenly spread, gap " .. gap) end
end)

test("sample_runs: fewer than two distinct points draw nothing", function()
	local l = logic()
	local vx, _, runs = l.sample_runs(points({ { 1, 1 }, { 1, 1 } }))
	assert_eq(#vx, 1)
	assert_eq(runs, 0)
	vx = l.sample_runs({}, {}, 0)
	assert_eq(#vx, 0)
end)

test("sample_runs: the 2x cap per player stays within 256 objects", function()
	local l = logic()
	assert_true(l.TRACE_SEGMENTS * 2 <= 256, "two render modes")
end)

test("confirm: first click arms, second fires, another key re-arms", function()
	local l = logic()
	local s, fire = l.confirm_click(nil, "fail:1", 100)
	assert_false(fire)
	assert_eq(s, { key = "fail:1", tick = 100 })
	assert_true(l.confirm_armed(s, "fail:1", 150))
	assert_false(l.confirm_armed(s, "recount:2", 150))
	local s2, fire2 = l.confirm_click(s, "recount:2", 150)
	assert_false(fire2)
	assert_eq(s2.key, "recount:2")
	local s3, fire3 = l.confirm_click(s2, "recount:2", 200)
	assert_true(fire3)
	assert_eq(s3, nil)
end)

test("confirm: an armed button is drawn back after 180 ticks", function()
	local l = logic()
	local s = l.confirm_click(nil, "fail:1", 100)
	assert_false(l.confirm_expired(s, 279))
	assert_true(l.confirm_expired(s, 280))
	assert_false(l.confirm_armed(s, "fail:1", 280))
	assert_false(l.confirm_expired(nil, 1000))
end)

test("confirm: a click applied within the grace after the expiry still fires (multiplayer input latency)", function()
	local l = logic()
	local s = l.confirm_click(nil, "fail:1", 100)
	assert_true(l.confirm_expired(s, 280))
	assert_false(l.confirm_gone(s, 309))
	assert_true(l.confirm_gone(s, 310))
	local s3, fire3 = l.confirm_click(s, "fail:1", 285)
	assert_true(fire3)
	assert_nil(s3)
	local _, fire4 = l.confirm_click(s, "recount:2", 285)
	assert_false(fire4, "another key arms that one")
	local s5, fire5 = l.confirm_click(s, "fail:1", 310)
	assert_false(fire5, "past the grace the click arms again")
	assert_eq(s5.tick, 310)
end)

test("job_continue: 50 trains per chunk, never one loop over everything", function()
	local l = logic()
	local i, chunks = 0, 0
	while i < 553 do
		local n = 0
		while i < 553 and l.job_continue(n, 0, 0) do
			i, n = i + 1, n + 1
		end
		assert_true(n <= 50)
		chunks = chunks + 1
	end
	assert_eq(chunks, 12)
end)

test("job_continue: the stop-visit budget splits singleton layouts, the first train always runs", function()
	local l = logic()
	local stops = 2030
	local single = l.job_cost(true, stops)
	assert_eq(single, 4060)
	assert_eq(l.job_cost(false, stops), 0)
	assert_true(l.job_continue(0, 0, 1e9))
	assert_true(l.job_continue(1, single, 0))
	assert_false(l.job_continue(1, single, single))
	assert_true(l.job_continue(1, 0, single, nil, l.JOB_STOP_VISITS))
	assert_false(l.job_continue(50, 0, 0))
	assert_false(l.job_continue(2, 0, 0, 2))
	assert_false(l.job_continue(1, 0, 2, 50, 1))
	-- 553 trains, every 10th alone on its layout, on a 2,000-station base's stop count: each such train gets its own chunk.
	local i, chunks, worst = 0, 0, 0
	while i < 553 do
		local n, spent = 0, 0
		while i < 553 do
			local cost = l.job_cost((i + 1) % 10 == 0, stops)
			if not l.job_continue(n, spent, cost) then break end
			i, n, spent = i + 1, n + 1, spent + cost
		end
		if spent > worst then worst = spent end
		chunks = chunks + 1
	end
	assert_eq(worst, single)
	assert_true(chunks >= 55)
end)

test("hud_values: totals, worst network, top reason with ties by lowest code", function()
	local l = logic()
	local v = l.hud_values({ [3] = 4, [1] = 4, [7] = 2 }, { ["signal-A"] = 3, ["signal-B"] = 0 })
	assert_eq(v, { unserved = 10, headroom = 0, network = "signal-B", top_reason = 1, top_count = 4 })
	v = l.hud_values({}, {})
	assert_eq(v, { unserved = 0, top_count = 0 })
	v = l.hud_values({}, { ["signal-B"] = 3 }, { ["signal-A"] = true, ["signal-B"] = true })
	assert_eq({ v.headroom, v.network }, { 0, "signal-A" }, "a network with trains but no counter is at 0")
end)

local function hash(name, quality)
	if quality == nil or quality == "normal" then return name end
	return name .. "|" .. quality
end

test("recount: provider side counts TO_P/P, requester side TO_P..R; manifests signed by side", function()
	local l = logic()
	local trains = {
		[1] = { status = STATUS_TO_P, p_station_id = 10, r_station_id = 20, manifest = { { name = "iron-plate", count = 400 } } },
		[2] = { status = STATUS_P, p_station_id = 10, r_station_id = 30, manifest = { { name = "copper-plate", count = 100 } } },
		-- Left the provider: counts at the requester only.
		[3] = { status = STATUS_TO_R, p_station_id = 10, r_station_id = 20, manifest = { { name = "iron-plate", count = 50 } } },
		[4] = { status = STATUS_R, p_station_id = 40, r_station_id = 20,
			manifest = { { name = "iron-plate", count = 7, quality = "rare" } } },
		-- Back from a delivery, refuelling, parked: no station ids count.
		[5] = { status = STATUS_TO_D, p_station_id = 10, r_station_id = 20 },
		[6] = { status = STATUS_F },
		[7] = { status = STATUS_D },
		-- Going home past a requester, or to a refueler, with stale ids from the last delivery: not bound.
		[8] = { status = STATUS_TO_D_BYPASS, p_station_id = 10, r_station_id = 20, manifest = { { name = "coal", count = 5 } } },
		[9] = { status = STATUS_TO_F, p_station_id = 10, r_station_id = 20, manifest = { { name = "coal", count = 5 } } },
	}
	local total, d, ids = l.recount(trains, 10, hash)
	assert_eq(total, 2)
	assert_eq(d, { ["iron-plate"] = -400, ["copper-plate"] = -100 })
	assert_eq(ids, { 1, 2 })
	total, d, ids = l.recount(trains, 20, hash)
	assert_eq(total, 3)
	assert_eq(d, { ["iron-plate"] = 450, ["iron-plate|rare"] = 7 })
	assert_eq(ids, { 1, 3, 4 })
	total, d, ids = l.recount(trains, 99, hash)
	assert_eq({ total, d, ids }, { 0, {}, {} }, "a station no train is bound to counts nothing")
end)

test("recount: a train bound at both ends of the same station counts twice and its manifest nets to zero", function()
	local l = logic()
	local total, d = l.recount({ [1] = { status = STATUS_P, p_station_id = 5, r_station_id = 5,
		manifest = { { name = "coal", count = 10 } } } }, 5, hash)
	assert_eq(total, 2)
	assert_eq(d, {})
end)

test("Log rows: every action code reads its own name", function()
	storage.trains = storage.trains or {}
	storage.stations = storage.stations or {}
	mod_settings.diagnostics = "basic"
	H.load("scripts.diag").apply()
	local model = H.load("scripts.gui.log-model")
	local ctx = { player = function() return "Daniel" end }
	local want = { [ACTION_FIX_PRIORITIES] = "fix-priorities", [ACTION_ABOLISH_SAME_DEPOT] = "abolish-same-depot",
		[ACTION_RECALCULATE_TRAIN_SIZE] = "recalculate-train-size", [ACTION_FAIL_DELIVERY] = "fail-delivery",
		[ACTION_REFRESH_ALLOW_LISTS] = "refresh-allow-lists", [ACTION_RECOUNT_DELIVERIES] = "recount-deliveries" }
	assert_eq(#ACTION_NAMES, 6)
	for a, name in pairs(want) do
		local g = { kind = DIAG_KIND_MANUAL_ACTION, code = 0, a = a, b = 0, station2 = 1, tick = 0, seq = 1, n = 1 }
		assert_eq(model.message(g, ctx), { "cybersyn-diag.msg-manual-action", { "cybersyn-diag.action-" .. name }, "Daniel" })
	end
end)

test("is_counter_leak: only a phantom finding that counts more deliveries than bound trains", function()
	local l = logic()
	assert_eq(l.is_counter_leak({ check = LINT_PHANTOM, a = 2, b = 1 }), true)
	assert_eq(l.is_counter_leak({ check = LINT_PHANTOM, a = 1, b = 0 }), true)
	assert_eq(l.is_counter_leak({ check = LINT_PHANTOM, a = 0, b = 1 }), false, "a bound train: send it home instead")
	assert_eq(l.is_counter_leak({ check = LINT_PHANTOM, a = 1, b = 1 }), false)
	assert_eq(l.is_counter_leak({ check = LINT_OCCUPANCY, a = 3, b = 1 }), false)
end)

test("stop_panel_fits: vanilla 1,067 + 300 logical px against the logical screen width", function()
	local l = logic()
	assert_eq(l.stop_panel_fits(3840, 1.5), true, "4K at 1.5: 2,560")
	assert_eq(l.stop_panel_fits(3840, 2.0), true, "4K at 2.0: 1,920")
	assert_eq(l.stop_panel_fits(1920, 1.0), true, "1080p at 1.0: 1,920")
	assert_eq(l.stop_panel_fits(1920, 1.25), true, "1080p at 1.25: 1,536")
	assert_eq(l.stop_panel_fits(1920, 1.5), false, "1080p at 1.5: 1,280")
	assert_eq(l.stop_panel_fits(1920, 2.0), false, "1080p at 2.0: 960")
	assert_eq(l.stop_panel_fits(1367, 1), true, "exactly the two widths")
	assert_eq(l.stop_panel_fits(1366, 1), false)
end)

-- The docked locomotive pane's right edge, measured with clients: physical px, the first pixel right of the pane's
-- outer border. Points: the base game with 0, 6 and 9 extra item groups (row count 6 and 100), and a large modpack
-- (11 groups, its post-processing sets the row count to 100).
test("train_pane_right: the measured pane edges", function()
	local l = logic()
	local points = {
		-- narrow, groups, row_count, scale, measured
		{ true, 11, 100, 1.0, 452, "from the character, 1080p" },
		{ true, 11, 6, 1.5, 678, "from the character, 4K/1.5" },
		{ false, 11, 6, 1.0, 454, "6 group tabs per row, 1080p" },
		{ false, 11, 6, 1.5, 678, "6 group tabs per row, 4K/1.5" },
		{ false, 11, 100, 1.0, 809, "11 groups in one row, 1080p" },
		{ false, 14, 100, 1.0, 1022, "14 groups in one row, 1080p" },
		{ false, 11, 100, 1.5, 1208, "11 groups in one row, 4K/1.5 (1208 px = 805 logical)" },
	}
	for _, p in ipairs(points) do
		assert_eq(l.train_pane_right(p[1], p[2], p[3], p[4]), p[5], p[6])
	end
	assert_eq(l.train_pane_right(false, 5, 6, 1.0), 452, "base game: 5 groups fit the narrow pane")
	assert_eq(l.train_pane_right(false, 5, 6, 1.5), 678)
	assert_eq(l.train_pane_right(false, 0, 100, 1.5), 678, "no burner, no Fuel tab")
	assert_eq(l.train_pane_right(false, 30, 6, 1.0), 454, "more groups than a row wrap: width of one row")
end)

test("train_panel_place: flush right of the pane at its top, kept on the screen", function()
	local l = logic()
	local x, y = l.train_panel_place(1208, 1.5, 3840)
	assert_eq({ x, y }, { 1208, 60 }, "pY wide pane at 4K/1.5")
	x, y = l.train_panel_place(452, 1.0, 1920)
	assert_eq({ x, y }, { 452, 40 }, "narrow pane at 1080p")
	x, y = l.train_panel_place(809, 1.0, 1920)
	assert_eq({ x, y }, { 809, 40 })
	x, y = l.train_panel_place(1800, 1.0, 1920)
	assert_eq({ x, y }, { 1920 - 324, 40 }, "a pane wider than the screen allows: the panel stays on it")
	x = l.train_panel_place(1022, 1.25, 1920)
	assert_eq(x, 1022)
end)

test("train_body_cap: the frame ends above the hotbar", function()
	local l = logic()
	assert_eq(l.train_body_cap(1080, 1.0), 1080 - 40 - 150 - 110)
	assert_eq(l.train_body_cap(2160, 1.5), 1440 - 40 - 150 - 110)
	assert_eq(l.train_body_cap(600, 1.0), 300)
	assert_eq(l.train_body_cap(400, 1.0), 120, "never below the minimum")
	-- Frame bottom = top + body + 135 measured chrome: above the 1080p hotbar top at 975.
	assert_eq(40 + l.train_body_cap(1080, 1.0) + 135 <= 975, true)
end)

test("train_body_cap: the paused banner comes out of the body", function()
	local l = logic()
	assert_eq(l.train_body_cap(1080, 1.0, 0), l.train_body_cap(1080, 1.0))
	assert_eq(l.train_body_cap(1080, 1.0, l.TRAIN_PANEL_BANNER), 1080 - 40 - 150 - 110 - 36)
	assert_eq(l.train_body_cap(2160, 1.5, l.TRAIN_PANEL_BANNER), 1440 - 40 - 150 - 110 - 36)
	assert_eq(l.train_body_cap(400, 1.0, l.TRAIN_PANEL_BANNER), 120, "never below the minimum")
	-- With the banner: top + banner + body + 135 measured chrome stays above the 1080p hotbar top at 975.
	assert_eq(40 + l.TRAIN_PANEL_BANNER + l.train_body_cap(1080, 1.0, l.TRAIN_PANEL_BANNER) + 135 <= 975, true)
end)
