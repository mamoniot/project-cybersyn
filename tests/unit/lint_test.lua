-- scripts/lint.lua: the check predicates against plain records, and scripts/actions.lua.

local H = require("harness")
local lint = H.load("scripts.lint")
local actions = H.load("scripts.actions")

local function checks(out)
	local names = {}
	for i, f in ipairs(out) do names[i] = LINT_NAMES[f.check] end
	return names
end

--- A requester record on signal-A (mask `mask`) asking for `hashes` = {hash = {threshold, active}}.
local function station(mask, hashes, extra)
	local st = { is_r = true, is_p = false, network_name = "signal-A", network_mask = mask, requested = {}, provided = {},
		deliveries = {}, thresholds = {} }
	for hash, r in pairs(hashes or {}) do
		st.requested[hash] = { count = -r[1], threshold = r[1], active = r[2] ~= false }
	end
	for k, v in pairs(extra or {}) do st[k] = v end
	return st
end

local function fleet(by_layout, mask_or)
	return { capability = { ["signal-A"] = by_layout }, mask_or = { ["signal-A"] = mask_or } }
end

local CLEAN = { limit = 2, count = 0, occupancy = 0, occupancy_gap = false, deliveries = 0, bound = 0, phantom = false }

local function run(st, rec, fl, pm, starved, live, overrides)
	local out = {}
	local mask = lint.check_station(out, 7, st, rec or { allows_all_trains = true, accepted_layouts = {} }, fl,
		{ masks = pm or {}, overrides = overrides, starved = starved or {} }, live or CLEAN)
	return mask, out
end

test("constants: one bit, key, name and severity per check", function()
	assert_eq(#LINT_NAMES, LINT_COUNT)
	local seen = 0
	for check = 1, LINT_COUNT do
		assert_eq(LINT_BY_NAME[LINT_NAMES[check]], check)
		assert_eq(LINT_BIT[check], 2 ^ (check - 1))
		assert_not_nil(LINT_SEVERITY[check])
		assert_true(bit32.band(seen, LINT_BIT[check]) == 0)
		seen = bit32.bor(seen, LINT_BIT[check])
	end
	assert_eq(LINT_KEYS[LINT_DEPOT_SHARED_NAME], "depot-shared-name")
	assert_eq(LINT_PREDICTS[LINT_CAPACITY], REASON_CAPACITY)
end)

test("predicts: the dispatcher's code for the station's role", function()
	assert_eq(lint.predicts(LINT_LAYOUT, "r"), REASON_R_LAYOUT)
	assert_eq(lint.predicts(LINT_LAYOUT, "p"), REASON_P_LAYOUT)
	assert_eq(lint.predicts(LINT_SAME_ITEM, "r"), REASON_R_IS_PROVIDING)
	assert_eq(lint.predicts(LINT_SAME_ITEM, "p"), REASON_P_IS_REQUESTING)
	assert_eq(lint.predicts(LINT_LIMIT_ZERO, "r"), REASON_R_DISABLED)
	assert_eq(lint.predicts(LINT_LIMIT_ZERO, "p"), REASON_P_AT_LIMIT)
	assert_eq(lint.predicts(LINT_MASK, "r"), REASON_MASK_MISMATCH)
	assert_eq(lint.predicts(LINT_TRAIN_MASK, "p"), REASON_TRAIN_FILTERED)
	assert_eq(lint.predicts(LINT_NO_TRAIN, "r"), REASON_NO_TRAINS_ON_NETWORK)
	-- A stop holding more trains than Cybersyn sent shows as destination_full on the train, not as a reason.
	assert_eq(lint.predicts(LINT_OCCUPANCY, "r"), nil)
	assert_eq(lint.predicts(LINT_DEPOT_LIMIT, "r"), nil)
end)

test("eligible: mask-matching trains, the ones the stop accepts and their largest capacities", function()
	local cap = {
		[1] = { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 1 },
		[2] = { count = 3, item_capacity = 80, fluid_capacity = 50000, mask_or = 2 },
		[3] = { count = 1, item_capacity = 120, fluid_capacity = 0, mask_or = 1 },
	}
	assert_eq({ lint.eligible(cap, 1, true, {}) }, { 3, 3, 120, 0, 120, 0 })
	assert_eq({ lint.eligible(cap, 1, false, { [1] = true }) }, { 3, 2, 40, 0, 120, 0 })
	assert_eq({ lint.eligible(cap, 3, false, { [2] = true }) }, { 6, 3, 80, 50000, 120, 50000 })
	assert_eq({ lint.eligible(cap, 4, true, {}) }, { 0, 0, 0, 0, 0, 0 })
	assert_eq({ lint.eligible(nil, 1, true, {}) }, { 0, 0, 0, 0, 0, 0 })
end)

test("capacity: a threshold above the largest eligible train, in stacks for items and units for fluids", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 25000, mask_or = 1 } }, 1)
	-- 5,000 iron plates (stack 100) = 50 slots > 40.
	local mask, out = run(station(1, { ["iron-plate"] = { 5000 } }), nil, fl)
	assert_eq(checks(out), { "capacity" })
	assert_eq({ out[1].a, out[1].b, out[1].network, out[1].item }, { 50, 40, "signal-A", "iron-plate" })
	assert_true(lint.has(mask, LINT_CAPACITY))
	-- 4,000 = 40 slots fits; an inactive request is configured all the same.
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 4000, false } }), nil, fl))), {})
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 4100, false } }), nil, fl))), { "capacity" })
	-- Quality hashes use the item's stack size; fluids compare units.
	assert_eq(checks(select(2, run(station(1, { ["iron-plate|rare"] = { 4100 } }), nil, fl))), { "capacity" })
	assert_eq(checks(select(2, run(station(1, { water = { 25000 } }), nil, fl))), {})
	assert_eq(checks(select(2, run(station(1, { water = { 25001 } }), nil, fl))), { "capacity" })
	-- The dispatcher tests capacity before layout: a 400-slot train the stop rejects makes it R_LAYOUT, not CAPACITY.
	local fl2 = fleet({
		[1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 },
		[2] = { count = 1, item_capacity = 400, fluid_capacity = 0, mask_or = 1 },
	}, 1)
	local _, lo = run(station(1, { ["iron-plate"] = { 5000 } }), { accepted_layouts = { [1] = true } }, fl2)
	assert_eq(checks(lo), { "layout" })
	-- One layout accepted; one the stop rejects would carry the 50 slots.
	assert_eq({ lo[1].a, lo[1].b, lo[1].item }, { 1, 1, "iron-plate" })
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 5000 } }), { allows_all_trains = true }, fl2))), {})
	-- Above every train of any layout it is capacity, whatever the stop accepts.
	local _, big = run(station(1, { ["iron-plate"] = { 50000 } }), { accepted_layouts = { [1] = true } }, fl2)
	assert_eq(checks(big), { "capacity" })
	assert_eq({ big[1].a, big[1].b }, { 500, 400 })
