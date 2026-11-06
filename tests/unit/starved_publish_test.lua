-- The starved set the planner publishes at the end of its poll, which the manager reads as is.

local H = require("harness")
local F = require("planner_fixtures")
local sig, station, world = F.sig, F.station, F.world

local function poll(map_data)
	map_data.tick_state = STATE_POLL_STATIONS
	map_data.tick_data = {}
	for _ = 1, 20 do
		tick(map_data, F.SETTINGS)
		if map_data.tick_state ~= STATE_POLL_STATIONS then return end
	end
	error("the planner did not finish polling")
end

test("starved: published once per cycle, as of the end of the poll, and kept while dispatch consumes the economy", function()
	H.fresh()
	local req = station(100, { list = { F.NET, sig("coal", -5000), sig("iron-plate", -5000) } }, nil, { is_p = false })
	local prov = station(300, { list = { F.NET, sig("iron-plate", 9000) } }, nil, { is_r = false })
	local map_data = world({ req, prov })
	map_data.economy.starved = { ["signal-A:stale"] = true }
	poll(map_data)
	local published = map_data.economy.starved
	assert_eq(published, { ["signal-A:coal"] = true })
	local surfaces = Surfaces
	Surfaces = { find_surface_connections_masked = function() return {} end }
	F.pass(map_data)
	Surfaces = surfaces
	assert_eq(#map_data.economy.all_names, 0)
	assert_eq(map_data.economy.starved, { ["signal-A:coal"] = true })
end)
