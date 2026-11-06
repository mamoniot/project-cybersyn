-- The manager filters in scripts/gui/utils/filters.lua: search terms, the filter set and its predicates.

local H = require("harness")

local function filters()
	return H.load("scripts.gui.utils.filters")
end

-- ------------------------------------------------------------------ search and filters

test("search_terms: lowercase whitespace-split words, nil when empty", function()
	local u = filters()
	assert_nil(u.search_terms(nil))
	assert_nil(u.search_terms(""))
	assert_nil(u.search_terms("  \t "))
	assert_eq(u.search_terms("Iron  Ore\tMINE"), { "iron", "ore", "mine" })
	assert_eq(u.search_terms(" a.b (c) "), { "a.b", "(c)" })
end)

test("set query: empty string clears, whitespace-only keeps the query but no terms", function()
	local u = filters()
	local pd = { filters = { query = "x", terms = { "x" } } }
	u.set(pd, "query", "")
	assert_eq(pd.filters, {})
	u.set(pd, "query", "Foo Bar")
	assert_eq(pd.filters, { query = "Foo Bar", terms = { "foo", "bar" } })
	u.set(pd, "query", "   ")
	assert_eq(pd.filters, { query = "   " })
	assert_nil(pd.filter_row_open, "the search is not one of the row's filters")
	u.set(pd, "query", nil)
	assert_eq(pd.filters, {})
end)

test("set: validates, resets every page, opens the row; a stale value clears the filter", function()
	local u = filters()
	storage.stations = { [12] = {} }
	game.surfaces = { [1] = {} }
	game.get_surface = function(i) return game.surfaces[i] end
	local pd = { filters = {}, page = { stations_tab = 3 } }
	u.set(pd, "item", "iron-plate|rare")
	assert_eq(pd.filters.item, "iron-plate|rare")
	assert_true(pd.filter_row_open)
	assert_eq(pd.page, {})
	pd.page.trains_tab = 2
	u.set(pd, "item", "bogus")
	assert_nil(pd.filters.item)
	assert_eq(pd.page, {})
	u.set(pd, "network", "signal-A")
	u.set(pd, "station", 12)
	u.set(pd, "surface", 1)
	u.set(pd, "mask", 4)
	assert_eq(pd.filters, { network = "signal-A", station = 12, surface = 1, mask = 4 })
	u.set(pd, "network", "no-such-signal")
	u.set(pd, "station", 99)
	u.set(pd, "surface", 2)
	u.set(pd, "mask", -1)
	assert_eq(pd.filters, {})
	pd.filter_row_open, pd.page.log_tab = nil, 4
	u.set(pd, "station", nil)
	assert_nil(pd.filter_row_open, "clearing a filter does not open the row")
	assert_eq(pd.page.log_tab, 4, "an unchanged filter keeps the pages")
end)

test("clear: chips, row and all scopes", function()
	local u = filters()
	local function full()
		return { filters = { query = "a", terms = { "a" }, item = "coal", station = 3, train = 5, network = "signal-A",
			mask = 2, surface = 1, stations_chip = "problems", problems_scope = "errors", trains_chip = "parked" },
			page = { stations_tab = 2 } }
	end
	local pd = full()
	u.clear(pd, "chips")
	assert_eq(pd.filters, { query = "a", terms = { "a" }, item = "coal", network = "signal-A", mask = 2, surface = 1 })
	assert_eq(pd.page, {})
	pd = full()
	u.clear(pd, "row")
	assert_eq(pd.filters, { query = "a", terms = { "a" } })
	pd = full()
	u.clear(pd, "all")
	assert_eq(pd.filters, {})
end)

test("active: the row's filters only, not the search or the tab chips", function()
	local u = filters()
	assert_false(u.active({ filters = {} }))
	assert_false(u.active({ filters = { query = "a", terms = { "a" }, stations_chip = "ok", trains_chip = "parked" } }))
	for _, field in ipairs({ "item", "station", "train", "network", "mask", "surface" }) do
		assert_true(u.active({ filters = { [field] = 1 } }), field)
	end
end)