end)

test("capacity: a provider's own item threshold below the requester's is what the train must carry", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 25000, mask_or = 1 } }, 1)
	local st = station(1, { ["iron-plate"] = { 5000 } })
	assert_eq(checks(select(2, run(st, nil, fl, nil, nil, nil, { ["signal-A:iron-plate"] = 2000 }))), {})
	assert_eq(checks(select(2, run(st, nil, fl, nil, nil, nil, { ["signal-A:iron-plate"] = 4100 }))), { "capacity" })
	-- An override above the requester's threshold is not used, and one on another network does not count.
	assert_eq(checks(select(2, run(st, nil, fl, nil, nil, nil, { ["signal-A:iron-plate"] = 9000 }))), { "capacity" })
	assert_eq(checks(select(2, run(st, nil, fl, nil, nil, nil, { ["signal-B:iron-plate"] = 2000 }))), { "capacity" })
	assert_eq(checks(select(2, run(station(1, { water = { 30000 } }), nil, fl, nil, nil, nil,
		{ ["signal-A:water"] = 20000 }))), {})
end)

test("layout: trains on the network but none with a layout the stop accepts", function()
	local fl = fleet({ [1] = { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } }, 1)
	local mask, out = run(station(1, { ["iron-plate"] = { 1000 } }), { accepted_layouts = { [9] = true } }, fl)
	assert_eq(checks(out), { "layout" })
	-- b counts the layouts kept out, not their trains: two trains of one layout are one layout.
	assert_eq({ out[1].a, out[1].b }, { 1, 1 })
	local fl2 = fleet({
		[1] = { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 1 },
		[2] = { count = 5, item_capacity = 80, fluid_capacity = 0, mask_or = 3 },
		[3] = { count = 4, item_capacity = 80, fluid_capacity = 0, mask_or = 2 },
	}, 3)
	local _, two = run(station(1, { ["iron-plate"] = { 1000 } }), { accepted_layouts = { [9] = true } }, fl2)
	assert_eq({ two[1].a, two[1].b }, { 1, 2 })
	-- A provider is checked the same way.
	local p = station(1, {}, { is_r = false, is_p = true })
	assert_eq(checks(select(2, run(p, { accepted_layouts = {} }, fl))), { "layout" })
	assert_eq(checks(select(2, run(p, { accepted_layouts = { [1] = true } }, fl))), {})
end)

