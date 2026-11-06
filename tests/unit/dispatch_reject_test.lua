-- A rejected schedule records its cause. ScheduleBuilder:is_path_available asks the pathfinder a second
-- time only after a failed pre-check and only with the probe, and diag.dispatch_failed writes the severity of the
-- cause, the manifest's first item and the train state.

local H = require("harness")

--- Replaces game.train_manager with one whose request_train_path answers from `answers` in call order and records
--- every request it gets.
local function stub_paths(answers)
	local calls = {}
	game.train_manager = {
		request_train_path = function(req)
			local copy = {}
			for k, v in pairs(req) do copy[k] = v end
			calls[#calls + 1] = copy
			return { found_path = answers[#calls] == true }
		end,
	}
	return calls
end

--- A builder with one stop record, as add_loading_order leaves it.
local function builder()
	local b = ScheduleBuilder:new()
	b.i = 1
	b.stops[1] = { name = "provider" }
	b.records[1] = { station = "provider" }
	return b
end

test("is_path_available: found = one request, with in_chain_signal_section on", function()
	local calls = stub_paths({ true })
	local found, blocked = builder():is_path_available({}, true)
	assert_eq({ found, blocked, #calls, calls[1].in_chain_signal_section }, { true, nil, 1, true })
end)

test("is_path_available: not found with the probe = a second request without the chain-signal rule", function()
	local calls = stub_paths({ false, true })
	local found, blocked = builder():is_path_available({}, true)
	assert_eq({ found, blocked, #calls }, { false, true, 2 }, "the probe found a route: blocked")
	assert_eq({ calls[1].in_chain_signal_section, calls[2].in_chain_signal_section }, { true, false })
	calls[1].in_chain_signal_section, calls[2].in_chain_signal_section = nil, nil
	assert_eq(calls[2], calls[1], "otherwise the same request")
	calls = stub_paths({ false, false })
	found, blocked = builder():is_path_available({}, true)
	assert_eq({ found, blocked, #calls }, { false, false, 2 }, "no route at all")
end)

test("is_path_available: not found without the probe = one request", function()
	local calls = stub_paths({ false, true })
	local found, blocked = builder():is_path_available({}, false)
	assert_eq({ found, blocked, #calls }, { false, nil, 1 })
	calls = stub_paths({})
	found = ScheduleBuilder:new():is_path_available({}, true)
	assert_eq({ found, #calls }, { false, 0 }, "no goal: no request")
end)

--- Runs set_manifest_schedule for a train heading to its depot (STATUS_TO_D_BYPASS) with the order builders and the
--- schedule writers replaced by stand-ins, so only its path checks and its return values are exercised.
--- @param answers boolean[] request_train_path answers in call order
--- @param d table? map_data.diag: nil = off, {} = Basic, { full = true } = Full
--- @param has_path boolean? the train's has_path after the orders are written
local function dispatch(answers, d, has_path)
	local calls = stub_paths(answers)
	local saved = { ScheduleBuilder.add_loading_order, ScheduleBuilder.add_unloading_order, clean_temporary_records,
		add_records_after_interrupt }
	ScheduleBuilder.add_loading_order = function(self, stop) self:add({ station = stop.name }, stop) end
	ScheduleBuilder.add_unloading_order = ScheduleBuilder.add_loading_order
	clean_temporary_records = function() end
	add_records_after_interrupt = function() return 1, 2 end
	local schedule = { current = 1, get_record_count = function() return 2 end, go_to_station = function() end }
	local train = { status = STATUS_TO_D_BYPASS, entity = { has_path = has_path,
		front_stock = { surface_index = 1 }, get_schedule = function() return schedule end } }
	local stop = function(name) return { name = name, valid = true, connected_rail = {}, surface_index = 1 } end
	game.tick = 100
	local ok, dispatched, why = pcall(set_manifest_schedule, { diag = d }, train, stop("depot"),
		false, stop("provider"), {}, stop("requester"), {}, {}, nil, false)
	ScheduleBuilder.add_loading_order, ScheduleBuilder.add_unloading_order, clean_temporary_records,
		add_records_after_interrupt = saved[1], saved[2], saved[3], saved[4]
	assert_true(ok, tostring(dispatched))
	return dispatched, why, #calls, train.skip_path_checks_until
end

test("set_manifest_schedule: the second request runs only in Full diagnostics; each cause is returned", function()
	local full = { full = true }
	assert_eq({ dispatch({ false, true }, nil) }, { false, DIAG_DISPATCH_NO_PATH, 1, 100 + NO_PATH_SKIP_TIME },
		"diagnostics off: no probe, the cause reads as no path")
	assert_eq({ dispatch({ false, true }, {}) }, { false, DIAG_DISPATCH_NO_PATH, 1, 100 + NO_PATH_SKIP_TIME },
		"Basic: no probe either")
	assert_eq({ dispatch({ false, true }, full) }, { false, DIAG_DISPATCH_PATH_BLOCKED, 2, 100 + NO_PATH_SKIP_TIME })
	assert_eq({ dispatch({ false, false }, full) }, { false, DIAG_DISPATCH_NO_PATH, 2, 100 + NO_PATH_SKIP_TIME })
	assert_eq({ dispatch({ true }, full, false) }, { false, DIAG_DISPATCH_NO_PATH_AFTER_WRITE, 1, nil })
	assert_eq({ dispatch({ true }, full, true) }, { true, nil, 1, nil })
end)

test("dispatch_failed: severity by cause, the first item interned, a = state + 1", function()
	mod_settings.diagnostics = "basic"
	storage.trains, storage.stations = {}, {}
	local diag = H.load("scripts.diag")
	local d = diag.apply()
	game.tick = 5
	local manifest = { { type = "item", name = "iron-plate", quality = "normal", count = 100 },
		{ type = "item", name = "coal", count = 5 } }
	diag.dispatch_failed(DIAG_DISPATCH_NO_PATH, 15, 358, 1134, manifest, defines.train_state.wait_station)
	diag.dispatch_failed(DIAG_DISPATCH_PATH_BLOCKED, 15, 358, 1134, manifest, defines.train_state.on_the_path)
	diag.dispatch_failed(DIAG_DISPATCH_NO_PATH_AFTER_WRITE, 16, 358, 1134, manifest, defines.train_state.no_path)
	diag.dispatch_failed(DIAG_DISPATCH_TRAIN_INVALID, 17, 358, 1134, manifest)
	diag.dispatch_failed(99, 18, 358, 1134)
	local rows = diag.events(nil, 0, 10)
	local got = {}
	for i, r in ipairs(rows) do got[i] = { r.code, DIAG_SEV_NAMES[r.sev], r.train, r.station, r.station2, r.item, r.a } end
	local iron = d.item_ix["iron-plate"]
	assert_true(iron ~= nil, "iron-plate interned (normal quality hashes to the bare name)")
	assert_eq(got, {
		{ DIAG_DISPATCH_NO_PATH, "info", 15, 358, 1134, iron, defines.train_state.wait_station + 1 },
		{ DIAG_DISPATCH_PATH_BLOCKED, "info", 15, 358, 1134, iron, defines.train_state.on_the_path + 1 },
		{ DIAG_DISPATCH_NO_PATH_AFTER_WRITE, "warning", 16, 358, 1134, iron, defines.train_state.no_path + 1 },
		{ DIAG_DISPATCH_TRAIN_INVALID, "error", 17, 358, 1134, iron, 0 },
		{ 99, "error", 18, 358, 1134, 0, 0 },
	})
end)

test("constants: DIAG_DISPATCH_SEVERITY parallel to DIAG_DISPATCH_NAMES, 1-5 unchanged", function()
	assert_eq(#DIAG_DISPATCH_SEVERITY, #DIAG_DISPATCH_NAMES)
	assert_eq({ DIAG_DISPATCH_NAMES[1], DIAG_DISPATCH_NAMES[2], DIAG_DISPATCH_NAMES[3], DIAG_DISPATCH_NAMES[4],
		DIAG_DISPATCH_NAMES[5] }, { "train_invalid", "depot_invalid", "provider_invalid", "requester_invalid",
		"schedule_rejected" })
	assert_eq({ DIAG_DISPATCH_NAMES[DIAG_DISPATCH_NO_PATH], DIAG_DISPATCH_NAMES[DIAG_DISPATCH_PATH_BLOCKED],
		DIAG_DISPATCH_NAMES[DIAG_DISPATCH_NO_PATH_AFTER_WRITE] }, { "no_path", "path_blocked", "no_path_after_write" })
	local sev = {}
	for i, s in ipairs(DIAG_DISPATCH_SEVERITY) do sev[i] = DIAG_SEV_NAMES[s] end
	assert_eq(sev, { "error", "error", "error", "error", "warning", "info", "info", "warning" })
end)

test("stop/train panel Last events: a dispatch_failed row names its cause", function()
	local rtext = H.load("scripts.gui.relative-text")
	assert_eq(rtext.event_detail({ kind = DIAG_KIND_DISPATCH_FAILED, code = DIAG_DISPATCH_NO_PATH, a = 8, b = 0 }),
		{ "cybersyn-diag.dispatch-no-path" })
	assert_eq(rtext.event_detail({ kind = DIAG_KIND_DISPATCH_FAILED, code = DIAG_DISPATCH_SCHEDULE_REJECTED, a = 0, b = 0 }),
		{ "cybersyn-diag.dispatch-schedule-rejected" })
	assert_eq(rtext.event_detail({ kind = DIAG_KIND_DISPATCH_FAILED, code = 99, a = 0, b = 0 }), nil)
end)