test("validate: drops what no longer resolves, derives missing terms", function()
	local u = filters()
	storage.stations = { [12] = {} }
	game.get_surface = function(i) return i == 1 and {} or nil end
	local pd = { filters = { item = "bogus", network = "signal-A", station = 13, surface = 2, query = "A b" } }
	u.validate(pd)
	assert_eq(pd.filters, { network = "signal-A", query = "A b", terms = { "a", "b" } })
	pd.filters = { item = "coal", station = 12, surface = 1 }
	u.validate(pd)
	assert_eq(pd.filters, { item = "coal", station = 12, surface = 1 })
end)

test("get: each tab gets the stored filters less those it does not apply", function()
	local u = filters()
	local pd = { filters = { terms = { "a" }, item = "coal", station = 3, train = 5, network = "signal-A", mask = 2,
		surface = 1 } }
	local place = { network = "signal-A", mask = 2, surface = 1 }
	local function with(extra)
		local f = H.copy(place)
		for k, v in pairs(extra) do f[k] = v end
		return f
	end
	local all = with({ terms = { "a" }, item = "coal", station = 3 })
	assert_eq(u.get(pd, "inventory_tab"), all)
	assert_eq(u.get(pd, "stations_tab"), all)
	assert_eq(u.get(pd, "trains_tab"), with({ terms = { "a" }, item = "coal", station = 3, train = 5 }))
	assert_eq(u.get(pd, "overview_tab"), with({ item = "coal" }))
	assert_eq(u.get(pd, "log_tab"), with({ item = "coal", station = 3 }))
	assert_eq(u.get(pd, "utilization_tab"), place)
	assert_eq(u.get(pd, "delivery_breakdown_tab"), with({ item = "coal" }))
	assert_eq(u.get({ filters = {} }, "stations_tab"), { mask = -1 })
	local f = u.get(pd, "stations_tab")
	f.terms = nil
	assert_eq(pd.filters.terms, { "a" }, "a tab may change its copy")
end)

test("signature: differs for every stored field", function()
	local u = filters()
	local sigs = { [u.signature({ filters = {} })] = true }
	for _, field in ipairs({ "query", "item", "station", "train", "network", "mask", "surface", "stations_chip",
		"problems_scope", "trains_chip" }) do
		local s = u.signature({ filters = { [field] = "1" } })
		assert_nil(sigs[s], field)
		sigs[s] = true
	end
end)

test("filters_active: each field and ignore_item", function()
	local u = filters()
	assert_false(u.filters_active({ mask = -1 }))
	assert_true(u.filters_active({ mask = -1, item = "coal" }))
	assert_false(u.filters_active({ mask = -1, item = "coal" }, true))
	assert_true(u.filters_active({ mask = 0 }))
	assert_true(u.filters_active({ mask = -1, terms = { "a" } }))
	assert_true(u.filters_active({ mask = -1, network = "signal-A" }))
	assert_true(u.filters_active({ mask = -1, surface = 1 }))
end)

test("network_passes: no network filter and mask -1 passes everything", function()
	local u = filters()
	local f = { mask = -1 }
	assert_true(u.network_passes(nil, nil, f))
	assert_true(u.network_passes("signal-A", 0, f))
	assert_true(u.network_passes(NETWORK_EACH, {}, f))
end)

test("network_passes: named network", function()
	local u = filters()
	local f = { network = "signal-A", mask = -1 }
	assert_true(u.network_passes("signal-A", 1, f))
	assert_false(u.network_passes("signal-B", 1, f))
	-- A station on the network with mask 0 shares no bit with -1.
	assert_false(u.network_passes("signal-A", 0, f))
	assert_false(u.network_passes("signal-A", { ["signal-A"] = 1 }, f))
	assert_false(u.network_passes(nil, 1, f))
	local f6 = { network = "signal-A", mask = 6 }
	assert_true(u.network_passes("signal-A", 2, f6))
	assert_false(u.network_passes("signal-A", 1, f6))
end)

test("network_passes: each-network stations use their per-network mask", function()
	local u = filters()
	local mask = { ["signal-A"] = 2, ["signal-B"] = 4 }
	assert_true(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = -1 }))
	assert_false(u.network_passes(NETWORK_EACH, mask, { network = "signal-C", mask = -1 }))
	assert_false(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = 1 }))
	assert_true(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = 3 }))
	assert_false(u.network_passes(NETWORK_EACH, 2, { network = "signal-A", mask = -1 }))