test("mask: no train shares a bit or the network has no train; the item's providers' bits are not a finding", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 2 } }, 2)
	local _, out = run(station(1, { ["iron-plate"] = { 1000 } }), nil, fl)
	assert_eq(checks(out), { "train_mask" })
	assert_eq({ out[1].a, out[1].b }, { 1, 2 })
	-- No train at all on the network (NO_TRAINS_ON_NETWORK's setup case).
	local _, none = run(station(1, {}), nil, { capability = {}, mask_or = {} })
	assert_eq(checks(none), { "no_train" })
	assert_eq(none[1].network, "signal-A")
	-- Trains fine, but every provider of the item is on mask 2 right now: providers whose masks follow demand make
	-- that a normal idle state, and the dispatcher's live MASK_MISMATCH covers a
	-- request it actually blocks.
	local fl3 = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 3 } }, 3)
	local _, prov = run(station(1, { ["iron-plate"] = { 1000 } }), nil, fl3, { ["signal-A:iron-plate"] = 2 })
	assert_eq(checks(prov), {})
end)

test("no_provider: an active request whose key is starved; an inactive one is not", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } }, 1)
	local starved = { ["signal-A:iron-plate"] = true }
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 1000 } }), nil, fl, {}, starved))), { "no_provider" })
	assert_eq(checks(select(2, run(station(1, { ["iron-plate"] = { 1000, false } }), nil, fl, {}, starved))), {})
end)

test("limit 0, same item both ways, occupancy and phantom come from the record and the live reads", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } }, 1)
	local live = { limit = 0, count = 2, occupancy = 1, occupancy_gap = true, deliveries = 3, bound = 1, phantom = true }
	local mask, out = run(station(1, {}), nil, fl, nil, nil, live)
	assert_eq(checks(out), { "limit_zero", "occupancy", "phantom" })
	assert_eq({ out[2].a, out[2].b, out[3].a, out[3].b }, { 1, 2, 3, 1 })
	assert_eq(mask, LINT_BIT[LINT_LIMIT_ZERO] + LINT_BIT[LINT_OCCUPANCY] + LINT_BIT[LINT_PHANTOM])
	-- Requesting what it is sending out (R_IS_PROVIDING), or providing what it has inbound (P_IS_REQUESTING).
	local both = station(1, { ["iron-plate"] = { 1000 } }, { is_p = true, deliveries = { ["iron-plate"] = -2000 } })
	local _, o1 = run(both, nil, fl)
	assert_eq(checks(o1), { "same_item" })
	assert_eq(o1[1].a, 2000)
	assert_eq(o1[1].b, 0)
	local inbound = station(1, {}, { is_p = true, provided = { ["iron-plate"] = 500 }, deliveries = { ["iron-plate"] = 800 } })
	local _, o2 = run(inbound, nil, fl)
	assert_eq(checks(o2), { "same_item" })
	assert_eq({ o2[1].a, o2[1].b }, { 800, 1 })
	-- The dispatcher skips the item whatever its own threshold (central-planning: R_IS_PROVIDING / P_IS_REQUESTING
	-- read only the deliveries), so an item threshold does not clear it; a stop that only
	-- requests never has it.
	both.thresholds = { ["iron-plate"] = 500 }
	assert_eq(checks(select(2, run(both, nil, fl))), { "same_item" })
	local r_only = station(1, { ["iron-plate"] = { 1000 } }, { deliveries = { ["iron-plate"] = -2000 } })
	assert_eq(checks(select(2, run(r_only, nil, fl))), {})
end)

