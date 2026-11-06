-- An inventory combinator's red I. The planner records a failed request per stop: any failed request
-- of the station lights the station combinator's red S (display_state bit 2), and one made by an
-- inventory's stop also lights that combinator's red I (`station.inv_failed[unit]`, operation OR). Driven through the
-- real `tick` (poll, then dispatch) against fake combinators.

local H = require("harness")

local F = require("planner_fixtures")
local sig, op, station, world, pass, NET = F.sig, F.op, F.station, F.world, F.pass, F.NET

test("is_secondary_inventory_op: AND and OR are one mode, nothing else is", function()
	assert_eq({ is_secondary_inventory_op("AND"), is_secondary_inventory_op("OR"), is_secondary_inventory_op("/"),
		is_secondary_inventory_op("^"), is_secondary_inventory_op(nil) }, { true, true, false, false, false })
	assert_eq(MODE_SECONDARY_INVENTORY_FAILED, "OR")
end)

test("get_comb_gui_settings: the red S and red I variants read as their mode", function()
	local function mode(o) return (get_comb_gui_settings(F.comb(1, o, { list = {} }))) end
	assert_eq({ mode(MODE_PRIMARY_IO_FAILED_REQUEST), mode(MODE_PRIMARY_IO_ACTIVE), mode(MODE_SECONDARY_INVENTORY_FAILED),
		mode(MODE_DEPOT) }, { MODE_PRIMARY_IO, MODE_PRIMARY_IO, MODE_SECONDARY_INVENTORY, MODE_DEPOT })
end)

test("no provider: only the inventory that requests shows the red I; the station shows the red S as before", function()
	H.fresh()
	local inv = { list = { sig("iron-plate", -5000) } }
	local st = station(100, { list = { NET } }, { [201] = inv, [202] = { list = {} } })
	local map_data = world({ st })
	pass(map_data)
	assert_eq(st.inv_failed, { [201] = true })
	assert_eq({ op(st.secondary_inv_combs[201]), op(st.secondary_inv_combs[202]), op(st.entity_comb1), st.display_state },
		{ "OR", "AND", "^", 2 })

	-- Still unserved: unchanged. Then it stops requesting: cleared on the next poll, the I goes cyan.
	pass(map_data)
	assert_eq(op(st.secondary_inv_combs[201]), "OR")
	inv.list = {}
	pass(map_data)
	assert_nil(st.inv_failed, "an empty set is dropped")
	assert_eq({ op(st.secondary_inv_combs[201]), op(st.entity_comb1), st.display_state }, { "AND", "/", 0 })
end)

test("the station combinator's own failure lights its S, not the inventory's I; the S clears with the whole station", function()
	H.fresh()
	local own = { list = { NET, sig("copper-plate", -5000) } }
	local inv = { list = {} }
	local st = station(100, own, { [201] = inv })
	local map_data = world({ st })
	pass(map_data)
	assert_eq({ op(st.entity_comb1), st.inv_failed, op(st.secondary_inv_combs[201]) }, { "^", nil, "AND" })

	-- The station combinator stops requesting while its inventory starts: the station still has an unserved request,
	-- so the S stays red, and the I lights.
	own.list = { NET }
	inv.list = { sig("iron-plate", -5000) }
	pass(map_data)
	assert_eq({ op(st.entity_comb1), st.display_state, st.inv_failed, op(st.secondary_inv_combs[201]) },
		{ "^", 2, { [201] = true }, "OR" })

	-- The station requests again while the inventory stops: the I goes out, the S stays red.
	own.list = { NET, sig("copper-plate", -5000) }
	inv.list = {}
	pass(map_data)
	assert_eq({ op(st.entity_comb1), st.inv_failed, op(st.secondary_inv_combs[201]) }, { "^", nil, "AND" })
end)

test("no requester can take a train: every listed inventory stop goes red, the station's own stop goes red", function()
	H.fresh()
	-- The requester is at its train limit (0), so the dispatcher finds no requester and marks every listed one.
	local req = station(100, { list = { NET, sig("iron-plate", -5000) } }, { [201] = { list = { sig("iron-plate", -5000) } } },
		{ is_p = false })
	req.entity_stop.trains_limit = 0
	local prov = station(300, { list = { NET, sig("iron-plate", 9000) } }, nil, { is_r = false })
	local map_data = world({ req, prov })
	pass(map_data)
	assert_eq({ req.inv_failed, op(req.secondary_inv_combs[201]), op(req.entity_comb1) }, { { [201] = true }, "OR", "^" })
	assert_eq({ prov.inv_failed, op(prov.entity_comb1) }, { nil, "/" })
end)

test("a provider but no train (an evaluated requester fails): the inventory's I and the station's S light", function()
	H.fresh()
	-- Only the inventory requests, so the requester is evaluated and fails on the missing train (not skipped).
	local req = station(100, { list = { NET } }, { [201] = { list = { sig("iron-plate", -5000) } } }, { is_p = false })
	local prov = station(300, { list = { NET, sig("iron-plate", 9000) } }, nil, { is_r = false })
	local map_data = world({ req, prov })
	local surfaces = Surfaces
	Surfaces = { find_surface_connections_masked = function() return {} end }
	local ok, err = pcall(pass, map_data)
	Surfaces = surfaces
	assert(ok, err)
	assert_eq({ req.inv_failed, op(req.secondary_inv_combs[201]), op(req.entity_comb1), req.display_state },
		{ { [201] = true }, "OR", "^", 2 })
	assert_eq({ prov.inv_failed, op(prov.entity_comb1) }, { nil, "/" })
end)

test("a station from an older save (no inv_failed) polls and fails like a new one", function()
	H.fresh()
	local st = station(100, { list = { NET } }, { [201] = { list = { sig("iron-plate", -5000) } } })
	st.inv_failed = nil
	local map_data = world({ st })
	pass(map_data)
	assert_eq(st.inv_failed, { [201] = true })
end)

test("update_inv_display: follows the bit, leaves a combinator in another mode and a missing one alone", function()
	H.fresh()
	local st = station(100, { list = {} }, { [201] = { list = {} }, [202] = { list = {} } })
	st.secondary_inv_combs[202].get_or_create_control_behavior().parameters.operation = MODE_SECONDARY_IO
	st.inv_failed = { [201] = true, [202] = true }
	update_inv_display({}, st, 201)
	update_inv_display({}, st, 202)
	update_inv_display({}, st, 999)
	assert_eq({ op(st.secondary_inv_combs[201]), op(st.secondary_inv_combs[202]) }, { "OR", "%" })
	st.inv_failed = nil
	update_inv_display({}, st, 201)
	assert_eq(op(st.secondary_inv_combs[201]), "AND")
end)