end)

test("network_passes: mask only, any network", function()
	local u = filters()
	local f = { mask = 4 }
	assert_true(u.network_passes(NETWORK_EACH, { ["signal-A"] = 1, ["signal-B"] = 4 }, f))
	assert_false(u.network_passes(NETWORK_EACH, { ["signal-A"] = 1 }, f))
	assert_true(u.network_passes("signal-A", 6, f))
	assert_false(u.network_passes("signal-A", 1, f))
	assert_false(u.network_passes("signal-A", nil, f))
end)

local function station(over)
	local st = {
		name_lower = "iron ore mine 1",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		provided = { ["iron-ore"] = 100 },
		requested = { ["coal"] = { count = -10, threshold = 5, active = true } },
		deliveries = { ["stone"] = 20 },
	}
	for k, v in pairs(over or {}) do st[k] = v end
	return st
end

test("station_passes: surface, plain-text AND terms, network, item", function()
	local u = filters()
	local st = station()
	assert_true(u.station_passes(st, { mask = -1 }))
	assert_false(u.station_passes(st, { mask = -1, surface = 2 }))
	assert_true(u.station_passes(st, { mask = -1, surface = 1 }))
	assert_true(u.station_passes(st, { mask = -1, terms = { "iron", "1" } }))
	assert_false(u.station_passes(st, { mask = -1, terms = { "iron", "copper" } }))
	-- Terms are plain substrings: "o.e" would match "ore" as a pattern.
	assert_false(u.station_passes(st, { mask = -1, terms = { "o.e" } }))
	assert_false(u.station_passes(st, { mask = -1, network = "signal-B" }))
	assert_true(u.station_passes(st, { mask = -1, item = "iron-ore" }))
	assert_true(u.station_passes(st, { mask = -1, item = "coal" }))
	assert_true(u.station_passes(st, { mask = -1, item = "stone" }))
	assert_false(u.station_passes(st, { mask = -1, item = "copper-ore" }))
	assert_true(u.station_passes(st, { mask = -1, item = "copper-ore" }, true))
end)

