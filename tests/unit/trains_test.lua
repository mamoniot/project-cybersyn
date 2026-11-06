-- The Trains query pipeline (scripts/gui/trains.lua): sort keys per column, the id tiebreak and the global filters.
-- These orders pin the tiebreak every util.sort_by caller shares.

local H = require("harness")

local function tr(id, over)
	local r = {
		id = id,
		network_name = "signal-A",
		network_mask = 1,
		manifest = {},
		manifest_hashes = {},
		depot_name = "",
		surface_index = 1,
		is_available = false,
	}
	for k, v in pairs(over) do r[k] = v end
	return r
end

local MAP_DATA = { layouts = { [1] = { 0, 1, 1 }, [2] = { 0, 1 }, [3] = { 0, 0, 1 } } }

local function setup()
	local trains_tab = H.load("scripts.gui.trains")
	local collector = require("scripts.gui.collector")
	storage.manager = { players = {} }
	collector.init()
	storage.stations = {}
	storage.refuelers = { [20] = { entity_stop = { valid = true, backer_name = "Fuel" } } }
	local snap = collector.get()
	snap.stations = {
		[10] = { id = 10, name = "Iron Mine", name_lower = "iron mine" },
		[11] = { id = 11, name = "Alpha", name_lower = "alpha" },
	}
	snap.trains = {
		[1] = tr(1, { status = STATUS_D, depot_name = "Depot B", layout_id = 1 }),
		[2] = tr(2, { status = STATUS_TO_P, p_station_id = 10, depot_name = "Depot A", layout_id = 2, manifest_hashes = { ["iron-ore"] = 200 } }),
		[3] = tr(3, {
			status = STATUS_TO_R, r_station_id = 11, depot_name = "Depot A", layout_id = 1, network_name = "signal-B",
			manifest_hashes = { coal = 50, stone = 50 }, surface_index = 2,
		}),
		[4] = tr(4, {
			status = STATUS_TO_P, p_station_id = 11, depot_name = "depot a", network_name = NETWORK_EACH,
			network_mask = { ["signal-A"] = 1 }, manifest_hashes = { ["iron-ore"] = 200 },
		}),
		[5] = tr(5, {}),
		[6] = tr(6, { status = STATUS_F, refueler_id = 20, depot_name = "Depot C", layout_id = 3, network_mask = 3 }),
	}
	snap.trains[5].network_name = nil
	return trains_tab
end

local function order(pd)
	local trains_tab = setup()
	local rows = trains_tab.query(MAP_DATA, H.player_data(pd))
	local out = {}
	for i, r in ipairs(rows) do out[i] = r.id end
	return out
end

local function sorted(column, ascending)
	return order({ sort = { trains_tab = { column = column, ascending = ascending } }, filters = {} })
end

test("query: default sort is train id ascending", function()
	local pd = { filters = {} }
	assert_eq(order(pd), { 1, 2, 3, 4, 5, 6 })
	assert_eq(pd.sort.trains_tab, { column = "train_id", ascending = true })
	assert_eq(sorted("train_id", false), { 6, 5, 4, 3, 2, 1 })
	assert_eq(sorted("bogus", true), { 1, 2, 3, 4, 5, 6 })
end)

test("query: status sorts by status code, then target name; no status last", function()
	-- Depot B, Alpha, Iron Mine (both fetching), Alpha (delivering), Fuel (refuelling), none.
	assert_eq(sorted("train_status", true), { 1, 4, 2, 3, 6, 5 })
	assert_eq(sorted("train_status", false), { 5, 6, 3, 2, 4, 1 })
end)

test("query: network sorts by name and mask; nil last in both directions, ties by id", function()
	assert_eq(sorted("network", true), { 1, 2, 6, 3, 4, 5 })
	assert_eq(sorted("network", false), { 4, 3, 6, 1, 2, 5 })
end)

test("query: layout sorts shorter trains first; trains without a layout last", function()
	-- Carriage count first: the two-carriage layout 2 sorts before "001" although "01" > "001" as strings.
	assert_eq(sorted("layout", true), { 2, 6, 1, 3, 4, 5 })
	assert_eq(sorted("layout", false), { 1, 3, 6, 2, 4, 5 })
end)

test("query: depot sorts by lowercase depot name, ties by id", function()
	assert_eq(sorted("depot", true), { 5, 2, 3, 4, 1, 6 })
	assert_eq(sorted("depot", false), { 6, 1, 2, 3, 4, 5 })
end)

test("query: shipment sorts by total amount; empty trains last", function()
	assert_eq(sorted("shipment", true), { 3, 2, 4, 1, 5, 6 })
	assert_eq(sorted("shipment", false), { 2, 4, 3, 1, 5, 6 })
end)

test("query: filters by item, station-name terms, network and surface", function()
	assert_eq(order({ filters = { item = "iron-ore" } }), { 2, 4 })
	assert_eq(order({ filters = { query = "alpha", terms = { "alpha" } } }), { 3, 4 })
	assert_eq(order({ filters = { query = "depot a", terms = { "depot", "a" } } }), { 2, 3, 4 })
	assert_eq(order({ filters = { network = "signal-A" } }), { 1, 2, 4, 6 })
	assert_eq(order({ filters = { mask = 2 } }), { 6 })
	assert_eq(order({ filters = { surface = 2 } }), { 3 })
end)

test("query: the context resolves target names from the snapshot and refuelers", function()
	local trains_tab = setup()
	local rows, snap, ctx = trains_tab.query(MAP_DATA, H.player_data({}))
	assert_eq(#rows, 6)
	assert_same(snap, require("scripts.gui.collector").get())
	assert_eq({ ctx.names(snap.trains[2], "station", 10) }, { "Iron Mine", "iron mine" })
	assert_eq({ ctx.names(snap.trains[6], "refueler", 20) }, { "Fuel", "fuel" })
	assert_eq({ ctx.names(snap.trains[6], "station", 99) }, {})
	assert_eq({ ctx.names(snap.trains[1], "depot") }, { "Depot B", "depot b" })
	-- Composition strings for the Layout column and its tooltip icons.
	assert_eq(ctx.comps[2], "L<C>")
	assert_eq(ctx.comps[3], "LL<C>")
	assert_eq(ctx.icons[2], "[item=locomotive][item=cargo-wagon]")
end)
