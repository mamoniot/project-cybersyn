-- The predicates in scripts/gui/utils/filters.lua (the Overview's filters, the surface default's station check),
-- name_cell.fit and the tile count format.

local H = require("harness")

local function filters() return H.load("scripts.gui.utils.filters") end

local function station(surface, network, mask)
	return { entity_stop = { valid = true, surface_index = surface }, network_name = network, network_mask = mask }
end

test("the Overview's filters: the station search never applies, the rest maps from player_data", function()
	local u = filters()
	local f = u.get({ filters = { query = "iron", terms = { "iron" }, network = "signal-A", mask = 2, surface = 3 } },
		"overview_tab")
	assert_eq(f, { network = "signal-A", mask = 2, surface = 3 })
	assert_true(u.place_filters_active(f))
	assert_false(u.place_filters_active(u.get({ filters = {} }, "overview_tab")))
end)

test("filter_signature: differs for every field, equal for equal filters", function()
	local u = filters()
	local base = { mask = -1 }
	local sigs = {}
	for _, f in ipairs({ base, { mask = 2 }, { mask = -1, surface = 1 }, { mask = -1, network = "signal-A" },
		{ mask = -1, item = "iron-plate" }, { mask = -1, terms = { "a" } } }) do
		local s = u.filter_signature(f)
		assert_eq(sigs[s], nil, s)
		sigs[s] = true
	end
	assert_eq(u.filter_signature({ mask = -1 }), u.filter_signature(base))
end)

test("requester_passes: the snapshot record decides, the live station while collecting, a gone one only unfiltered", function()
	local u = filters()
	storage.stations = { [7] = station(2, "signal-B", 1) }
	local stations = { [5] = { surface_index = 1, network_name = "signal-A", network_mask = 1 } }
	local all = { mask = -1 }
	assert_true(u.requester_passes(5, stations, all))
	assert_true(u.requester_passes(99, stations, all))
	assert_true(u.requester_passes(5, stations, { mask = -1, surface = 1 }))
	assert_false(u.requester_passes(5, stations, { mask = -1, surface = 2 }))
	assert_true(u.requester_passes(5, stations, { mask = -1, network = "signal-A" }))
	assert_false(u.requester_passes(5, stations, { mask = -1, network = "signal-B" }))
	assert_false(u.requester_passes(5, stations, { mask = 2 }))
	assert_true(u.requester_passes(7, stations, { mask = -1, surface = 2, network = "signal-B" }))
	assert_false(u.requester_passes(7, stations, { mask = -1, surface = 1 }))
	assert_false(u.requester_passes(99, stations, { mask = -1, surface = 1 }))
	storage.stations[7].entity_stop.valid = false
	assert_false(u.requester_passes(7, stations, { mask = -1, surface = 2 }))
end)

test("surface_has_station: any valid stop on the surface", function()
	local u = filters()
	storage.stations = { [1] = station(2, "signal-A", 1), [2] = { entity_stop = { valid = false, surface_index = 3 } } }
	assert_true(u.surface_has_station(2))
	assert_false(u.surface_has_station(1))
	assert_false(u.surface_has_station(3))
end)

test("name_cell.fit: lead icons give way first when the text would get less than 120 px", function()
	local nc = H.load("scripts.gui.name-cell")
	local parts = { text = "Requestor for", lead = { "item/a", "item/b" }, lead_quality = { [1] = "rare" },
		tail = { "fluid/c" } }
	assert_true(nc.fit(parts, 400) == parts)
	local fitted = nc.fit(parts, 180)
	assert_eq(fitted, { text = "Requestor for", tail = { "fluid/c" } })
	assert_eq(parts.lead[2], "item/b")
	assert_eq(nc.fit(nil, 10), nil)
	local plain = { text = "x", tail = { "item/a" } }
	assert_true(nc.fit(plain, 10) == plain)
end)

test("text.count: exact below 10,000, k/M above, never cut", function()
	local text = H.load("scripts.gui.unserved-text")
	assert_eq(text.count(nil), "–")
	assert_eq(text.count(0), "0")
	assert_eq(text.count(9999), "9,999")
	assert_eq(text.count(12345), "12.3k")
	assert_eq(text.count(20000), "20k")
	assert_eq(text.count(1500000), "1.5M")
	assert_eq(text.count(2500000000), "2.5G")
	assert_eq(text.count(-12345), "-12.4k")
end)