test("each network of a NETWORK_EACH stop is checked with its own mask", function()
	local st = station({ ["signal-A"] = 1, ["signal-B"] = 4 }, { ["iron-plate"] = { 1000 } }, { network_name = NETWORK_EACH })
	local fl = { capability = {
		["signal-A"] = { [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } },
		["signal-B"] = { [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } },
	}, mask_or = { ["signal-A"] = 1, ["signal-B"] = 1 } }
	local _, out = run(st, nil, fl)
	assert_eq(checks(out), { "train_mask" })
	assert_eq(out[1].network, "signal-B")
end)

test("depot: limit not 1 (unset reads as -1) and a shared name with same-depot trains and bypass", function()
	local out = {}
	local mask = lint.check_depot(out, 5, 4294967295, nil)
	assert_eq(checks(out), { "depot_limit" })
	assert_eq(out[1].a, -1)
	assert_eq(lint.check_depot({}, 5, 1, nil), 0)
	out = {}
	lint.check_depot(out, 5, 1, { ids = { 5, 6 }, same_depot_bypass = 3 })
	assert_eq(checks(out), { "depot_shared_name" })
	assert_eq({ out[1].a, out[1].b }, { 2, 3 })
	assert_eq(lint.check_depot({}, 5, 1, { ids = { 5, 6 }, same_depot_bypass = 0 }), 0)
	assert_eq(lint.check_depot({}, 5, 1, { ids = { 5 }, same_depot_bypass = 2 }), 0)
	assert_true(mask ~= 0)
end)

test("refueler: a mask that shares no bit with the network's trains", function()
	local fl = { capability = {}, mask_or = { ["signal-A"] = 3 } }
	local out = {}
	lint.check_refueler(out, 9, { network_name = "signal-A", network_mask = 4 }, fl)
	assert_eq(checks(out), { "refueler_mask" })
	assert_eq({ out[1].a, out[1].b }, { 4, 3 })
	assert_eq(lint.check_refueler({}, 9, { network_name = "signal-A", network_mask = 2 }, fl), 0)
	assert_eq(lint.check_refueler({}, 9, { network_name = nil }, fl), 0)
end)

test("train: group, missing record, never refuelled, capacity drift (items, then fluid)", function()
	local train = { item_slot_capacity = 40, fluid_capacity = 0 }
	local out = {}
	lint.check_train(out, 3, train, { in_group = true, missing_record = 2, never_refuelled = "signal-A", items = 40,
		fluid = 0 })
	assert_eq(checks(out), { "in_group", "missing_stop", "never_refuelled" })
	assert_eq(out[2].a, 2)
	out = {}
	lint.check_train(out, 3, train, { in_group = false, items = 80, fluid = 0 })
	assert_eq(checks(out), { "capacity_drift" })
	assert_eq({ out[1].a, out[1].b }, { 40, 80 })
	out = {}
	lint.check_train(out, 3, { item_slot_capacity = 0, fluid_capacity = 25000 }, { items = 0, fluid = 50000 })
	assert_eq(checks(out), { "capacity_drift" })
	-- A quality fluid wagon's size is not known from the prototype: no fluid comparison.
	assert_eq(lint.check_train({}, 3, { item_slot_capacity = 0, fluid_capacity = 25000 }, { items = 0 }), 0)
end)

test("actions: single player always; admins, everyone and nobody against player.admin", function()
	local admin, other = { admin = true, valid = true }, { admin = false, valid = true }
	game.is_multiplayer = function() return false end
	mod_settings.manager_actions = "nobody"
	assert_true(actions.may_act(other))
	game.is_multiplayer = function() return true end
	local want = {
		admins = { true, false, true },
		everyone = { true, true, true },
		nobody = { false, false, false },
	}
	for setting, w in pairs(want) do
		mod_settings.manager_actions = setting
		assert_eq({ actions.may_act(admin), actions.may_act(other), actions.may_act(nil) }, w, setting)
	end
	mod_settings.manager_actions = nil
	assert_eq(actions.setting(), "admins")
end)