test("row_passes / station_passes: each row its own network and items, deliveries on row 0, the station chip", function()
	local u = filters()
	local st = station({ id = 9, network_mask = 1, requested = {} })
	st.provided = { ["iron-ore"] = 100 }
	st.sources = {
		{ kind = "station", index = 0, unit = 90, ok = true, priority = 0, network_name = "signal-A", mask = 1,
			provided = { ["iron-ore"] = 60 }, requested = {}, ignored = {} },
		{ kind = "inventory", index = 1, unit = 91, ok = true, priority = 2, network_name = "signal-A", mask = 4,
			provided = { ["iron-ore"] = 40 }, requested = { coal = { count = -10, threshold = 1, active = true } }, ignored = {} },
	}
	local rows = require("inventory_fixtures").rows(st).rows
	assert_eq(#rows, 2)
	local r0, r1 = rows[1], rows[2]
	assert_true(u.row_passes(r0, { mask = -1 }))
	assert_true(u.row_passes(r0, { mask = 1, network = "signal-A" }))
	assert_false(u.row_passes(r1, { mask = 1, network = "signal-A" }))
	assert_true(u.row_passes(r1, { mask = 4 }))
	assert_true(u.station_passes(st, { mask = 4 }), "any row")
	assert_false(u.station_passes(st, { mask = 8 }))
	-- Items: each row its own lists; the station's deliveries (stone) count on its first row only.
	assert_false(u.row_passes(r0, { mask = -1, item = "coal" }))
	assert_true(u.row_passes(r1, { mask = -1, item = "coal" }))
	assert_true(u.row_passes(r0, { mask = -1, item = "stone" }))
	assert_false(u.row_passes(r1, { mask = -1, item = "stone" }))
	assert_true(u.row_passes(r1, { mask = -1, item = "stone" }, true))
	assert_true(u.station_passes(st, { mask = -1, item = "coal" }))
	assert_false(u.station_passes(st, { mask = 1, item = "coal" }), "coal is requested on bit 3 only")
	-- Station-wide fields hold for every row.
	assert_false(u.row_passes(r1, { mask = -1, surface = 2 }))
	assert_false(u.row_passes(r1, { mask = -1, terms = { "copper" } }))
	assert_true(u.row_passes(r1, { mask = -1, station = 9 }))
	assert_false(u.row_passes(r1, { mask = -1, station = 10 }))
	assert_false(u.station_passes(st, { mask = -1, station = 10 }))
	-- An unread inventory (no mask) passes only without a network filter.
	r1.mask = nil
	assert_true(u.row_passes(r1, { mask = -1 }))
	assert_false(u.row_passes(r1, { mask = 4 }))
end)

test("filter_signature: the station chip field", function()
	local u = filters()
	local a = u.filter_signature({ mask = -1 })
	assert_true(a ~= u.filter_signature({ mask = -1, station = 12 }))
end)

local function with_snapshot_stations(stations)
	local snapshot = require("scripts.gui.collector").empty()
	snapshot.stations = stations
	storage.manager = { players = {}, snapshot = snapshot, collect_log = { epoch = 1, base = 0, ids = {} } }
end

test("train_terms_pass: depot, provider and requester names; every term must hit one", function()
	local u = filters()
	with_snapshot_stations({ [1] = { name_lower = "iron mine" }, [2] = { name_lower = "smelter in" } })
	local tr = { depot_name = "Depot North", p_station_id = 1, r_station_id = 2 }
	assert_true(u.train_terms_pass(tr, { "depot" }))
	assert_true(u.train_terms_pass(tr, { "north", "mine" }))
	assert_true(u.train_terms_pass(tr, { "smelter" }))
	assert_false(u.train_terms_pass(tr, { "copper" }))
	assert_false(u.train_terms_pass(tr, { "mine", "copper" }))
	assert_true(u.train_terms_pass(tr, {}))
	assert_false(u.train_terms_pass({ depot_name = "", p_station_id = 9 }, { "x" }))
end)

test("train_passes: surface, network, manifest item, terms", function()
	local u = filters()
	with_snapshot_stations({ [1] = { name_lower = "iron mine" } })
	local tr = {
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		manifest_hashes = { ["iron-plate"] = 50 },
		depot_name = "Depot",
		p_station_id = 1,
	}
	assert_true(u.train_passes(tr, { mask = -1 }))
	assert_false(u.train_passes(tr, { mask = -1, surface = 2 }))
	assert_false(u.train_passes(tr, { mask = -1, network = "signal-B" }))
	assert_true(u.train_passes(tr, { mask = -1, item = "iron-plate" }))
	assert_false(u.train_passes(tr, { mask = -1, item = "coal" }))
	assert_true(u.train_passes(tr, { mask = -1, item = "coal" }, true))
	assert_true(u.train_passes(tr, { mask = -1, terms = { "mine" } }))
	assert_false(u.train_passes(tr, { mask = -1, terms = { "smelter" } }))
end)

test("the train chip: set validates against Cybersyn's trains, only that train passes, no '#<id>' search", function()
	local u = filters()
	storage.trains = { [5] = {} }
	local pd = { filters = {} }
	u.set(pd, "train", 7)
	assert_nil(pd.filters.train, "not a Cybersyn train")
	u.set(pd, "train", 5)
	assert_eq(pd.filters.train, 5)
	assert_true(pd.filter_row_open, "a train chip opens the row, so closing the row clears it")
	with_snapshot_stations({})
	local function tr(id) return { id = id, manifest_hashes = {}, depot_name = "Depot" } end
	local f = u.get(pd, "trains_tab")
	assert_true(u.filters_active(f))
	assert_true(u.train_passes(tr(5), f))
	assert_false(u.train_passes(tr(6), f))
	assert_true(u.filter_signature(f) ~= u.filter_signature({ mask = -1 }))
	assert_false(u.train_terms_pass(tr(5), { "#5" }), "the search is text only")
	storage.trains[5] = nil
	u.validate(pd)
	assert_nil(pd.filters.train, "a train that is gone drops its chip")
end)
