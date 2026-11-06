-- Stop-name helpers shared by the Log, Overview and Stations tabs (scripts/gui/name-cell.lua).

local H = require("harness")

local function nc()
	return H.load("scripts.gui.name-cell")
end

local function stop(name, valid)
	return { valid = valid ~= false, backer_name = name }
end

test("station_view: snapshot first, then depot and refueler stops; gone stops are nil and cached as such", function()
	local n = nc()
	storage.stations = {}
	storage.depots = { [2] = { entity_stop = stop("[item=iron-plate] Depot") } }
	storage.refuelers = { [3] = { entity_stop = stop("Fuel", false) } }
	local parts = { text = "Snap" }
	local stations = { [1] = { name = "Snap full", name_parts = parts } }
	local v, st = n.station_view(1, stations)
	assert_eq(v, { name = "Snap full", text = "Snap", parts = parts, kind = "station" })
	assert_eq(st, stations[1])
	local cache = {}
	local d = n.station_view(2, stations, cache)
	assert_eq(d.kind, "depot")
	assert_eq(d.text, "Depot")
	assert_eq(cache[2], d)
	assert_eq(n.station_view(3, stations, cache), nil)
	assert_eq(cache[3], false)
	assert_eq(n.station_view(0, stations), nil)
	assert_eq(n.station_view(nil, stations), nil)
end)

test("station_tooltip: bold name, the optional line, the link footer", function()
	local n = nc()
	local links = require("scripts.gui.utils.links")
	assert_eq(n.station_tooltip(nil), "")
	assert_eq(n.station_tooltip({ name = "A" }, "x"),
		{ "", "[font=default-semibold]", "A", "[/font]", "\n", "x", "\n", links.LINK_FOOTER })
	assert_eq(n.station_tooltip({ name = "A" }), { "", "[font=default-semibold]", "A", "[/font]", "\n", links.LINK_FOOTER })
end)

test("unknown icon qualities are dropped, so a sprite-button never gets one the game lacks", function()
	local n = nc()
	local parts = {
		text = "X",
		lead = { "item/iron-plate", "item/copper-plate" },
		lead_quality = { [1] = "foo", [2] = "rare" },
	}
	local def = n.def(parts, "[item=iron-plate,quality=foo][item=copper-plate,quality=rare] X", { kind = "stop", id = 1 }, 400, "", "s")
	assert_eq(def[1].type, "sprite-button")
	assert_eq(def[1].quality, nil)
	assert_eq(def[2].quality, "rare")

	local added = {}
	local flow = { children = { { valid = true, style = {} } } }
	function flow.add(d)
		local elem = { sprite = d.sprite, quality = d.quality }
		added[#added + 1] = elem
		return elem
	end
	n.write_pooled(flow, {}, parts, "X", 400)
	assert_eq(#added, 2)
	assert_eq(added[1].quality, nil)
	assert_eq(added[2].quality, "rare")
end)