test("mask: only mask 0 on a network with trains, a warning, not on a stop without power or switched off", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 3 } }, 3)
	-- A secondary combinator's request on bits no provider has now is not a finding.
	local st = station(2, { ["iron-plate"] = { 1000 } })
	st.requested["iron-plate"].mask = 2
	assert_eq(checks(select(2, run(st, nil, fl, { ["signal-A:iron-plate"] = 1 }))), {})
	-- Mask 0 matches nothing; the dispatcher stops at the provider mask check, so it is MASK_MISMATCH's finding.
	local zero = station(0, {})
	local _, z = run(zero, nil, fl)
	assert_eq(checks(z), { "mask" })
	assert_eq({ z[1].a, z[1].b, z[1].network }, { 0, 3, "signal-A" })
	assert_eq(LINT_SEVERITY[LINT_MASK], DIAG_SEV_WARNING)
	for _, status in ipairs({ "no_power", "disabled" }) do
		assert_eq(checks(select(2, run(station(0, {}, { status = status }), nil, fl))), {}, status)
	end
	assert_eq(checks(select(2, run(station(0, {}, { status = "starved" }), nil, fl))), { "mask" })
	-- A NETWORK_EACH stop with mask 0 on one of its networks.
	local each = station({ ["signal-A"] = 0 }, {}, { network_name = NETWORK_EACH })
	assert_eq(checks(select(2, run(each, nil, fl))), { "mask" })
end)

test("phantom: the direction decides the detail and the fix; occupancy names its train; priority not 50", function()
	local fl = fleet({ [1] = { count = 1, item_capacity = 40, fluid_capacity = 0, mask_or = 1 } }, 1)
	local function live(extra)
		local t = {}
		for k, v in pairs(CLEAN) do t[k] = v end
		for k, v in pairs(extra) do t[k] = v end
		return t
	end
	-- Counted deliveries no train serves: a counter leak, repaired by a recount.
	local _, leak = run(station(1, {}), nil, fl, nil, nil, live({ phantom = true, deliveries = 2, bound = 0 }))
	assert_eq(checks(leak), { "phantom" })
	assert_eq({ leak[1].a, leak[1].b, leak[1].fix, leak[1].train }, { 2, 0, "phantom-leak", nil })
	-- A bound train the station does not count: named with its status, the check's own fix (send it home).
	local _, bound = run(station(1, {}), nil, fl, nil, nil,
		live({ phantom = true, deliveries = 0, bound = 1, phantom_train = 15, phantom_status = STATUS_P }))
	assert_eq({ bound[1].a, bound[1].b, bound[1].fix, bound[1].train, bound[1].status }, { 0, 1, nil, 15, STATUS_P })
	local _, occ = run(station(1, {}), nil, fl, nil, nil,
		live({ occupancy_gap = true, occupancy = 0, count = 1, occupancy_train = 412 }))
	assert_eq(checks(occ), { "occupancy" })
	assert_eq({ occ[1].a, occ[1].b, occ[1].train }, { 0, 1, 412 })
	local _, prio = run(station(1, {}), nil, fl, nil, nil, live({ priority = 49 }))
	assert_eq(checks(prio), { "priority" })
	assert_eq(prio[1].a, 49)
	assert_eq(checks(select(2, run(station(1, {}), nil, fl, nil, nil, live({ priority = 50 })))), {})
	local out = {}
	assert_eq(lint.check_depot(out, 5, 1, nil, 60), LINT_BIT[LINT_PRIORITY])
	assert_eq({ out[1].subject, out[1].a }, { LINT_SUBJECT_DEPOT, 60 })
	out = {}
	lint.check_refueler(out, 9, { network_name = nil }, { capability = {}, mask_or = {} }, 10)
	assert_eq(checks(out), { "priority" })
	assert_eq(out[1].subject, LINT_SUBJECT_REFUELER)
end)

