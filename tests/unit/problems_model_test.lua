-- The setup lint's texts (scripts/gui/problems-model.lua): the Stations Problems column's order and sort rank, the
-- detail per check, and every locale key the column, the stop panel and Explain use.

local H = require("harness")

local function pm()
	return H.load("scripts.gui.problems-model")
end

local function finding(check, subject, id, a, b, extra)
	local f = { check = check, subject = subject, id = id, a = a or 0, b = b or 0 }
	for k, v in pairs(extra or {}) do f[k] = v end
	return f
end

local S, D, T = LINT_SUBJECT_STATION, LINT_SUBJECT_DEPOT, LINT_SUBJECT_TRAIN

-- Whether a station_rank falls in DIAG_SEV_ERROR's band; 64 is problems-model's RANK_STEP.
local function is_open_error_rank(rank)
	return rank ~= nil and rank < (DIAG_SEV_ERROR + 1) * 64
end

-- The Stations Problems column sorts stations by their worst check and spells out a station's worst
-- finding first, acknowledged ones last.
test("rank / mask_rank: severity first, then the check index; a clean mask has none", function()
	local model = pm()
	assert_true(model.rank(LINT_CAPACITY) < model.rank(LINT_LAYOUT), "two errors by index")
	assert_true(model.rank(LINT_PHANTOM) < model.rank(LINT_LIMIT_ZERO), "an error before a warning")
	assert_true(model.rank(LINT_LIMIT_ZERO) < model.rank(LINT_NEVER_REFUELLED), "a warning before an info")
	assert_nil(model.mask_rank(0))
	assert_nil(model.mask_rank(nil))
	assert_eq(model.mask_rank(LINT_BIT[LINT_LIMIT_ZERO] + LINT_BIT[LINT_LAYOUT]), model.rank(LINT_LAYOUT))
	assert_eq(model.mask_rank(LINT_BIT[LINT_NEVER_REFUELLED]), model.rank(LINT_NEVER_REFUELLED))
end)

-- The Overview's Misconfigured line counts the stations with an error nobody acknowledged; the Problems view ranks
-- exactly those first, so the line and the rows it jumps to agree.
test("open_errors / station_rank: acknowledgements move a station behind every open one", function()
	local model = pm()
	local acked = {}
	local function is_acked(kind, id, check)
		assert_eq(kind, "lint")
		return acked[id .. ":" .. check]
	end
	local cap, layout, limit, refuel = LINT_BIT[LINT_CAPACITY], LINT_BIT[LINT_LAYOUT], LINT_BIT[LINT_LIMIT_ZERO],
		LINT_BIT[LINT_NEVER_REFUELLED]
	assert_eq(bit32.band(model.error_mask(), cap + layout), cap + layout, "both errors in the error mask")
	assert_eq(bit32.band(model.error_mask(), limit + refuel), 0, "warning and info are not")
	local by_check = {}
	assert_eq(model.open_errors(7, cap + layout + limit, is_acked, by_check), 2)
	assert_eq(by_check[LINT_CAPACITY], 1)
	assert_nil(by_check[LINT_LIMIT_ZERO], "warnings are not counted")
	assert_eq(model.open_errors(7, limit, is_acked), 0)
	assert_eq(model.open_errors(7, nil, is_acked), 0)
	assert_nil(model.station_rank(7, 0, is_acked))
	assert_eq(model.station_rank(7, cap + limit, is_acked), model.rank(LINT_CAPACITY))
	assert_true(is_open_error_rank(model.station_rank(7, cap + limit, is_acked)))

	acked["7:" .. LINT_CAPACITY] = { player_index = 1 }
	assert_eq(model.open_mask(7, cap + limit, is_acked), limit)
	assert_eq(model.open_errors(7, cap + limit, is_acked), 0, "the acknowledged error leaves the count")
	-- The open warning now decides the place: behind every open error, before any fully acknowledged station.
	local warn_rank = model.station_rank(7, cap + limit, is_acked)
	assert_eq(warn_rank, model.rank(LINT_LIMIT_ZERO))
	assert_false(is_open_error_rank(warn_rank))
	assert_true(model.station_rank(8, layout, is_acked) < warn_rank, "another station's open error leads")
	acked["7:" .. LINT_LIMIT_ZERO] = { player_index = 1 }
	local all_acked = model.station_rank(7, cap + limit, is_acked)
	assert_true(all_acked > model.station_rank(9, refuel, is_acked), "fully acknowledged after an open info")
	assert_false(is_open_error_rank(all_acked))
	assert_eq(model.open_mask(7, cap + limit, is_acked), 0)
end)