test("stop_facts: doubled and conflicting combinators, control-only stops and ghosts at unregistered stops", function()
	local function c(primary, secondary, depot, refueler, attached)
		return { primary = primary, secondary = secondary, depot = depot, refueler = refueler, attached = attached }
	end
	local function keys(found)
		local out = {}
		for m in pairs(found or {}) do out[#out + 1] = m end
		table.sort(out)
		return out
	end
	assert_eq(lint.stop_facts(c(1, 1, 0, 0, 2), true, false), nil)
	assert_eq(keys(lint.stop_facts(c(2, 0, 0, 0, 2), true, false)), { "double-station" })
	assert_eq(keys(lint.stop_facts(c(1, 2, 0, 0, 3), true, false)), { "double-station-control" })
	assert_eq(keys(lint.stop_facts(c(0, 0, 2, 0, 2), true, false)), { "double-depot" })
	assert_eq(keys(lint.stop_facts(c(0, 0, 0, 2, 2), true, false)), { "double-refueler" })
	assert_eq(keys(lint.stop_facts(c(1, 0, 1, 1, 3), true, false)),
		{ "depot-and-refueler", "station-and-depot", "station-and-refueler" })
	-- Not registered: a ghost waiting to be built says why first; else combinators that make no station.
	assert_eq(keys(lint.stop_facts(c(0, 1, 0, 0, 1), false, false)), { "stop-no-combinator" })
	assert_eq(keys(lint.stop_facts(c(0, 1, 0, 0, 1), false, true)), { "ghost-combinator" })
	assert_eq(keys(lint.stop_facts(c(0, 0, 0, 0, 0), false, true)), { "ghost-combinator" })
	assert_eq(lint.stop_facts(c(0, 0, 0, 0, 0), false, false), nil)
	-- Every message names a registry check, and every registry check has a message.
	local seen = {}
	for m, check in pairs(lint.MESSAGE_CHECK) do
		assert_true(lint.REGISTRY_CHECKS[check], m)
		seen[check] = true
	end
	for check in pairs(lint.REGISTRY_CHECKS) do assert_true(seen[check], LINT_NAMES[check]) end
	assert_true(not lint.REGISTRY_CHECKS[LINT_PRIORITY], "priority is a pass check now")
end)

test("sent_here: a train counts for the station it is bound to on its current leg only", function()
	assert_eq(lint.sent_here({ status = STATUS_TO_P, p_station_id = 1, r_station_id = 2 }, 1), true)
	assert_eq(lint.sent_here({ status = STATUS_P, p_station_id = 1, r_station_id = 2 }, 2), false)
	assert_eq(lint.sent_here({ status = STATUS_TO_R, p_station_id = 1, r_station_id = 2 }, 2), true)
	assert_eq(lint.sent_here({ status = STATUS_TO_R, p_station_id = 1, r_station_id = 2 }, 1), false)
	assert_eq(lint.sent_here({ status = STATUS_D, depot_id = 3 }, 3), false)
	assert_eq(lint.sent_here(nil, 3), false)
end)

test("rejected_layouts: mask-eligible layouts the allow list keeps out, optionally only those that carry the need", function()
	local cap = {
		[1] = { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 1 },
		[2] = { count = 3, item_capacity = 80, fluid_capacity = 50000, mask_or = 1 },
		[3] = { count = 1, item_capacity = 120, fluid_capacity = 0, mask_or = 2 },
	}
	assert_eq(lint.rejected_layouts(cap, 1, false, { [1] = true }), 1)
	assert_eq(lint.rejected_layouts(cap, 3, false, {}), 3)
	assert_eq(lint.rejected_layouts(cap, 3, false, {}, 60), 2)
	assert_eq(lint.rejected_layouts(cap, 3, false, {}, 30000, true), 1)
	assert_eq(lint.rejected_layouts(cap, 3, true, {}), 0)
	assert_eq(lint.rejected_layouts(nil, 3, false, {}), 0)
end)

test("subject_key and refuel_from: trains by negated id; tracking from first sight, never before it began", function()
	assert_eq(lint.subject_key(LINT_SUBJECT_TRAIN, 7), -7)
	assert_eq(lint.subject_key(LINT_SUBJECT_STATION, 7), 7)
	assert_eq(lint.subject_key(LINT_SUBJECT_COMBINATOR, 9), 9)
	storage.stats = { refuel_since = 1000 }
	assert_eq(lint.refuel_from({}), 1000)
	assert_eq(lint.refuel_from({ seen_tick = 500 }), 1000)
	assert_eq(lint.refuel_from({ seen_tick = 5000 }), 5000)
	storage.stats = nil
	assert_eq(lint.refuel_from({ seen_tick = 5000 }), 5000)
end)

test("progress: 0 before a job, the job's share while it runs, nil once a pass completed", function()
	local saved = storage.manager
	storage.manager = {}
	assert_eq(lint.progress(), 0)
	storage.manager.lint = { job = { sids = { 1, 2, 3 }, tids = { 4 }, i = 2, ti = 1 } }
	assert_eq(lint.progress(), 0.75)
	storage.manager.lint.tick = 10
	assert_nil(lint.progress())
	storage.manager = saved
end)