-- A station the Misconfigured line counts reads "Setup" instead of "OK" on Stations, the stop panel and
-- the drill-down; a status that already says why nothing moves stays.
test("shown_status: Setup replaces only OK, and only while an error is open", function()
	local model = pm()
	local acked = {}
	local function is_acked(kind, id, check) return acked[id .. ":" .. check] end
	local cap, limit, refuel = LINT_BIT[LINT_CAPACITY], LINT_BIT[LINT_LIMIT_ZERO], LINT_BIT[LINT_NEVER_REFUELLED]
	assert_eq(model.shown_status("ok", 7, cap, is_acked), "setup")
	assert_eq(model.shown_status(nil, 7, cap, is_acked), "setup", "a record without a status counts as OK")
	assert_eq(model.shown_status("starved", 7, cap, is_acked), "starved")
	assert_eq(model.shown_status("idle", 7, cap, is_acked), "idle")
	assert_eq(model.shown_status("ok", 7, limit + refuel, is_acked), "ok", "warnings and info do not block")
	assert_eq(model.shown_status("ok", 7, 0, is_acked), "ok")
	assert_eq(model.shown_status("ok", 7, nil, is_acked), "ok")
	local checks, mask = model.open_error_checks(7, cap + LINT_BIT[LINT_LAYOUT] + limit, is_acked)
	assert_eq(checks, { LINT_CAPACITY, LINT_LAYOUT })
	assert_eq(mask, cap + LINT_BIT[LINT_LAYOUT])
	acked["7:" .. LINT_CAPACITY] = { player_index = 1 }
	assert_eq(model.shown_status("ok", 7, cap + limit, is_acked), "ok", "an acknowledged error is OK again")
	assert_eq(model.open_error_checks(7, cap + limit, is_acked), {})
	local tip = model.setup_status_tooltip({ LINT_LAYOUT })
	assert_eq(tip[2], { "cybersyn-gui.station-status-setup-tooltip" })
	assert_eq(tip[4], model.caption(LINT_LAYOUT))
	local many = {}
	for check = 1, 12 do many[check] = check end
	local long = model.setup_status_tooltip(many)
	assert_true(#long <= 21, "a LocalisedString holds at most 20 parameters: " .. #long)
	assert_eq(long[#long], "\n+4")
end)

test("order: open before acknowledged, then severity, check, item and subject", function()
	local model = pm()
	local list = {
		finding(LINT_LIMIT_ZERO, S, 10),
		finding(LINT_CAPACITY, S, 10, 50, 40, { item = "iron-plate" }),
		finding(LINT_CAPACITY, S, 10, 50, 40, { item = "copper-plate" }),
		finding(LINT_NO_PROVIDER, S, 10, 0, 0, { item = "coal" }),
		finding(LINT_NEVER_REFUELLED, T, 7, 1, 0),
	}
	local acked = { [LINT_NO_PROVIDER] = { until_tick = 5 } }
	local out = model.order(list, function(f) return acked[f.check] end)
	local got = {}
	for i, e in ipairs(out) do got[i] = LINT_NAMES[e.f.check] .. ":" .. tostring(e.f.item) .. (e.ack and ":acked" or "") end
	assert_eq(got, { "capacity:copper-plate", "capacity:iron-plate", "limit_zero:nil", "never_refuelled:nil",
		"no_provider:coal:acked" })
	assert_eq(out[1].sev, LINT_SEVERITY[LINT_CAPACITY])
end)

local ENV = {
	item = function(hash) return hash and ("[item=" .. hash .. "]") or "" end,
	network = function(name) return "[virtual-signal=" .. tostring(name) .. "]" end,
	is_fluid = function(hash) return hash == "water" end,
	duration = function(ticks) return tostring(math.floor(ticks / 60)) .. "s" end,
}

test("detail sig: a never-refuelled row keeps its sig while the tracked time grows within the hour", function()
	local model = pm()
	local function sig(a) return model.detail_sig(finding(LINT_NEVER_REFUELLED, T, 7, a, 0, { network = "signal-A" })) end
	assert_eq(sig(216000 * 3 + 60), sig(216000 * 3 + 200000))
	assert_eq(sig(216000 * 3) ~= sig(216000 * 4), true)
	local function cap(a) return model.detail_sig(finding(LINT_CAPACITY, S, 1, a, 40, { item = "coal" })) end
	assert_eq(cap(50) ~= cap(51), true)
end)

test("detail: the numbers behind each check", function()
	local model = pm()
	local function d(check, a, b, extra) return model.detail(finding(check, S, 1, a, b, extra), ENV) end
	local K = "cybersyn-diag.lint-detail-"
	assert_eq(d(LINT_CAPACITY, 50, 40, { item = "iron-plate" }), { K .. "capacity", "[item=iron-plate]", "50", "40" })
	assert_eq(d(LINT_CAPACITY, 30000, 25000, { item = "water" }),
		{ K .. "capacity-fluid", "[item=water]", "30,000", "25,000" })
	assert_eq(d(LINT_CAPACITY, 50, 40, { item = "iron-plate", c = 5000 }),
		{ K .. "capacity-threshold", "[item=iron-plate]", "5,000", "50", "40" }, "the typed threshold first")
	assert_eq(d(LINT_LAYOUT, 1, 2, { network = "signal-A" }), { K .. "layout", "1", "2", "[virtual-signal=signal-A]" })
	assert_eq(d(LINT_LAYOUT, 1, 2, { network = "signal-A", item = "coal" }),
		{ K .. "layout-item", "[item=coal]", "1", "2", "[virtual-signal=signal-A]" }, "the capacity path names its item")
	assert_eq(d(LINT_MASK, 0, 6, { network = "signal-B" }), { K .. "mask-zero", "[virtual-signal=signal-B]" })
	assert_eq(d(LINT_NO_PROVIDER, 0, 0, { item = "coal", network = "signal-A" }),
		{ K .. "no-provider", "[item=coal]", "[virtual-signal=signal-A]" })
	assert_eq(d(LINT_LIMIT_ZERO, 0, 0), { K .. "limit-zero", "0", "0" })
	assert_eq(d(LINT_SAME_ITEM, 0, 0, { item = "coal" }), { K .. "same-item-static", "[item=coal]" })
	assert_eq(d(LINT_SAME_ITEM, 2000, 0, { item = "coal" }), { K .. "same-item-out", "[item=coal]", "2,000" })
	assert_eq(d(LINT_SAME_ITEM, 800, 1, { item = "coal" }), { K .. "same-item-in", "[item=coal]", "800" })
	assert_eq(d(LINT_OCCUPANCY, 0, 1), { K .. "occupancy", "0", "1" })
	assert_eq(d(LINT_OCCUPANCY, 0, 1, { train = 412 }), { K .. "occupancy-train", "412", "1", "0" },
		"the train the stop holds that Cybersyn did not send")
	assert_eq(d(LINT_PHANTOM, 2, 0, { fix = "phantom-leak" }), { K .. "phantom-leak", "2" },
		"a counter leak with no train bound")
	assert_eq(d(LINT_PHANTOM, 3, 2, { fix = "phantom-leak" }), { K .. "phantom-leak-bound", "3", "2", "1" },
		"a counter leak beside real deliveries keeps both counts")
	assert_eq(d(LINT_PHANTOM, 1, 3, { train = 15, status = STATUS_P }),
		{ K .. "phantom-trains", "15", { "cybersyn-diag.lint-train-status-2" }, "3", "1" },
		"several bound trains: the one named is one of them")
	assert_eq(d(LINT_PHANTOM, 0, 1), { K .. "phantom", "0", "1" }, "no train named: both counts")
	assert_eq(d(LINT_PHANTOM, 0, 1, { train = 15, status = STATUS_P }),
		{ K .. "phantom-train", "15", { "cybersyn-diag.lint-train-status-2" }, "0" }, "a bound train the station does not count")
	assert_eq(d(LINT_PRIORITY, 49, 0), { K .. "priority", "49", "0" })
	assert_eq(d(LINT_DEPOT_LIMIT, -1, 0), { K .. "depot-limit-none" })
	assert_eq(d(LINT_DEPOT_LIMIT, 3, 0), { K .. "depot-limit", "3" })
	assert_eq(d(LINT_DEPOT_SHARED_NAME, 2, 2), { K .. "depot-shared-name", "2", "2" })
	assert_eq(d(LINT_REFUELER_MASK, 4, 1, { network = "signal-7" }),
		{ K .. "refueler-mask", "4", "1", "[virtual-signal=signal-7]" })
	assert_eq(d(LINT_NEVER_REFUELLED, 216060, 0, { network = "signal-7" }),
		{ K .. "never-refuelled", "[virtual-signal=signal-7]", "3600s" })
	assert_eq(d(LINT_IN_GROUP, 2, 0), { K .. "in-group", "2", "0" })
	assert_eq(d(LINT_MISSING_STOP, 2, 0), { K .. "missing-stop", "2", "0" })
	assert_eq(d(LINT_CAPACITY_DRIFT, 7, 40), { K .. "capacity-drift", "7", "40" })
	assert_eq(d(LINT_TRAIN_MASK, 1, 42, { network = "signal-B" }),
		{ K .. "train-mask", "1", "42", "[virtual-signal=signal-B]" })
	assert_eq(d(LINT_NO_TRAIN, 0, 0, { network = "signal-8" }), { K .. "no-train", "[virtual-signal=signal-8]" })
	assert_eq(model.detail({ check = LINT_DOUBLE_COMB, subject = LINT_SUBJECT_STOP, id = 5, message = "station-and-depot" },
		ENV), { "cybersyn-gui.problems-world-station-and-depot" })
end)

test("detail wording: the item and its amount first, amounts as the other cells write them", function()
	local model = pm()
	local env = {}
	for k, v in pairs(ENV) do env[k] = v end
	env.count = format_signal_count
	local function d(check, a, b, extra) return model.detail(finding(check, S, 1, a, b, extra), env) end
	local K = "cybersyn-diag.lint-detail-"
	assert_eq(d(LINT_CAPACITY, 400, 40, { item = "iron-plate", c = 2000 }),
		{ K .. "capacity-threshold", "[item=iron-plate]", "2.0k", "400", "40" }, "the typed threshold in k-format")
	assert_eq(d(LINT_CAPACITY, 30000, 25000, { item = "water" }), { K .. "capacity-fluid", "[item=water]", "30k", "25k" })
	assert_eq(d(LINT_SAME_ITEM, 2000, 0, { item = "coal" }), { K .. "same-item-out", "[item=coal]", "2.0k" })
	-- The locale: an icon parameter is never followed by an orphan separator, and the capacity texts open with the
	-- item and what it needs, so a cut cell still tells two findings apart.
	local f = assert(io.open(H.mod_root .. "/locale/en/manager.cfg", "r"))
	local text = f:read("*a")
	f:close()
	for key, value in string.gmatch(text, "\n(lint%-detail%-[%w%-]+)=([^\n]*)") do
		assert_true(not string.find(value, "^__1__ ·"), key .. " starts with an icon and a separator: " .. value)
	end
	for _, key in ipairs({ "capacity", "capacity-threshold", "capacity-fluid" }) do
		local value = string.match(text, "\nlint%-detail%-" .. string.gsub(key, "%-", "%%-") .. "=([^\n]*)")
		assert_true(value and string.find(value, "^__1__ needs __2__") ~= nil, key .. ": " .. tostring(value))
	end
	assert_eq(string.match(text, "\nlint%-detail%-no%-provider=([^\n]*)"), "__1__ no provider on __2__")
end)

test("captions and fix lines: one locale key per check, the fix line without numbers", function()
	local model = pm()
	for check = 1, LINT_COUNT do
		assert_eq(model.caption(check), { "cybersyn-diag.lint-" .. LINT_KEYS[check] })
		assert_eq(model.fix(check), { "cybersyn-diag.lint-fix-" .. LINT_KEYS[check] })
		assert_eq(model.fix(check, { check = check }), { "cybersyn-diag.lint-fix-" .. LINT_KEYS[check] })
		assert_eq(model.chip(check), { "cybersyn-diag.lint-chip-" .. LINT_KEYS[check] })
		assert_not_nil(model.CHIP_STYLE[LINT_SEVERITY[check]])
		assert_not_nil(model.DOT[LINT_SEVERITY[check]])
	end
	assert_eq(model.fix(LINT_PHANTOM, { check = LINT_PHANTOM, fix = "phantom-leak" }),
		{ "cybersyn-diag.lint-fix-phantom-leak" }, "a counter leak names the recount")
end)

--- Every key the model and the tab use resolves in every locale, through its own translation or the en fallback.
test("locale: every lint caption, fix and detail key, and the Problems column's keys, in every locale", function()
	local keys = {}
	for check = 1, LINT_COUNT do
		keys[#keys + 1] = "lint-" .. LINT_KEYS[check]
		keys[#keys + 1] = "lint-fix-" .. LINT_KEYS[check]
		keys[#keys + 1] = "lint-chip-" .. LINT_KEYS[check]
	end
	for _, k in ipairs({ "capacity", "capacity-fluid", "capacity-threshold", "layout", "layout-item", "mask-zero", "no-provider", "limit-zero",
		"same-item-static", "same-item-out", "same-item-in", "occupancy", "occupancy-train", "phantom", "phantom-train",
		"phantom-trains", "phantom-leak", "phantom-leak-bound", "priority", "depot-limit", "depot-limit-none",
		"depot-shared-name", "refueler-mask", "never-refuelled", "in-group", "missing-stop", "capacity-drift",
		"train-mask", "no-train" }) do
		keys[#keys + 1] = "lint-detail-" .. k
	end
	for _, m in ipairs({ "double-station", "double-station-control", "double-depot", "double-refueler",
		"station-and-depot", "station-and-refueler", "depot-and-refueler", "non-default-priority",
		"name-overlap-with-depot", "derelict-combinator", "ghost-combinator", "stop-no-combinator",
		"wrong-side-combinator" }) do
		keys[#keys + 1] = "problems-world-" .. m
	end
	keys[#keys + 1] = "lint-fix-phantom-leak"
	for status = STATUS_D, STATUS_F do keys[#keys + 1] = "lint-train-status-" .. status end
	for _, k in ipairs({ "problems-predicts", "problems-predicts-none", "problems-chip-tooltip", "problems-ack-tooltip",
		"problems-ack-until-clear", "problems-pending-progress", "stations-chip-problems", "stations-chip-problems-tooltip",
		"stations-problems", "stations-sort-problems", "stations-problems-more", "stations-problems-none", "stations-problems-none-filtered", "stations-open-errors",
		"stations-open-errors-acked", "stations-open-errors-tooltip",
		"stations-registry-stop", "stations-registry-combinator", "stations-registry-tooltip", "stations-summary-registry",
		"stations-last-dispatch", "stations-sort-last-dispatch", "stations-last-dispatch-never",
		"station-status-setup", "station-status-setup-tooltip" }) do
		keys[#keys + 1] = k
	end
	-- Findings live on the Stations tab: no locale carries keys of a Problems tab of its own.
	for _, k in ipairs({ "problems", "problems-scan-tooltip", "problems-sev-error", "problems-show-acked",
		"problems-col-check", "problems-group", "problems-empty", "problems-footer", "problems-pending",
		"problems-badge-tooltip", "stations-chip-setup", "stations-setup-chip" }) do
		for _, loc in ipairs(H.LOCALES) do
			assert_true(H.locale_text(loc):find("\n" .. k .. "=", 1, true) == nil, loc .. " still has " .. k)
		end
	end
	for _, loc in ipairs(H.LOCALES) do
		local text = H.locale_text(loc)
		for _, k in ipairs(keys) do
			assert_true(text:find("\n" .. k .. "=", 1, true) ~= nil, loc .. " lacks " .. k)
		end
		-- Fix lines carry no numbers: the detail column has them.
		for check = 1, LINT_COUNT do
			local line = text:match("\nlint%-fix%-" .. LINT_KEYS[check]:gsub("%-", "%%-") .. "=([^\n]*)")
			assert_true(line ~= nil and not line:find("__%d__"), loc .. " lint-fix-" .. LINT_KEYS[check])
		end
		assert_true(not text:match("\nlint%-fix%-phantom%-leak=([^\n]*)"):find("__%d__"), loc .. " lint-fix-phantom-leak")
		-- There is no world scan button, so no locale has its tooltip.
		assert_true(text:find("\nproblems-scan-tooltip=", 1, true) == nil, loc .. " still has problems-scan-tooltip")
	end
end)

test("lint-text: a counter leak's fix line reads Recount deliveries in the Stations tooltip; a bound train keeps Send home", function()
	local lt = H.load("scripts.gui.lint-text")
	local K = "cybersyn-diag.lint-fix-"
	local leak = { check = LINT_PHANTOM, subject = LINT_SUBJECT_STATION, id = 1, a = 2, b = 0, fix = "phantom-leak" }
	local bound = { check = LINT_PHANTOM, subject = LINT_SUBJECT_STATION, id = 2, a = 0, b = 1, train = 15 }
	local t_leak = lt.texts(LINT_PHANTOM, "r", leak)
	local t_bound = lt.texts(LINT_PHANTOM, "r", bound)
	assert_eq(t_leak.fix, { K .. "phantom-leak" })
	assert_eq(t_leak.tooltip[4], { K .. "phantom-leak" }, "the tooltip carries the finding's fix line")
	assert_eq(t_bound.fix, { K .. "phantom" })
	assert_eq(t_bound.tooltip[4], { K .. "phantom" })
	assert_true(t_leak.key ~= t_bound.key, "the per-check cache keeps the two apart")
	assert_eq(lt.texts(LINT_PHANTOM, "r").fix, { K .. "phantom" }, "no finding: the per-check line")
	assert_true(lt.texts(LINT_PHANTOM, "r", leak) == t_leak, "cached per variant")
end)
